module device.uhd_usrp;

import std.complex;
import std.exception;
import std.json;
import std.string;

import device;


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


    DeviceHandler setupDevice(const(char)* configJSON);
    void destroyDevice(ref DeviceHandler handler);
    void setParam(DeviceHandler handler, const(char)* key_, ulong keylen, const(char)* jsonvalue_, ulong jsonvaluelen, const(ubyte)* info, ulong infolen);
    void beginBurstTransmitImpl(TxStreamerHandler handler, scope const(ubyte)* optArgs, ulong optArgsLength);
    void endBurstTransmitImpl(TxStreamerHandler handler);
    ulong burstTransmitImpl(TxStreamerHandler handler, const(void**) signals, ulong sample_size, ulong num_samples);
    void startContinuousReceiveImpl(RxStreamerHandler, scope const(ubyte)* optArgs, ulong optArgsLength);
    void stopContinuousReceiveImpl(RxStreamerHandler);
    ulong continuousReceiveImpl(RxStreamerHandler, void** buffptr, ulong sizeofElement, ulong numSamples);

    TxStreamerHandler getTxStreamer(DeviceHandler, uint index);
    RxStreamerHandler getRxStreamer(DeviceHandler, uint index);
    ulong numTxStream(TxStreamerHandler handler);
    ulong numRxStream(RxStreamerHandler handler);
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


    void setup(JSONValue[string] configJSON)
    {
        this.handler = setupDevice(JSONValue(configJSON).toString().toStringz());
    }


    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] q) shared
    {
        .setParam(cast()this.handler, key.ptr, key.length, value.ptr, value.length, q.ptr, q.length);
    }


    const(char)[] getParam(const(char)[] key, scope const(ubyte)[] q) shared { assert(q.length == 0, "additional arguments is not supported"); assert(0, "this is not implemented."); return null; }


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

        spinLock.lock();
        scope(exit) spinLock.unlock();

        if(args[0] == "TX") {
            auto shndlr = getTxStreamer(cast() handler, index);
            return new TxStreamerImpl!(Complex!float)(cast(shared) this, shndlr);
        } else {
            auto shndlr = getRxStreamer(cast() handler, index);
            return new RxStreamerImpl!(Complex!float)(cast(shared) this, shndlr);
        }
    }


  private:
    DeviceHandler handler;
    shared(SpinLock) spinLock;


    static class TxStreamerImpl(C) : IStreamer, IBurstTransmitter!C, ILoopTransmitter!C
    {
        this(shared(UHDMultiUSRP) dev, TxStreamerHandler handler)
        {
            _dev = dev;
            _handler = handler;
            _numCh = .numTxStream(_handler);
        }


        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared @nogc { return _numCh; }


        void beginBurstTransmit(scope const(ubyte)[] q)
        {
            .beginBurstTransmitImpl(_handler, q.ptr, q.length);
        }


        void endBurstTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");
            .endBurstTransmitImpl(_handler);
        }


        void burstTransmit(scope const C[][] signals, scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");
            const(C)*[128] _tmp;
            foreach(i; 0 .. signals.length)
                _tmp[i] = signals[i].ptr;

            size_t remain = signals[0].length;
            while(remain != 0) {
                size_t num;
                num = .burstTransmitImpl(_handler, cast(const(void)**)_tmp.ptr, C.sizeof, signals[0].length);

                foreach(i; 0 .. signals.length)
                    _tmp[i] += num;
                
                remain -= num;
            }
        }


        mixin LoopByBurst!C;

      private:
        shared(UHDMultiUSRP) _dev;
        TxStreamerHandler _handler;
        size_t _numCh;
    }


    static class RxStreamerImpl(C) : IStreamer, IContinuousReceiver!C
    {
        this(shared(UHDMultiUSRP) dev, RxStreamerHandler handler)
        {
            _dev = dev;
            _handler = handler;
            _numCh = .numRxStream(_handler);
        }

        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared @nogc { return _numCh; }


        void startContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            .startContinuousReceiveImpl(_handler, optArgs.ptr, optArgs.length);
        }

        void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            assert(optArgs.length == 0, "additional arguments is not supported");
            .stopContinuousReceiveImpl(_handler);
        }

        void singleReceive(scope C[][] buffers, scope const(ubyte)[] optArgs) @nogc
        {
            assert(optArgs.length == 0, "additional arguments is not supported");
            const(C)*[128] _tmp;
            foreach(i; 0 .. buffers.length)
                _tmp[i] = buffers[i].ptr;

            size_t remain = buffers[0].length;
            while(remain != 0) {
                size_t num = .continuousReceiveImpl(_handler, cast(void**)_tmp.ptr, C.sizeof, remain);

                foreach(i; 0 .. buffers.length)
                    _tmp[i] += num;
                
                remain -= num;
            }
        }

      private:
        shared(UHDMultiUSRP) _dev;
        RxStreamerHandler _handler;
        size_t _numCh;
    }
}

unittest
{
    UHDMultiUSRP a;
}