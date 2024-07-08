module device.uhd_loop_tx_dram;

import iface;
import std.complex;
import std.json;
import std.string;

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
    void setParam(const(char)* key, const(char)* jsonvalue);
}



class UHDLoopTransmitterFromDRAM : LoopTransmitter!(Complex!float), Synchronizable, Reconfigurable
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

    void setParam(string key, JSONValue value)
    {
        .setParam(this.handler, key.toStringz(), value.toString().toStringz());
    }


    void setLoopTransmitSignal(const Complex!float[][] signals)
    {
        const(void*)[1] arr = [signals[0].ptr];
        setTransmitSignal(this.handler, arr, 4, signals[0].length, 1);
    }


    void startLoopTransmit()
    {
        .startTransmit(this.handler);
    }


    void stopLoopTransmit()
    {
        .stopLoopTransmit(this.handler);
    }


    void performLoopTransmit() {}


    DeviceHandler handler;
}
