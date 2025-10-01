module controller.cyclicrx;

import core.atomic;
import core.sync.event;
import core.lifetime;

import std.algorithm : min;
import std.exception;
import std.experimental.allocator;
import std.format;
import std.json;

import controller;
import device;
import multithread;
import utils;
import types;


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
        _requestWaitQueue = new LockFreeSPSCQueue!(ReceiveRequest)(1024);
        _requestDoneQueue = new LockFreeSPSCQueue!(ReceiveRequest)(1024);
    }


    override
    void onInit()
    {
        _receiveBuffers = alloc.makeMultidimensionalArray!C((cast(shared) this)._numTotalStream, _alignSize);
        _receiveDoneSamples = alloc.makeArray!size_t((cast(shared) this)._numTotalStream);
        _receiveDoneSamples[] = 0;
    }


    override
    void onFinish()
    {
        if(_isStreaming) {
            foreach(StreamerType d; this.streamers)
                d.stopContinuousReceive(null);
        }

        alloc.disposeMultidimensionalArray(_receiveBuffers);
        _receiveBuffers = null;
        alloc.dispose(_receiveDoneSamples);
        _receiveDoneSamples = null;
    }


    override
    void onStart()
    {
        this._startWithQuery(null);
    }


    private void _startWithQuery(scope const(ubyte)[] query) @nogc
    {
        _receiveDoneSamples[] = 0; // 受信完了サンプル数を初期化
        if(_isStreaming) {
            foreach(StreamerType d; this.streamers) {
                d.startContinuousReceive(query);
            }
        }
    }


    override
    void onRunTick()
    {
        // dbg.writefln("isStreaming=%s, alignSize=%s, _receiveBuffers.ptr=%s, _request.hasRequest=%s", _isStreaming, _alignSize, _receiveBuffers.ptr, _request.hasRequest);

        if(_isStreaming) {
            size_t idx;
            foreach(StreamerType s; this.streamers){
                C[][32] _tmpbuffers;
                size_t[32] dones;
                assert(s.numChannel <= dones.length, "Too many channels in a single streamer.");
                foreach(i; 0 .. s.numChannel)
                    _tmpbuffers[i] = _receiveBuffers[idx + i][_receiveDoneSamples[idx + i] .. $];

                s.singleReceive(_tmpbuffers[0 .. s.numChannel], null, dones[0 .. s.numChannel]);
                _receiveDoneSamples[idx .. idx + s.numChannel] += dones[0 .. s.numChannel];

                // 次のスレッドへ
                idx += s.numChannel;
            }

            // 全バッファーがすべて受信完了したかどうかを確認
            bool allDone = true;
            foreach(i, e; _receiveDoneSamples) {
                if(e < _receiveBuffers[i].length) {
                    allDone = false;
                    break;
                }
            }

            // 全バッファーがすべて受信完了していたら受信サンプル数を初期化
            if(allDone)
                _receiveDoneSamples[] = 0;

            // 現在処理中のリクエストがなく，待機列にはあるならば，待機列からリクエストを取り出す
            if(!_requestNow.hasRequest && !_requestWaitQueue.empty) {
                ReceiveRequest req;
                if(_requestWaitQueue.pop(req)) {
                    _requestNow.buffer = cast(shared(C)[][]) req.buffer;
                    _requestNow.remain = req.buffer[0].length;
                    _requestNow.hasRequest = true;
                }
            }

            // 受信要求があり、かつすべてのバッファーが受信完了している場合は、受信したデータを要求されたバッファーに書き込む
            if(_requestNow.hasRequest && allDone) {
                import std.algorithm : min;
                size_t num = min(_requestNow.remain, _alignSize);
                // dbg.writefln("remain=%s, alignSize=%s, num=%s", _requestNow.remain, _alignSize, num);

                foreach(i, e; _receiveBuffers)
                    _requestNow.buffer[i][$ - _requestNow.remain .. $ - _requestNow.remain + num] = e[0 .. num];
                
                _requestNow.remain -= num;

                // リクエストが完了したら，完了キューに追加
                if(_requestNow.remain == 0) {
                    ReceiveRequest doneReq;
                    doneReq.buffer = cast(shared) _requestNow.buffer;
                    if(_requestDoneQueue.push(doneReq)) {
                        _requestNow.hasRequest = false;
                        _requestNow.buffer = null;
                    }
                }
            }
        }
    }


    override
    void onPause()
    {
        if(_isStreaming) {
            foreach(StreamerType s; this.streamers)
                s.stopContinuousReceive(null);
        }
    }


    override
    void onResume()
    {
        this._startWithQuery(null);
    }


  private:
    bool _isStreaming;
    size_t _alignSize;
    C[][] _receiveBuffers;
    size_t[] _receiveDoneSamples;
    // ReceiveRequest _request;

    size_t _numTotalStream() shared {
        size_t dst;
        foreach(shared(StreamerType) s; this.streamers)
            dst += s.numChannel;
        
        return dst;
    }

    static struct ReceiveRequest {
        // shared(NotifiedLazy!bool)* pdone;
        shared(C[][]) buffer;
        // size_t remain;
        // bool hasRequest = false;
    }

    shared LockFreeSPSCQueue!(ReceiveRequest) _requestWaitQueue;
    shared LockFreeSPSCQueue!(ReceiveRequest) _requestDoneQueue;

    static struct ReceiveRequestNowProcessing {
        shared(C)[][] buffer = null;
        size_t remain = 0;
        bool hasRequest = false;
    }
    ReceiveRequestNowProcessing _requestNow;
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
    void setup(string name, IStreamer[] rxs, JSONValue[string] settings)
    {
        super.setup(name, rxs, settings);
        foreach(i, e; rxs) {
            assert(e.numChannel > 0);
            enforce(isSameStreamerElementType!C(e.elementType), "The streamer#%s is not a %s type.".format(i));
            _streamers_tmp ~= enforce(cast(IContinuousReceiver!C) e, "The streamer#%s is not a IContinuousReceiver.".format(i));
        }

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
            foreach(ref d; _streamers_tmp)
                thread.registerStreamer(d);

            this.registerThread(thread);
            thread.start();
        } else {
            foreach(d; _streamers_tmp) {
                auto thread = new CyclicRXControllerThread!C(this._alignSize, this._initStreaming);
                thread.registerStreamer(d);

                this.registerThread(thread);
                thread.start();
            }
        }

        _streamers_tmp = null;
    }


    override
    void processMessage(scope const(ubyte)[] msgbin, void delegate(scope const(ubyte)[]) writer)
    {
        dbg.writefln("msgbin.length = %s [bytes]", msgbin.length);
        dbg.writefln("msgbin = %s", msgbin);

        auto reader = BinaryReader(msgbin);
        const(ubyte)[] subargs = reader.tryDeserializeArray!ubyte.enforceIsNotNull("Cannot read subargs").get;
        dbg.writefln("subargs = %s", subargs);
        UniqueArray!ubyte query = makeUniqueArray!ubyte(subargs.length);
        query.array[] = subargs[];

        ubyte msgtype = reader.tryDeserialize!ubyte.enforceIsNotNull("Cannot read msgtype").get;
        dbg.writefln("msgtype = 0x%X", msgtype);

        switch(msgtype) {
        // case 0b00010000:
        //     break;
        
        case 0b00010001:        // ループ受信の開始
            foreach(size_t i, ThreadType t; this.threadList) {
                t.invoke(function(CyclicRXControllerThread!C thread, ref UniqueArray!ubyte query){
                    if(!thread._isStreaming) {
                        thread._isStreaming = true;
                        thread._startWithQuery(query.array);
                    }
                }, query.dup);
            }
            break;

        case 0b00010010:        // ループ受信の終了
            foreach(size_t i, ThreadType t; this.threadList) {
                t.invoke(function(CyclicRXControllerThread!C thread, ref UniqueArray!ubyte query){
                    if(thread._isStreaming) {
                        thread._isStreaming = false;
                        foreach(thread.StreamerType s; thread.streamers)
                            s.stopContinuousReceive(query.array);
                    }
                }, query.dup);
            }
            break;

        case 0b00010011:         // alignSizeの変更
            enforce(query.length == 0, "Ignore subargs");
            ulong newAlignSize = reader.tryDeserialize!ulong.enforceIsNotNull("Cannot read align size").get;
            this._alignSize = newAlignSize;

            foreach(size_t i, ThreadType t; this.threadList) {
                t.invoke(function(CyclicRXControllerThread!C thread, ulong newAlignSize){
                    thread._alignSize = newAlignSize;
                    thread.alloc.disposeMultidimensionalArray(thread._receiveBuffers);
                    thread._receiveBuffers = alloc.makeMultidimensionalArray!C((cast(shared) thread)._numTotalStream, thread._alignSize);
                }, newAlignSize);
            }
            break;

        case 0b00010100:        // 受信要求
            enforce(query.length == 0, "Ignore subargs");
            size_t numRecvSamples = reader.tryDeserialize!ulong.enforceIsNotNull("Cannot read number of samples").get;
            dbg.writefln("numRecvSamples = %s", numRecvSamples);

            // 受信要求を各スレッドにプッシュする
            this.pushReceiveRequest(numRecvSamples, writer);
            break;

        case 0b00010101:        // 受信結果の取得
            enforce(query.length == 0, "Ignore subargs");
            size_t maxResult = reader.tryDeserialize!ulong.enforceIsNotNull("Cannot read max result").get;
            size_t minResult = reader.tryDeserialize!ulong.enforceIsNotNull("Cannot read min result").get;
            dbg.writefln("maxResult = %s, minResult = %s", maxResult, minResult);

            // 各スレッドから受信結果をポップする
            this.popReceiveResult(maxResult, minResult, writer);
            break;
        
        case 0b00010110:        // サンプルの型の取得
            enforce(query.length == 0, "Ignore subargs");
            static if(is(typeof(C.init.re) == float))
                immutable elemTypeStr = "ComplexFloat32";
            else static if(is(typeof(C.init.re) == double))
                immutable elemTypeStr = "ComplexFloat64";
            else static if(is(typeof(C.init.re) == short))
                immutable elemTypeStr = "ComplexInt16";
            else static if(is(typeof(C.init.re) == byte))
                immutable elemTypeStr = "ComplexInt8";
            else
                static assert(false, "Unsupported type");

            rawWriteValue!ulong(writer, elemTypeStr.length);
            writer(cast(ubyte[]) elemTypeStr);
            break;

        default:
            dbg.writefln("Unsupported msgtype %X", msgbin[0]);
            break;
        }
    }


    ThreadType.ReceiveRequest makeReceiveRequest(size_t numStream, size_t numRecvSamples)
    {
        // 受信要求を作成する
        auto buffer = cast(shared) alloc.makeMultidimensionalArray!C(numStream, numRecvSamples);
        auto req = ThreadType.ReceiveRequest(buffer);
        return req;
    }


    void disposeReceiveRequest(ref ThreadType.ReceiveRequest req)
    {
        // 受信要求を破棄する
        if(req.buffer !is null) {
            alloc.disposeMultidimensionalArray(cast(C[][]) req.buffer);
            req.buffer = null;
        }
    }


    void pushReceiveRequest(size_t numRecvSamples, scope void delegate(scope const(ubyte)[]) writer)
    {
        // まずは全てのスレッドのキューに空きがあるかを確認する
        bool allNotFilled = true;
        foreach(size_t i, ThreadType t; this.threadList) {
            if(t._requestWaitQueue.filled) {
                allNotFilled = false;
                break;
            }
        }

        // 空きがなかったらクライアントに"F"を返す
        if(!allNotFilled) {
            writer(cast(ubyte[1])['F']);    // Failure
            dbg.writefln("Cannot push receive request: all queues are filled.");
            return;
        }

        foreach(size_t i, ThreadType t; this.threadList) {
            // 各スレッドに受信要求を送る
            auto req = this.makeReceiveRequest(t._numTotalStream, numRecvSamples);
            enforce(t._requestWaitQueue.push(req));
        }

        // すべてのスレッドに受信要求を送ったら成功を返す
        writer(cast(ubyte[1])['S']);
    }


    void popReceiveResult(size_t maxResult, size_t minResult, scope void delegate(scope const(ubyte)[]) writer)
    {
        // すべてのスレッドから取り出せる結果の数を計算する
        size_t numResult;
        while(1) {
            numResult = maxResult; // 初期値は最大数
            foreach(size_t i, ThreadType t; this.threadList) {
                size_t n = t._requestDoneQueue.length;
                numResult = min(numResult, n);
            }

            // 最小数以上の結果が得られたらループを抜ける
            if(numResult >= minResult)
                break;

            import core.thread : Thread;
            Thread.yield(); // まだ結果が得られない場合は、スレッドを一時停止して待機する
        }

        // numResultをクライアントに返す
        rawWriteValue!ulong(writer, numResult);

        foreach(i; 0 .. numResult) {
            rawWriteValue!ulong(writer, this._numTotalStreamAllThread);
            foreach(size_t j, ThreadType t; this.threadList) {
                // 各スレッドから受信結果を取り出す
                ThreadType.ReceiveRequest req;
                enforce(t._requestDoneQueue.pop(req));

                foreach(i, C[] e; cast(C[][]) req.buffer) {
                    rawWriteValue!ulong(writer, e.length);
                    writer(cast(ubyte[])e);
                }

                // 受信要求を破棄する
                this.disposeReceiveRequest(req);
            }
        }
    }


  private:
    bool _singleThread = false;
    size_t _alignSize = 4096;
    bool _initStreaming = true;
    IContinuousReceiver!C[] _streamers_tmp;


    size_t _numTotalStreamAllThread()
    {
        size_t dst;
        foreach(ThreadType t; this.threadList) {
            dst += t._numTotalStream;
        }

        return dst;
    }


    private
    static void rawWriteValue(T)(scope void delegate(scope const(ubyte)[]) writer, T value)
    {
        T[1] arr = [value];
        writer(cast(ubyte[]) arr[]);
    }
}


unittest
{
    import std;
    import core.thread;
    alias C = Complex!float;

    class TestReceiver : IContinuousReceiver!C
    {
        size_t _numRxStream;
        C[][] buffer;
        string state = "init";
        size_t index;

        this(size_t n, C[][] buf) { _numRxStream = n; buffer = buf; assert(buffer.length == _numRxStream); }

        string nameImpl() shared const @nogc { return "TestReceiver"; }
        StreamerElementType elementTypeImpl() shared @nogc { return StreamerElementType.ComplexFloat32; }
        shared(IDevice) device() shared @nogc { return null; }
        size_t numChannelImpl() shared const @nogc { return _numRxStream; }
        void singleReceive(scope C[][] signal, scope const(ubyte)[] q, scope size_t[] rxsamples) @nogc {
            foreach(i, e; signal) {
                foreach(j; 0 .. e.length) {
                    e[j] = cast()buffer[i][(index + j) % $];
                }
                rxsamples[i] = e.length;
            }

            index += signal[0].length;
        }
        void startContinuousReceive(scope const(ubyte)[] q) @nogc { assert(state != "start"); atomicStore(state, "start"); }
        void stopContinuousReceive(scope const(ubyte)[] q) @nogc { assert(state != "stop"); atomicStore(state, "stop"); }
    }

    auto ctrl = new CyclicRXController!C();
    
    // すべてのテストデバイスは，10の約数の周期の信号を生成している
    TestReceiver[] devs = [
        new TestReceiver(2, [[C(1, 1), C(2, 2)], [C(3, 3), C(4, 4)]]),            // 周期2
        new TestReceiver(1, [[C(5, 5), C(6, 6), C(7, 7), C(8, 8), C(9, 9)]]),     // 周期5
        new TestReceiver(3, [[C(10, 10)], [C(11, 11)], [C(12, 12)]])];            // 周期1

    // alignSize=10にすれば，かならず受信信号の先頭は上でデバイスに設定した配列の先頭になるため，先頭要素はランダムにならない
    import std.algorithm : map;
    ctrl.setup("TestRXController", devs.map!(a => cast(IStreamer) a).array(), ["alignSize": JSONValue(10)]);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    Thread.sleep(10.msecs);
    foreach(d; devs) assert(d.state == "start");

    ubyte[8] subargsLengthBinary = [0, 0, 0, 0, 0, 0, 0, 0];
    foreach(_; 0 .. 10) {
        // ループ受信の開始
        immutable(ubyte)[] responseBinary;
        ulong[1] numRecv = [73];

        // 受信要求
        ctrl.processMessage(subargsLengthBinary ~ [cast(ubyte)0b00010100] ~ cast(ubyte[])numRecv[], (const(ubyte)[] buf){
            responseBinary ~= buf;
        });

        ulong[2] minmaxRecv = [1, 1];

        // 受信結果の取得
        ctrl.processMessage(subargsLengthBinary ~ [cast(ubyte)0b00010101] ~ cast(ubyte[])minmaxRecv[], (const(ubyte)[] buf){
            responseBinary ~= buf;
        });

        auto reader = BinaryReader(responseBinary);
        assert(reader.read!ubyte == 'S'); // 成功
        assert(reader.read!ulong == 1); // 受信結果の数
        assert(reader.read!ulong == ctrl._numTotalStreamAllThread);     // 受信ストリームの数
        foreach(i; 0 .. ctrl._numTotalStreamAllThread) {
            assert(reader.read!ulong == 73);    // 受信サンプル数
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

    // サンプル型の取得
    ubyte[] respbuf;
    ctrl.processMessage(subargsLengthBinary ~ [cast(ubyte)0b00010110], (scope const(ubyte)[] buf){
        respbuf ~= buf;
    });
    writefln("respbuf = %s", respbuf);
    assert(respbuf.length == (8 + "ComplexFloat32".length));
    assert(respbuf[0] == "ComplexFloat32".length);
    foreach(i; 1 .. 8)
        assert(respbuf[i] == 0);

    assert(cast(char[])respbuf[8 .. $] == "ComplexFloat32");
}
