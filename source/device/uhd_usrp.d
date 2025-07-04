module device.uhd_usrp;

import std.algorithm : min, max;
import std.complex;
import std.exception;
import std.json;
import std.string;

import device;
import cpp.string;
import utils : UniqueArray;
import types;


extern(C++, "uhd_usrp_multiusrp") nothrow @nogc
{
    struct DeviceHandler
    {
        void* _payload;
    }


    struct TxStreamerHandler
    {
        void* _payload;
    }


    struct RxStreamerHandler
    {
        void* _payload;
    }


    DeviceHandler setupDevice(const(char)* name, const(char)* configJSON);
    void destroyDevice(ref DeviceHandler handler);
    void setParam(DeviceHandler handler, const(char)* key_, ulong keylen, const(char)* jsonvalue_, ulong jsonvaluelen, const(ubyte)* info, ulong infolen);
    String getParam(DeviceHandler handler, const(char)* key_, ulong keylen, const(ubyte)* info, ulong infolen);
    void beginBurstTransmitImpl(TxStreamerHandler handler, scope const(ubyte)* optArgs, ulong optArgsLength);
    void endBurstTransmitImpl(TxStreamerHandler handler);
    ulong burstTransmitImpl(TxStreamerHandler handler, const(void**) signals, ulong sample_size, ulong num_samples);
    void startContinuousReceiveImpl(RxStreamerHandler, scope const(ubyte)* optArgs, ulong optArgsLength);
    void stopContinuousReceiveImpl(RxStreamerHandler);
    ulong continuousReceiveImpl(RxStreamerHandler, void** buffptr, ulong sizeofElement, ulong numSamples);

    TxStreamerHandler getTxStreamer(const(char)*, DeviceHandler, uint index);
    RxStreamerHandler getRxStreamer(const(char)*, DeviceHandler, uint index);
    ulong numTxStream(TxStreamerHandler handler);
    ulong numRxStream(RxStreamerHandler handler);
    StreamerElementType getTxStreamerElementType(TxStreamerHandler handler);
    StreamerElementType getRxStreamerElementType(RxStreamerHandler handler);
    // void waitDoneSyncPPS(DeviceHandler handler);
}


class UHDMultiUSRP : IDevice
{
    import multithread : SpinLock;

    this(){}

    void construct(){}
    void destruct()
    {
        destroyDevice(this.handler);
    }


    void setup(string name, JSONValue[string] configJSON)
    {
        this._name = name;
        this.handler = setupDevice(name.toStringz(), JSONValue(configJSON).toString().toStringz());
    }


    string nameImpl() shared @nogc const
    {
        return this._name;
    }


    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] q) shared
    {
        .setParam(cast()this.handler, key.ptr, key.length, value.ptr, value.length, q.ptr, q.length);
    }


    UniqueArray!char getParam(const(char)[] key, scope const(ubyte)[] q) shared {
        String dst;
        scope(exit) destroyString(dst);

        dst = .getParam(cast()this.handler, key.ptr, key.length, q.ptr, q.length);
        return typeof(return)(dst.toSlice());
    }


    void query(scope const(ubyte)[] q, scope void delegate(scope const(ubyte)[]) writer) shared
    {
        assert(0, "this is not implemented.");
    }


    IStreamer makeStreamer(string[] args) shared
    {
        import std.conv;

        // DeviceName:{TX|RX}:<Index>形式かどうかを判定する
        immutable bool isValidFmt
            = args.length == 2
            && (args[0] == "TX" || args[0] == "RX");

        immutable int index = ifThrown(args[1].to!int, -1);
        enforce(isValidFmt && index >= 0, "Invalid streamer argument format. Please use {DeviceName}:{TX|RX}:{Index}.");

        immutable string streamerName = format!"%s:%s:%s"(this._name, args[0], args[1]);
        spinLock.lock();
        scope(exit) spinLock.unlock();

        if(args[0] == "TX") {
            auto shndlr = getTxStreamer(streamerName.toStringz(), cast() handler, index);
            if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat32)
                return new TxStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat64)
                return new TxStreamerImpl!(Complex!double)(streamerName, cast(shared) this, shndlr);
            else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexInt16)
                return new TxStreamerImpl!(ComplexInt!short)(streamerName, cast(shared) this, shndlr);
            else if(getTxStreamerElementType(shndlr) == StreamerElementType.ComplexInt8)
                return new TxStreamerImpl!(ComplexInt!byte)(streamerName, cast(shared) this, shndlr);
            else {
                enforce(0, "Unsupported type for TX streamer '%s', whose element type is '%s'.".format(streamerName, getTxStreamerElementType(shndlr)));
                assert(0, "Unsupported type");
            }
        } else {
            auto shndlr = getRxStreamer(streamerName.toStringz(), cast() handler, index);
            if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat32)
                return new RxStreamerImpl!(Complex!float)(streamerName, cast(shared) this, shndlr);
            else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexFloat64)
                return new RxStreamerImpl!(Complex!double)(streamerName, cast(shared) this, shndlr);
            else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexInt16)
                return new RxStreamerImpl!(ComplexInt!short)(streamerName, cast(shared) this, shndlr);
            else if(getRxStreamerElementType(shndlr) == StreamerElementType.ComplexInt8)
                return new RxStreamerImpl!(ComplexInt!byte)(streamerName, cast(shared) this, shndlr);
            else {
                enforce(0, "Unsupported type for RX streamer '%s', whose element type is '%s'.".format(streamerName, getRxStreamerElementType(shndlr)));
                assert(0, "Unsupported type");
            }
        }
    }


  private:
    string _name;
    DeviceHandler handler;
    shared(SpinLock) spinLock;


    static class TxStreamerImpl(C) : IStreamer, IBurstTransmitter!C, ILoopTransmitter!C
    {
        this(string name, shared(UHDMultiUSRP) dev, TxStreamerHandler handler)
        {
            _name = name;
            _dev = dev;
            _handler = handler;
            _numCh = .numTxStream(_handler);
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
            .beginBurstTransmitImpl(_handler, q.ptr, q.length);
        }


        void endBurstTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");
            .endBurstTransmitImpl(_handler);
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

            size_t num = .burstTransmitImpl(_handler, cast(const(void**))_tmp.ptr, C.sizeof, remain);
            txsamples[] = num;
        }


        mixin LoopByBurst!C;

      private:
        string _name;
        shared(UHDMultiUSRP) _dev;
        TxStreamerHandler _handler;
        size_t _numCh;
    }


    static class RxStreamerImpl(C) : IStreamer, IContinuousReceiver!C
    {
        this(string name, shared(UHDMultiUSRP) dev, RxStreamerHandler handler)
        {
            _name = name;
            _dev = dev;
            _handler = handler;
            _numCh = .numRxStream(_handler);
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
            .startContinuousReceiveImpl(_handler, optArgs.ptr, optArgs.length);
        }

        void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            assert(optArgs.length == 0, "additional arguments is not supported");
            .stopContinuousReceiveImpl(_handler);
        }

        void singleReceive(scope C[][] buffers, scope const(ubyte)[] optArgs, scope size_t[] rxsamples) @nogc
        in(buffers.length > 0 && buffers[0].length > 0)
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

            size_t num = .continuousReceiveImpl(_handler, cast(void**)_tmp.ptr, C.sizeof, remain);
            rxsamples[] = num;
        }

      private:
        string _name;
        shared(UHDMultiUSRP) _dev;
        RxStreamerHandler _handler;
        size_t _numCh;
    }
}

unittest
{
    UHDMultiUSRP a;
}