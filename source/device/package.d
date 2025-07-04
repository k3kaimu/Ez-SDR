module device;

import core.lifetime : forward;
import std.json;
import std.experimental.allocator.mallocator;
import std.experimental.allocator;
import utils : UniqueArray;
import types;


interface IDevice
{
    void construct();
    void destruct();
    void setup(string name, JSONValue[string] configJSON);

    string nameImpl() shared @nogc const;
    final string name() shared @nogc const { return this.nameImpl(); }
    final string name() @nogc const { return (cast(shared)this).nameImpl(); }

    IStreamer makeStreamer(string[] args) shared;
    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] optArgs) shared @nogc;
    UniqueArray!char getParam(const(char)[] key, scope const(ubyte)[] optArgs) shared @nogc;

    void query(scope const(ubyte)[] optArgs, scope void delegate(scope const(ubyte)[]) writer) shared @nogc;
}


interface IStreamer
{
    string nameImpl() shared @nogc const;
    final string name() shared @nogc const { return this.nameImpl(); }
    final string name() @nogc const { return (cast(shared)this).nameImpl(); }

    final size_t numChannel() shared @nogc const { return this.numChannelImpl(); }
    final size_t numChannel() @nogc const { return (cast(shared)this).numChannelImpl(); }
    size_t numChannelImpl() shared @nogc const;

    final StreamerElementType elementType() shared @nogc { return this.elementTypeImpl(); }
    final StreamerElementType elementType() @nogc { return (cast(shared)this).elementTypeImpl(); }
    StreamerElementType elementTypeImpl() shared @nogc;

    shared(IDevice) device() shared @nogc;
}


interface IBurstTransmitter(C) : IStreamer
{
    void beginBurstTransmit(scope const(ubyte)[] optArgs) @nogc;
    void endBurstTransmit(scope const(ubyte)[] optArgs) @nogc;
    void burstTransmit(scope const C[][] signal, scope const(ubyte)[] optArgs, scope size_t[] txsamples) @nogc;
}


interface IContinuousReceiver(C) : IStreamer
{
    void startContinuousReceive(scope const(ubyte)[] optArgs) @nogc;
    void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc;
    void singleReceive(scope C[][], scope const(ubyte)[] optArgs, scope size_t[] rxsamples) @nogc;
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
        _doneSamples[] = 0;
        this.beginBurstTransmit(optArgs);
    }


    void stopLoopTransmit(scope const(ubyte)[] optArgs) @nogc
    {
        this.endBurstTransmit(optArgs);
    }


    void performLoopTransmit(scope const(ubyte)[] optArgs) @nogc
    {
        immutable size_t numCh = this.numChannel();

        C[][maxSlot] txsignals;
        foreach(i; 0 .. numCh) {
            txsignals[i] = _loopSignals[i][_doneSamples[i] ..  $];
        }

        size_t[maxSlot] dones;
        this.burstTransmit(txsignals[0 .. numCh], optArgs, dones[0 .. numCh]);

        _doneSamples[] += dones[];
        foreach(i; 0 .. numCh)
            _doneSamples[i] %= _loopSignals[i].length;
    }

  private:
    C[][maxSlot] _loopSignals;
    size_t[maxSlot] _doneSamples;
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
