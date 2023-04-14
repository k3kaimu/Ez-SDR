module receiver;

import core.time;
import core.thread;

import std.algorithm : min;
import std.sumtype;
import std.complex;
import std.stdio;
import std.math;
import std.experimental.allocator;
import std.typecons;

import utils;
import msgqueue;

import lock_free.rwqueue;

import uhd.usrp;
import uhd.capi;
import uhd.utils;


struct RxRequestTypes(C)
{
    // static struct ChangeAlignSize
    // {
    //     size_t alignSize;
    // }


    // static struct DelayAlign
    // {
    //     size_t delaySize;
    // }


    static struct Receive
    {
        C[][] buffer;
    }
}


struct RxResponseTypes(C)
{
    static struct Receive
    {
        C[][] buffer;
    }
}


alias RxRequest(C) = SumType!(/*RxRequestTypes!C.ChangeAlignSize, RxRequestTypes!C.DelayAlign, */RxRequestTypes!C.Receive);
alias RxResponse(C) = SumType!(RxResponseTypes!C.Receive);



void receive_worker(C, Alloc)(
    ref shared bool stop_signal_called,
    ref Alloc alloc,
    ref USRP usrp,
    size_t nRXUSRP,
    string cpu_format,
    string wire_format,
    immutable(size_t)[] rx_channel_nums,
    float settling_time,
    ref shared MsgQueue!(shared(RxRequest!C)*, shared(RxResponse!C)*) rxMsgQueue,
)
{
    alias dbg = debugMsg!"receive_worker";

    scope(exit) {
        dbg.writeln("END receive_worker");
    }

    int num_total_samps = 0;
    //create a receive streamer
    dbg.writeln("CPU_FORMAT: ", cpu_format);
    dbg.writeln("WIRE_FORMAT: ", wire_format);
    StreamArgs stream_args = StreamArgs(cpu_format, wire_format, "", rx_channel_nums);
    RxStreamer rx_stream = usrp.makeRxStreamer(stream_args);

    // Prepare buffers for received samples and metadata
    RxMetaData md = makeRxMetaData();
    C[][] receiveBuffers = alloc.makeMultidimensionalArray!C(nRXUSRP, 4096);
    scope(exit) {
        alloc.disposeMultidimensionalArray(receiveBuffers);
    }

    bool overflow_message = true;
    float timeout = settling_time + 0.1f; //expected settling time + padding for first recv

    //setup streaming
    usrp.setTimeNow(0.seconds);
    StreamCommand stream_cmd = StreamCommand.startContinuous;
    stream_cmd.streamNow = rx_channel_nums.length == 1 ? true : false;
    stream_cmd.timeSpec = (cast(long)floor(settling_time*1E6)).usecs;
    rx_stream.issue(stream_cmd);

    shared(RxRequest!C)* nowTargetRequest;
    shared(RxRequestTypes!C.Receive) nowTargetReceiveRequest;
    auto nowTargetBuffers = new shared(C)[][](nRXUSRP);


    // fillBufferの内部で利用する
    C[][] _tmpbuffers = alloc.makeArray!(C[])(nRXUSRP);
    scope(exit) alloc.dispose(_tmpbuffers);

    Nullable!VUHDException fillBuffer(C[][] buffer)
    in {
        assert(buffer.length == nRXUSRP);
        foreach(i; 0 .. nRXUSRP)
            assert(buffer[i].length == buffer[0].length);
    }
    do {
        scope(exit) foreach(i; 0 .. nRXUSRP) _tmpbuffers[i] = null;

        size_t numTotalSamples = 0;
        while(numTotalSamples < buffer[0].length) {
            foreach(i; 0 .. nRXUSRP)
                _tmpbuffers[i] = buffer[i][numTotalSamples .. $];

            size_t num_rx_samps;
            if(auto err = rx_stream.recv(_tmpbuffers, md, timeout, num_rx_samps)){
                return typeof(return)(err);
            }
            numTotalSamples += num_rx_samps;
        }

        return typeof(return).init;
    }


    VUHDException error;
    Thread.sleep(1.seconds);
    () {
        while(! stop_signal_called) {

            // リクエストの処理をする
            while(! rxMsgQueue.emptyRequest) {
                auto req = rxMsgQueue.popRequest();
                dbg.writeln("POP Request!");
                (cast()*req).match!(
                    (RxRequestTypes!C.Receive r) {
                        dbg.writeln("POP Receive Request!");
                        nowTargetRequest = req;
                        nowTargetReceiveRequest = cast(shared)r;
                        foreach(i; 0 .. nRXUSRP)
                            nowTargetBuffers[i] = cast(shared)r.buffer[i];
                    }
                )();
            }


            // 受信をする
            {
                auto err = fillBuffer(receiveBuffers);
                if(!err.isNull) {
                    error = err.get;
                    return;
                }
            }
            timeout = 0.1f; //small timeout for subsequent recv

            md.ErrorCode errorCode;
            if(auto uhderr = md.getErrorCode(errorCode)){
                error = uhderr;
                Thread.sleep(2.seconds);
                receive_worker!C(stop_signal_called, alloc, usrp, nRXUSRP, cpu_format, wire_format, rx_channel_nums, settling_time, rxMsgQueue);
            }
            if (errorCode == md.ErrorCode.TIMEOUT) {
                import core.stdc.stdio : puts;
                puts("Timeout while streaming");
                break;
            }
            if (errorCode == md.ErrorCode.OVERFLOW) {
                if (overflow_message){
                    import core.stdc.stdio : fprintf, stderr;
                    overflow_message = false;
                    fprintf(stderr, "Got an overflow indication.");
                }
                continue;
            }
            if (errorCode != md.ErrorCode.NONE) {
                import core.stdc.stdio : fprintf, stderr;
                md.printError();
                fprintf(stderr, "Unknown error.");
            }


            // コピーする
            if(nowTargetRequest !is null && nowTargetBuffers[0].length != 0) {
                immutable numCopy = min(nowTargetBuffers[0].length, receiveBuffers[0].length);
                foreach(i; 0 .. nRXUSRP) {
                    nowTargetBuffers[i][0 .. numCopy] = receiveBuffers[i][0 .. numCopy];
                    nowTargetBuffers[i] = nowTargetBuffers[i][numCopy .. $];
                }
            }

            // レスポンスを返す
            if(nowTargetRequest !is null && nowTargetBuffers[0].length == 0) {
                rxMsgQueue.pushResponse(nowTargetRequest, cast(shared)alloc.make!(RxResponse!C)(RxResponseTypes!C.Receive(cast(C[][]) nowTargetReceiveRequest.buffer)));
                dbg.writeln("Push Response!");
                nowTargetRequest = null;
                nowTargetReceiveRequest = typeof(nowTargetReceiveRequest).init;
                foreach(i; 0 .. nRXUSRP)
                    nowTargetBuffers[i] = null;
            }
        }
    }();

    // Shut down receiver
    rx_stream.issue(StreamCommand.stopContinuous);

    if(error)
        throw error.makeException();
}
