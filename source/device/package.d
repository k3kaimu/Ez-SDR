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
    size_t numTxStreamImpl() shared @nogc;
    size_t numRxStreamImpl() shared @nogc;


    final size_t numTxStream() @nogc
    {
        return (cast(shared)this).numTxStreamImpl();
    }


    final size_t numTxStream() shared @nogc
    {
        return this.numTxStreamImpl();
    }


    final size_t numRxStream() shared @nogc
    {
        return this.numRxStreamImpl();
    }


    final size_t numRxStream() @nogc
    {
        return (cast(shared)this).numRxStreamImpl();
    }

    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] optArgs) shared @nogc;
    const(char)[] getParam(const(char)[] key, scope const(ubyte)[] optArgs) shared @nogc;

    void query(scope const(ubyte)[] optArgs, scope void delegate(scope const(ubyte)[]) writer) shared @nogc;
}


interface IBurstTransmitter(C) : IDevice
{
    void beginBurstTransmit(scope const(ubyte)[] optArgs) shared @nogc;
    void endBurstTransmit(scope const(ubyte)[] optArgs) shared @nogc;
    void burstTransmit(scope const C[][] signal, scope const(ubyte)[] optArgs) shared @nogc;
}


interface IContinuousReceiver(C) : IDevice
{
    void startContinuousReceive(scope const(ubyte)[] optArgs) shared @nogc;
    void stopContinuousReceive(scope const(ubyte)[] optArgs) shared @nogc;
    void singleReceive(scope C[][], scope const(ubyte)[] optArgs) shared @nogc;
}


interface ILoopTransmitter(C) : IDevice
{
    void setLoopTransmitSignal(scope const C[][], scope const(ubyte)[] optArgs) shared @nogc;
    void startLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc;
    void stopLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc;
    void performLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc;
}


mixin template LoopByBurst(C, size_t maxSlot = 32)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    alias _alloc = Mallocator.instance;


    synchronized
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

            _loopSignals[i] = cast(shared)_alloc.makeArray!C(signals[i].length);
            _loopSignals[i][] = signals[i][];
        }
    }


    void startLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc
    {
        this.beginBurstTransmit(optArgs);
    }


    void stopLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc
    {
        this.endBurstTransmit(optArgs);
    }


    void performLoopTransmit(scope const(ubyte)[] optArgs) shared @nogc
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
        case "USRP_TX_Burst":
            import device.uhd_usrp;
            return new UHD_USRPBurstTX();
        default:
            writefln("Cannot file device type: %s", type);
            return null;
    }

    // return null;
}
