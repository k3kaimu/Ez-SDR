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


// kill switch for transmit and receive threads
shared bool stop_signal_called = false;

/***********************************************************************
 * Utilities
 **********************************************************************/
//! Change to filename, e.g. from usrp_samples.dat to usrp_samples.00.dat,
//  but only if multiple names are to be generated.
string generate_out_filename(string base_fn, size_t n_names, size_t this_name)
{
    if (n_names == 1) {
        return base_fn;
    }

    return base_fn.setExtension(format("%02d.%s", base_fn.extension));
}


/***********************************************************************
 * Main function
 **********************************************************************/
void main(string[] args){
    alias C = Complex!float;

    string tx_args, tx_ant, tx_subdev, clockref, timeref, otw, cpufmt, tx_channels;
    string config_json;
    bool time_sync = false;
    double tx_rate, tx_freq, tx_gain, tx_bw;
    float ampl;

    string rx_args, rx_ant, rx_subdev, rx_channels;
    double rx_rate, rx_freq, rx_gain, rx_bw;
    float settling;
    bool tx_int_n, rx_int_n;
    ushort tcpPort = 8888;
    size_t recvAlignSize = 4096;

    // set default values
    ampl = 0.3;
    settling = 1;
    otw = "sc16";
    cpufmt = "fc32";

    auto helpInformation1 = getopt(
        args,
        std.getopt.config.passThrough,
        "config_json|c", "read settings from json", &config_json,
    );

    if(config_json !is null) {
        import std.file : read;
        JSONValue[string] settings = parseJSON(cast(const(char)[])read(config_json)).object;
        writeln("[multiusrp] Read config json: ", config_json);

        tx_args = settings.get("tx-args", JSONValue(tx_args)).get!(typeof(tx_args))();
        rx_args = settings.get("rx-args", JSONValue(rx_args)).get!(typeof(rx_args))();
        settling = settings.get("settling", JSONValue(settling)).get!(typeof(settling))();
        tx_rate = settings.get("tx-rate", JSONValue(tx_rate)).get!(typeof(tx_rate))();
        rx_rate = settings.get("rx-rate", JSONValue(rx_rate)).get!(typeof(rx_rate))();
        tx_freq = settings.get("tx-freq", JSONValue(tx_freq)).get!(typeof(tx_freq))();
        rx_freq = settings.get("rx-freq", JSONValue(rx_freq)).get!(typeof(rx_freq))();
        tx_gain = settings.get("tx-gain", JSONValue(tx_gain)).get!(typeof(tx_gain))();
        rx_gain = settings.get("rx-gain", JSONValue(rx_gain)).get!(typeof(rx_gain))();
        tx_ant = settings.get("tx-ant", JSONValue(tx_ant)).get!(typeof(tx_ant))();
        rx_ant = settings.get("rx-ant", JSONValue(rx_ant)).get!(typeof(rx_ant))();
        tx_subdev = settings.get("tx-subdev", JSONValue(tx_subdev)).get!(typeof(tx_subdev))();
        rx_subdev = settings.get("rx-subdev", JSONValue(rx_subdev)).get!(typeof(rx_subdev))();
        tx_bw = settings.get("tx-bw", JSONValue(tx_bw)).get!(typeof(tx_bw))();
        rx_bw = settings.get("rx-bw", JSONValue(rx_bw)).get!(typeof(rx_bw))();
        clockref = settings.get("clockref", JSONValue(clockref)).get!(typeof(clockref))();
        timeref = settings.get("timeref", JSONValue(timeref)).get!(typeof(timeref))();
        time_sync = settings.get("timesync", JSONValue(time_sync)).get!(typeof(time_sync))();
        otw = settings.get("otw", JSONValue(otw)).get!(typeof(otw))();
        cpufmt = settings.get("cpufmt", JSONValue(cpufmt)).get!(typeof(cpufmt))();
        tx_channels = settings.get("tx-channels", JSONValue(tx_channels)).get!(typeof(tx_channels))();
        rx_channels = settings.get("rx-channels", JSONValue(rx_channels)).get!(typeof(rx_channels))();
        tx_int_n = settings.get("tx_int_n", JSONValue(tx_int_n)).get!(typeof(tx_int_n))();
        rx_int_n = settings.get("rx_int_n", JSONValue(rx_int_n)).get!(typeof(rx_int_n))();
        tcpPort = settings.get("port", JSONValue(tcpPort)).get!(typeof(tcpPort))();
        recvAlignSize = settings.get("recv_align", JSONValue(recvAlignSize)).get!(typeof(recvAlignSize))();
    }

    auto helpInformation2 = getopt(
        args,
        "tx-args",  "uhd transmit device address args",             &tx_args,
        "rx-args",  "uhd receive device address args",              &rx_args,
        "settling", "total time (seconds) before receiving",        &settling,
        "tx-rate",  "rate of transmit outgoing samples",            &tx_rate,
        "rx-rate",  "rate of receive incoming samples",             &rx_rate,
        "tx-freq",  "transmit RF center frequency in Hz",           &tx_freq,
        "rx-freq",  "receive RF center frequency in Hz",            &rx_freq,
        "tx-gain",  "gain for the transmit RF chain",               &tx_gain,
        "rx-gain",  "gain for the receive RF chain",                &rx_gain,
        "tx-ant",   "transmit antenna selection",                   &tx_ant,
        "rx-ant",   "receive antenna selection",                    &rx_ant,
        "tx-subdev",    "transmit subdevice specification",         &tx_subdev,
        "rx-subdev",    "receive subdevice specification",          &rx_subdev,
        "tx-bw",    "analog transmit filter bandwidth in Hz",       &tx_bw,
        "rx-bw",    "analog receive filter bandwidth in Hz",        &rx_bw,
        "clockref",      "clock reference (internal, external, mimo)",   &clockref,
        "timeref",      "time reference (internal, external, mimo)",   &timeref,
        "timesync",     "synchronization of timing",                &time_sync,
        "otw",      "specify the over-the-wire sample mode",        &otw,
        "cpufmt",   "specify the on-CPU sample mode",               &cpufmt,
        "tx-channels",  `which TX channel(s) to use (specify "0", "1", "0,1", etc)`,    &tx_channels,
        "rx-channels",  `which RX channel(s) to use (specify "0", "1", "0,1", etc)`,    &rx_channels,
        "tx_int_n", "tune USRP TX with integer-N tuing", &tx_int_n,
        "rx_int_n", "tune USRP RX with integer-N tuing", &rx_int_n,
        "port", "TCP port", &tcpPort,
        "recv_align", "alignment of buffer on the receivers", &recvAlignSize,
        "config_json|c", "read settings from json", &config_json,
    );

    // helpInformation2には--helpの情報がないので，helpInformation2でhelpを表示するか判断する
    if(helpInformation1.helpWanted){
        // ただじ実際に表示するhelp情報はhelpInformation2を使う
        defaultGetoptPrinter("Management system of multiple USRPs.", helpInformation2.options);
        return;
    }

    immutable(size_t)[] tx_channel_nums = tx_channels.splitter(',').map!(to!size_t).array();
    immutable(size_t)[] rx_channel_nums = rx_channels.splitter(',').map!(to!size_t).array();

    immutable bool
        useTxUSRP = tx_channel_nums.length != 0,
        useRxUSRP = rx_channel_nums.length != 0;

    if(!useTxUSRP && !useRxUSRP) {
        writeln("[multiusrp] Please add 'tx-args' or 'rx-args'!");
        return;
    }

    USRP tx_usrp, rx_usrp;

    if(useTxUSRP) {
        writefln("Creating the transmit usrp device with: %s...", tx_args);
        tx_usrp = USRP(tx_args);
    }

    if(useRxUSRP) {
        writefln("Creating the receive usrp device with: %s...", rx_args);
        rx_usrp = USRP(rx_args);
    }

    foreach(e; tx_channel_nums) enforce(e < tx_usrp.txNumChannels, "Invalid TX channel(s) specified.");
    foreach(e; rx_channel_nums) enforce(e < rx_usrp.rxNumChannels, "Invalid RX channel(s) specified.");

    // Set time source
    if(useTxUSRP && timeref !is null) tx_usrp.timeSource = timeref;
    if(useRxUSRP && timeref !is null) rx_usrp.timeSource = timeref;

    //Lock mboard clocks
    if(useTxUSRP && clockref !is null) tx_usrp.clockSource = clockref;
    if(useRxUSRP && clockref !is null) rx_usrp.clockSource = clockref;

    //always select the subdevice first, the channel mapping affects the other settings
    if(useTxUSRP && ! tx_subdev.empty) tx_usrp.txSubdevSpec = tx_subdev;
    if(useRxUSRP && ! rx_subdev.empty) rx_usrp.rxSubdevSpec = rx_subdev;

    //set the transmit sample rate
    if(useTxUSRP) {

        if(tx_rate.isNaN) {
            writeln("Please specify the transmit sample rate with --tx-rate");
            return;
        }

        writefln("Setting TX Rate: %f Msps...", tx_rate/1e6);
        tx_usrp.txRate = tx_rate;
        writefln("Actual TX Rate: %f Msps...", tx_usrp.txRate/1e6);
    }

    //set the receive sample rate
    if(useRxUSRP) {
        if (rx_rate.isNaN){
            writeln("Please specify the sample rate with --rx-rate");
            return;
        }
        writefln("Setting RX Rate: %f Msps...", rx_rate/1e6);
        rx_usrp.rxRate = rx_rate;
        writefln("Actual RX Rate: %f Msps...", rx_usrp.rxRate/1e6);
    }

    //set the transmit center frequency
    if(useTxUSRP) {
        if (tx_freq.isNaN) {
            writeln("Please specify the transmit center frequency with --tx-freq");
            return;
        }

        foreach(channel; tx_channel_nums){
            if (tx_channel_nums.length > 1) {
                writefln("Configuring TX Channel %s", channel);
            }
            writefln("Setting TX Freq: %f MHz...", tx_freq/1e6);
            TuneRequest tx_tune_request = TuneRequest(tx_freq);
            if(tx_int_n) tx_tune_request.args = "mode_n=integer";
            tx_usrp.tuneTxFreq(tx_tune_request, channel);
            writefln("Actual TX Freq: %f MHz...", tx_usrp.getTxFreq(channel)/1e6);

            //set the rf gain
            if (! tx_gain.isNaN) {
                writefln("Setting TX Gain: %f dB...", tx_gain);
                tx_usrp.setTxGain(tx_gain, channel);
                writefln("Actual TX Gain: %f dB...", tx_usrp.getTxGain(channel));
            }

            //set the analog frontend filter bandwidth
            if (! tx_bw.isNaN){
                writefln("Setting TX Bandwidth: %f MHz...", tx_bw);
                tx_usrp.setTxBandwidth(tx_bw, channel);
                writefln("Actual TX Bandwidth: %f MHz...", tx_usrp.getTxBandwidth(channel));
            }

            //set the antenna
            if (! tx_ant.empty) tx_usrp.setTxAntenna(tx_ant, channel);
        }
    }

    //set the receiver center frequency
    if(useRxUSRP) {
        foreach(channel; rx_channel_nums){
            if (rx_channel_nums.length > 1) {
                writeln("Configuring RX Channel ", channel);
            }

            //set the receive center frequency
            if (rx_freq.isNaN){
                stderr.writeln("Please specify the center frequency with --rx-freq");
                return;
            }
            writefln("Setting RX Freq: %f MHz...", rx_freq/1e6);
            TuneRequest rx_tune_request = TuneRequest(rx_freq);
            if(rx_int_n) rx_tune_request.args = "mode_n=integer";
            rx_usrp.tuneRxFreq(rx_tune_request, channel);
            writefln("Actual RX Freq: %f MHz...", rx_usrp.getRxFreq(channel)/1e6);

            //set the receive rf gain
            if (! rx_gain.isNaN){
                writefln("Setting RX Gain: %f dB...", rx_gain);
                rx_usrp.setRxGain(rx_gain, channel);
                writefln("Actual RX Gain: %f dB...", rx_usrp.getRxGain(channel));
            }

            //set the receive analog frontend filter bandwidth
            if (! rx_bw.isNaN){
                writefln("Setting RX Bandwidth: %f MHz...", rx_bw/1e6);
                rx_usrp.setRxBandwidth(rx_bw, channel);
                writefln("Actual RX Bandwidth: %f MHz...", rx_usrp.getRxBandwidth(channel)/1e6);
            }
        }
    }

    //set the receive antenna
    if (useRxUSRP && ! rx_ant.empty) rx_usrp.rxAntenna = rx_ant;

    {
        writeln("Press Ctrl + C to stop streaming...");
    }

    scope(exit)
        stop_signal_called = true;
    writeln("START");

    GC.disable();

    shared txMsgQueue = new UniqueMsgQueue!(TxRequest!C, TxResponse!C)();
    shared rxMsgQueue = new UniqueMsgQueue!(RxRequest!C, RxResponse!C)();

    enforce(cpufmt == "fc32");

    auto event_dg = delegate(){
        scope(exit) {
            writeln("[eventIOLoop] END");
            stop_signal_called = true;
        }

        try
            // イベントループを始める
            eventIOLoop!C(stop_signal_called, tcpPort, theAllocator, tx_channel_nums.length, rx_channel_nums.length, cpufmt, txMsgQueue.makeCommander, rxMsgQueue.makeCommander);
        catch(Exception ex){
            writeln(ex);
        }
    };

    auto transmit_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            transmit_worker!C(stop_signal_called, theAllocator, tx_usrp, tx_channel_nums.length, cpufmt, otw, time_sync, tx_channel_nums, settling, txMsgQueue.makeExecuter);
        catch(Throwable ex){
            writeln(ex);
        }
    });

    if(useTxUSRP) transmit_thread.start();

    auto receive_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            receive_worker!C(stop_signal_called, theAllocator, rx_usrp, rx_channel_nums.length, cpufmt, otw, time_sync, rx_channel_nums, settling, recvAlignSize, rxMsgQueue.makeExecuter);
        catch(Throwable ex){
            writeln(ex);
        }
    });

    if(useRxUSRP) receive_thread.start();

    // run TCP/IP loop
    event_dg();
    stop_signal_called = true;

    //clean up
    if(useTxUSRP) transmit_thread.join();
    if(useRxUSRP) receive_thread.join();

    writeln("\nDone!\n");
}
