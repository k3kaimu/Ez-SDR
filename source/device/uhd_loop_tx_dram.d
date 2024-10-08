module device.uhd_loop_tx_dram;

import core.thread;
import std.complex;
import std.json;
import std.string;

import device;
import utils;

extern(C++, "looptx_rfnoc_replay_block") nothrow @nogc
{
    struct DeviceHandler
    {
        void* _payload;
    }

    DeviceHandler setupDevice(const(char)* configJSON);
    void destroyDevice(ref DeviceHandler handler);
    void setTransmitSignal(DeviceHandler handler, const void** signals, ulong sample_size, ulong num_samples);
    void startTransmit(DeviceHandler handler);
    void stopTransmit(DeviceHandler handler);
    void setParam(DeviceHandler handler, const(char)* key, const(char)* jsonvalue);
    void setTimeNextPPS(DeviceHandler handler, long fullsecs, double fracsecs);
    void getTimeLastPPS(DeviceHandler handler, ref long fullsecs, ref double fracsecs);
    void setNextCommandTime(DeviceHandler handler, long fullsecs, double fracsecs);
}



class UHDLoopTransmitterFromDRAM : IDevice
{
    import std.experimental.allocator;
    import std.experimental.allocator.mallocator;
    alias alloc = Mallocator.instance;

    this() {}


    void construct() {}
    void destruct()
    {
        destroyDevice(this.handler);
    }


    void setup(JSONValue[string] configJSON)
    {
        this.handler = .setupDevice(JSONValue(configJSON).toString().toStringz());
    }


    synchronized
    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] q) @nogc
    {
        assert(q.length == 0, "additional arguments is not supported");

        auto keybuf = makeUniqueArray!char(key.length + 1),
             valuebuf = makeUniqueArray!char(key.length + 1);

        keybuf.array[0 .. key.length] = key[];
        keybuf.array[$-1] = 0;
        valuebuf.array[0 .. value.length] = value[];
        valuebuf.array[$-1] = 0;
        .setParam(cast()this.handler, keybuf.array.ptr, valuebuf.array.ptr);
    }


    synchronized
    const(char)[] getParam(const(char)[] key, scope const(ubyte)[] q) { assert(q.length == 0, "additional arguments is not supported"); assert(0, "this is not implemented."); return null; }


    synchronized
    void query(scope const(ubyte)[] q, scope void delegate(scope const(ubyte)[]) writer)
    {
        assert(0, "this is not implemented yet.");
    }


    IStreamer makeStreamer(string[] args) shared
    in(args.length == 0)
    {
        return new StreamerImpl(this);
    }


  private:
    DeviceHandler handler;


    static class StreamerImpl : ILoopTransmitter!(Complex!float)
    {
        this(shared(UHDLoopTransmitterFromDRAM) dev)
        {
            _dev = dev;
        }


        shared(IDevice) device() shared { return _dev; }


        size_t numChannelImpl() shared @nogc { return 1; }


        void setLoopTransmitSignal(scope const Complex!float[][] signals, scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            const(void*)[1] arr = [signals[0].ptr];
            setTransmitSignal(cast()_dev.handler, arr.ptr, 4, signals[0].length);
        }


        void startLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            .startTransmit(cast()_dev.handler);
        }


        void stopLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            .stopTransmit(cast()_dev.handler);
        }


        void performLoopTransmit(scope const(ubyte)[] q)
        {
            assert(q.length == 0, "additional arguments is not supported");

            Thread.sleep(10.msecs);
        }


      private:
        shared(UHDLoopTransmitterFromDRAM) _dev;
    }
}
