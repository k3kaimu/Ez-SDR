module controller.looptx;

import core.thread;
import core.sync.event;

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



class LoopTXControllerThread(C) : ControllerThreadImpl!(ILoopTransmitter!C)
{
    alias alloc = Mallocator.instance;


    this()
    {
        super();
        _queue = new Requests.Queue;
    }


    override
    void onInit()
    {
        isStreaming = false;
        isPaused = false;
    }


    override
    void onStart() { }


    override
    void onRunTick()
    {
        // writeln("OnRunTick");
        while(!_queue.emptyRequest()) {
            auto req = _queue.popRequest();

            req.match!(
                (Requests.SetTransmitSignal r) {
                    size_t idx = 0;
                    foreach(d; this.deviceList) {
                        d.setLoopTransmitSignal(r.buffer[idx .. idx + d.numTxStream]);
                        idx += d.numTxStream;
                    }

                    foreach(ref e; r.buffer) {
                        alloc.dispose(e);
                        e = null;
                    }
                    alloc.dispose(r.buffer);
                    r.buffer = null;
                },
                (Requests.StartLoopTransmit) {
                    foreach(d; this.deviceList) {
                        d.startLoopTransmit();
                    }
                    isStreaming = true;
                },
                (Requests.StopLoopTransmit) {
                    foreach(d; this.deviceList) {
                        d.stopLoopTransmit();
                    }
                    isStreaming = false;
                }
            )();
        }

        // writeln("OnRunTick2: ", isStreaming);

        if(isStreaming) {
            foreach(d; this.deviceList)
                d.performLoopTransmit();
        }
    }


    override
    void onFinish()
    {
        if(isStreaming) {
            foreach(d; this.deviceList)
                d.stopLoopTransmit();
        }

        isStreaming = false;
    }


    override
    void onPause()
    {
        if(isStreaming) {
            foreach(d; this.deviceList)
                d.stopLoopTransmit();

            isStreaming = false;
            isPaused = true;
        }
    }


    override
    void onResume()
    {
        if(isPaused) {
            foreach(d; this.deviceList)
                d.startLoopTransmit();

            isStreaming = true;
            isPaused = false;
        }
    }


    void setTransmitSignal(scope const(C)[][] signals)
    {
        Requests.SetTransmitSignal req;
        req.buffer = alloc.makeArray!(C[])(signals.length);
        foreach(i; 0 .. signals.length) {
            req.buffer[i] = alloc.makeArray!C(signals[i].length);
            req.buffer[i][] = signals[i][];
        }

        _queue.pushRequest(Requests.Types(req));
    }


    void startLoopTransmit()
    {
        _queue.pushRequest(Requests.Types(Requests.StartLoopTransmit()));
    }


    void stopLoopTransmit()
    {
        _queue.pushRequest(Requests.Types(Requests.StopLoopTransmit()));
    }


  private:
    bool isStreaming = false;
    bool isPaused = false;
    shared(Requests.Queue) _queue;


    static struct Requests
    {
        static struct SetTransmitSignal { C[][] buffer; }
        static struct StartLoopTransmit {}
        static struct StopLoopTransmit {}

        alias Types = SumType!(SetTransmitSignal, StartLoopTransmit, StopLoopTransmit);
        alias Queue = UniqueRequestQueue!Types;
    }
}


class LoopTXController(C) : ControllerImpl!(LoopTXControllerThread!C)
{
    this()
    {
        super();
    }


    override
    void setup(IDevice[] devs, JSONValue[string] settings)
    {
        foreach(i, e; devs) {
            _devs ~= enforce(cast(ILoopTransmitter!C) e, "The device#%s is not a ILoopTransmitter.".format(i));
        }

        if("singleThread" in settings && settings["singleThread"].get!bool)
            _singleThread = true;
    }


    override
    void spawnDeviceThreads()
    {
        if(_singleThread) {
            auto thread = new LoopTXControllerThread!C();
            foreach(d; _devs)
                thread.registerDevice(d);

            this.registerThread(thread);
            thread.start();
        } else {
            foreach(d; _devs) {
                auto thread = new LoopTXControllerThread!C();
                thread.registerDevice(d);

                this.registerThread(thread);
                thread.start();
            }
        }
    }


    override
    void processMessage(scope const(ubyte)[] msgbin, void delegate(scope const(ubyte)[]) writer)
    {
        auto alloc = Mallocator.instance;
        alias dbg = debugMsg!"LoopTXController";
        dbg.writefln("msgtype = 0x%X, msglen = %s [bytes]", msgbin[0], msgbin.length);

        auto reader = BinaryReader(msgbin);
        if(reader.length < 1)
            return;

        switch(reader.read!ubyte) {
        case 0b00001000:        // Resume Device Thread
            this.resumeDeviceThreads();
            break;

        case 0b00001001:
            this.pauseDeviceThreads();
            break;

        case 0b00010000:        // 送信信号の設定
            size_t cntStream = 0;
            const(C)[] parseSignal() {
                if(!reader.canRead!size_t) { dbg.writefln("Cannot read %s-th signal length", cntStream); return null; }
                immutable siglen = reader.read!size_t;
                dbg.writefln("siglen = %s", siglen);

                if(!reader.canReadArray!C(siglen)) { dbg.writefln("Cannot read %s-th signal (len = %s)", cntStream, siglen); return null; }
                return reader.readArray!C(siglen);
            }

            size_t totStream = 0;
            foreach(d; _devs) totStream += d.numTxStream();
            if(_singleThread) {
                const(C)[][] buffer = alloc.makeArray!(const(C)[])(totStream);
                scope(exit) alloc.dispose(buffer);

                foreach(i; 0 .. totStream) buffer[i] = parseSignal();
                this.threadList[0].setTransmitSignal(buffer);
            } else {
                foreach(i, t; this.threadList) {
                    assert(t.deviceList.length == 1);
                    auto d = t.deviceList[0];
                    const(C)[][] buffer = alloc.makeArray!(const(C)[])(d.numTxStream);
                    scope(exit) alloc.dispose(buffer);

                    foreach(j; 0 .. d.numTxStream) buffer[j] = parseSignal();   
                    t.setTransmitSignal(buffer);
                }
            }
            break;

        case 0b00010001:     // ループ送信の開始
            foreach(t; this.threadList)
                t.startLoopTransmit();
            break;
        case 0b00010010:     // ループ送信の終了
            foreach(t; this.threadList)
                t.stopLoopTransmit();
            break;
        default:
            dbg.writefln("Unsupported msgtype %X", msgbin[0]);
        }
    }


  private:
    ILoopTransmitter!C[] _devs;
    bool _singleThread = false;
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
        void setParam(const(char)[] key, const(char)[] value) {}
        const(char)[] getParam(const(char)[] key) { return null; }
    }

    auto ctrl = new LoopTXController!C();
    TestDevice[] devs = [new TestDevice(2), new TestDevice(1), new TestDevice(3)];
    foreach(d; devs) d.construct();
    ctrl.setup(devs.map!(a => cast(IDevice)a).array, null);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    Thread.sleep(100.msecs);

    foreach(id, d; devs) {
        assert(devs[id].state == "init");
    }

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
    ctrl.processMessage([cast(ubyte)0b00010001], (scope const(ubyte)[] buf){});
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
    foreach(d; devs) assert(d.cntPerf > 0);
}
