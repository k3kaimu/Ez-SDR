module settingfile;

import std.json;
import std.exception : enforce;
import std.algorithm : startsWith, endsWith;
import std.conv : to;
import std.ascii : isDigit, isAlpha;
import std.stdio;
import std.math : isNaN;


JSONValue[string] parseSettingFile(JSONValue[string] json)
{
    static
    JSONValue recursiveParse(JSONValue json, JSONValue[string] consts, ref bool updated)
    {
        if(json.type == JSONType.string) {
            auto str = json.str;
            if(str.startsWith("!COMPUTE(") && str.endsWith(")")) {
                auto expr = str[9 .. $ - 1];
                
                bool allConstsEvaluated;
                double evalResult = evaluateExpression(expr, consts, allConstsEvaluated);
                if(!allConstsEvaluated) {
                    // 定数の中にまだ評価されていないものがある場合は今回は諦めてスキップする
                    return json;
                } else {
                    updated = true;
                    return JSONValue(evalResult);
                }
            } else if(str.startsWith("!") && str.length >= 2 && isAlpha(str[1])) {
                debug writeln("Expanding constant for string: ", str);
                auto key = str[1 .. $];
                if(key in consts) {
                    if(isNotYetEvaluated(consts[key])) {
                        debug writeln("Constant ", key, " is not yet evaluated.");
                        // 定数自体がまだ評価されていない場合は今回は諦めてスキップする
                        return json;
                    } else {
                        updated = true;
                        debug writeln("Expanded constant: ", key, " -> ", consts[key]);
                        return consts[key];
                    }
                } else {
                    throw new Exception("Undefined constant: " ~ key);
                }
            }

            return json;
        }
        else if(json.type == JSONType.object) {
            JSONValue[string] result;
            foreach(k, v; json.object) {
                result[k] = recursiveParse(v, consts, updated);
            }
            return JSONValue(result);
        }
        else if(json.type == JSONType.array) {
            JSONValue[] result;
            foreach(v; json.array) {
                result ~= recursiveParse(v, consts, updated);
            }
            return JSONValue(result);
        }
        else {
            return json;
        }
    }


    // 再帰的に展開を繰り返す．また，定数展開や計算式展開が行われなくなるまで繰り返す
    while(1) {
        JSONValue[string] consts;
        if("CONSTANTS" in json) {
            enforce(json["CONSTANTS"].type == JSONType.object, "In the setting file, 'CONSTANTS' must be an object");
            consts = json["CONSTANTS"].object;
        }

        bool updated = false;
        json = recursiveParse(JSONValue(json), consts, updated).object;
        if(!updated) break;
    }

    return json;
}

unittest
{
    JSONValue[string] json;
    json["CONSTANTS"] = JSONValue([
        "A": JSONValue(10),
        "B": JSONValue(5),
        "C": JSONValue("!COMPUTE(A * B)"),
    ]);

    json["value1"] = JSONValue("!A");
    json["value2"] = JSONValue("!COMPUTE(A + B * 2)");
    json["nested"] = JSONValue([
        "value3": JSONValue("!COMPUTE((C - B) / 5)")
    ]);

    auto parsed = parseSettingFile(json);

    writeln(parsed);

    assert(parsed["value1"].get!double == 10);
    assert(parsed["value2"].get!double == 20);
    assert(parsed["nested"]["value3"].get!double == 9);
    assert(parsed["CONSTANTS"]["C"].get!double == 50);
}

private
bool isNotYetEvaluated(JSONValue jv)
{
    if(jv.type == JSONType.string) {
        auto str = jv.str;
        return (str.startsWith("!") && str.length >= 2 && isAlpha(str[1])) ||
                (str.startsWith("!COMPUTE(") && str.endsWith(")"));
    }

    return false;
}


private
void skipWhitespace(ref string expr) {
    while(expr.length > 0 && expr[0] == ' ') {
        expr = expr[1 .. $];
    }
}


double evaluateExpression(string expr, JSONValue[string] consts, ref bool allConstsEvaluated) {
    allConstsEvaluated = true;
    return parseExpression(expr, consts, allConstsEvaluated);
}


private
double parseExpression(ref string expr, JSONValue[string] consts, ref bool allConstsEvaluated) {
    debug writeln("Parsing expression from: ", expr);
    double x = parseTerm(expr, consts, allConstsEvaluated);
    while(expr.length > 0) {
        if(expr[0] == '+') { expr = expr[1 .. $]; x += parseTerm(expr, consts, allConstsEvaluated); }
        else if(expr[0] == '-') { expr = expr[1 .. $]; x -= parseTerm(expr, consts, allConstsEvaluated); }
        else if(expr[0] == ' ') { skipWhitespace(expr); }
        else break;
    }
    return x;
}


private
double parseTerm(ref string expr, JSONValue[string] consts, ref bool allConstsEvaluated) {
    debug writeln("Parsing term from: ", expr);
    double x = parseFactor(expr, consts, allConstsEvaluated);
    while(expr.length > 0) {
        if(expr[0] == '*') { expr = expr[1 .. $]; x *= parseFactor(expr, consts, allConstsEvaluated); }
        else if(expr[0] == '/') { expr = expr[1 .. $]; x /= parseFactor(expr, consts, allConstsEvaluated); }
        else if(expr[0] == ' ') { skipWhitespace(expr); }
        else break;
    }
    return x;
}


private
double parseFactor(ref string expr, JSONValue[string] consts, ref bool allConstsEvaluated) {
    debug writeln("Parsing factor from: ", expr);
    skipWhitespace(expr);

    if(expr.length > 0 && expr[0] == '(') {
        expr = expr[1 .. $]; // '(' を飛ばす
        double x = parseExpression(expr, consts, allConstsEvaluated);
        skipWhitespace(expr);
        enforce(expr[0] == ')', "Mismatched parentheses in expression");
        expr = expr[1 .. $]; // ')' を飛ばす
        return x;
    }
    
    // 数値の読み取り
    int start = 0;
    if(expr.length > 0 && (isDigit(expr[0]) || expr[0] == '-')) {
        start++;
        while (start < expr.length && (isDigit(expr[start]) || expr[start] == '.')) {
            start++;
        }

        debug writeln("Parsed number: ", expr[0 .. start]);
        auto result = to!double(expr[0 .. start]);
        expr = expr[start .. $];  // 読み取った部分を削除
        return result;
    } else {
        // 定数の読み取り
        while(start < expr.length && (isAlpha(expr[start]) || isDigit(expr[start]) || expr[start] == '_')) {
            start++;
        }
        auto key = expr[0 .. start];
        debug writeln("Parsed constant key: ", key);
        if(key in consts) {
            expr = expr[start .. $];  // 読み取った部分を削除
            if(isNotYetEvaluated(consts[key])) {
                allConstsEvaluated = false;
                return double.nan;
            }

            return consts[key].get!double;
        } else {
            throw new Exception("Undefined constant: " ~ key);
        }
    }
}

unittest
{
    bool allConstsEvaluated;
    assert(evaluateExpression("3 + 5 * (2 - 8)", null, allConstsEvaluated) == -27);
    assert(allConstsEvaluated == true);
    
    JSONValue[string] consts;
    consts["A"] = JSONValue(10);
    consts["B"] = JSONValue(2);
    assert(evaluateExpression("A * B + 5", consts, allConstsEvaluated) == 25);
    assert(allConstsEvaluated == true);

    assert(evaluateExpression("(A / B) * (B + 3) - 3", consts, allConstsEvaluated) == 22);
    assert(allConstsEvaluated == true);

    consts["C"] = JSONValue("!COMPUTE(A - 5)");
    assert(evaluateExpression("(A / B) * (B + 3) - C", consts, allConstsEvaluated).isNaN);
    assert(allConstsEvaluated == false);
}