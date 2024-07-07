module transmitter_dram;


extern(C++, "looptx_rfnoc_replay_block")
{
    struct DeviceHandler;

    DeviceHandler* setUpDevice(const(char)* configJSON);
    void destroyDevice(DeviceHandler*);
}