module device.uhd_tx;




class USRP_UHD_TX : IDevice, IPPSSynchronizable, IReconfigurable, IBurstTransmitter, ILoopTransmitter
{
    this(){}

    void construct(){}
    void destruct(){}


    void setup(JSONValue[string] configJSON)
    {
        settingUSRPGeneral(_usrp, configJSON);
        settingTransmitDevice(_usrp, configJSON);
        _chlist = configJSON["channels"].array.map!"cast(immutable)a.get!size_t".array();
    }


    size_t numTxStream() { return _chlist.length; }
    size_t numRxStream() { return 0; }


    void setTimeNextPPS(DeviceTime time)
    {
        _usrp.setTimeUnknownPPS()
    }

    


  private:
    USRP _usrp;
    size_t[] _chlist;
}