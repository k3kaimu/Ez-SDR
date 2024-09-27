module device;

import core.lifetime : forward;
import std.json;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;


interface IDevice
{
    void construct();
    void destruct();
    void setup(JSONValue[string] configJSON);

    IStreamer makeStreamer(string[] args) shared;
    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] optArgs) shared @nogc;
    const(char)[] getParam(const(char)[] key, scope const(ubyte)[] optArgs) shared @nogc;

    void query(scope const(ubyte)[] optArgs, scope void delegate(scope const(ubyte)[]) writer) shared @nogc;
}


interface IStreamer
{
    final size_t numChannel() shared @nogc { return this.numChannelImpl(); }
    final size_t numChannel() @nogc { return (cast(shared)this).numChannelImpl(); }

    size_t numChannelImpl() shared @nogc;
    shared(IDevice) device() shared @nogc;
}


interface IBurstTransmitter(C) : IStreamer
{
    void beginBurstTransmit(scope const(ubyte)[] optArgs) @nogc;
    void endBurstTransmit(scope const(ubyte)[] optArgs) @nogc;
    void burstTransmit(scope const C[][] signal, scope const(ubyte)[] optArgs) @nogc;
}


interface IContinuousReceiver(C) : IStreamer
{
    void startContinuousReceive(scope const(ubyte)[] optArgs) @nogc;
    void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc;
    void singleReceive(scope C[][], scope const(ubyte)[] optArgs) @nogc;
}


interface ILoopTransmitter(C) : IStreamer
{
    void setLoopTransmitSignal(scope const C[][], scope const(ubyte)[] optArgs) @nogc;
    void startLoopTransmit(scope const(ubyte)[] optArgs) @nogc;
    void stopLoopTransmit(scope const(ubyte)[] optArgs) @nogc;
    void performLoopTransmit(scope const(ubyte)[] optArgs) @nogc;
}


mixin template LoopByBurst(C, size_t maxSlot = 32)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    alias _alloc = Mallocator.instance;


    void setLoopTransmitSignal(scope const C[][] signals, scope const(ubyte)[] optArgs) @nogc
    in {
        assert(signals.length == this.numTxStream);
        assert(optArgs.length == 0);
    }
    do {
        foreach(i; 0 .. signals.length) {
            if(_loopSignals[i].length != 0) {
                _alloc.dispose(cast(void[])_loopSignals[i]);
                _loopSignals[i] = null;
            }

            _loopSignals[i] = _alloc.makeArray!C(signals[i].length);
            _loopSignals[i][] = signals[i][];
        }
    }


    void startLoopTransmit(scope const(ubyte)[] optArgs) @nogc
    {
        this.beginBurstTransmit(optArgs);
    }


    void stopLoopTransmit(scope const(ubyte)[] optArgs) @nogc
    {
        this.endBurstTransmit(optArgs);
    }


    void performLoopTransmit(scope const(ubyte)[] optArgs) @nogc
    {
        this.burstTransmit(cast(C[][])(_loopSignals[]), optArgs);
    }

  private:
    C[][maxSlot] _loopSignals;
}


IDevice newDevice(string type)
{
    import std.stdio;
    writefln("Lookup: %s", type);

    switch(type) {
        case "USRP_TX_LoopDRAM":
            import device.uhd_loop_tx_dram;
            return new UHDLoopTransmitterFromDRAM();
        case "MultiUSRP":
            import device.uhd_usrp;
            return new UHDMultiUSRP();
        default:
            writefln("Cannot file device type: %s", type);
            return null;
    }

    // return null;
}
