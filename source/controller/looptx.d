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
    }


    override
    void onInit(DontCallOnOtherThread) shared
    {
        isStreaming = false;
        isPaused = false;
    }


    override
    void onStart(DontCallOnOtherThread) shared { }


    override
    void onRunTick(DontCallOnOtherThread) shared
    {
        if(isStreaming) {
            foreach(d; this.deviceList)
                d.performLoopTransmit();
        }
    }


    override
    void onFinish(DontCallOnOtherThread) shared
    {
        if(isStreaming) {
            foreach(d; this.deviceList)
                d.stopLoopTransmit();
        }

        isStreaming = false;
    }


    override
    void onPause(DontCallOnOtherThread) shared
    {
        if(isStreaming) {
            foreach(d; this.deviceList)
                d.stopLoopTransmit();

            isStreaming = false;
            isPaused = true;
        }
    }


    override
    void onResume(DontCallOnOtherThread) shared
    {
        if(isPaused) {
            foreach(d; this.deviceList)
                d.startLoopTransmit();

            isStreaming = true;
            isPaused = false;
        }
    }


  private:
    bool isStreaming = false;
    bool isPaused = false;
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
            _devs ~= cast(shared)enforce(cast(ILoopTransmitter!C) e, "The device#%s is not a ILoopTransmitter.".format(i));
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
        alias alloc = Mallocator.instance;
        alias dbg = debugMsg!"LoopTXController";
        dbg.writefln("msgtype = 0x%X, msglen = %s [bytes]", msgbin[0], msgbin.length);

        auto reader = BinaryReader(msgbin);
        if(reader.length < 1)
            return;

        size_t cntStream = 0;
        shared(C)[] parseAndAllocSignal() {
            if(!reader.canRead!size_t) { dbg.writefln("Cannot read %s-th signal length", cntStream); return null; }
            immutable siglen = reader.read!size_t;
            dbg.writefln("siglen = %s", siglen);

            if(!reader.canReadArray!C(siglen)) { dbg.writefln("Cannot read %s-th signal (len = %s)", cntStream, siglen); return null; }
            const(C)[] arr = reader.readArray!C(siglen);
            auto buf = alloc.makeArray!(shared(C))(arr.length);
            buf[0 .. arr.length] = arr[];
            return buf;
        }

        static void disposeSignal(shared(C[])[] buffer) {
            foreach(ref e; buffer) {
                alloc.dispose(cast(C[])e);
            }
            alloc.dispose(cast(C[][])buffer);
        }

        switch(reader.read!ubyte) {
        case 0b00001000:        // Resume Device Thread
            this.resumeDeviceThreads();
            break;

        case 0b00001001:
            this.pauseDeviceThreads();
            break;

        case 0b00010000:        // 送信信号の設定
            size_t totStream = 0;
            foreach(d; _devs) totStream += d.numTxStream();
            if(_singleThread) {
                shared(C)[][] buffer = alloc.makeArray!(shared(C)[])(totStream);
                foreach(ref e; buffer) e = parseAndAllocSignal();

                this.threadList[0].invoke(function(shared(LoopTXControllerThread!C) thread, shared(C[])[] buf){
                    size_t idx;
                    foreach(d; thread.deviceList) {
                        d.setLoopTransmitSignal(cast(C[][])buf[idx .. idx + d.numTxStream]);
                        idx += d.numTxStream;
                    }

                    disposeSignal(buf);
                }, cast(shared(C[])[])buffer);
            } else {
                foreach(i, t; this.threadList) {
                    assert(t.deviceList.length == 1);
                    auto d = t.deviceList[0];
                    shared(C)[][] buffer = alloc.makeArray!(shared(C)[])(d.numTxStream);
                    foreach(ref e; buffer) e = parseAndAllocSignal();

                    t.invoke(function(shared(LoopTXControllerThread!C) thread, shared(C[])[] buf){
                        thread.deviceList[0].setLoopTransmitSignal(cast(C[][])buf);
                        disposeSignal(buf);
                    }, cast(shared(C[])[])buffer);
                }
            }
            break;

        case 0b00010001:     // ループ送信の開始
            foreach(t; this.threadList)
                t.invoke(function(shared(LoopTXControllerThread!C) thread){
                    foreach(d; thread.deviceList) d.startLoopTransmit();
                    thread.isStreaming = true;
                });
            break;
        case 0b00010010:     // ループ送信の終了
            foreach(t; this.threadList)
                t.invoke(function(shared(LoopTXControllerThread!C) thread){
                    foreach(d; thread.deviceList) d.stopLoopTransmit();
                    thread.isStreaming = false;
                });
            break;
        default:
            dbg.writefln("Unsupported msgtype %X", msgbin[0]);
        }
    }


  private:
    shared(ILoopTransmitter!C)[] _devs;
    bool _singleThread = false;
}



unittest
{
    import std;
    alias C = Complex!float;

    class TestDevice : ILoopTransmitter!C
    {
        size_t _numTxStream;
        UniqueArray!(C[]) _buffer;
        string state;
        size_t cntPerf;

        this(size_t n) { _numTxStream = n; }

        void construct() { state = "init"; }
        void destruct() { state = "finished"; }
        void setup(JSONValue[string] configJSON) {}
        size_t numTxStreamImpl() shared { return _numTxStream; }
        size_t numRxStreamImpl() shared { return 0; }
        synchronized void setLoopTransmitSignal(scope const C[][] signal) {
            import core.lifetime : move;

            auto newbuf = makeUniqueArray!(C[])(signal.length);
            foreach(i; 0 .. signal.length) {
                auto e = makeUniqueArray!C(signal[i].length);
                e.array[] = signal[i][];
                newbuf[i] = move(e);
            }

            move(newbuf, cast()_buffer);
        }
        synchronized void startLoopTransmit() { state = "start"; }
        synchronized void stopLoopTransmit() { state = "stop"; }
        synchronized void performLoopTransmit() { cntPerf = cntPerf + 1; Thread.sleep(10.msecs); }
        synchronized void setParam(const(char)[] key, const(char)[] value) {}
        synchronized const(char)[] getParam(const(char)[] key) { return null; }
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
        assert(devs[id]._buffer.array.length == d.numTxStream);

        foreach(istream; 0 .. d.numTxStream) {
            assert(devs[id]._buffer.array[istream][0] == C(cnt, cnt));
            ++cnt;
        }
    }

    ctrl.processMessage([cast(ubyte)0b0010010], (scope const(ubyte)[] buf){});
    Thread.sleep(100.msecs);
    foreach(d; devs) assert(d.state == "stop");
    foreach(d; devs) assert(d.cntPerf > 0);
}
