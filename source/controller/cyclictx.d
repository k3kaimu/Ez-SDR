module controller.cyclictx;

import core.lifetime;
import core.thread;
import core.sync.event;
import core.atomic;

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
import multithread;



class CyclicTXControllerThread(C) : ControllerThreadImpl!(ILoopTransmitter!C)
{
    alias alloc = Mallocator.instance;


    this()
    {
        super();
    }


    override
    void onInit()
    {
        isStreaming = false;
    }


    override
    void onStart() { }


    override
    void onRunTick()
    {
        if(isStreaming) {
            foreach(StreamerType e; this.streamers)
                e.performLoopTransmit(null);
        }
    }


    override
    void onFinish()
    {
        if(isStreaming) {
            foreach(StreamerType e; this.streamers)
                e.stopLoopTransmit(null);
        }

        isStreaming = false;
    }


    override
    void onPause()
    {
        if(isStreaming) {
            foreach(StreamerType e; this.streamers) {
                e.stopLoopTransmit(_addinfoOnNextPause.array);
                _addinfoOnNextPause.resize(0);
            }
        }
    }


    override
    void onResume()
    {
        if(isStreaming) {
            foreach(StreamerType e; this.streamers) {
                e.startLoopTransmit(_addinfoOnNextResume.array);
                _addinfoOnNextResume.resize(0);
            }
        }
    }


  private:
    bool isStreaming = false;
    UniqueArray!(ubyte) _addinfoOnNextResume;
    UniqueArray!(ubyte) _addinfoOnNextPause;
}


class CyclicTXController(C) : ControllerImpl!(CyclicTXControllerThread!C)
{
    alias dbg = debugMsg!"CyclicTXController";


    this()
    {
        super();
    }


    override
    void setup(IStreamer[] streamers, JSONValue[string] settings)
    {
        foreach(i, e; streamers) {
            _streamers ~= cast(shared) enforce(cast(ILoopTransmitter!C) e, "The streamer#%s is not a ILoopTransmitter.".format(i));
        }

        if("singleThread" in settings && settings["singleThread"].get!bool)
            _singleThread = true;
    }


    override
    void spawnDeviceThreads()
    {
        if(_singleThread) {
            auto thread = new CyclicTXControllerThread!C();
            foreach(e; _streamers)
                thread.registerStreamer(cast()e);

            this.registerThread(thread);
            thread.start();
        } else {
            foreach(e; _streamers) {
                auto thread = new CyclicTXControllerThread!C();
                thread.registerStreamer(cast()e);

                this.registerThread(thread);
                thread.start();
            }
        }
    }


    override
    void processMessage(scope const(ubyte)[] msgbin, void delegate(scope const(ubyte)[]) writer)
    {
        alias alloc = Mallocator.instance;
        dbg.writefln("msgbin.length = %s [bytes]", msgbin.length);
        dbg.writefln("msgbin = %s", msgbin);

        auto reader = BinaryReader(msgbin);
        const(ubyte)[] subargs = reader.tryDeserializeArray!ubyte.enforceIsNotNull("Cannot read subargs").get;
        dbg.writefln("subargs = %s", subargs);

        UniqueArray!ubyte query = makeUniqueArray!ubyte(subargs.length);
        query.array[] = subargs[];

        ubyte msgtype = reader.tryDeserialize!ubyte.enforceIsNotNull("Cannot read msgtype").get;
        dbg.writefln("msgtype = %s", msgtype);

        UniqueArray!T parseAndAllocArray(T)() {
            if(!reader.canRead!size_t) { dbg.writeln("Cannot read array"); return typeof(return).init; }
            immutable arrlen = reader.read!size_t;
            dbg.writefln("arrlen = %s", arrlen);

            if(!reader.canReadArray!T(arrlen)) { dbg.writefln("Cannot read array (len = %s)", arrlen); return typeof(return).init; }
            const(T)[] arr = reader.readArray!T(arrlen);
            UniqueArray!T dst = makeUniqueArray!T(arr.length);
            dst.array[] = arr[];
            return move(dst);
        }


        switch(msgtype) {
        case 0b00001000:        // Resume device thread with optArgs
            this.resumeDeviceThreads();
            break;

        case 0b00001001:        // Pause device threads with optArgs
            this.pauseDeviceThreads();
            break;

        case 0b00010000:        // 送信信号の設定
            size_t totStream = 0;
            foreach(e; _streamers) totStream += e.numChannel();
            if(_singleThread) {
                UniqueArray!(C, 2) buffer = makeUniqueArray!(C, 2)(totStream);
                foreach(i; 0 .. totStream) buffer[i] = parseAndAllocArray!C();

                this.threadList[0].invoke(function(CyclicTXControllerThread!C thread, ref UniqueArray!(C, 2) buf, ref UniqueArray!ubyte query) {
                    size_t idx;
                    foreach(thread.StreamerType e; thread.streamers) {
                        e.setLoopTransmitSignal(buf.array[idx .. idx + e.numChannel], query.array);
                        idx += e.numChannel;
                    }
                }, move(buffer), move(query));
            } else {
                foreach(size_t i, this.ThreadType t; this.threadList) {
                    assert(t.streamers.length == 1);
                    auto e = t.streamers[0];
                    UniqueArray!(C, 2) buffer = makeUniqueArray!(C, 2)(e.numChannel);
                    foreach(j; 0 .. e.numChannel) {
                        dbg.writefln("e.numChannel: %s, j: %s, buffer.length: %s", e.numChannel, j, buffer.length);
                        buffer[j] = parseAndAllocArray!C();
                    }

                    t.invoke(function(CyclicTXControllerThread!C thread, ref UniqueArray!(C, 2) buf) {
                        thread.streamers[0].setLoopTransmitSignal(buf.array, null);
                    }, move(buffer));
                }
            }
            break;

        case 0b00010001:     // ループ送信の開始
            foreach(ThreadType t; this.threadList)
                t.invoke(function(CyclicTXControllerThread!C thread, ref UniqueArray!ubyte query){
                    if(!thread.isStreaming) {
                        foreach(thread.StreamerType e; thread.streamers) e.startLoopTransmit(query.array);
                        thread.isStreaming = true;
                    }
                }, query.dup);
            break;
        case 0b00010010:     // ループ送信の終了
            foreach(ThreadType t; this.threadList)
                t.invoke(function(CyclicTXControllerThread!C thread, ref UniqueArray!ubyte query){
                    if(thread.isStreaming) {
                        foreach(thread.StreamerType e; thread.streamers) e.stopLoopTransmit(query.array);
                        thread.isStreaming = false;
                    }
                }, query.dup);
            break;

        default:
            dbg.writefln("Unsupported msgtype %s", msgtype);
        }
    }


  private:
    shared(ILoopTransmitter!C)[] _streamers;
    bool _singleThread = false;
}



unittest
{
    import std;
    alias C = Complex!float;

    class TestTransmitter : ILoopTransmitter!C
    {
        size_t _numTxStream;
        UniqueArray!(C, 2) _buffer;
        string state = "init";
        size_t cntPerf;

        this(size_t n) { _numTxStream = n; }

        shared(IDevice) device() shared @nogc { return null; }
        size_t numChannelImpl() shared @nogc { return atomicLoad(_numTxStream); }
        void setLoopTransmitSignal(scope const C[][] signal, scope const(ubyte)[] q) {
            import core.lifetime : move;

            auto newbuf = makeUniqueArray!(C, 2)(signal.length);
            foreach(i; 0 .. signal.length) {
                auto e = makeUniqueArray!C(signal[i].length);
                e.array[] = signal[i][];
                newbuf[i] = move(e);
            }

            move(newbuf, cast()_buffer);
        }
        void startLoopTransmit(scope const(ubyte)[] q) { assert(state != "start"); atomicStore(state, "start"); }
        void stopLoopTransmit(scope const(ubyte)[] q) { assert(state != "stop"); atomicStore(state, "stop"); }
        void performLoopTransmit(scope const(ubyte)[] q) { ++cntPerf; Thread.sleep(1.msecs); }
    }

    auto ctrl = new CyclicTXController!C();
    TestTransmitter[] devs = [new TestTransmitter(2), new TestTransmitter(1), new TestTransmitter(3)];
    ctrl.setup(devs.map!(a => cast(IStreamer) a).array(), null);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    Thread.sleep(10.msecs);

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
    
    // 信号の設定
    ctrl.processMessage(txmsg, (scope const(ubyte)[] buf){});

    // ループ送信の開始
    ctrl.processMessage([cast(ubyte)0b00010001], (scope const(ubyte)[] buf){});
    Thread.sleep(10.msecs);

    size_t cnt;
    foreach(id, d; devs) {
        assert(devs[id].state == "start");
        assert(devs[id]._buffer.array.length == d.numChannel);

        foreach(istream; 0 .. d.numChannel) {
            assert(devs[id]._buffer.array[istream][0] == C(cnt, cnt));
            ++cnt;
        }
    }

    // デバイススレッドを一度止める
    ctrl.pauseDeviceThreads();
    Thread.sleep(10.msecs);

    // ループ送信は一時停止
    foreach(d; devs) assert(d.state == "stop");

    // デバイススレッドを再開する
    ctrl.resumeDeviceThreads();
    Thread.sleep(10.msecs);

    // ループ送信は再開されている
    foreach(d; devs) assert(d.state == "start");

    // ループ送信している状態でループ送信開始命令を送っても無視
    ctrl.processMessage([cast(ubyte)0b00010001], (scope const(ubyte)[] buf){});
    Thread.sleep(10.msecs);
    foreach(d; devs) assert(d.state == "start");

    // ループ送信の終了
    ctrl.processMessage([cast(ubyte)0b0010010], (scope const(ubyte)[] buf){});
    Thread.sleep(10.msecs);
    foreach(d; devs) assert(d.state == "stop");
    foreach(d; devs) assert(d.cntPerf > 0);

    // ループ送信が止まっている状態でループ送信停止命令を送っても無視
    ctrl.processMessage([cast(ubyte)0b0010010], (scope const(ubyte)[] buf){});
    Thread.sleep(10.msecs);
}
