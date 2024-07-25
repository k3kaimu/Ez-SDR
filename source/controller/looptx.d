module controller.looptx;

import core.thread;

import std.json;
import std.sumtype;
import std.exception;
import std.format;
import std.stdio;

import std.experimental.allocator;
import std.experimental.allocator.mallocator;


import controller;
import device;
import msgqueue;
import utils;



class LoopTXController(C) : IController
{
    enum size_t maxTotalStream = 32;

    this() {}

    void setup(IDevice[] devs, JSONValue[string])
    {
        foreach(i, e; devs) {
            _devs ~= enforce(cast(ILoopTransmitter!C) e, "The device#%s is not a ILoopTransmitter.".format(i));
            _msgQueueList ~= new UniqueMsgQueue!(ReqTypes, ResTypes)();

            enforce(e.numTxStream() <= maxTotalStream, "The controller '%s' can handle only %s streams for each device at most.".format(typeof(this).stringof, maxTotalStream));
        }

        this._killSwitch = false;
    }
    

    void spawnDeviceThreads()
    {
        auto makeThread(alias fn, T...)(ref shared(bool) stop_signal_called, T args)
        {
            return new Thread(delegate(){
                scope(exit) stop_signal_called = true;

                try
                    fn(stop_signal_called, args);
                catch(Throwable ex){
                    import std.stdio;
                    writeln(ex);
                }
            });
        }

        foreach(i, d; _devs) {
            _devthreads ~= makeThread!(loopTXControllerDeviceThread!C)(this._killSwitch, d, this._msgQueueList[i].makeExecuter);
            _devthreads[i].start();
        }
    }


    void killDeviceThreads()
    {
        _killSwitch = true;
    }


    // 先頭1バイトでメッセージの種類を判断
    // 0x000XXXXX   デバイスセット設定など（32種類）
    // 0b001XXXXX   送信系（32種類）
    // 0x010XXXXX   受信系（32種類）
    // 0b011XXXXX   
    // 0x1XXXXXXX　ユーザー定義命令
    void processMessage(scope const(ubyte)[] msgbin, void delegate(scope const(ubyte)[]) writer)
    {
        auto alloc = Mallocator.instance;
        alias dbg = debugMsg!"LoopTXController";
        dbg.writefln("msgtype = 0x%X, msglen = %s [bytes]", msgbin[0], msgbin.length);

        auto reader = BinaryReader(msgbin);
        if(reader.length < 1)
            return;

        switch(reader.read!ubyte) {
        case 0b0010000:     // 送信信号の設定
            size_t cntStream = 0;
            foreach(i, d; _devs) {
                RequestTypes!C.SetTransmitSignal req;
                foreach(j; 0 .. d.numTxStream()) {
                    if(!reader.canRead!size_t) { dbg.writefln("Cannot read %s-th signal length", cntStream); return; }
                    immutable siglen = reader.read!size_t;
                    dbg.writefln("siglen = %s", siglen);

                    if(!reader.canReadArray!C(siglen)) { dbg.writefln("Cannot read %s-th signal (len = %s)", cntStream, siglen); return; }
                    const(C)[] sig = reader.readArray!C(siglen);
                    ++cntStream;

                    C[] buf = alloc.makeArray!C(siglen);
                    buf[] = sig[];
                    req.buffer[j] = buf;
                }
                _msgQueueList[i].pushRequest(ReqTypes(req));
            }
            break;

        case 0b0010001:     // ループ送信の開始
            foreach(d; _devs)
                d.startLoopTransmit();
            break;
        case 0b0010010:     // ループ送信の終了
            foreach(d; _devs)
                d.stopLoopTransmit();
            break;
        default:
            dbg.writefln("Unsupported msgtype %X", msgbin[0]);
        }
    }


  private:
    ILoopTransmitter!C[] _devs;
    shared(bool) _killSwitch;
    shared(UniqueMsgQueue!(ReqTypes, ResTypes))[] _msgQueueList;
    Thread[] _devthreads;


    alias ReqTypes = SumType!(
        RequestTypes!C.SetTransmitSignal,
        RequestTypes!C.StartLoopTransmit,
        RequestTypes!C.StopLoopTransmit,
        RequestTypes!C.SetParam,
        RequestTypes!C.SyncPPS);

    alias ResTypes = SumType!(int);

    static struct RequestTypes(C)
    {
        static struct SetTransmitSignal
        {
            C[][maxTotalStream] buffer;
        }


        static struct StartLoopTransmit {}
        static struct StopLoopTransmit {}

        static struct SetParam
        {
            string key;
            string value;
        }

        static struct SyncPPS
        {
            DeviceTime settling;
        }
    }


    static struct ResponseTypes(C)
    {

    }


    static void loopTXControllerDeviceThread(C)(
        ref shared(bool) killSwitch,
        ILoopTransmitter!C dev,
        UniqueMsgQueue!(ReqTypes, ResTypes).Executer msgQueue)
    {
        alias dbg = debugMsg!"loopTXControllerDeviceThread";
        auto alloc = Mallocator.instance;

        immutable size_t numTxStream = dev.numTxStream;
        bool isStreaming = false;

        while(!killSwitch) {
            // すべてのリクエストを処理する
            while(! msgQueue.emptyRequest) {
                dbg.writeln("POP Request");

                auto req = cast()msgQueue.popRequest();
                req.match!(
                    (RequestTypes!C.SetTransmitSignal r) {
                        dev.setLoopTransmitSignal(r.buffer[0 .. numTxStream]);
                        foreach(e; r.buffer[0 .. numTxStream]) {
                            if(e.length) alloc.dispose(e);
                        }
                    },
                    (RequestTypes!C.StartLoopTransmit r) {
                        dev.startLoopTransmit();
                        isStreaming = true;
                    },
                    (RequestTypes!C.StopLoopTransmit r) {
                        dev.stopLoopTransmit();
                        isStreaming = false;
                    },
                    (RequestTypes!C.SetParam r) {
                        enforce(cast(IReconfigurable) dev, "The device is not IReconfigurable").setParam(r.key, r.value);
                    },
                    (RequestTypes!C.SyncPPS r) {
                        if(auto syncdev = cast(IPPSSynchronizable) dev) {
                            if(isStreaming)
                                dev.stopLoopTransmit();
                            
                            syncdev = enforce(cast(IPPSSynchronizable) dev, "The device is not IPPSSynchronizable");
                            syncdev.setTimeNextPPS(DeviceTime(0.0));
                            syncdev.setNextCommandTime(r.settling);
                            dev.startLoopTransmit();
                        }
                    }
                );
            }

            if(isStreaming) {
                // ループ送信に必要な処理があれば実行する
                dev.performLoopTransmit();
            }
        }
    }
}


unittest
{
    import std;
    alias C = Complex!float;

    class TestDevice : ILoopTransmitter!C
    {
        size_t _numTxStream;
        C[][] _buffer;
        string state;
        size_t cntPerf;

        this(size_t n) { _numTxStream = n; }

        void construct() { state = "init"; }
        void destruct() { state = "finished"; }
        void setup(JSONValue[string] configJSON) {}
        size_t numTxStream() { return _numTxStream; }
        size_t numRxStream() { return 0; }
        void setLoopTransmitSignal(scope const C[][] signal) {
            _buffer = null;
            foreach(e; signal)
                _buffer ~= e.dup;
        }
        void startLoopTransmit() { state = "start"; }
        void stopLoopTransmit() { state = "stop"; }
        void performLoopTransmit() { ++cntPerf; Thread.sleep(10.msecs); }
    }

    auto ctrl = new LoopTXController!C();
    TestDevice[] devs = [new TestDevice(2), new TestDevice(1), new TestDevice(3)];
    ctrl.setup(devs.map!(a => cast(IDevice)a).array, null);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    Thread.sleep(100.msecs);

    C[][] txsignals = [[C(0, 0)], [C(1, 1)], [C(2, 2)], [C(3, 3)], [C(4, 4)], [C(5, 5)]];
    
    // ubyte[] txmsg = [cast(ubyte)0b0010000] ~ cast(ubyte[])txsignals;
    ubyte[] txmsg = [cast(ubyte)0b0010000];
    foreach(e; txsignals) {
        size_t[] len = [e.length];
        txmsg ~= cast(ubyte[])len;
        txmsg ~= cast(ubyte[])e;
    }
    assert(txmsg.length == 1 + (8 + 8) * 6);
    

    ctrl.processMessage(txmsg, (scope const(ubyte)[] buf){});
    ctrl.processMessage([cast(ubyte)0b0010001], (scope const(ubyte)[] buf){});
    Thread.sleep(100.msecs);

    size_t cnt;
    foreach(id, d; devs) {
        assert(devs[id].state == "start");
        assert(devs[id]._buffer.length == d.numTxStream);

        foreach(istream; 0 .. d.numTxStream) {
            assert(devs[id]._buffer[istream][0] == C(cnt, cnt));
            ++cnt;
        }
    }

    ctrl.processMessage([cast(ubyte)0b0010010], (scope const(ubyte)[] buf){});
    Thread.sleep(100.msecs);
    foreach(d; devs) assert(d.state == "stop");
}
