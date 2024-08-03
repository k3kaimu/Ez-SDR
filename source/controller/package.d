module controller;

import core.thread;

import std.complex;
import std.socket;
import std.json;

import device;


interface IController
{
    void setup(IDevice[], JSONValue[string]);

    void spawnDeviceThreads();
    void killDeviceThreads();

    void pauseDeviceThreads();
    void resumeDeviceThreads();

    void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter);

    // void applyToDeviceSync(IDevice dev, void delegate(IDevice dev));
    // void applyToDeviceAsync(IDevice, dev, void delegate(IDevice dev));
}



IController newController(string type)
{
    import controller.looptx;

    switch(type) {
        case "LoopTX":
            return new LoopTXController!(Complex!float)();
        default:
            return null;
    }

    // return null;
}



interface IControllerThread
{
    enum State { RUN, PAUSE, FINISH }

    void start();
    State state() shared;
    bool hasDevice(IDevice d) shared;
    void kill() shared;
    void pause() shared;
    void resume() shared;
    void callOnThis(void delegate(IControllerThread) dg) shared;
}



class ControllerThreadImpl(DeviceType : IDevice) : IControllerThread
{
    import std.sumtype;
    import msgqueue;
    import core.sync.event;
    import core.atomic;

    static struct Message
    {
        static struct Pause {}
        static struct CallOnThis { void delegate(shared(IControllerThread)) dg; }

        alias Types = SumType!(Pause, CallOnThis);
        alias Queue = UniqueRequestQueue!Types;
    }


    this()
    {
        _killSwitch = false;
        _resumeEvent.initialize(true, true);

        _queue = new Message.Queue;

        _thread = new Thread(() { (cast(shared)this).run(); });
    }


    void start(bool defaultRun = true)
    {
        if(defaultRun)
            _resumeEvent.setIfInitialized();
        else
            _resumeEvent.reset();

        _thread.start();
    }


    synchronized void run()
    {
        this.onInit();
        _state = State.PAUSE;

        (cast()_resumeEvent).wait();

        this.onStart();
        _state = State.RUN;

        while(!_killSwitch) {
            while(!_queue.emptyRequest()) {
                auto req = _queue.popRequest();
                req.match!(
                    (Message.Pause) {
                        this.onPause();
                        _state = State.PAUSE;
                        (cast()_resumeEvent).wait();
                        this.onResume();
                        _state = State.RUN;
                    },
                    (Message.CallOnThis r) {
                        r.dg(this);
                    }
                );
            }

            this.onRunTick();
        }
        this.onFinish();
        _state = State.FINISH;
    }


    State state() shared { return atomicLoad(_state); }


    abstract void onInit() shared;
    abstract void onRunTick() shared;
    abstract void onStart() shared;
    abstract void onFinish() shared;
    abstract void onPause() shared;
    abstract void onResume() shared;


    shared(DeviceType)[] deviceList() { return _devs; }
    shared(DeviceType)[] deviceList() shared { return _devs; }


    void registerDevice(shared DeviceType dev)
    {
        _devs ~= dev;
    }


    bool hasDevice(IDevice d) shared
    {
        foreach(e; _devs) {
            if(e is cast(shared)d) return true;
        }

        return false;
    }


    void kill() shared
    {
        _killSwitch = true;
    }


    void pause() shared
    {
        (cast()_resumeEvent).reset();
        _queue.pushRequest(Message.Types(Message.Pause()));
    }


    void resume() shared
    {
        (cast()_resumeEvent).setIfInitialized();
    }


    void callOnThis(void delegate(shared(IControllerThread)) dg) shared
    {
        _queue.pushRequest(Message.Types(Message.CallOnThis(dg)));
    }


  private:
    Thread _thread;
    bool _killSwitch;
    Event _resumeEvent;
    shared(Message.Queue) _queue;
    shared(DeviceType)[] _devs;
    State _state;
}


class ControllerImpl(CtrlThread : IControllerThread) : IController
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    this() {}

    abstract
    void setup(IDevice[], JSONValue[string]);


    void registerThread(CtrlThread thread)
    {
        _threads ~= cast(shared)thread;
    }


    shared(CtrlThread)[] threadList()
    {
        return _threads;
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


    void applyToDeviceSync(IDevice dev, scope void delegate() dg)
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

        // すべてのスレッドが停止するまで待つ
        foreach(i, t; _threads)
            if(stopList[i])
                while(t.state != IControllerThread.State.PAUSE) { Thread.yield(); }

        // 処理を呼び出す
        dg();

        // 止めたスレッドを実行し直す
        foreach(i; 0 .. _threads.length) {
            if(stopList[i])
                _threads[i].resume();
        }
    }


    void applyToDeviceAsync(IDevice dev, void delegate(shared(IControllerThread)) sharedDg)
    {
        foreach(i; 0 .. _threads.length) {
            if(_threads[i].hasDevice(dev)) {
                // 一番最初に見つかったスレッドに処理を移譲する
                _threads[i].callOnThis(sharedDg);
            }
        }
    }

  private:
    shared(CtrlThread)[] _threads;
}

unittest
{
    class TestDevice : IDevice
    {
        string state;
        this() { }
        void construct() { state = "init"; }
        void destruct() { state = "finished"; }
        void setup(JSONValue[string] configJSON) {}
        size_t numTxStreamImpl() shared { return 1; }
        size_t numRxStreamImpl() shared { return 0; }
        synchronized void setParam(const(char)[] key, const(char)[] value) {}
        synchronized const(char)[] getParam(const(char)[] key) { return null; }
    }

    class TestThread : ControllerThreadImpl!IDevice
    {
        size_t count;
        this() { super(); }
        override synchronized void onInit() {}
        override synchronized void onRunTick() { count = count + 1; }
        override synchronized void onStart() { assert(state == State.PAUSE); }
        override synchronized void onFinish() { assert(state == State.RUN); }
        override synchronized void onPause() { assert(state == State.RUN); }
        override synchronized void onResume() { assert(state == State.PAUSE); }
    }

    class TestController : ControllerImpl!TestThread
    {
        shared(IDevice)[] devs;

        this() { super(); }
        override void setup(IDevice[] devs, JSONValue[string]) { this.devs = cast(shared)devs; }
        override void spawnDeviceThreads() {
            foreach(d; devs) {
                auto thread = new TestThread();
                thread.registerDevice(d);
                this.registerThread(thread);
                thread.start(d !is null ? true : false);
            }
        }
        override void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) responseWriter) {}
    }

    auto ctrl = new TestController();
    auto dev = new TestDevice();
    ctrl.setup([dev, null], null);
    ctrl.spawnDeviceThreads();
    scope(exit) ctrl.killDeviceThreads();

    assert(ctrl.threadList.length == 2);
    assert(ctrl.threadList[0].hasDevice(dev));
    assert(!ctrl.threadList[1].hasDevice(dev));
    Thread.sleep(10.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.RUN);
    assert(ctrl.threadList[1].state == IControllerThread.State.PAUSE);
    ctrl.pauseDeviceThreads();
    Thread.sleep(10.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.PAUSE);
    assert(ctrl.threadList[1].state == IControllerThread.State.PAUSE);
    ctrl.resumeDeviceThreads();
    Thread.sleep(10.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.RUN);
    assert(ctrl.threadList[1].state == IControllerThread.State.RUN);

    bool executed = false;
    ctrl.applyToDeviceSync(dev, (){
        assert(ctrl.threadList[0].state == IControllerThread.State.PAUSE);
        assert(ctrl.threadList[1].state == IControllerThread.State.RUN);
        executed = true;
    });
    assert(executed);

    executed = false;
    ctrl.applyToDeviceAsync(dev, (thread){
        assert(ctrl.threadList[0].state == IControllerThread.State.RUN);
        assert(ctrl.threadList[1].state == IControllerThread.State.RUN);
        executed = true;
    });
    Thread.sleep(10.msecs);
    assert(executed);

    ctrl.killDeviceThreads();
    Thread.sleep(10.msecs);
    assert(ctrl.threadList[0].state == IControllerThread.State.FINISH);
    assert(ctrl.threadList[1].state == IControllerThread.State.FINISH);
}
