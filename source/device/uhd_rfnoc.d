module device.uhd_rfnoc;

import std.stdio;

import core.thread;
import std.algorithm : min, max;
import std.complex;
import std.conv;
import std.exception;
import std.json;
import std.string;

import device;
import cpp.string;
import utils : UniqueArray;
import types;

extern(C++, "uhd_rfnoc") nothrow @nogc
{
    struct DeviceHandler { void* _payload; }
    struct TxReplayStreamerHandler { void* _payload; }
    struct TxDefaultStreamerHandler { void* _payload; }
    struct RxDefaultStreamerHandler { void* _payload; }

    DeviceHandler setupDevice(const(char)* name, const(char)* json);
    // TxDefaultStreamerHandler getTxDefaultStreamer(const(char)* name, DeviceHandler handler, uint index);
    // RxDefaultStreamerHandler getRxDefaultStreamer(const(char)* name, DeviceHandler handler, uint index);
    
    void destroyDevice(ref DeviceHandler handler);
    void setParam(DeviceHandler handler, const(char)* key, const(char)* value);
    void setTimeNextPPS(DeviceHandler handler, long fullsecs, double fracsecs);
    void getTimeLastPPS(DeviceHandler handler, ref long fullsecs, ref double fracsecs);

    TxReplayStreamerHandler getTxReplayStreamer(const(char)* name, DeviceHandler handler, uint index);
    ulong setTransmitSignal(TxReplayStreamerHandler handler, const(void**) signals, ulong sample_size, ulong num_samples);
    void startTransmit(TxReplayStreamerHandler handler);
    void stopTransmit(TxReplayStreamerHandler handler);
    uint getNumChannels(TxReplayStreamerHandler handler);

    TxDefaultStreamerHandler getTxDefaultStreamer(const(char)* name, DeviceHandler handler, uint index);
    void beginBurstTransmit(TxDefaultStreamerHandler handler, const(ubyte)* optArgs, ulong optArgsLength);
    void endBurstTransmit(TxDefaultStreamerHandler handler);
    ulong burstTransmit(TxDefaultStreamerHandler handler, const(void** ) signals, ulong sample_size, ulong num_samples);
    uint getNumChannels(TxDefaultStreamerHandler handler);

    RxDefaultStreamerHandler getRxDefaultStreamer(const(char)* name, DeviceHandler handler, uint index);
    void startContinuousReceive(RxDefaultStreamerHandler handler, const(ubyte)* optArgs, ulong optArgsLength);
    void stopContinuousReceive(RxDefaultStreamerHandler handler);
    ulong continuousReceive(RxDefaultStreamerHandler handler, void** signals, ulong sample_size, ulong num_samples);
    uint getNumChannels(RxDefaultStreamerHandler handler);
}


class UHDRFNoC : IDevice
{
    import multithread : SpinLock;

    this(){}

    void construct() {}
    void destruct() {
        destroyDevice(this.handler);
    }

    
    void setup(string name, JSONValue[string] configJSON)
    {
        this._name = name;
        this.configJSON = configJSON;
        this.handler = setupDevice(name.toStringz(), JSONValue(configJSON).toString().toStringz());
    }


    string nameImpl() shared @nogc const
    {
        return this._name;
    }


    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] q) shared
    {
        assert(0, "this is not implemented.");
    }


    UniqueArray!char getParam(const(char)[] key, scope const(ubyte)[] q) shared
    {
        assert(0, "this is not implemented.");
        return typeof(return).init;
    }


    void query(scope const(ubyte)[] q, scope void delegate(scope const(ubyte)[]) writer) shared
    {
        assert(0, "this is not implemented.");
    }


    IStreamer makeStreamer(string[] args) shared
    {
        spinLock.lock();
        scope(exit) spinLock.unlock();

        immutable bool isValidFmt
            = args.length == 2
            && (args[0] == "TX" || args[0] == "RX");

        immutable int index = ifThrown(args[1].to!int, -1);
        enforce(isValidFmt && index >= 0, "Invalid streamer argument format. Please use {DeviceName}:{TX|RX}:{Index}.");

        immutable string streamerName = format!"%s:%s:%s"(this._name, args[0], args[1]);

        JSONValue[string] streamerConfig;
        if(args[0] == "TX")
            streamerConfig = (cast(JSONValue[string])this.configJSON)["tx-streamers"][index].object;
        else if(args[0] == "RX")
            streamerConfig = (cast(JSONValue[string])this.configJSON)["rx-streamers"][index].object;

        if(args[0] == "TX") {
            if(streamerConfig["type"].str == "replay") {
                auto shndlr = getTxReplayStreamer(streamerName.toStringz(), cast() handler, index);
                return new TxReplayStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            } else if(streamerConfig["type"].str == "default") {
                auto shndlr = getTxDefaultStreamer(streamerName.toStringz(), cast() handler, index);
                return new TxDefaultStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            } else {
                enforce(0, "Unsupported TX streamer type: '" ~ streamerConfig["type"].str ~ "' for streamer " ~ streamerName ~ ". Acceptable types are ['replay', 'default'].");
                return null;
            }
            // auto shndlr = getTxStreamer(streamerName.toStringz(), cast() handler, index);
            // if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat32)
            // return new TxStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            // else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat64)
            //     return new TxStreamerImpl!(Complex!double)(streamerName, cast(shared) this, shndlr);
            // else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexInt16)
            //     return new TxStreamerImpl!(ComplexInt!short)(streamerName, cast(shared) this, shndlr);
            // else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexInt8)
            //     return new TxStreamerImpl!(ComplexInt!byte)(streamerName, cast(shared) this, shndlr);
            // else {
            //     enforce(0, "Unsupported type for TX streamer '%s', whose element type is '%s'.".format(streamerName, getTxStreamerElementType(shndlr)));
            //     assert(0, "Unsupported type");
            // }
        } else {
            if(streamerConfig["type"].str == "default") {
                auto shndlr = getRxDefaultStreamer(streamerName.toStringz(), cast() handler, index);
                return new RxDefaultStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            } else {
                enforce(0, "Unsupported RX streamer type: '" ~ streamerConfig["type"].str ~ "' for streamer " ~ streamerName ~ ". Acceptable type is ['default'].");
                return null;
            }
            // assert(0, "RX streamer is not implemented yet.");
            // return null;
            // auto shndlr = getRxStreamer(streamerName.toStringz(), cast() handler, index);
            // if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat32)
            //     return new RxStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            // else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat64)
            //     return new RxStreamerImpl!(Complex!double)(streamerName, cast(shared) this, shndlr);
            // else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexInt16)
            //     return new RxStreamerImpl!(ComplexInt!short)(streamerName, cast(shared) this, shndlr);
            // else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexInt8)
            //     return new RxStreamerImpl!(ComplexInt!byte)(streamerName, cast(shared) this, shndlr);
            // else {
            //     enforce(0, "Unsupported type for RX streamer '%s', whose element type is '%s'.".format(streamerName, getRxStreamerElementType(shndlr)));
            //     assert(0, "Unsupported type");
            // }
        }
    }


  private:
    string _name;
    DeviceHandler handler;
    shared(SpinLock) spinLock;
    JSONValue[string] configJSON;


    static class TxReplayStreamerImpl(C) : IStreamer, ILoopTransmitter!C
    {
        this(string name, shared(UHDRFNoC) dev, TxReplayStreamerHandler handler)
        {
            _name = name;
            _dev = dev;
            _handler = handler;
            _numCh = .getNumChannels(_handler);
        }


        string nameImpl() shared @nogc const { return _name; }
        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared @nogc const { return _numCh; }


        StreamerElementType elementTypeImpl() shared @nogc const
        {
            static if(is(typeof(C.init.re) == float))
                return StreamerElementType.ComplexFloat32;
            else static if(is(typeof(C.init.re) == double))
                return StreamerElementType.ComplexFloat64;
            else static if(is(typeof(C.init.re) == short))
                return StreamerElementType.ComplexInt16;
            else static if(is(typeof(C.init.re) == byte))
                return StreamerElementType.ComplexInt8;
            else
                static assert(0, "Unsupported type");
        }


        void setLoopTransmitSignal(scope const Complex!float[][] signals, scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            // const(void*)[1] arr = [signals[0].ptr];
            const(void)*[32] arr;
            foreach(i; 0 .. signals.length)
                arr[i] = signals[i].ptr;

            this._handler.setTransmitSignal(arr.ptr, 4, signals[0].length);
        }


        void startLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            this._handler.startTransmit();
        }


        void stopLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            this._handler.stopTransmit();
        }


        void performLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            Thread.sleep(10.msecs);
        }


      private:
        string _name;
        shared(UHDRFNoC) _dev;
        TxReplayStreamerHandler _handler;
        size_t _numCh;
    }


    static class TxDefaultStreamerImpl(C) : IStreamer, IBurstTransmitter!C, ILoopTransmitter!C
    {
        this(string name, shared(UHDRFNoC) dev, TxDefaultStreamerHandler handler)
        {
            _name = name;
            _dev = dev;
            _handler = handler;
            _numCh = getNumChannels(_handler);
        }


        string nameImpl() shared @nogc const { return _name; }
        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared @nogc const { return _numCh; }


        StreamerElementType elementTypeImpl() shared @nogc const
        {
            static if(is(typeof(C.init.re) == float))
                return StreamerElementType.ComplexFloat32;
            else static if(is(typeof(C.init.re) == double))
                return StreamerElementType.ComplexFloat64;
            else static if(is(typeof(C.init.re) == short))
                return StreamerElementType.ComplexInt16;
            else static if(is(typeof(C.init.re) == byte))
                return StreamerElementType.ComplexInt8;
            else
                static assert(0, "Unsupported type");
        }


        void beginBurstTransmit(scope const(ubyte)[] q)
        {
            // .waitDoneSyncPPS(cast() _dev.handler);
            .beginBurstTransmit(_handler, q.ptr, q.length);
        }


        void endBurstTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");
            .endBurstTransmit(_handler);
        }


        void burstTransmit(scope const C[][] signals, scope const(ubyte)[] q, scope size_t[] txsamples)
        in(signals.length > 0 && signals[0].length > 0)
        in(signals.length == txsamples.length)
        in(signals.length <= 128)
        do {
            assert(q.length == 0, "additional arguments is not supported");
            const(C)*[128] _tmp;

            size_t remain = size_t.max;
            foreach(i; 0 .. signals.length) {
                _tmp[i] = signals[i].ptr;
                remain = min(remain, signals[i].length);
            }

            size_t num = .burstTransmit(_handler, cast(const(void**))_tmp.ptr, C.sizeof, remain);
            txsamples[] = num;
        }


        mixin LoopByBurst!C;

      private:
        string _name;
        shared(UHDRFNoC) _dev;
        TxDefaultStreamerHandler _handler;
        size_t _numCh;
    }


    static class RxDefaultStreamerImpl(C) : IStreamer, IContinuousReceiver!C
    {
        this(string name, shared(UHDRFNoC) dev, RxDefaultStreamerHandler handler)
        {
            _name = name;
            _dev = dev;
            _handler = handler;
            _numCh = getNumChannels(_handler);
        }

        string nameImpl() shared @nogc const { return _name; }
        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared @nogc const { return _numCh; }


        StreamerElementType elementTypeImpl() shared @nogc const
        {
            static if(is(typeof(C.init.re) == float))
                return StreamerElementType.ComplexFloat32;
            else static if(is(typeof(C.init.re) == double))
                return StreamerElementType.ComplexFloat64;
            else static if(is(typeof(C.init.re) == short))
                return StreamerElementType.ComplexInt16;
            else static if(is(typeof(C.init.re) == byte))
                return StreamerElementType.ComplexInt8;
            else
                static assert(0, "Unsupported type");
        }


        void startContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            // .waitDoneSyncPPS(cast() _dev.handler);
            .startContinuousReceive(_handler, optArgs.ptr, optArgs.length);
        }

        void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            assert(optArgs.length == 0, "additional arguments is not supported");
            .stopContinuousReceive(_handler);
        }

        void singleReceive(scope C[][] buffers, scope const(ubyte)[] optArgs, scope size_t[] rxsamples) @nogc
        in(buffers.length > 0)
        in{
            foreach(e; buffers)
                assert(e.length > 0, "each buffer must have at least one sample");
        }
        in(buffers.length == rxsamples.length)
        in(buffers.length <= 128)
        do {
            assert(optArgs.length == 0, "additional arguments is not supported");
            const(C)*[128] _tmp;

            size_t remain = size_t.max;
            foreach(i; 0 .. buffers.length) {
                _tmp[i] = buffers[i].ptr;
                remain = min(remain, buffers[i].length);
            }

            if(remain == 0) {
                import core.stdc.stdio : printf;
                printf("Warning: No samples to receive. Some buffers are empty.\n");
            }

            size_t num = .continuousReceive(_handler, cast(void**)_tmp.ptr, C.sizeof, remain);
            rxsamples[] = num;
        }

      private:
        string _name;
        shared(UHDRFNoC) _dev;
        RxDefaultStreamerHandler _handler;
        size_t _numCh;
    }
}