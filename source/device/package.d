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
    size_t numTxStreamImpl() shared;
    size_t numRxStreamImpl() shared;


    final size_t numTxStream()
    {
        return (cast(shared)this).numTxStreamImpl();
    }


    final size_t numTxStream() shared
    {
        return this.numTxStreamImpl();
    }


    final size_t numRxStream() shared
    {
        return this.numRxStreamImpl();
    }


    final size_t numRxStream()
    {
        return (cast(shared)this).numRxStreamImpl();
    }

    void setParam(const(char)[] key, const(char)[] value) shared;
    const(char)[] getParam(const(char)[] key) shared;
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
    void setTimeNextPPS(DeviceTime) shared;
    DeviceTime getTimeLastPPS() shared;
    void setNextCommandTime(DeviceTime) shared;
}


interface IBurstTransmitter(C) : IDevice
{
    void beginBurstTransmit() shared;
    void endBurstTransmit() shared;
    void burstTransmit(scope const C[][]) shared;
}


interface IContinuousReceiver(C) : IDevice
{
    void startContinuousReceive() shared;
    void stopContinuousReceive() shared;
    void singleReceive(scope C[][]) shared;
    void setAlignSize(size_t alignsize) shared;
}


interface ILoopTransmitter(C) : IDevice
{
    void setLoopTransmitSignal(scope const C[][]) shared;
    void startLoopTransmit() shared;
    void stopLoopTransmit() shared;
    void performLoopTransmit() shared;
}


mixin template LoopByBurst(C, size_t maxSlot = 32)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    alias _alloc = Mallocator.instance;


    synchronized
    void setLoopTransmitSignal(scope const C[][] signals)
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


    void startLoopTransmit() shared
    {
        this.beginBurstTransmit();
    }


    void stopLoopTransmit() shared
    {
        this.endBurstTransmit();
    }


    void performLoopTransmit() shared
    {
        this.burstTransmit(cast(C[][])(_loopSignals[]));
    }

  private:
    C[][maxSlot] _loopSignals;
}


IDevice newDevice(string type)
{
    import device.uhd_loop_tx_dram;
    import std.stdio;
    writefln("Lookup: %s", type);

    switch(type) {
        case "USRP_TX_LoopDRAM":
            return new UHDLoopTransmitterFromDRAM();
        default:
            writefln("Cannot file device type: %s", type);
            return null;
    }

    // return null;
}
