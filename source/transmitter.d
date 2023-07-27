module transmitter;

import core.thread;

import std.algorithm;
import std.array;
import std.exception;
import std.experimental.allocator;
import std.json;
import std.sumtype;
import std.complex;
import std.conv;
import std.math;
import std.stdio;
import std.typecons;

import utils;
import msgqueue;

import uhd.usrp;
import uhd.capi;
import uhd.utils;

import automem.unique;

struct TxRequestTypes(C)
{
    static struct Transmit
    {
        C[][] buffer;
    }


    static struct SyncToPPS
    {
        size_t myIndex;
        shared(bool)[] isReady;
        shared(bool)[] isDone;
    }


    static struct ClearCmdQueue {}
}


struct TxResponseTypes(C)
{
    static struct TransmitDone
    {
        C[][] buffer;
    }
}


alias TxRequest(C) = SumType!(TxRequestTypes!C.Transmit, TxRequestTypes!C.SyncToPPS, TxRequestTypes!C.ClearCmdQueue);
alias TxResponse(C) = SumType!(TxResponseTypes!C.TransmitDone);


void transmit_worker(C, Alloc)(
    ref shared bool stop_signal_called,
    ref Alloc alloc,
    ref USRP usrp,
    immutable(size_t)[] tx_channel_nums,
    string cpu_format,
    string wire_format,
    bool time_sync,
    float settling_time,
    JSONValue[string] settings,
    UniqueMsgQueue!(TxRequest!C, TxResponse!C).Executer txMsgQueue,
){
    alias dbg = debugMsg!"transmit_worker";

    scope(exit) {
        writefln("[transmit_worker] END transmit_worker");
        writefln("[transmit_worker] stop_signal_called = %s", stop_signal_called);
    }

    immutable nTXUSRP = tx_channel_nums.length;

    StreamArgs stream_args = StreamArgs(cpu_format, wire_format, "", tx_channel_nums);
    auto tx_streamer = usrp.makeTxStreamer(stream_args);

    C[][] nullBuffers;
    foreach(i; 0 .. nTXUSRP) nullBuffers ~= null;

    TxMetaData firstMD = TxMetaData((cast(long)floor(settling_time*1E6)).usecs, true, false);
    TxMetaData afterFirstMD = TxMetaData(false, 0, 0, false, false);
    TxMetaData endMD = TxMetaData(false, 0, 0, false, true);
    VUHDException error;

    C[][] initTxBuffers = alloc.makeMultidimensionalArray!C(nTXUSRP, 4096);
    scope(exit) alloc.disposeMultidimensionalArray(initTxBuffers);
    foreach(i; 0 .. nTXUSRP)
        initTxBuffers[i][] = C(0);

    static struct RequestInfo {
        bool haveRequest = false;
        TxRequest!C req;
        TxRequestTypes!C.Transmit txReq;
    }

    RequestInfo reqInfo;

    scope(exit) {
        if(reqInfo.haveRequest)
            txMsgQueue.pushResponse(reqInfo.req, TxResponse!C(TxResponseTypes!C.TransmitDone(cast(C[][]) reqInfo.txReq.buffer)));

        reqInfo.haveRequest = false;
        reqInfo.req = typeof(reqInfo.req).init;
        reqInfo.txReq = typeof(reqInfo.txReq).init;
    }

    // PPSのsettling_time秒後に送信
    if(time_sync)
        usrp.setTimeUnknownPPS(0.seconds);
    else
        usrp.setTimeNow(0.seconds);

    tx_streamer.send(nullBuffers, firstMD, 1);

    const(C)[][128] _tmpbuffers;
    Nullable!VUHDException transmitAllBuffer(const(C)[][] buffers) @nogc
    in(buffers.length == nTXUSRP)
    {
        size_t numTotalSamples = 0;
        while(numTotalSamples < buffers[0].length && !stop_signal_called) {
            foreach(i; 0 .. nTXUSRP)
                _tmpbuffers[i] = buffers[i][numTotalSamples .. $];

            size_t txsize;
            if(auto err = tx_streamer.send(_tmpbuffers[0 .. nTXUSRP], afterFirstMD, 0.1, txsize)){
                return typeof(return)(err);
            }
            numTotalSamples += txsize;
        }

        return typeof(return).init;
    }


    () {
        //send data until the signal handler gets called
        while(!stop_signal_called){
            {
                bool b = false;
                scope(exit) {
                    if(b == false) {
                        writeln("[transmit_worker] This thread is killed by txMsgQueue.");
                    }
                }

                if(!txMsgQueue.emptyRequest) {
                    // キューにClearCmdQueueがあれば，全てのキューに入っているコマンドを消す
                    bool isClear = txMsgQueue.allRequestList.canFind!(a => a.match!((TxRequestTypes!C.ClearCmdQueue q) => true, _ => false));
                    while(isClear && !txMsgQueue.emptyRequest)
                        txMsgQueue.popRequest();
                }

                while(! txMsgQueue.emptyRequest) {
                    writeln("POPOPOP");
                    auto req = cast()txMsgQueue.popRequest();
                    req.match!(
                        (TxRequestTypes!C.Transmit r) {
                            if(reqInfo.haveRequest)
                                txMsgQueue.pushResponse(reqInfo.req, TxResponse!C(TxResponseTypes!C.TransmitDone(cast(C[][]) reqInfo.txReq.buffer)));

                            reqInfo.haveRequest = true;
                            reqInfo.req = req;
                            reqInfo.txReq = r;
                        },
                        (TxRequestTypes!C.SyncToPPS r) {
                                import core.atomic;
                                scope(exit) {
                                    if(r.myIndex == 0) {
                                        alloc.dispose(cast(void[])r.isReady);
                                        alloc.dispose(cast(void[])r.isDone);
                                    }
                                }

                                // 現在送信中のストリームを終了
                                tx_streamer.send(nullBuffers, endMD, 0.1);

                                dbg.writeln("Ready sync and wait other threads...");
                                // 自分は準備完了したことを他のスレッドに伝える
                                notifyAndWait(r.isReady, r.myIndex);

                                // PPSのsettling_time秒後に送信
                                if(time_sync)
                                    usrp.setTimeUnknownPPS(0.seconds);
                                else
                                    usrp.setTimeNow(0.seconds);

                                dbg.writeln("Ready transmit and wait other threads...");
                                // 自分は設定完了したことを他のスレッドに伝える
                                notifyAndWait(r.isDone, r.myIndex);
                                tx_streamer.send(nullBuffers, firstMD, 1);
                        },
                        (TxRequestTypes!C.ClearCmdQueue) {
                            while(!txMsgQueue.emptyRequest)
                                txMsgQueue.popRequest();
                        }
                    )();
                    writeln("POP");
                }
                b = true;
            }

            {
                bool b = false;
                scope(exit) {
                    if(b == false) {
                        writeln("[transmit_worker] This thread is killed by transmitAllBuffer.");
                    }
                }
                auto err = transmitAllBuffer(!reqInfo.haveRequest ? cast(const(C)[][])initTxBuffers : cast(const(C)[][])reqInfo.txReq.buffer);
                if(! err.isNull) {
                    error = err.get;
                    writeln(error);
                    Thread.sleep(2.seconds);
                    transmit_worker!C(stop_signal_called, alloc, usrp, tx_channel_nums, cpu_format, wire_format, time_sync, settling_time, settings, txMsgQueue);
                }
                b = true;
            }
        }
    }();

    //send a mini EOB packet
    tx_streamer.send(nullBuffers, endMD, 0.1);

    if(error)
        throw error.makeException();
}



void settingTransmitUSRP(ref USRP usrp, JSONValue[string] settings)
{
    enforce("args" in settings, "Please specify the argument for USRP.");
    writefln("Creating the transmit usrp device with: %s...", settings["args"].str);
    usrp = USRP(settings["args"].str);

    // check channel settings
    immutable chNums = settings["channels"].array.map!"a.get!size_t".array();
    foreach(e; chNums) enforce(e < usrp.txNumChannels, "Invalid TX channel(s) specified.");

    // Set time source
    if("timeref" in settings) usrp.timeSource = settings["timeref"].str;

    //Lock mboard clocks
    if("clockref" in settings) usrp.clockSource = settings["clockref"].str;

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