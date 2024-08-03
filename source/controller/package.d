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
    void start();
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


    void start()
    {
        _thread.start();
    }


    synchronized void run()
    {
        this.onInit();
        (cast()_resumeEvent).wait();
        this.onStart();
        while(!_killSwitch) {
            while(!_queue.emptyRequest()) {
                auto req = _queue.popRequest();
                req.match!(
                    (Message.Pause) {
                        this.onPause();
                        (cast()_resumeEvent).wait();
                        this.onResume();
                    },
                    (Message.CallOnThis r) {
                        r.dg(this);
                    }
                );
            }

            this.onRunTick();
        }
        this.onFinish();
    }


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
}


class ControllerImpl(CtrlThread : IControllerThread) : IController
{
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
        // 関連するすべてのDeviceThreadを一度止める
        bool[] stopList = new bool[](_threads.length);
        foreach(i; 0 .. _threads.length) {
            stopList[i] = _threads[i].hasDevice(dev);
            if(stopList[i])
                _threads[i].pause();
        }

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
