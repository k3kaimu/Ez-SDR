module iface;

import core.lifetime : forward;
import std.json;

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
    long fullsecs;
    double fracsecs;
}


interface IPPSSynchronizable
{
    void setTimeNextPPS(DeviceTime);
    DeviceTime getTimeLastPPS();
    void setNextCommandTime(DeviceTime);
}


interface IReconfigurable
{
    void setParam(string key, JSONValue value);
}


interface IBurstTransmitter(C) : IDevice
{
    void beginBurstTransmit();
    void endBurstTransmit();
    void burstTransmit(const C[][]);
    void singleTransmit(const C[][]);
}


interface IContinuousReceiver(C) : IDevice
{
    void startContinuousReceive();
    void stopContinuousReceive();
    size_t continuousReceive(C[][]);
    void singleReceive(C[][]);
}


interface ILoopTransmitter(C) : IDevice
{
    void setLoopTransmitSignal(const C[][]);
    void startLoopTransmit();
    void stopLoopTransmit();
    void performLoopTransmit();
}


class LoopTransmitterByBurst(Base) : Base
if(is(Base : IBurstTransmitter))
{
    this(T...)(auto ref T args)
    {
        super(forward!args);
    }


    void setup(JSONValue[string] configJSON)
    {
        super.setup(configJSON);
        _signals.length = this.numTxStream();
    }


    void setLoopTransmitSignal(const C[][] signal) {
        foreach(i, ref e; _signals) {
            e.length = _signals[i].length;
            e[] = _signals[i];
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
        this.burstTransmit(_signals);
    }


  private:
    C[][] _signals;
}
