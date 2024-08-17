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

    void setParam(const(char)[] key, const(char)[] value) shared @nogc;
    const(char)[] getParam(const(char)[] key) shared @nogc;
}


struct DeviceTime
{
    this(double time)
    {
        this.fullsecs = cast(long)time;
        this.fracsecs = time - this.fullsecs;
    }

    long fullsecs;
    double fracsecs;
}

unittest
{
    assert(DeviceTime(3.0).fullsecs == 3);
    assert(DeviceTime(3.0).fracsecs == 0);

    assert(DeviceTime(3.5).fullsecs == 3);
    assert(DeviceTime(3.5).fracsecs == 0.5);
}


interface IPPSSynchronizable
{
    void setTimeNextPPS(DeviceTime) shared @nogc;
    DeviceTime getTimeLastPPS() shared @nogc;
    void setNextCommandTime(DeviceTime) shared @nogc;
}


interface IBurstTransmitter(C) : IDevice
{
    void beginBurstTransmit() shared @nogc;
    void endBurstTransmit() shared @nogc;
    void burstTransmit(scope const C[][]) shared @nogc;
}


interface IContinuousReceiver(C) : IDevice
{
    void startContinuousReceive() shared @nogc;
    void stopContinuousReceive() shared @nogc;
    void singleReceive(scope C[][]) shared @nogc;
    void setAlignSize(size_t alignsize) shared @nogc;
}


interface ILoopTransmitter(C) : IDevice
{
    void setLoopTransmitSignal(scope const C[][]) shared @nogc;
    void startLoopTransmit() shared @nogc;
    void stopLoopTransmit() shared @nogc;
    void performLoopTransmit() shared @nogc;
}


mixin template LoopByBurst(C, size_t maxSlot = 32)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    alias _alloc = Mallocator.instance;


    synchronized
    void setLoopTransmitSignal(scope const C[][] signals) @nogc
    in {
        assert(signals.length == this.numTxStream);
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


    void startLoopTransmit() shared @nogc
    {
        this.beginBurstTransmit();
    }


    void stopLoopTransmit() shared @nogc
    {
        this.endBurstTransmit();
    }


    void performLoopTransmit() shared @nogc
    {
        this.burstTransmit(cast(C[][])(_loopSignals[]));
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
