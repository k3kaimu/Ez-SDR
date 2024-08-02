module device.uhd_loop_tx_dram;

import core.thread;
import std.complex;
import std.json;
import std.string;

import device;

extern(C++, "looptx_rfnoc_replay_block")
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



class UHDLoopTransmitterFromDRAM : ILoopTransmitter!(Complex!float), IPPSSynchronizable
{
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


    size_t numTxStream() { return 1; }
    size_t numRxStream() { return 0; }

    void sync() { assert(0, "please implement"); }

    void setParam(const(char)[] key, const(char)[] value)
    {
        .setParam(this.handler, key.toStringz, value.toStringz);
    }


    const(char)[] getParam(const(char)[] key) { assert(0, "this is not implemented."); return null; }


    void setLoopTransmitSignal(scope const Complex!float[][] signals)
    {
        const(void*)[1] arr = [signals[0].ptr];
        setTransmitSignal(this.handler, arr.ptr, 4, signals[0].length);
    }


    void startLoopTransmit()
    {
        .startTransmit(this.handler);
    }


    void stopLoopTransmit()
    {
        .stopTransmit(this.handler);
    }


    void performLoopTransmit()
    {
        Thread.sleep(10.msecs);
    }


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


  private:
    DeviceHandler handler;
}
