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
    size_t numTxStream();
    size_t numRxStream();
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
    void setTimeNextPPS(DeviceTime);
    DeviceTime getTimeLastPPS();
    void setNextCommandTime(DeviceTime);
}


interface IReconfigurable
{
    void setParam(const(char)[] key, const(char)[] value);
}


interface IBurstTransmitter(C) : IDevice
{
    void beginBurstTransmit();
    void endBurstTransmit();
    void burstTransmit(scope const C[][]);
}


interface IContinuousReceiver(C) : IDevice
{
    void startContinuousReceive();
    void stopContinuousReceive();
    void singleReceive(scope C[][]);
    void setAlignSize(size_t alignsize);
}


interface ILoopTransmitter(C) : IDevice
{
    void setLoopTransmitSignal(scope const C[][]);
    void startLoopTransmit();
    void stopLoopTransmit();
    void performLoopTransmit();
}


mixin template LoopByBurst(C, size_t maxSlot = 32)
{
    import std.experimental.allocator.mallocator;
    import std.experimental.allocator;

    // setup()後に呼び出してください
    void setupLoopByBurst()
    {
        _alloc = Mallocator.instance;
    }


    void setLoopTransmitSignal(scope const C[][] signals)
    in {
        assert(signals.length == this.numTxStream);
    }
    do {
        foreach(i; 0 .. signals.length) {
            if(_loopSignals[i].length != 0) {
                _alloc.dispose(_loopSignals[i]);
                _loopSignals[i] = null;
            }

            _loopSignals[i] = _alloc.makeArray!C(signals[i].length);
            _loopSignals[i][] = signals[i][];
        }
    }


    void startLoopTransmit()
    {
        this.beginBurstTransmit();
    }


    void stopLoopTransmit()
    {
        this.endBurstTransmit();
    }


    void performLoopTransmit()
    {
        this.burstTransmit(_loopSignals);
    }

  private:
    C[][maxSlot] _loopSignals;
    shared(Mallocator) _alloc;
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