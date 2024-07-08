module device.uhd_loop_tx_dram;


extern(C++, "looptx_rfnoc_replay_block")
{
    struct DeviceHandler;

    DeviceHandler* setupDevice(const(char)* configJSON, const(char)* cpu_fmt, const(char)* wire_fmt);
    void destroyDevice(ref DeviceHandler* handler);
    void setTransmitSignal(DeviceHandler* handler, void** signals, ulong sample_size, ulong num_samples, ulong num_stream);
    void startTransmit(DeviceHandler* handler);
    void stopTransmit(DeviceHandler* handler);
}