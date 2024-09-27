module controller;

import core.thread;
import core.lifetime;

import std.complex;
import std.exception;
import std.socket;
import std.json;
import std.typecons;
import std.traits;

import device;
import utils;
import multithread;


interface IController
{
    void setup(IStreamer[], JSONValue[string]);

    void spawnDeviceThreads();
    void killDeviceThreads();

    void pauseDeviceThreads();
    void resumeDeviceThreads();

    void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter);
}



IController newController(string type)
{
    import controller.cyclictx;
    import controller.cyclicrx;

    switch(type) {
        case "CyclicTX":
            return new CyclicTXController!(Complex!float)();
        case "CyclicRX":
            return new CyclicRXController!(Complex!float)();
        default:
            enforce(0, "Cannot find controller '" ~ type ~ "'.");
            return null;
    }

    // return null;
}



interface IControllerThread
{
    /// スレッドの動作状態
    enum State { RUN, PAUSE, FINISH }

    /// スレッドを返します
    Thread getThread();

    /// スレッドを実行します
    void start(bool defaultRun = true);

    /// このスレッドの動作状態を返します
    State state() shared;

    /// このスレッドがデバイスを操作しているかどうかを返します
    bool hasDevice(IDevice d) shared;

    /// このスレッドを破棄する
    void kill() shared;

    /// このスレッドの操作を一時停止する
    void pause() shared;

    /// このスレッドの動作を再開する
    void resume() shared;
}



/**
このクラスのsynchronizedメソッドは，runメソッドを実行しているスレッドからしか呼び出せません．
synchronizedではないsharedメソッドは他のスレッドから呼び出される可能性があります．
*/
class ControllerThreadImpl(StreamerType_ : IStreamer) : IControllerThread
{
    alias StreamerType = StreamerType_;

    import std.sumtype;
    import msgqueue;
    import core.sync.event;
    import core.atomic;


    this()
    {
        _killSwitch = false;
        _resumeEvent.initialize(true, true);
        _taskList = SharedTaskList!(No.locked)();
        _thread = new Thread(&this.run);
    }


    Thread getThread() { return _thread; }


    void start(bool defaultRun = true)
    {
        if(defaultRun)
            _resumeEvent.setIfInitialized();
        else
            _resumeEvent.reset();

        _thread.start();
    }


    void run()
    {
        Thread.getThis.priority = Thread.PRIORITY_MAX;

        () @nogc {
            this.onInit();
            _state = State.PAUSE;

            (cast()_resumeEvent).wait();

            this.onStart();
            _state = State.RUN;

            while(!_killSwitch) {
                if(!_taskList.empty) _taskList.processAll();
                this.onRunTick();
            }
            this.onFinish();
            _state = State.FINISH;
        }();
    }


    State state() shared @nogc { return atomicLoad(_state); }
    State state() @nogc { return atomicLoad(_state); }


    abstract void onInit() @nogc;
    abstract void onRunTick() @nogc;
    abstract void onStart() @nogc;
    abstract void onFinish() @nogc;
    abstract void onPause() @nogc;
    abstract void onResume() @nogc;


    ReadOnlyArray!(StreamerType) streamers() @nogc { return _streamers.readOnlyArray; }
    ReadOnlyArray!(shared(StreamerType)) streamers() shared @nogc { return _streamers.readOnlyArray; }


    void registerStreamer(StreamerType s)
    {
        _streamers ~= s;
    }


    bool hasDevice(shared(IDevice) d) shared @nogc
    {
        foreach(e; _streamers) {
            assert(e !is null);
            if(e.device is d) return true;
        }

        return false;
    }


    bool hasStreamer(IStreamer s) shared @nogc
    {
        foreach(e; _streamers) {
            if(e is cast(shared)s) return true;
        }

        return false;
    }


    void kill() shared
    {
        _killSwitch = true;
    }


    void pause() shared @nogc
    {
        (cast()_resumeEvent).reset();
        this.invoke(function(ControllerThreadImpl _this){
            _this.onPause();
            _this._state = State.PAUSE;
            (cast()_this._resumeEvent).wait();
            _this.onResume();
            _this._state = State.RUN;
        });
    }


    void resume() shared @nogc
    {
        (cast()_resumeEvent).setIfInitialized();
    }


    void invoke(this T, Callable, U...)(Callable fn, auto ref U args) shared @nogc
    {
        static void impl(ref Callable fn, ref T this_, ref U args)
        {
            fn(cast(Unqual!T) this_, args);
        }

        _taskList.push(&impl, move(fn), cast(T) this, forward!args);
    }


  private:
    Thread _thread;
    bool _killSwitch;
    Event _resumeEvent;
    shared(SharedTaskList!(No.locked)) _taskList;
    StreamerType[] _streamers;
    shared State _state;
}


class ControllerImpl(CtrlThread : IControllerThread) : IController
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    alias ThreadType = shared(CtrlThread);

    this() {}

    abstract
    void setup(IStreamer[], JSONValue[string]);


    void registerThread(CtrlThread thread)
    {
        _threads ~= cast(shared)thread;
    }


    ReadOnlyArray!(shared(CtrlThread)) threadList()
    {
        return _threads.readOnlyArray();
    }


    abstract
    void spawnDeviceThreads();


    void killDeviceThreads()
    {
        foreach(t; _threads) t.kill();
    }


    void pauseDeviceThreads()
    {
        foreach(t; _threads) t.pause();
    }


    void resumeDeviceThreads()
    {
        foreach(t; _threads) t.resume();
    }


    abstract
    void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter);


    void applyToDeviceSync(shared(IDevice) dev, scope void delegate() dg)
    {
        alias alloc = Mallocator.instance;
        bool[] stopList = alloc.makeArray!bool(_threads.length);
        scope(exit) alloc.dispose(stopList);

        // 関連するすべてのDeviceThreadを一度止める
        foreach(i; 0 .. _threads.length) {
            // 止めたスレッドをマーキングする
            stopList[i] = _threads[i].hasDevice(dev);
            if(stopList[i])
                _threads[i].pause();
        }
        scope(exit) {
            // 止めたスレッドを実行し直す
            foreach(i; 0 .. _threads.length) {
                if(stopList[i])
                    _threads[i].resume();
            }
        }

        // すべてのスレッドが停止するまで待つ
        foreach(i, t; _threads)
            if(stopList[i])
                while(t.state != IControllerThread.State.PAUSE) { Thread.yield(); }

        // 処理を呼び出す
        dg();
    }


  private:
    shared(CtrlThread)[] _threads;
}

unittest
{
    import std.stdio;
    import std.algorithm : map;
    import std.array : array;

    class TestDevice : IDevice {
        void construct() {}
        void destruct() {}
        void setup(JSONValue[string]){}
        IStreamer makeStreamer(string[] args) shared { return null; }
        void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] optArgs) shared @nogc {}
        const(char)[] getParam(const(char)[] key, scope const(ubyte)[] optArgs) shared @nogc { return null; }
        void query(scope const(ubyte)[] optArgs, scope void delegate(scope const(ubyte)[]) writer) shared @nogc {}
    }

    class TestStreamer : IStreamer
    {
        this(shared(TestDevice) d, string s = "init") { dev = d; state = s; }

        shared(TestDevice) dev;
        string state;
        size_t numChannelImpl() shared @nogc { return 1; }
        shared(IDevice) device() shared @nogc { return dev; }
    }

    class TestThread : ControllerThreadImpl!IStreamer
    {
        size_t count;
        this() { super(); }
        override void onInit() {}
        override void onRunTick() { count = count + 1; }
        override void onStart() { assert(state == State.PAUSE); }
        override void onFinish() { assert(state == State.RUN); }
        override void onPause() { assert(state == State.RUN); }
        override void onResume() { assert(state == State.PAUSE); }

        size_t countCallSync;
        void callSync() @nogc { countCallSync = countCallSync + 1; }
    }

    class TestController : ControllerImpl!TestThread
    {
        IStreamer[] streamers;

        this() { super(); }
        override void setup(IStreamer[] streamers, JSONValue[string]) { this.streamers = streamers; }
        override void spawnDeviceThreads() {
            foreach(s; streamers) {
                auto thread = new TestThread();
                thread.registerStreamer(s);
                this.registerThread(thread);
                thread.start(s !is null ? true : false);
            }
        }
        override void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter) {}
    }

    shared dev = cast(shared) new TestDevice();
    auto ctrl = new TestController();
    auto testStreamer = new TestStreamer(dev);
    ctrl.setup([testStreamer, new TestStreamer(null)], null);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    assert(ctrl.threadList.length == 2);
    assert(ctrl.threadList[0].hasDevice(dev));
    assert(!ctrl.threadList[1].hasDevice(dev));
    Thread.sleep(1.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.RUN);
    assert(ctrl.threadList[1].state == IControllerThread.State.RUN);
    ctrl.pauseDeviceThreads();
    Thread.sleep(1.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.PAUSE);
    assert(ctrl.threadList[1].state == IControllerThread.State.PAUSE);
    ctrl.resumeDeviceThreads();
    Thread.sleep(1.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.RUN);
    assert(ctrl.threadList[1].state == IControllerThread.State.RUN);

    bool executed = false;
    ctrl.applyToDeviceSync(dev, (){
        assert(ctrl.threadList[0].state == IControllerThread.State.PAUSE);
        assert(ctrl.threadList[1].state == IControllerThread.State.RUN);
        executed = true;
    });
    assert(executed);
    Thread.sleep(1.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.RUN);

    executed = false;
    auto thread0 = ctrl.threadList[0];
    thread0.invoke(cast(shared)delegate(TestThread thread0){
        assert(thread0.state == IControllerThread.State.RUN);
        executed = true;
    });
    Thread.sleep(1.msecs);
    assert(executed);

    assert(thread0.countCallSync == 0);
    thread0.invoke(function(TestThread t) @nogc {
        // callSyncはsharedメソッドではないため，
        // 他のスレッドから呼び出せないのでinvokeの中で呼び出す
        t.callSync();
    });
    Thread.sleep(1.msecs);
    assert(thread0.countCallSync == 1);

    thread0.invoke(function(TestThread t, size_t num) @nogc {
        foreach(i; 0 .. num)
            t.callSync();
    }, 10);
    Thread.sleep(1.msecs);
    assert(thread0.countCallSync == 11);

    ctrl.killDeviceThreads();
    Thread.sleep(1.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.FINISH);
    assert(ctrl.threadList[1].state == IControllerThread.State.FINISH);
}


enum PredefinedCommandIDs : ubyte
{
    PAUSE_DEV_THREAD_WITH_OPTARGS = 0b_1000_0000,
    RESUME_DEV_THREAD_WITH_OPTARGS,
}