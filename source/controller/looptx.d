module controller.looptx;

import core.thread;

import std.json;
import std.sumtype;
import std.exception;
import std.format;

import controller;
import device;
import msgqueue;
import utils;



class LoopTXController(C) : IController
{
    this() {}

    void setup(IDevice[] devs, JSONValue[string])
    {
        foreach(i, e; devs) {
            _devs ~= enforce(cast(ILoopTransmitter!C) e, "The device#%s is not a ILoopTransmitter".format(i));
            _msgQueueList ~= new UniqueMsgQueue!(ReqTypes, ResTypes)();
        }

        this._killSwitch = false;
    }
    

    void spawnDeviceThreads()
    {
        auto makeThread(alias fn, T...)(ref shared(bool) stop_signal_called, auto ref T args)
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


    void processMessage(scope void[] msgbuf, void delegate(void[]) writer)
    {

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

    alias ResTypes = SumType!(void[1]);

    static struct RequestTypes(C)
    {
        static struct SetTransmitSignal
        {
            C[][32] buffer;
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
        alias dbg = debugMsg!"[loopTXControllerDeviceThread]";

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

            // ループ送信に必要な処理があれば実行する
            dev.performLoopTransmit();
        }
    }
}