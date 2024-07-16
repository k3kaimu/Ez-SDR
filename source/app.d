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
import controller;
import device;

import std.experimental.allocator;

import lock_free.rwqueue;


void main(string[] args)
{
    string config_json;
    short tcpPort = -1;
    bool flagRetry = false;

    // コマンドライン引数指定されたjsonファイルを読み込む
    auto helpInformation1 = getopt(
        args,
        std.getopt.config.passThrough,
        "config_json|c", "read settings from json", &config_json,
        "port", "TCP port", &tcpPort,
        "retry", "retry", &flagRetry,
    );

    writeln("[multiusrp] Read config json: ", config_json);

    import std.file : read;
    JSONValue[string] settings = parseJSON(cast(const(char)[])read(config_json)).object;

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
        catch(UHDException ex) {
            writeln(ex);
            hasUHDException = true;
            writeln("Retry...");
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

    // USRP[] xcvrUSRPs, txUSRPs, rxUSRPs;
    // xcvrUSRPs.length = ("xcvr" in settings) ? settings["xcvr"].array.length : 0;
    // txUSRPs.length = ("tx" in settings) ? settings["tx"].array.length : 0;
    // rxUSRPs.length = ("rx" in settings) ? settings["rx"].array.length : 0;

    IDevice[string] devs;
    IController[string] ctrls;
    scope(exit) {
        foreach(tag, ctrl; ctrls)
            ctrl.killDeviceThreads();

        ctrls = null;

        foreach(tag, dev; devs)
            dev.destruct();

        devs = null;
    }

    // Deviceの構築
    foreach(string tag, deviceSettings; settings["devices"]) {
        writefln("Create and setup the device '%s'...", tag);

        auto newdev = newDevice(deviceSettings["type"].str);
        newdev.construct();
        newdev.setup(deviceSettings.object);
        devs[tag] = newdev;
    }

    // Controllerの構築
    foreach(string tag, ctrlSettings; settings["controllers"]) {
        writefln("Create and setup the controller '%s'...", tag);

        auto newctrl = newController(ctrlSettings["type"].str);

        IDevice[] devlist;
        foreach(JSONValue devtag; ctrlSettings["devices"].array) {
            devlist ~= devs[devtag.str];
        }

        newctrl.setup(devlist, ctrlSettings.object);
        ctrls[tag] = newctrl;
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
    scope(exit) {
        GC.enable();
    }

    auto event_dg = delegate(){
        scope(exit) {
            writeln("[eventIOLoop] END");
            stop_signal_called = true;
        }

        try {
            // イベントループを始める
            eventIOLoop!C(stop_signal_called, cast(short)settings["port"].integer, theAllocator, ctrls);
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


void settingUSRPGeneral(ref USRP usrp, JSONValue[string] settings)
{
    enforce("args" in settings, "Please specify the argument for USRP.");
    writefln("Creating the transmit usrp device with: %s...", settings["args"].str);
    usrp = USRP(settings["args"].str);

    // Set time source
    if("timeref" in settings) usrp.timeSource = settings["timeref"].str;

    //Lock mboard clocks
    if("clockref" in settings) usrp.clockSource = settings["clockref"].str;
}


void settingTransmitDevice(ref USRP usrp, JSONValue[string] settings)
{
    // check channel settings
    immutable chNums = settings["channels"].array.map!"a.get!size_t".array();
    foreach(e; chNums) enforce(e < usrp.txNumChannels, "Invalid TX channel(s) specified.");

    //always select the subdevice first, the channel mapping affects the other settings
    if("subdev" in settings) usrp.txSubdevSpec = settings["subdev"].str;

    //set the transmit sample rate
    immutable tx_rate = enforce("rate" in settings, "Please specify the transmit sample rate.").floating;
    writefln("Setting TX Rate: %f Msps...", tx_rate/1e6);
    usrp.txRate = tx_rate;
    writefln("Actual TX Rate: %f Msps...", usrp.txRate/1e6);

    //set the transmit center frequency
    auto pfreq = enforce("freq" in settings, "Please specify the transmit center frequency.");
    foreach(i, channel; chNums){
        if (chNums.length > 1) {
            writefln("Configuring TX Channel %s", channel);
        }

        immutable tx_freq = ((*pfreq).type == JSONType.array) ? (*pfreq)[i].floating : (*pfreq).floating;
        bool tx_int_n = false;
        if("int_n" in settings)
            tx_int_n = (settings["int_n"].type == JSONType.array) ? settings["int_n"][i].boolean : settings["int_n"].boolean;

        writefln("Setting TX Freq: %f MHz...", tx_freq/1e6);
        TuneRequest tx_tune_request = TuneRequest(tx_freq);
        if(tx_int_n) tx_tune_request.args = "mode_n=integer";
        usrp.tuneTxFreq(tx_tune_request, channel);
        writefln("Actual TX Freq: %f MHz...", usrp.getTxFreq(channel)/1e6);

        //set the rf gain
        if(auto p = "gain" in settings) {
            immutable tx_gain = ((*p).type == JSONType.array) ? (*p)[i].get!double : (*p).get!double;
            writefln("Setting TX Gain: %f dB...", tx_gain);
            usrp.setTxGain(tx_gain, channel);
            writefln("Actual TX Gain: %f dB...", usrp.getTxGain(channel));
        }

        //set the analog frontend filter bandwidth
        if (auto p = "bw" in settings){
            immutable tx_bw = ((*p).type == JSONType.array) ? (*p)[i].get!double : (*p).get!double;
            writefln("Setting TX Bandwidth: %f MHz...", tx_bw);
            usrp.setTxBandwidth(tx_bw, channel);
            writefln("Actual TX Bandwidth: %f MHz...", usrp.getTxBandwidth(channel));
        }

        //set the antenna
        if (auto p = "ant" in settings) usrp.setTxAntenna(p.str, channel);
    }
}


void settingReceiveDevice(ref USRP usrp, JSONValue[string] settings)
{
    // check channel settings
    immutable chNums = settings["channels"].array.map!"a.get!size_t".array();
    foreach(e; chNums) enforce(e < usrp.rxNumChannels, "Invalid RX channel(s) specified.");

    //always select the subdevice first, the channel mapping affects the other settings
    if("subdev" in settings) usrp.rxSubdevSpec = settings["subdev"].str;

    //set the receive sample rate
    immutable rx_rate = enforce("rate" in settings, "Please specify the receiver sample rate.").get!double;
    writefln("Setting RX Rate: %f Msps...", rx_rate/1e6);
    usrp.rxRate = rx_rate;
    writefln("Actual RX Rate: %f Msps...", usrp.rxRate/1e6);

    //set the receiver center frequency
    auto pfreq = enforce("freq" in settings, "Please specify the receiver center frequency.");
    foreach(i, channel; chNums) {
        if(chNums.length > 1) {
            writeln("Configuring RX Channel ", channel);
        }

        immutable rx_freq = ((*pfreq).type == JSONType.array) ? (*pfreq)[i].get!double : (*pfreq).get!double;
        bool rx_int_n = false;
        if("int_n" in settings)
            rx_int_n = (settings["int_n"].type == JSONType.array) ? settings["int_n"][i].boolean : settings["int_n"].boolean;

        writefln("Setting RX Freq: %f MHz...", rx_freq/1e6);
        TuneRequest rx_tune_request = TuneRequest(rx_freq);
        if(rx_int_n) rx_tune_request.args = "mode_n=integer";
        usrp.tuneRxFreq(rx_tune_request, channel);
        writefln("Actual RX Freq: %f MHz...", usrp.getRxFreq(channel)/1e6);

        //set the receive rf gain
        if(auto p = "gain" in settings) {
            immutable rx_gain = ((*p).type == JSONType.array) ? (*p)[i].get!double : (*p).get!double;
            writefln("Setting RX Gain: %f dB...", rx_gain);
            usrp.setRxGain(rx_gain, channel);
            writefln("Actual RX Gain: %f dB...", usrp.getRxGain(channel));
        }

        //set the receive analog frontend filter bandwidth
        if(auto p = "bw" in settings) {
            immutable rx_bw = ((*p).type == JSONType.array) ? (*p)[i].get!double : (*p).get!double;
            writefln("Setting RX Bandwidth: %f MHz...", rx_bw/1e6);
            usrp.setRxBandwidth(rx_bw, channel);
            writefln("Actual RX Bandwidth: %f MHz...", usrp.getRxBandwidth(channel)/1e6);
        }

        if(auto p = "ant" in settings) {
            usrp.setRxAntenna(p.str, channel);
        }
    }
}
