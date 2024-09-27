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

import core.time;
import core.thread;
import core.atomic;
import core.memory;

import core.stdc.stdlib;
import core.atomic;

import tcp_iface;

import msgqueue;
import controller;
import device;
import dispatcher;
import multithread;

import std.experimental.allocator;

import lock_free.rwqueue;


void main(string[] args)
{
    string config_json = null;
    short tcpPort = -1;
    bool flagRetry = false;
    string[] modifySettings;

    // コマンドライン引数指定されたjsonファイルを読み込む
    auto helpInformation1 = getopt(
        args,
        std.getopt.config.passThrough,
        "config_json|c", "Read settings from a json file. If this argument is not specified, it is read from the standard input.", &config_json,
        "port", "TCP port", &tcpPort,
        "retry", "retry", &flagRetry,
    );

    JSONValue[string] settings;
    if(config_json) {
        writeln("[multiusrp] Read config json from file: ", config_json);

        import std.file : read;
        settings = parseJSON(cast(const(char)[])read(config_json)).object;
    } else {
        writeln("[multiusrp] Read config json from stdin as follows:");
        settings = parseJSON(stdin.byLine.join()).object;
        writeln(settings);
    }

    bool hasUHDException = false;
    bool isUpdatedConfig = false;
    do {
        try {
            if("version" !in settings)
                settings = convertSettingJSONFromV1ToV2(settings);

            if(settings["version"].integer == 2) {
                settings = normalizeSettingJSONForV2(settings);
                // settings = convertSettingJSONFromV2ToV3(settings);
            }

            if(tcpPort != -1)
                settings["port"] = tcpPort;

            mainImpl!(Complex!float)(settings);
        }
        catch(RestartWithConfigData ex) {
            settings = parseJSON(ex.configJSON).object;
            isUpdatedConfig = true;
            writeln("Restart with updated config JSON data...");
        }
    } while(isUpdatedConfig || (flagRetry && hasUHDException) );
}


void mainImpl(C)(JSONValue[string] settings){
    immutable cpufmt = ("cpufmt" in settings) ? settings["cpufmt"].str : "fc32";
    immutable otwfmt = ("otwfmt" in settings) ? settings["otwfmt"].str : "sc16";

    if(is(C == Complex!float))
        enforce(cpufmt == "fc32");
    else if(is(C == short[2]))
        enforce(cpufmt == "sc16");

    LocalRef!(shared(IDevice))[string] devs;
    IController[string] ctrls;
    scope(exit) {
        foreach(tag, ctrl; ctrls)
            ctrl.killDeviceThreads();

        ctrls = null;

        foreach(tag, dev; devs)
            (cast()dev.get).destruct();

        devs = null;
    }

    // Deviceの構築
    foreach(string tag, JSONValue deviceSettings; settings["devices"].object) {
        import std.stdio;
        writefln("Create and setup the device '%s' with %s", tag, deviceSettings);

        auto newdev = newDevice(deviceSettings["type"].str);
        newdev.construct();
        newdev.setup(deviceSettings.object);
        devs[tag] = cast(shared)newdev;
    }

    // Controllerの構築
    foreach(string tag, ctrlSettings; settings["controllers"].object) {
        writefln("Create and setup the controller '%s'...", tag);

        auto newctrl = newController(ctrlSettings["type"].str);

        IStreamer[] streamers;
        foreach(JSONValue tag; ctrlSettings["streamers"].array) {
            string tagstr = tag.str;
            auto tagsplit = tagstr.split(":");
            string devtag = tagsplit[0];
            streamers ~= devs[devtag].makeStreamer(tagsplit[1 .. $]);
        }

        newctrl.setup(streamers, ctrlSettings.object);
        ctrls[tag] = newctrl;
    }

    {
        writeln("Press Ctrl + C to stop streaming...");
    }

    // kill switch for transmit and receive threads
    shared bool stop_signal_called = false;
    scope(exit)
        atomicStore(stop_signal_called, true);

    writeln("START");

    GC.disable();
    scope(exit) {
        GC.enable();
    }

    auto event_dg = delegate(){
        scope(exit) {
            writeln("[eventIOLoop] END");
            atomicStore(stop_signal_called, true);
        }

        try {
            MessageDispatcher dispatcher = new MessageDispatcher(devs, ctrls);
            // イベントループを始める
            eventIOLoop!C(stop_signal_called, cast(short)settings["port"].integer, theAllocator, dispatcher);
        }
        catch(Exception ex){
            writeln(ex);
        }
    };

    foreach(tag, ctrl; ctrls) ctrl.spawnDeviceThreads();

    // run TCP/IP loop
    event_dg();
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
    dst["version"] = 2;

    return dst;
}


JSONValue[string] convertSettingJSONFromV2ToV3(JSONValue[string] oldSettings)
{
    JSONValue[string] dst;
    dst["version"] = 3;
    if("port" in oldSettings)   dst["port"] = oldSettings["port"];
    if("otw" in oldSettings)    dst["otwfmt"] = oldSettings["otw"];
    if("cpufmt" in oldSettings) dst["cpufmt"] = oldSettings["cpufmt"];

    JSONValue[string] devices;
    if("tx" in oldSettings) {
        JSONValue[string] newlist;
        foreach(i, e; oldSettings["tx"].array) {
            e["type"] = "LoopTX:USRP_TX";
            devices[format("TX%d", i)] = e;
        }
    }

    if("rx" in oldSettings) {
        JSONValue[] newlist;
        foreach(i, e; oldSettings["rx"].array) {
            e["type"] = "LoopRX:USRP_RX";
            devices[format("RX%d", i)] = e;
        }
    }

    if("trx" in oldSettings) {
        JSONValue[] newlist;
        foreach(i, e; oldSettings["trx"].array) {
            e["type"] = "LoopTRX:USRP_TRX";
            devices[format("TRX%d", i)] = e;
        }
    }

    dst["devices"] = JSONValue(devices);
    return dst;
}


JSONValue[string] normalizeSettingJSONForV2(JSONValue[string] settings)
{
    void fixChannel(ref JSONValue[string] obj) {
        if("channels" in obj && obj["channels"].type == JSONType.string) {
            obj["channels"] = obj["channels"].get!string.splitter(',').map!(a => JSONValue(a.to!size_t)).array();
        }
    }

    if("xcvr" in settings) {
        foreach(ref e; settings["xcvr"].array)
            foreach(trx; ["tx", "rx"]) {
                if(trx in e)
                    fixChannel(e[trx].object);
            }
    }

    foreach(trx; ["tx", "rx"]) {
        if(trx !in settings)
            continue;
        
        foreach(ref e; settings[trx].array) {
            fixChannel(e.object);
        }
    }

    return settings;
}
