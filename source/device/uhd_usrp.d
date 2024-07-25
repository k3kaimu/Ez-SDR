module device.uhd_usrp;

import std.complex;
import std.json;
import std.string;

import device;


extern(C++, "uhd_usrp_tx_burst")
{
    struct DeviceHandler
    {
        void* _payload;
    }

    DeviceHandler setupDevice(const(char)* configJSON);
    void destroyDevice(ref DeviceHandler handler);
    ulong numTxStream(DeviceHandler handler);
    void setParam(DeviceHandler handler, const(char)* key, const(char)* jsonvalue);
    void setTimeNextPPS(DeviceHandler handler, long fullsecs, double fracsecs);
    void getTimeLastPPS(DeviceHandler handler, ref long fullsecs, ref double fracsecs);
    void setNextCommandTime(DeviceHandler handler, long fullsecs, double fracsecs);
    void beginBurstTransmit(DeviceHandler handler);
    void endBurstTransmit(DeviceHandler handler);
    void burstTransmit(DeviceHandler handler, const(void**) signals, ulong sample_size, ulong num_samples);
}


class UHD_USRPBurstTX : IDevice, IPPSSynchronizable, IReconfigurable, IBurstTransmitter!(Complex!float), ILoopTransmitter!(Complex!float)
{
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


    size_t numTxStream() { return .numTxStream(this.handler); }
    size_t numRxStream() { return 0; }


    void setTimeNextPPS(DeviceTime t)
    {
        .setTimeNextPPS(this.handler, t.fullsecs, t.fracsecs);
    }


    DeviceTime getTimeLastPPS()
    {
        DeviceTime t;
        .getTimeLastPPS(this.handler, t.fullsecs, t.fracsecs);
        return t;
    }


    void setNextCommandTime(DeviceTime t)
    {
        .setNextCommandTime(this.handler, t.fullsecs, t.fracsecs);
    }


    void beginBurstTransmit()
    {
        .beginBurstTransmit(this.handler);
    }


    void endBurstTransmit()
    {
        .endBurstTransmit(this.handler);
    }


    void burstTransmit(scope const Complex!float[][] signals)
    {
        const(void)*[128] _tmp;
        foreach(i; 0 .. signals.length)
            _tmp[i] = cast(const(void)*)signals[i].ptr;

        .burstTransmit(this.handler, _tmp.ptr, (Complex!float).sizeof, signals[0].length);
    }


    void setParam(const(char)[] key, const(char)[] value)
    {

    }


    mixin LoopByBurst!(Complex!float);


  private:
    DeviceHandler handler;
}

unittest
{
    UHD_USRPBurstTX a;
}