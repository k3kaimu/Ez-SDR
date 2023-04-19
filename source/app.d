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

// gdb --args ./multiusrp --tx-args="addr0=192.168.10.211,addr1=192.168.10.212" --rx-args="addr0=192.168.10.213,addr1=192.168.10.214" --tx-rate=1e6 --rx-rate=1e6 --tx-freq=2.45e9 --rx-freq=2.45e9 --tx-gain=10 --rx-gain=30 --clockref=external --timeref=external --tx-channels="0,1" --rx-channels="0,1" --port=8888

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


/***********************************************************************
 * Signal handlers
 **********************************************************************/
shared bool stop_signal_called = false;
extern(C) void sig_int_handler(int) nothrow @nogc @system
{
    import core.stdc.stdio;
    printf("STOP\n");
    stop_signal_called = true;
}

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

    string tx_args, /*wave_type,*/ tx_ant, tx_subdev, clockref = "internal", timeref = "internal", otw, tx_channels;
    double tx_rate, tx_freq, tx_gain, /*wave_freq,*/ tx_bw;
    float ampl;

    //receive variables to be set by po
    string rx_args, file, type, rx_ant, rx_subdev, rx_channels;
    // size_t spb;
    double rx_rate, rx_freq, rx_gain, rx_bw;
    float settling;
    bool tx_int_n, rx_int_n;
    ushort tcpPort = 8888;
    size_t recvAlignSize = 4096;

    // set default values
    file = "usrp_samples.dat";
    type = "short";
    ampl = 0.3;
    settling = 1;
    otw = "sc16";
    // wave_freq = 0;

    auto helpInformation = getopt(
        args,
        "tx-args",  "uhd transmit device address args",             &tx_args,
        "rx-args",  "uhd receive device address args",              &rx_args,
        "file",     "name of the file to write binary samples to",  &file,
        "type",     "sample type in file: double, float, or short", &type,
        // "nsamps",   "total number of samples to receive",           &total_num_samps,
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
        // "txfiles",  "transmit waveform file",                       &txfiles, 
        // "wave-type",    "waveform type (CONST, SQUARE, RAMP, SINE)",    &wave_type,
        // "wave-freq",    "waveform frequency in Hz",                 &wave_freq,
        "clockref",      "clock reference (internal, external, mimo)",   &clockref,
        "timeref",      "time reference (internal, external, mimo)",   &timeref,
        "otw",      "specify the over-the-wire sample mode",        &otw,
        "tx-channels",  `which TX channel(s) to use (specify "0", "1", "0,1", etc)`,    &tx_channels,
        "rx-channels",  `which RX channel(s) to use (specify "0", "1", "0,1", etc)`,    &rx_channels,
        "tx_int_n", "tune USRP TX with integer-N tuing", &tx_int_n,
        "rx_int_n", "tune USRP RX with integer-N tuing", &rx_int_n,
        "port", "TCP port", &tcpPort,
        "recv_align", "alignment of buffer on the receivers", &recvAlignSize,
    );

    if(helpInformation.helpWanted){
        defaultGetoptPrinter("UHD TXRX Loopback to File.", helpInformation.options);
        return;
    }

    writefln("Creating the transmit usrp device with: %s...", tx_args);
    USRP tx_usrp = USRP(tx_args);
    writefln("Creating the receive usrp device with: %s...", rx_args);
    USRP rx_usrp = USRP(rx_args);

    immutable(size_t)[] tx_channel_nums = tx_channels.splitter(',').map!(to!size_t).array();
    // enforce(tx_channel_nums.length == txfiles.length, "The number of channels is not equal to the number of txfiles.");
    foreach(e; tx_channel_nums) enforce(e < tx_usrp.txNumChannels, "Invalid TX channel(s) specified.");

    immutable(size_t)[] rx_channel_nums = rx_channels.splitter(',').map!(to!size_t).array();
    foreach(e; rx_channel_nums) enforce(e < rx_usrp.rxNumChannels, "Invalid RX channel(s) specified.");

    // Set time source
    tx_usrp.timeSource = timeref;
    rx_usrp.timeSource = timeref;

    //Lock mboard clocks
    tx_usrp.clockSource = clockref;
    rx_usrp.clockSource = clockref;

    //always select the subdevice first, the channel mapping affects the other settings
    if(! tx_subdev.empty) tx_usrp.txSubdevSpec = tx_subdev;
    if(! rx_subdev.empty) rx_usrp.rxSubdevSpec = rx_subdev;

    static if(0){
        writeln("Using TX Device: ", tx_usrp);
        writeln("Using RX Device: ", rx_usrp);
    }

    //set the transmit sample rate
    if (tx_rate.isNaN){
        writeln("Please specify the transmit sample rate with --tx-rate");
        return;
    }

    writefln("Setting TX Rate: %f Msps...", tx_rate/1e6);
    tx_usrp.txRate = tx_rate;
    writefln("Actual TX Rate: %f Msps...", tx_usrp.txRate/1e6);

    //set the receive sample rate
    if (rx_rate.isNaN){
        writeln("Please specify the sample rate with --rx-rate");
        return;
    }
    writefln("Setting RX Rate: %f Msps...", rx_rate/1e6);
    rx_usrp.rxRate = rx_rate;
    writefln("Actual RX Rate: %f Msps...", rx_usrp.rxRate/1e6);

    //set the transmit center frequency
    if (tx_freq.isNaN) {
        writeln("Please specify the transmit center frequency with --tx-freq");
        return;
    }

    // for(size_t ch = 0; ch < tx_channel_nums.size(); ch++) {
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
    //set the receive antenna
    if (! rx_ant.empty) rx_usrp.rxAntenna = rx_ant;

    writeln("Check Ref and LO Lock detect");
    //Check Ref and LO Lock detect
    foreach(i, ref usrp; AliasSeq!(tx_usrp, rx_usrp)){
        foreach(sname; usrp.getTxSensorNames(0)){
            if(sname == "lo_locked"){
                SensorValue lo_locked = tx_usrp.getTxSensor(sname, 0);
                static if(0) writefln("Checking %s: %s ...", i == 0 ? "TX" : "RX", lo_locked);
                enforce(cast(bool)lo_locked);
            }
        }
    }

    foreach(i, ref usrp; AliasSeq!(tx_usrp, rx_usrp)){
        foreach(sname; usrp.getMboardSensorNames(0)){
            if((clockref == "mimo" && sname == "mimo_locked") || (clockref == "external" && sname == "ref_locked")){
                SensorValue locked = tx_usrp.getTxSensor(sname, 0);
                static if(0) writefln("Checking %s: %s ...", i == 0 ? "TX" : "RX", locked);
                enforce(cast(bool)locked);
            }
        }
    }

    {
        import core.stdc.signal;
        signal(SIGINT, &sig_int_handler);
        writeln("Press Ctrl + C to stop streaming...");
    }

    scope(exit)
        stop_signal_called = true;
    writeln("START");

    GC.disable();

    shared MsgQueue!(shared(TxRequest!C)*, shared(TxResponse!C)*) txMsgQueue;
    shared MsgQueue!(shared(RxRequest!C)*, shared(RxResponse!C)*) rxMsgQueue;

    auto event_thread = new Thread(delegate(){
        scope(exit) {
            writeln("[eventIOLoop] END");
            stop_signal_called = true;
        }

        try
            // イベントループを始める
            eventIOLoop!C(stop_signal_called, tcpPort, theAllocator, tx_channel_nums.length, rx_channel_nums.length, txMsgQueue, rxMsgQueue);
        catch(Exception ex){
            writeln(ex);
        }
    });
    event_thread.start();

    auto transmit_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            transmit_worker!C(stop_signal_called, theAllocator, tx_usrp, tx_channel_nums.length, "fc32", otw, tx_channel_nums, settling, txMsgQueue);
        catch(Throwable ex){
            writeln(ex);
        }
    });
    transmit_thread.start();

    auto receive_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            receive_worker!C(stop_signal_called, theAllocator, rx_usrp, rx_channel_nums.length, "fc32", otw, rx_channel_nums, settling, recvAlignSize, rxMsgQueue);
        catch(Throwable ex){
            writeln(ex);
        }
    });
    receive_thread.start();

    //clean up
    transmit_thread.join();
    receive_thread.join();
    event_thread.join();

    stop_signal_called = true;
    writeln("\nDone!\n");
}
