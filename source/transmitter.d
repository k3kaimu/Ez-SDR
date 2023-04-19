module transmitter;

import core.thread;

import std.experimental.allocator;
import std.sumtype;
import std.complex;
import std.math;
import std.stdio;
import std.typecons;

import utils;
import msgqueue;

import uhd.usrp;
import uhd.capi;
import uhd.utils;

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
    }
}


struct TxResponseTypes(C)
{
    static struct TransmitDone
    {
        C[][] buffer;
    }
}


alias TxRequest(C) = SumType!(TxRequestTypes!C.Transmit, TxRequestTypes!C.SyncToPPS);
alias TxResponse(C) = SumType!(TxResponseTypes!C.TransmitDone);



/***********************************************************************
 * transmit_worker function
 * A function to be used as a boost::thread_group thread for transmitting
 **********************************************************************/
void transmit_worker(C, Alloc)(
    ref shared bool stop_signal_called,
    ref Alloc alloc,
    ref USRP usrp,
    size_t nTXUSRP,
    string cpu_format,
    string wire_format,
    bool time_sync,
    immutable(size_t)[] tx_channel_nums,
    float settling_time,
    ref shared MsgQueue!(shared(TxRequest!C)*, shared(TxResponse!C)*) txMsgQueue,
){
    alias dbg = debugMsg!"transmit_worker";

    scope(exit) {
        writefln("[transmit_worker] END transmit_worker");
        writefln("[transmit_worker] stop_signal_called = %s", stop_signal_called);
    }

    StreamArgs stream_args = StreamArgs(cpu_format, wire_format, "", tx_channel_nums);
    auto tx_streamer = usrp.makeTxStreamer(stream_args);

    C[][] nullBuffers;
    foreach(i; 0 .. nTXUSRP) nullBuffers ~= null;

    // TxMetaData firstMD = TxMetaData((cast(long)floor(settling_time*1E6)).usecs + 1.seconds, true, false);
    TxMetaData firstMD = TxMetaData((cast(long)floor(settling_time*1E6)).usecs, true, false);
    TxMetaData afterFirstMD = TxMetaData(false, 0, 0, false, false);
    TxMetaData endMD = TxMetaData(false, 0, 0, false, true);
    VUHDException error;

    C[][] initTxBuffers = alloc.makeMultidimensionalArray!C(nTXUSRP, 4096);
    scope(exit) alloc.disposeMultidimensionalArray(initTxBuffers);
    foreach(i; 0 .. nTXUSRP)
        initTxBuffers[i][] = C(0);

    // C[][] txbuffers = alloc.makeMultidimensionalArray!C(nTXUSRP, 4096);
    // scope(exit) alloc.disposeMultidimensionalArray(txbuffers);

    shared(TxRequest!C)* nowTargetRequest;
    shared(TxRequestTypes!C.Transmit) nowTargetTransmitRequest;
    // auto nowTargetBuffers = new shared(const(C))[][](nTXUSRP);

    scope(exit) {
        if(nowTargetRequest !is null)
            txMsgQueue.pushResponse(nowTargetRequest, cast(shared)alloc.make!(TxResponse!C)(TxResponseTypes!C.TransmitDone(cast(C[][]) nowTargetTransmitRequest.buffer)));

        nowTargetRequest = null;
        nowTargetTransmitRequest = typeof(nowTargetTransmitRequest).init;
    }

    // PPSのsettling_time秒後に送信
    if(time_sync)
        usrp.setTimeUnknownPPS(0.seconds);
    else
        usrp.setTimeNow(0.seconds);

    tx_streamer.send(nullBuffers, firstMD, 1);

    const(C)[][128] _tmpbuffers;
    Nullable!VUHDException transmitAllBuffer(const(C)[][] buffers)
    in(buffers.length == nTXUSRP)
    {
        size_t numTotalSamples = 0;
        while(numTotalSamples < buffers[0].length && !stop_signal_called) {
            // dbg.writefln("*");
            // {
            //     import std.algorithm;
            //     immutable nMin = min(buffers[0].length, txbuffers[0].length - numTotalSamples);
            //     foreach(i; 0 .. nTXUSRP) {
            //         txbuffers[i][0 .. nMin] = buffers[i][numTotalSamples .. numTotalSamples + nMin];
            //         _tmpbuffers[i] = txbuffers[i][0 .. nMin];
            //     }
            // }

            foreach(i; 0 .. nTXUSRP)
                _tmpbuffers[i] = buffers[i][numTotalSamples .. $];

            size_t txsize;
            if(auto err = tx_streamer.send(_tmpbuffers[0 .. nTXUSRP], afterFirstMD, 0.1, txsize)){
                // error = err;
                // writeln(err);
                // Thread.sleep(2.seconds);
                // transmit_worker!C(stop_signal_called, alloc, nTXUSRP, txMsgQueue, tx_streamer, metadata);
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

                while(! txMsgQueue.emptyRequest) {
                    writeln("POPOPOP");
                    auto req = txMsgQueue.popRequest();
                    (cast(TxRequest!C) *req).match!(
                        (TxRequestTypes!C.Transmit r) {
                            if(nowTargetRequest !is null)
                                txMsgQueue.pushResponse(nowTargetRequest, cast(shared)alloc.make!(TxResponse!C)(TxResponseTypes!C.TransmitDone(cast(C[][]) nowTargetTransmitRequest.buffer)));

                            nowTargetRequest = req;
                            nowTargetTransmitRequest = cast(shared)r;
                        },
                        (TxRequestTypes!C.SyncToPPS r) {
                                import core.atomic;
                                scope(exit) {
                                    alloc.dispose(req);
                                    if(r.myIndex == 0)
                                        alloc.dispose(cast(void[])r.isReady);
                                }

                                // 現在送信中のストリームを終了
                                tx_streamer.send(nullBuffers, endMD, 0.1);

                                dbg.writeln("Ready sync and wait other threads...");
                                // 自分は準備完了したことを他のスレッドに伝える
                                atomicStore(r.isReady[r.myIndex], true);

                                // 他のスレッドがすべて準備完了するまでwhileで待つ
                                while(1) {
                                    bool check = true;
                                    foreach(ref b; r.isReady)
                                        check = check && atomicLoad(b);

                                    if(check)
                                        break;
                                }

                                // PPSのsettling_time秒後に送信
                                if(time_sync)
                                    usrp.setTimeUnknownPPS(0.seconds);
                                else
                                    usrp.setTimeNow(0.seconds);
                                tx_streamer.send(nullBuffers, firstMD, 1);
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
                auto err = transmitAllBuffer(nowTargetRequest is null ? cast(const(C)[][])initTxBuffers : cast(const(C)[][])nowTargetTransmitRequest.buffer);
                if(! err.isNull) {
                    error = err.get;
                    writeln(error);
                    Thread.sleep(2.seconds);
                    transmit_worker!C(stop_signal_called, alloc, usrp, nTXUSRP, cpu_format, wire_format, time_sync, tx_channel_nums, settling_time, txMsgQueue);
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

