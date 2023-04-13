module transmitter;

import core.thread;

import std.experimental.allocator;
import std.sumtype;
import std.complex;
import std.stdio;
import std.typecons;

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
}


struct TxResponseTypes(C)
{
    static struct TransmitDone
    {
        C[][] buffer;
    }
}


alias TxRequest(C) = SumType!(TxRequestTypes!C.Transmit);
alias TxResponse(C) = SumType!(TxResponseTypes!C.TransmitDone);



/***********************************************************************
 * transmit_worker function
 * A function to be used as a boost::thread_group thread for transmitting
 **********************************************************************/
void transmit_worker(C, Alloc)(
    ref shared bool stop_signal_called,
    ref Alloc alloc,
    size_t nTXUSRP,
    ref shared MsgQueue!(shared(TxRequest!C)*, shared(TxResponse!C)*) txMsgQueue,
    ref TxStreamer tx_streamer,
    ref TxMetaData metadata
){
    scope(exit) {
        writeln("END transmit_worker");
    }

    C[][] eob;
    foreach(i; 0 .. nTXUSRP) eob ~= null;

    TxMetaData afterFirstMD = TxMetaData(false, 0, 0, false, false);
    TxMetaData endMD = TxMetaData(false, 0, 0, false, true);
    VUHDException error;

    tx_streamer.send(eob, metadata, 0.1);

    C[][] initTxBuffers = alloc.makeMultidimensionalArray!C(nTXUSRP, 4096);
    scope(exit) alloc.disposeMultidimensionalArray(initTxBuffers);
    foreach(i; 0 .. nTXUSRP)
        initTxBuffers[i][] = C(0);

    shared(TxRequest!C)* nowTargetRequest;
    shared(TxRequestTypes!C.Transmit) nowTargetTransmitRequest;
    // auto nowTargetBuffers = new shared(const(C))[][](nTXUSRP);

    scope(exit) {
        if(nowTargetRequest !is null)
            txMsgQueue.pushResponse(nowTargetRequest, cast(shared)alloc.make!(TxResponse!C)(TxResponseTypes!C.TransmitDone(cast(C[][]) nowTargetTransmitRequest.buffer)));

        nowTargetRequest = null;
        nowTargetTransmitRequest = typeof(nowTargetTransmitRequest).init;
    }

    const(C)[][] _tmpbuffers = alloc.makeArray!(const(C)[])(nTXUSRP);
    Nullable!VUHDException transmitAllBuffer(const(C)[][] buffers)
    {
        size_t numTotalSamples = 0;
        while(numTotalSamples < buffers[0].length && !stop_signal_called) {
            foreach(i; 0 .. nTXUSRP)
                _tmpbuffers[i] = buffers[i][numTotalSamples .. $];

            size_t txsize;
            if(auto err = tx_streamer.send(_tmpbuffers, afterFirstMD, 0.1, txsize)){
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
            while(! txMsgQueue.emptyRequest) {
                auto req = txMsgQueue.popRequest();
                (cast(TxRequest!C) *req).match!(
                    (TxRequestTypes!C.Transmit r) {
                        if(nowTargetRequest !is null)
                            txMsgQueue.pushResponse(nowTargetRequest, cast(shared)alloc.make!(TxResponse!C)(TxResponseTypes!C.TransmitDone(cast(C[][]) nowTargetTransmitRequest.buffer)));

                        nowTargetRequest = req;
                        nowTargetTransmitRequest = cast(shared)r;
                    }
                )();
            }

            {
                auto err = transmitAllBuffer(nowTargetRequest is null ? cast(const(C)[][])initTxBuffers : cast(const(C)[][])nowTargetTransmitRequest.buffer);
                if(! err.isNull) {
                    error = err.get;
                    writeln(error);
                    Thread.sleep(2.seconds);
                    transmit_worker!C(stop_signal_called, alloc, nTXUSRP, txMsgQueue, tx_streamer, metadata);
                }
                write("T");
            }
        }
    }();

    //send a mini EOB packet
    tx_streamer.send(eob, endMD, 0.1);

    if(error)
        throw error.makeException();
}

