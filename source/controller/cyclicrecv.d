module controller.cyclicrecv;

import core.atomic;
import core.sync.event;

import std.exception;
import std.experimental.allocator;
import std.format;
import std.json;

import controller;
import device;
import multithread;
import utils;


class CyclicRXControllerThread(C) : ControllerThreadImpl!(IContinuousReceiver!C)
{
    import std.experimental.allocator.mallocator;
    alias alloc = Mallocator.instance;
    alias dbg = debugMsg!"CyclicRXControllerThread";


    this(size_t alignSize, bool initStreaming = true)
    {
        super();
        _alignSize = alignSize;
        _isStreaming = initStreaming;
    }


    override
    void onInit(DontCallOnOtherThread) shared
    {
        _receiveBuffers = alloc.makeMultidimensionalArray!(shared(C))(this._numTotalStream, _alignSize);
    }


    override
    void onFinish(DontCallOnOtherThread) shared
    {
        if(_isStreaming) {
            foreach(DeviceType d; this.deviceList)
                d.stopContinuousReceive();
        }

        alloc.disposeMultidimensionalArray(cast(C[][])_receiveBuffers);
        _receiveBuffers = null;
    }


    override
    void onStart(DontCallOnOtherThread) shared
    {
        if(_isStreaming) {
            foreach(DeviceType d; this.deviceList)
                d.startContinuousReceive();
        }
    }


    override
    void onRunTick(DontCallOnOtherThread) shared
    {
        // dbg.writefln("isStreaming=%s, alignSize=%s, _receiveBuffers.ptr=%s, _request.hasRequest=%s", _isStreaming, _alignSize, _receiveBuffers.ptr, _request.hasRequest);

        if(_isStreaming) {
            size_t idx;
            foreach(DeviceType d; this.deviceList){
                d.singleReceive(cast(C[][])_receiveBuffers[idx .. idx + d.numRxStream]);
                idx += d.numRxStream;
            }

            if(_request.hasRequest) {
                import std.algorithm : min;
                size_t num = min(_request.remain, _alignSize);
                // dbg.writefln("remain=%s, alignSize=%s, num=%s", _request.remain, _alignSize, num);

                foreach(i, e; _receiveBuffers)
                    _request.buffer[i][$ - _request.remain .. $ - _request.remain + num] = e[0 .. num];
                
                cast()_request.remain -= num;

                if(_request.remain == 0) {
                    _request.pdone.write(true);
                    _request.hasRequest = false;
                    _request.pdone = null;
                    _request.buffer = null;
                }
            }
        }
    }


    override
    void onPause(DontCallOnOtherThread) shared
    {
        if(_isStreaming) {
            foreach(DeviceType d; this.deviceList)
                d.stopContinuousReceive();
        }
    }


    override
    void onResume(DontCallOnOtherThread) shared
    {
        if(_isStreaming) {
            foreach(DeviceType d; this.deviceList)
                d.startContinuousReceive();
        }
    }


  private:
    bool _isStreaming;
    size_t _alignSize;
    shared(C)[][] _receiveBuffers;
    ReceiveRequest _request;

    size_t _numTotalStream() shared {
        size_t dst;
        foreach(DeviceType d; this.deviceList)
            dst += d.numRxStream;
        
        return dst;
    }

    static struct ReceiveRequest {
        shared(NotifiedLazy!bool)* pdone;
        shared(C)[][] buffer;
        size_t remain;
        bool hasRequest = false;
    }
}


class CyclicRXController(C) : ControllerImpl!(CyclicRXControllerThread!C)
{
    import std.experimental.allocator.mallocator;
    alias alloc = Mallocator.instance;
    alias dbg = debugMsg!"CyclicRXController";


    this()
    {
        super();
    }


    override
    void setup(LocalRef!(shared(IDevice))[] devs, JSONValue[string] settings)
    {
        IContinuousReceiver!C[] tmplist;
        foreach(i, ref LocalRef!(shared(IDevice)) e; devs) {
            assert(e.numRxStream > 0);
            tmplist ~= enforce(cast(IContinuousReceiver!C) cast()(e.get), "The device#%s is not a IContinuousReceiver.".format(i));
        }

        _devs = cast(shared) tmplist;

        if("singleThread" in settings && settings["singleThread"].get!bool)
            _singleThread = true;

        if("alignSize" in settings && settings["alignSize"].get!size_t) {
            _alignSize = settings["alignSize"].get!size_t;
        } else {
            _alignSize = 4096;
        }

        if("initStreaming" in settings) {
            _initStreaming = settings["initStreaming"].get!bool;
        }
    }


    override
    void spawnDeviceThreads()
    {
        if(_singleThread) {
            auto thread = new CyclicRXControllerThread!C(this._alignSize, this._initStreaming);
            foreach(ref d; _devs)
                thread.registerDevice(d);

            this.registerThread(thread);
            thread.start();
        } else {
            foreach(d; _devs) {
                auto thread = new CyclicRXControllerThread!C(this._alignSize);
                thread.registerDevice(d);

                this.registerThread(thread);
                thread.start();
            }
        }
    }


    override
    void processMessage(scope const(ubyte)[] msgbin, void delegate(scope const(ubyte)[]) writer)
    {
        dbg.writefln("msgtype = 0x%X, msglen = %s [bytes]", msgbin[0], msgbin.length);

        auto reader = BinaryReader(msgbin);
        if(reader.length < 1)
            return;

        switch(reader.read!ubyte) {
        case 0b00010000:        // 受信命令
            processReceiveMessage(reader.read!(ulong), writer);
            break;
        default:
            dbg.writefln("Unsupported msgtype %X", msgbin[0]);
            break;
        }
    }


    void processReceiveMessage(size_t numRecvSamples, void delegate(scope const(ubyte)[]) writer)
    {
        auto buffer = UniqueArray!(C, 2)(this._numTotalStreamAllThread, numRecvSamples);
        auto doneEvent = UniqueArray!(shared(NotifiedLazy!bool)*)(this.threadList.length);
        foreach(ref e; doneEvent.array) e = NotifiedLazy!bool.make();
        scope(exit) foreach(ref e; doneEvent.array) NotifiedLazy!bool.dispose(cast(NotifiedLazy!bool*)e);

        size_t idx;
        foreach(size_t i, ThreadType t; this.threadList) {
            t.invoke(function(shared(CyclicRXControllerThread!C) thread, shared(C[][]) buf, shared(NotifiedLazy!bool)* pdone){
                if(!thread._isStreaming) {
                    thread._isStreaming = true;
                    foreach(thread.DeviceType d; thread.deviceList)
                        d.startContinuousReceive();
                }

                assert(!thread._request.hasRequest);
                thread._request.remain = buf[0].length;
                thread._request.pdone = pdone;
                thread._request.buffer = buf;
                thread._request.hasRequest = true;
            }, cast(shared(C[][])) buffer.array[idx .. idx + t._numTotalStream], doneEvent.array[i]);

            idx += t._numTotalStream;
        }

        // すべてのスレッドが終了するまで待つ
        foreach(ref e; doneEvent.array) e.read();

        // 返答する
        foreach(i, C[] e; buffer.array) {
            ulong[1] sizebuf = [e.length];
            writer(cast(ubyte[])sizebuf[]);
            writer(cast(ubyte[])e);
        }
    }


  private:
    bool _singleThread = false;
    size_t _alignSize = 4096;
    bool _initStreaming = true;
    shared(IContinuousReceiver!C)[] _devs;


    size_t _numTotalStreamAllThread()
    {
        size_t dst;
        foreach(ThreadType t; this.threadList) {
            dst += t._numTotalStream;
        }

        return dst;
    }
}


unittest
{
    import std;
    import core.thread;
    alias C = Complex!float;

    class TestDevice : IContinuousReceiver!C
    {
        size_t _numRxStream;
        C[][] buffer;
        string state;
        size_t index;

        this(size_t n, C[][] buf) { _numRxStream = n; buffer = buf; assert(buffer.length == _numRxStream); }

        void construct() { state = "init"; }
        void destruct() { state = "finished"; }
        void setup(JSONValue[string] configJSON) {}
        size_t numTxStreamImpl() shared { return 0; }
        size_t numRxStreamImpl() shared { return atomicLoad(_numRxStream); }
        synchronized void singleReceive(scope C[][] signal) {
            foreach(i, e; signal) {
                foreach(j; 0 .. e.length) {
                    e[j] = cast()buffer[i][(index + j) % $];
                }
            }

            index.atomicOp!"+="(signal[0].length);
        }
        synchronized void startContinuousReceive() { assert(state != "start"); atomicStore(state, "start"); }
        synchronized void stopContinuousReceive() { assert(state != "stop"); atomicStore(state, "stop"); }
        synchronized void setParam(const(char)[] key, const(char)[] value) {}
        synchronized const(char)[] getParam(const(char)[] key) { return null; }
    }

    auto ctrl = new CyclicRXController!C();
    
    // すべてのテストデバイスは，10の約数の周期の信号を生成している
    TestDevice[] devs = [
        new TestDevice(2, [[C(1, 1), C(2, 2)], [C(3, 3), C(4, 4)]]),            // 周期2
        new TestDevice(1, [[C(5, 5), C(6, 6), C(7, 7), C(8, 8), C(9, 9)]]),     // 周期5
        new TestDevice(3, [[C(10, 10)], [C(11, 11)], [C(12, 12)]])];            // 周期1
    foreach(d; devs) d.construct();

    // alignSize=10にすれば，かならず受信信号の先頭は上でデバイスに設定した配列の先頭になるため，先頭要素はランダムにならない
    ctrl.setup(devs.map!(a => localRef(cast(shared(IDevice))a)).array, ["alignSize": JSONValue(10)]);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    Thread.sleep(10.msecs);
    foreach(d; devs) assert(d.state == "start");

    foreach(_; 0 .. 10) {
        // ループ受信の開始
        immutable(ubyte)[] responseBinary;
        ulong[1] numRecv = [73];
        ctrl.processMessage([cast(ubyte)0b00010000] ~ cast(ubyte[])numRecv[], (const(ubyte)[] buf){
            responseBinary ~= buf;
        });

        auto reader = BinaryReader(responseBinary);
        foreach(i; 0 .. ctrl._numTotalStreamAllThread) {
            assert(reader.read!ulong == 73);
            auto recv = reader.readArray!C(73);
            foreach(j, e; recv) {
                ulong x;
                if(i == 0 || i == 1) x = i*2 + j%2 + 1;
                if(i == 2) x = j%5 + 5;
                if(i == 3 || i == 4 || i == 5) x = i + 7;
                // writefln("%s == %s -> %s", e, C(x, x), e == C(x, x));
                assert(e == C(x, x));
            }
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
}
