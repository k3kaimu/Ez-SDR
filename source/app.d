//
// Copyright 2010-2012,2014-2015 Ettus Research LLC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

// gdb --args ./multiusrp --tx-args="addr0=192.168.10.211,addr1=192.168.10.212" --rx-args="addr0=192.168.10.213,addr1=192.168.10.214" --tx-rate=1e6 --rx-rate=1e6 --tx-freq=2.45e9 --rx-freq=2.45e9 --tx-gain=10 --rx-gain=30 --clockref=external --timeref=external --timesync=true --tx-channels="0,1" --rx-channels="0,1" --port=8888

import std.complex;
import std.math;
import std.stdio;
import std.path;
import std.format;
import std.string;
import std.getopt;
import std.range;
import std.algorithm;
import std.conv;
import std.exception;
import std.meta;
import std.json;
import uhd.usrp;
import uhd.capi;
import uhd.utils;
import core.time;
import core.thread;
import core.atomic;
import core.memory;

import core.stdc.stdlib;

import binif;
import transmitter;
import receiver;
import msgqueue;

import std.experimental.allocator;

import lock_free.rwqueue;


void main(string[] args)
{
    string config_json;
    short tcpPort = -1;

    // コマンドライン引数指定されたjsonファイルを読み込む
    auto helpInformation1 = getopt(
        args,
        std.getopt.config.passThrough,
        "config_json|c", "read settings from json", &config_json,
        "port", "TCP port", &tcpPort,
    );

    writeln("[multiusrp] Read config json: ", config_json);

    import std.file : read;
    JSONValue[string] settings = parseJSON(cast(const(char)[])read(config_json)).object;
    if("version" !in settings)
        settings = convertSettingJSONFromV1ToV2(settings);

    settings = normalizeSettingJSON(settings);

    if(tcpPort != -1)
        settings["port"] = tcpPort;

    mainImpl!(Complex!float)(settings);
}


void mainImpl(C)(JSONValue[string] settings){
    immutable cpufmt = ("cpufmt" in settings) ? settings["cpufmt"].str : "fc32";
    immutable otwfmt = ("otwfmt" in settings) ? settings["otwfmt"].str : "sc16";

    if(is(C == Complex!float))
        enforce(cpufmt == "fc32");
    else if(is(C == short[2]))
        enforce(cpufmt == "sc16");

    USRP[] txUSRPs, rxUSRPs;
    txUSRPs.length = ("tx" in settings) ? settings["tx"].array.length : 0;
    rxUSRPs.length = ("rx" in settings) ? settings["rx"].array.length : 0;

    immutable(size_t)[][] txChannelList = ("tx" in settings) ? settings["tx"].array.map!`a["channels"].array.map!"cast(immutable)a.get!size_t".array()`.array() : null;
    immutable(size_t)[][] rxChannelList = ("rx" in settings) ? settings["rx"].array.map!`a["channels"].array.map!"cast(immutable)a.get!size_t".array()`.array() : null;

    shared(UniqueMsgQueue!(TxRequest!C, TxResponse!C))[] txMsgQueues;
    shared(UniqueMsgQueue!(RxRequest!C, RxResponse!C))[] rxMsgQueues;

    foreach(i, ref e; txUSRPs) {
        settingTransmitUSRP(e, settings["tx"][i].object);
        txMsgQueues ~= new UniqueMsgQueue!(TxRequest!C, TxResponse!C)();
    }

    foreach(i, ref e; rxUSRPs) {
        settingReceiveUSRP(e, settings["rx"][i].object);
        rxMsgQueues ~= new UniqueMsgQueue!(RxRequest!C, RxResponse!C)();
    }

    {
        writeln("Press Ctrl + C to stop streaming...");
    }

    // kill switch for transmit and receive threads
    shared bool stop_signal_called = false;
    scope(exit)
        stop_signal_called = true;

    writeln("START");

    GC.disable();

    auto event_dg = delegate(){
        scope(exit) {
            writeln("[eventIOLoop] END");
            stop_signal_called = true;
        }

        try {
            auto txCommanders = txMsgQueues.map!"a.makeCommander".array();
            auto rxCommanders = rxMsgQueues.map!"a.makeCommander".array();

            // イベントループを始める
            eventIOLoop!C(stop_signal_called, cast(short)settings["port"].integer, theAllocator, txChannelList.map!"a.length".array(), rxChannelList.map!"a.length".array(), cpufmt, txCommanders, rxCommanders);
        }
        catch(Exception ex){
            writeln(ex);
        }
    };

    auto makeThread(alias fn, T...)(ref shared(bool) stop_signal_called, auto ref T args)
    {
        return new Thread(delegate(){
            scope(exit) stop_signal_called = true;

            try
                fn(stop_signal_called, args);
            catch(Throwable ex){
                writeln(ex);
            }
        });
    }

    Thread[] txThreads;
    foreach(i, ref usrp; txUSRPs) {
        immutable bool timesync = ("timesync" in settings["tx"][i].object) ? settings["tx"][i]["timesync"].boolean : false;
        immutable double settling =  ("settling" in settings["tx"][i].object) ? settings["tx"][i]["settling"].floating : 1;
        txThreads ~= makeThread!(transmit_worker!(C, typeof(theAllocator)))(stop_signal_called, theAllocator, usrp, txChannelList[i], cpufmt, otwfmt, timesync, settling, settings["tx"][i].object, txMsgQueues[i].makeExecuter);
    }

    foreach(e; txThreads) e.start();

    Thread[] rxThreads;
    foreach(i, ref usrp; rxUSRPs) {
        immutable timesync = ("timesync" in settings["rx"][i].object) ? settings["rx"][i]["timesync"].boolean : false;
        immutable double settling =  ("settling" in settings["rx"][i].object) ? settings["rx"][i]["settling"].floating : 1;
        immutable size_t recvAlignSize = ("alignsize" in settings["rx"][i].object) ? settings["rx"][i]["alignsize"].integer : 4096;
        rxThreads ~= makeThread!(receive_worker!(C, typeof(theAllocator)))(stop_signal_called, theAllocator, usrp, rxChannelList[i], cpufmt, otwfmt, timesync, settling, recvAlignSize, settings["rx"][i].object, rxMsgQueues[i].makeExecuter);
    }

    foreach(e; rxThreads) e.start();

    // run TCP/IP loop
    event_dg();
    stop_signal_called = true;

    //clean up
    foreach(e; txThreads) e.join();
    foreach(e; rxThreads) e.join();

    GC.enable();
    GC.collect();
    writeln("\nDone!\n");
}



JSONValue[string] convertSettingJSONFromV1ToV2(JSONValue[string] oldSettings)
{
    JSONValue[string] dst;
    if("tx-args" in oldSettings) {
        JSONValue txSettings;

        if("tx-rate" in oldSettings)        txSettings["rate"] = oldSettings["tx-rate"];
        if("tx-freq" in oldSettings)        txSettings["freq"] = oldSettings["tx-freq"];
        if("tx-gain" in oldSettings)        txSettings["gain"] = oldSettings["tx-gain"];
        if("tx-ant" in oldSettings)         txSettings["ant"] = oldSettings["tx-ant"];
        if("tx-subdev" in oldSettings)      txSettings["subdev"] = oldSettings["tx-subdev"];
        if("tx-bw" in oldSettings)          txSettings["bw"] = oldSettings["tx-bw"];
        if("clockref" in oldSettings)       txSettings["clockref"] = oldSettings["clockref"];
        if("timeref" in oldSettings)        txSettings["timeref"] = oldSettings["timeref"];
        if("tx-channels" in oldSettings)    txSettings["channels"] = oldSettings["tx-channels"];
        if("tx_int_n" in oldSettings)       txSettings["int_n"] = oldSettings["tx_int_n"];
        if("settling" in oldSettings)       txSettings["settling"] = oldSettings["settling"];

        dst["tx"] = [txSettings];
    }

    if("rx-args" in oldSettings) {
        JSONValue rxSettings;

        if("rx-rate" in oldSettings)        rxSettings["rate"] = oldSettings["rx-rate"];
        if("rx-freq" in oldSettings)        rxSettings["freq"] = oldSettings["rx-freq"];
        if("rx-gain" in oldSettings)        rxSettings["gain"] = oldSettings["rx-gain"];
        if("rx-ant" in oldSettings)         rxSettings["ant"] = oldSettings["rx-ant"];
        if("rx-subdev" in oldSettings)      rxSettings["subdev"] = oldSettings["rx-subdev"];
        if("rx-bw" in oldSettings)          rxSettings["bw"] = oldSettings["rx-bw"];
        if("clockref" in oldSettings)       rxSettings["clockref"] = oldSettings["clockref"];
        if("timeref" in oldSettings)        rxSettings["timeref"] = oldSettings["timeref"];
        if("rx-channels" in oldSettings)    rxSettings["channels"] = oldSettings["rx-channels"];
        if("rx_int_n" in oldSettings)       rxSettings["int_n"] = oldSettings["rx_int_n"];
        if("recv_align" in oldSettings)     rxSettings["align"] = oldSettings["recv_align"];
        if("settling" in oldSettings)       rxSettings["settling"] = oldSettings["settling"];

        dst["rx"] = [rxSettings];
    }

    if("port" in oldSettings)   dst["port"] = oldSettings["port"];
    if("otw" in oldSettings)    dst["otwfmt"] = oldSettings["otw"];
    if("cpufmt" in oldSettings) dst["cpufmt"] = oldSettings["cpufmt"];

    return dst;
}


JSONValue[string] normalizeSettingJSON(JSONValue[string] settings)
{
    foreach(trx; ["tx", "rx"]) {
        if(trx !in settings)
            continue;
        
        foreach(ref e; settings[trx].array) {
            if("channels" in e && e["channels"].type == JSONType.string) {
                e["channels"] = e["channels"].get!string.splitter(',').map!(a => JSONValue(a.to!size_t)).array();
            }
        }
    }

    return settings;
}
