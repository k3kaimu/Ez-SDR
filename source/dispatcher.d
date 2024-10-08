module dispatcher;

import std.stdio;
import controller;
import device;
import utils;
import multithread;
import std.exception;
import std.regex;


class MessageDispatcher
{
    alias dbg = debugMsg!"MessageDispatcher";

    this(LocalRef!(shared(IDevice))[string] devices, IController[string] controllers)
    {
        this.devs = devices;
        this.ctrls = controllers;
    }


    void dispatchToServer(scope const(char)[] target, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        dbg.writefln("msgbuf.length = %s", msgbuf.length);
        dbg.writefln("msgbuf = %s", msgbuf);

        auto reader = BinaryReader(msgbuf);
        scope msgtypeid = reader.tryDeserialize!ubyte;
        if(msgtypeid.isNull) {
            dbg.writefln("[Error] cannot read msgtypeid");
            return;
        }

        switch(msgtypeid.get) {
        case 0b00000000:    // 設定ファイルを返す
            enforce(0, "This command is not implemented yet.");
            break;

        case 0b00000001:    // regexに一致するコントローラを動かす
            scope const(char)[] targetRegexString = reader.tryDeserializeArray!char.enforceIsNotNull("[Error] Cannot deserialize target regex string.").get;
            auto re = regex(targetRegexString);
            foreach(string tag, IController c; ctrls) {
                if(tag.matchFirst(re)) {
                    c.resumeDeviceThreads();
                    dbg.writefln("Controller '%s' is resumed.", tag);
                }
            }
            break;

        case 0b00000010:    // regexに一致するコントローラを止める
            scope const(char)[] targetRegexString = reader.tryDeserializeArray!char.enforceIsNotNull("[Error] Cannot deserialize target regex string.").get;
            auto re = regex(targetRegexString);
            foreach(string tag, IController c; ctrls) {
                if(tag.matchFirst(re)) {
                    c.pauseDeviceThreads();
                    dbg.writefln("Controller '%s' is stopped.", tag);
                }
            }
            break;

        case 0b00000011:    // すべてのコントローラーを動かす
            foreach(t, c; ctrls)
                c.resumeDeviceThreads();
            break;
        case 0b00000100:    // すべてのコントローラーを止める
            foreach(t, c; ctrls)
                c.pauseDeviceThreads();
            break;
        default:
            dbg.writefln("msgtype = %s is not supported.", msgbuf[0]);
            break;
        }
    }


    void dispatchToAllCtrls(scope const(char)[] tag, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        foreach(t, c; ctrls)
            c.processMessage(msgbuf, writer);
    }


    void dispatchOtherRegex(scope const(char)[] tag, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        if(auto c = tag in ctrls)
            c.processMessage(msgbuf, writer);
        else if(auto d = tag in devs)
        {
            if(msgbuf.length == 0) return;
            switch(msgbuf[0]) {
            case 0b00000010:    // SetParam
                writefln("[WARNIGN] SetParam does not implemented yet.");
                break;
            case 0b00000011:    // GetParam
                writefln("[WARNIGN] GetParam does not implemented yet.");
                break;
            default:
                dbg.writefln("msgtype = %s is not supported.", msgbuf[0]);
                break;
            }
        }
        else
            writefln("[WARNIGN] cannot find tag '%s'", tag);
    }


    void dispatchToDevice(ref LocalRef!(shared(IDevice)) dev, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        // writeln("[WARNIGN] dispatchToDevice is not implemented yet.");
        dbg.writefln("msgbuf.length = %s", msgbuf.length);
        if(msgbuf.length == 0) return;

        auto reader = BinaryReader(msgbuf[1 .. $]);
        dbg.writefln("msgbuf = %s", msgbuf);


        switch(msgbuf[0]) {
        case 0b00000000:        // setParam
            size_t keylen = reader.read!ulong;
            dbg.writefln("keylen = %s", keylen);
            const(char)[] key = reader.readArray!char(keylen);
            dbg.writefln("key = %s", key);
            size_t valuelen = reader.read!ulong;
            dbg.writefln("valuelen = %s", valuelen);
            const(char)[] value = reader.readArray!char(valuelen);
            dbg.writefln("value = %s", value);
            
            dev.get.setParam(key, value, null);
            break;
        case 0b00000001:        // getParam
            size_t keylen = reader.read!ulong;
            dbg.writefln("keylen = %s", keylen);
            const(char)[] key = reader.readArray!char(keylen);
            dbg.writefln("key = %s", key);

            const(char)[] ret = dev.get.getParam(key, null);
            {
                ulong[1] len = [ret.length];
                writer(cast(ubyte[]) len[]);
            }
            writer(cast(ubyte[]) ret);
            break;
        case 0b00000010:        // query
            size_t qslen = reader.read!ulong;
            dbg.writefln("qslen = %s", qslen);
            const(char)[] qs = reader.readArray!char(qslen);
            dbg.writefln("qs = %s", qs);

            dev.get.query(cast(ubyte[]) qs, writer);
            break;
        default:
            dbg.writefln("msgtype = %s is not supported.", msgbuf[0]);
            break;
        }
    }


    void dispatch(scope const(char)[] target, scope const(ubyte)[] msgbuf, scope void delegate(scope const(ubyte)[]) writer)
    {
        if(target.length == 0) return;

        if(target == "@allctrls") {
            this.dispatchToAllCtrls(target, msgbuf, writer);
        } else if(target == "@server") {
            this.dispatchToServer(target, msgbuf, writer);
        } else if(target == "@alldevs") {
            foreach(string key, LocalRef!(shared(IDevice)) d; devs)
                this.dispatchToDevice(d, msgbuf, writer);
        } else if(target[0] == '/') {
            this.dispatchOtherRegex(target[1 .. $], msgbuf, writer);
        } else if(auto pdev = target in devs) {
            this.dispatchToDevice(*pdev, msgbuf, writer);
        } else if(auto pctrl = target in ctrls) {
            pctrl.processMessage(msgbuf, writer);
        } else {
            writefln("Invalid target '%s'", target);
        }
    }


  private:
    LocalRef!(shared(IDevice))[string] devs;
    IController[string] ctrls;
}