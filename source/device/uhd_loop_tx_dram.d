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


    size_t numTxStreamImpl() shared { return 1; }
    size_t numRxStreamImpl() shared { return 0; }

    void sync() { assert(0, "please implement"); }

    synchronized
    void setParam(const(char)[] key, const(char)[] value)
    {
        .setParam(cast()this.handler, key.toStringz, value.toStringz);
    }


    synchronized
    const(char)[] getParam(const(char)[] key) { assert(0, "this is not implemented."); return null; }


    synchronized
    void setLoopTransmitSignal(scope const Complex!float[][] signals)
    {
        const(void*)[1] arr = [signals[0].ptr];
        setTransmitSignal(cast()this.handler, arr.ptr, 4, signals[0].length);
    }


    synchronized
    void startLoopTransmit()
    {
        .startTransmit(cast()this.handler);
    }


    synchronized
    void stopLoopTransmit()
    {
        .stopTransmit(cast()this.handler);
    }


    void performLoopTransmit() shared
    {
        Thread.sleep(10.msecs);
    }


    synchronized
    void setTimeNextPPS(DeviceTime t)
    {
        .setTimeNextPPS(cast()this.handler, t.fullsecs, t.fracsecs);
    }


    synchronized
    DeviceTime getTimeLastPPS()
    {
        DeviceTime t;
        .getTimeLastPPS(cast()this.handler, t.fullsecs, t.fracsecs);
        return t;
    }


    synchronized
    void setNextCommandTime(DeviceTime t)
    {
        .setNextCommandTime(cast()this.handler, t.fullsecs, t.fracsecs);
    }


  private:
    DeviceHandler handler;
}
