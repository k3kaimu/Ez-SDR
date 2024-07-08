module iface;

import core.lifetime : forward;
import std.json;

interface Device
{
    void construct();
    void destruct();
    void setup(JSONValue[string] configJSON);
    size_t numTxStream();
    size_t numRxStream();
}


interface Synchronizable
{
    void sync();
}


interface Reconfigurable
{
    void setParam(string key, JSONValue value);
}


interface BurstTransmitter(C) : Device
{
    void beginBurstTransmit();
    void endBurstTransmit();
    void burstTransmit(const C[][]);
    void singleTransmit(const C[][]);
}


interface ContinuousReceiver(C) : Device
{
    void startContinuousReceive();
    void stopContinuousReceive();
    size_t continuousReceive(C[][]);
    void singleReceive(C[][]);
}


interface LoopTransmitter(C) : Device
{
    void setLoopTransmitSignal(const C[][]);
    void startLoopTransmit();
    void stopLoopTransmit();
    void performLoopTransmit();
}


class LoopTransmitterByBurst(Base) : Base
if(is(Base : BurstTransmitter))
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
