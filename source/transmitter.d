module transmitter;

import core.thread;
import core.atomic;

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


    static struct StopStreaming
    {
        shared(bool)* isDone;
    }


    static struct StartStreaming {}


    static struct SetParam
    {
        string type;
        shared(double)[] param;
        shared(bool)* isDone;
        shared(bool)* isError;
    }
}


struct TxResponseTypes(C)
{
    static struct TransmitDone
    {
        C[][] buffer;
    }
}


alias TxRequest(C) = SumType!(
    TxRequestTypes!C.Transmit,
    TxRequestTypes!C.SyncToPPS,
    TxRequestTypes!C.ClearCmdQueue,
    TxRequestTypes!C.StopStreaming,
    TxRequestTypes!C.StartStreaming,
    TxRequestTypes!C.SetParam);

alias TxResponse(C) = SumType!(
    TxResponseTypes!C.TransmitDone,
);


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
    Flag!"isStopped" isStoppedInit = No.isStopped,
    Fiber ctxSwitch = null,
    Flag!"isForcedCtxSwitch" isForcedCtxSwitch = No.isForcedCtxSwitch,
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

    bool isStopped = isStoppedInit;

    if(!isStopped) {
    // PPSのsettling_time秒後に送信
    if(time_sync)
        usrp.setTimeUnknownPPS(0.seconds);
    else
        usrp.setTimeNow(0.seconds);

    tx_streamer.send(nullBuffers, firstMD, 1);
    }

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
                if((isForcedCtxSwitch || isStopped) && ctxSwitch !is null)
                    ctxSwitch.yield();

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
                                        // 他のスレッドが終了するまで待つ
                                        notifyAndWait(r.isDone, r.myIndex, ctxSwitch, stop_signal_called);
                                        alloc.dispose(cast(void[])r.isReady);
                                        alloc.dispose(cast(void[])r.isDone);
                                    } else {
                                        // 自分は設定完了したことを他のスレッドに伝える
                                        atomicStore(r.isDone[r.myIndex], true);
                                    }
                                }

                            if(isStopped) {
                                // 停止中なので何もしない
                                atomicStore(r.isReady[r.myIndex], true);
                                atomicStore(r.isDone[r.myIndex], true);
                                return;
                            }

                            // 現在送信中のストリームを終了
                            tx_streamer.send(nullBuffers, endMD, 0.1);

                            dbg.writeln("Ready sync and wait other threads...");
                            // 自分は準備完了したことを他のスレッドに伝える
                            if(!notifyAndWait(r.isReady, r.myIndex, ctxSwitch, stop_signal_called)) return;

                            // PPSのsettling_time秒後に送信
                            if(time_sync)
                                usrp.setTimeUnknownPPS(0.seconds);
                            else
                                usrp.setTimeNow(0.seconds);

                            dbg.writeln("Send stream command");
                            tx_streamer.send(nullBuffers, firstMD, 1);
                            dbg.writeln("Restart transmit");
                        },
                        (TxRequestTypes!C.ClearCmdQueue) {
                            while(!txMsgQueue.emptyRequest)
                                txMsgQueue.popRequest();
                        },
                        (TxRequestTypes!C.StopStreaming r) {
                            import core.atomic;
                            scope(exit) {
                                // 完了報告
                                if(r.isDone !is null) atomicStore(*(r.isDone), true);
                            }

                            if(isStopped)
                                return;

                            //send a mini EOB packet
                            tx_streamer.send(nullBuffers, endMD, 0.1);
                            isStopped = true;
                        },
                        (TxRequestTypes!C.StartStreaming r) {
                            if(!isStopped)
                                return;
                            
                            tx_streamer.send(nullBuffers, firstMD, 1);
                            isStopped = false;
                        },
                        (TxRequestTypes!C.SetParam r) {
                            scope(exit) {
                                // 正常に終了していない場合はisDoneがfalseなのでエラーフラグを立てて通知する
                                if(!atomicLoad(*(r.isDone))) {
                                    atomicStore(*(r.isDone), true);
                                    atomicStore(*(r.isError), true);
                                }
                            }

                            switch(r.type) {
                                case "gain":
                                    foreach(i, chidx; tx_channel_nums) {
                                        usrp.setTxGain(r.param[i], chidx);
                                        r.param[i] = usrp.getTxGain(chidx);
                                    }
                                    break;

                                case "freq":
                                    foreach(i, chidx; tx_channel_nums) {
                                        bool tx_int_n = false;
                                        if("int_n" in settings)
                                            tx_int_n = (settings["int_n"].type == JSONType.array) ? settings["int_n"][i].boolean : settings["int_n"].boolean;

                                        TuneRequest tx_tune_request = TuneRequest(r.param[i]);
                                        if(tx_int_n) tx_tune_request.args = "mode_n=integer";
                                        usrp.tuneTxFreq(tx_tune_request, chidx);
                                        r.param[i] = usrp.getTxFreq(chidx);
                                    }
                                    break;

                                default:
                                    dbg.writefln("Unexpected parameter type: %s", r.type);
                                    foreach(ref e; r.param)
                                        e = typeof(e).nan;

                                    break;
                            }

                            atomicStore(*(r.isDone), true);
                        }
                    )();
                    writeln("POP");
                }
                b = true;
            }

            if(!isStopped){
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

    if(!isStopped) {
    //send a mini EOB packet
    tx_streamer.send(nullBuffers, endMD, 0.1);
    }

    if(error)
        throw error.makeException();
}
