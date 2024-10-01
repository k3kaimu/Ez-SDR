#include <uhd/usrp/multi_usrp.hpp>
#include <nlohmann/json.hpp>
#include <uhd/types/ref_vector.hpp>
#include <string>
#include <format>
#include <type_traits>
#include "addinfo.hpp"


namespace uhd_usrp_multiusrp
{



struct TxStreamer
{
    uhd::tx_streamer::sptr streamer;
    std::vector<std::complex<float> const*> buffptrs;
    int numChannel;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
    uhd::tx_metadata_t md;
};


struct RxStreamer
{
    uhd::rx_streamer::sptr streamer;
    std::vector<std::complex<float> const*> buffptrs;
    int numChannel;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
    uhd::rx_metadata_t md;
};


struct TxStreamerHandler
{
    TxStreamer* streamer;
};


struct RxStreamerHandler
{
    RxStreamer* streamer;
};


enum class Mode
{
    TX, RX, TRX
};


struct Device
{
    nlohmann::json config;
    uhd::usrp::multi_usrp::sptr usrp;
    Mode mode;

    std::set<size_t> tx_channels;
    std::set<size_t> rx_channels;

    // std::vector<TxStreamer*> txstreamers;
    // std::vector<RxStreamer*> rxstreamers;
};


struct DeviceHandler
{
    Device* dev;
};


void setupTx(Device& dev, nlohmann::json& config)
{
    // always select the subdevice first, the channel mapping affects the other settings
    {
        std::string subdev = config.value("subdev", "");
        if (subdev.size() > 0)
            dev.usrp->set_tx_subdev_spec(subdev);
    }

    // check used channels
    for(auto& e: config["streamers"]) {
        for(auto& chan_: e["channels"]) {
            int chan = chan_.get<int>();
            if (chan >= dev.usrp->get_tx_num_channels()) {
                throw std::runtime_error("Invalid channel(s) specified.");
            }

            dev.tx_channels.insert(chan);
        }
    }

    // set the tx sample rate
    {
        double rate = config.value("rate", -1.0);
        std::cout << std::format("Setting TX Rate: {} Msps...", rate / 1e6) << std::endl;
        dev.usrp->set_tx_rate(rate);
        std::cout << std::format("Actual TX Rate: {} Msps...", dev.usrp->get_tx_rate() / 1e6)
                << std::endl
                << std::endl;
    }

    // set the center frequency
    {
        double freq = config.value("freq", -1.0);
        bool has_int_n = config.contains("int_n");
        double lo_offset = config.value("lo_offset", 0.0);

        if (freq < 0) {
            throw std::runtime_error("Please specify the center frequency with 'freq'");
        }

        std::cout << "Requesting TX Freq: " << freq / 1e6 << " MHz..." << std::endl;
        std::cout << "Requesting TX LO Offset: " << lo_offset / 1e6 << " MHz..." << std::endl;

        for (auto& e: dev.tx_channels) {
            uhd::tune_request_t tune_request;
            tune_request = uhd::tune_request_t(freq, lo_offset);

            if (has_int_n)
                tune_request.args = uhd::device_addr_t("mode_n=integer");

            dev.usrp->set_tx_freq(tune_request, e);
            std::cout << "Actual TX Freq: " << (dev.usrp->get_tx_freq(e) / 1e6)
                << " MHz for the channel #" << e << "..." << std::endl
                << std::endl;
        }
    }

    // set the gain
    {
        double gain = config.value("gain", 0.0);

        std::cout << "Requesting TX Gain: " << gain << " dB ..." << std::endl;
        for(auto& e: dev.tx_channels) {
            dev.usrp->set_tx_gain(gain, e);

            std::cout << "Actual TX Gain: " << (dev.usrp->get_tx_gain(e)) << " for the channel #" << e << "..."
                    << std::endl
                    << std::endl;
        }
    }

    // set the analog frontend filter bandwidth
    {
        double bw = config.value("bw", -1.0);

        if(bw > 0) {
            std::cout << "Requesting TX Bandwidth: " << (bw / 1e6) << " MHz..." << std::endl;

            for(auto& e: dev.tx_channels) {
                dev.usrp->set_tx_bandwidth(bw, e);
                std::cout << "Actual TX Bandwidth: "
                        << dev.usrp->get_tx_bandwidth(e) / 1e6 << " MHz for the channel #" << e << "..."
                        << std::endl
                        << std::endl;
            }
        }
    }
}


void setupRx(Device& dev, nlohmann::json& config)
{
    // always select the subdevice first, the channel mapping affects the other settings
    {
        std::string subdev = config.value("subdev", "");
        if (subdev.size() > 0)
            dev.usrp->set_rx_subdev_spec(subdev);
    }

    for(auto& e: config["streamers"]) {
        for(auto& chan_: e["channels"]) {
            int chan = chan_.get<int>();
            if (chan >= dev.usrp->get_rx_num_channels()) {
                throw std::runtime_error("Invalid channel(s) specified.");
            }

            dev.rx_channels.insert(chan);
        }
    }

    // set the tx sample rate
    {
        double rate = config.value("rate", -1.0);
        std::cout << std::format("Setting RX Rate: {} Msps...", rate / 1e6) << std::endl;
        dev.usrp->set_rx_rate(rate);
        std::cout << std::format("Actual RX Rate: {} Msps...", dev.usrp->get_rx_rate() / 1e6)
                << std::endl
                << std::endl;
    }

    // set the center frequency
    {
        double freq = config.value("freq", -1.0);
        bool has_int_n = config.contains("int_n");
        double lo_offset = config.value("lo_offset", 0.0);

        if (freq < 0) {
            throw std::runtime_error("Please specify the center frequency with 'freq'");
        }

        std::cout << "Requesting RX Freq: " << freq / 1e6 << " MHz..." << std::endl;
        std::cout << "Requesting RX LO Offset: " << lo_offset / 1e6 << " MHz..." << std::endl;

       for (auto& e: dev.tx_channels) {
            uhd::tune_request_t tune_request;
            tune_request = uhd::tune_request_t(freq, lo_offset);

            if (has_int_n)
                tune_request.args = uhd::device_addr_t("mode_n=integer");

            dev.usrp->set_rx_freq(tune_request, e);
            std::cout << "Actual RX Freq: " << (dev.usrp->get_rx_freq(e) / 1e6)
                << " MHz for the channel #" << e << "..." << std::endl
                << std::endl;
        }
    }

    // set gains
    {
        double gain = config.value("gain", 0.0);

        for(auto& e: dev.rx_channels) {
            dev.usrp->set_rx_gain(gain, e);

            std::cout << "Actual RX Gain: " << (dev.usrp->get_rx_gain(e)) << " for the channel #" << e << "..."
                    << std::endl
                    << std::endl;
        }
    }

    // set the analog frontend filter bandwidth
    {
        double bw = config.value("bw", -1.0);

        if(bw > 0) {
            std::cout << "Requesting RX Bandwidth: " << (bw / 1e6) << " MHz..." << std::endl;

            for(auto& e: dev.rx_channels) {
                dev.usrp->set_rx_bandwidth(bw, e);
                std::cout << "Actual RX Bandwidth: "
                        << dev.usrp->get_rx_bandwidth(e) / 1e6 << " MHz for the channel #" << e << "..."
                        << std::endl
                        << std::endl;
            }
        }
    }

    // // create a transmit streamer
    // uhd::stream_args_t stream_args("fc32"); // complex floats
    // stream_args.channels             = channels;
    // uhd::rx_streamer::sptr rx_stream = dev.usrp->get_rx_stream(stream_args);
    // dev.rxstreamer.streamer = rx_stream;
    // dev.rxstreamer.buffptrs.resize(channels.size());

    // uhd::rx_metadata_t md;
    // md.has_time_spec = false;
    // dev.rxstreamer.md = md;
}


DeviceHandler setupDevice(char const* configJSON)
{
    nlohmann::json config = nlohmann::json::parse(configJSON);

    std::string args = config.value("args", "");
    std::string clockref = config.value("clockref", "");
    std::string timeref = config.value("timeref", "");

    Device* dev = new Device;
    dev->config = config;

    uhd::usrp::multi_usrp::sptr usrp = uhd::usrp::multi_usrp::make(args);
    dev->usrp = usrp;

    std::cout << "Using Device: " << dev->usrp->get_pp_string() << std::endl;

    // Get mode
    if(config.value("mode", "") == "TX") {
        dev->mode = Mode::TX;
    } else if(config.value("mode", "") == "RX") {
        dev->mode = Mode::RX;
    } else {
        dev->mode = Mode::TRX;
    }

    // Lock mboard clocks
    if(clockref.size() > 0) {
        usrp->set_clock_source(clockref);
    }

    // Set time source
    if(timeref.size() > 0) {
        usrp->set_time_source(timeref);
    }

    if(dev->mode == Mode::TX || dev->mode == Mode::TRX)
        setupTx(*dev, config["tx"]);

    if(dev->mode == Mode::RX || dev->mode == Mode::TRX)
        setupRx(*dev, config["rx"]);
    
    return DeviceHandler{dev};
}


TxStreamerHandler getTxStreamer(DeviceHandler handler, uint index)
{
    auto dev = handler.dev;
    auto streamer_settings = dev->config["tx"]["streamers"][index];
    TxStreamer* txstreamer = new TxStreamer;

    std::vector<size_t> channels = streamer_settings["channels"].get<std::vector<size_t>>();

    uhd::stream_args_t stream_args("fc32"); // complex floats
    stream_args.channels             = channels;
    uhd::tx_streamer::sptr tx_stream = dev->usrp->get_tx_stream(stream_args);
    txstreamer->streamer = tx_stream;
    txstreamer->buffptrs.resize(channels.size());
    txstreamer->numChannel = channels.size();

    uhd::tx_metadata_t md;
    md.has_time_spec = false;
    txstreamer->md = md;

    TxStreamerHandler dst(txstreamer);
    return dst;
}


RxStreamerHandler getRxStreamer(DeviceHandler handler, uint index)
{
    auto dev = handler.dev;
    auto streamer_settings = dev->config["rx"]["streamers"][index];
    RxStreamer* rxstreamer = new RxStreamer;

    std::vector<size_t> channels = streamer_settings["channels"].get<std::vector<size_t>>();

    uhd::stream_args_t stream_args("fc32"); // complex floats
    stream_args.channels             = channels;
    uhd::rx_streamer::sptr rx_stream = dev->usrp->get_rx_stream(stream_args);
    rxstreamer->streamer = rx_stream;
    rxstreamer->buffptrs.resize(channels.size());
    rxstreamer->numChannel = channels.size();

    uhd::rx_metadata_t md;
    md.has_time_spec = false;
    rxstreamer->md = md;

    RxStreamerHandler dst(rxstreamer);
    return dst;
}


void destroyDevice(DeviceHandler& handler)
{
    Device* dev = handler.dev;
    delete dev;
    handler.dev = nullptr;
}


uint64_t numTxStream(TxStreamerHandler handler)
{
    return handler.streamer->numChannel;
}


uint64_t numRxStream(RxStreamerHandler handler)
{
    return handler.streamer->numChannel;
}


void setParam(DeviceHandler handler, char const* key_, uint64_t keylen, char const* jsonvalue_, uint64_t jsonvaluelen, uint8_t const* info, uint64_t infolen)
{
    Device* dev = handler.dev;
    std::string_view key(key_, keylen);
    std::string_view jsonstr(jsonvalue_, jsonvaluelen);
    nlohmann::json value = nlohmann::json::parse(jsonstr);

    if(key == "set_time_unknown_pps_to_zero") {
        dev->usrp->set_time_unknown_pps(uhd::time_spec_t(double(0)));
    }


    // std::string_view jsonvalue(jsonvalue_, jsonvaluelen);
    // nlohmann::json value = nlohmann::json::parse(jsonvalue);
    // auto addinfo = parseAdditionalInfo(info, infolen);

    // bool has_time_spec = addinfo.optCommandTimeInfo.size() > 0;
    // uhd::time_spec_t time = uhd::time_spec_t(addinfo.optCommandTimeInfo.back().nsecs / 1000000000, (addinfo.optCommandTimeInfo.back().nsecs % 1000000000)/1000000000.0);

    // int chindex = addinfo.optUSRPStreamerChannelInfo.size() > 0 ? addinfo.optUSRPStreamerChannelInfo.back().index : -1;

    // if(key == "freq") {
    //     double freq = value.get<double>();

    //     uhd::tune_request_t tune_request;
    //     tune_request = uhd::tune_request_t(freq, dev->lo_offset);

    //     bool intN = dev->tuningIntN;
    //     if(config.contains("integerN"))
    //         intN = value["integerN"].get<bool>();

    //     if(intN)
    //         tune_request.args = uhd::device_addr_t("mode_n=integer");

    //     if(has_time_spec) dev->usrp->set_command_time(time);

    //     if(chindex < 0) {
    //         for(int i = 0; i < dev->channels.size(); ++i)
    //             dev->usrp->set_tx_freq(tune_request, dev->channels[i]);
    //     } else {
    //         dev->usrp->set_tx_freq(tune_request, dev->channels[chindex]);
    //     }

    //     if(has_time_spec) dev->usrp->clear_command_time();

    //     dev->freq = freq;
    //     dev->tuningIntN = intN;
    // } else if(key == "gain") {
    //     double gain = value.get<double>();

    //     if(has_time_spec) dev->usrp->set_command_time(time);

    //     if(chindex == -1) {
    //         for(int i = 0; i < dev->channels.size(); ++i)
    //             dev->usrp->set_tx_gain(gain, dev->channels[i]);
    //     } else {
    //         dev->usrp->set_tx_gain(gain, dev->channels[chindex]);
    //     }

    //     if(has_time_spec) dev->usrp->clear_command_time();
    //     dev->gain = gain;
    // }
}


void beginBurstTransmitImpl(TxStreamerHandler handler, uint8_t const* optArgs, uint64_t optArgsLength)
{
    auto streamer = handler.streamer;

    streamer->md.start_of_burst = true;
    streamer->md.end_of_burst = false;

    // std::cout << "optArgsLength = " << optArgsLength << std::endl;

    forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
        std::cout << "tagid = " << tag << std::endl;
        if(tag == CommandTimeInfo::tag) {
            assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
            CommandTimeInfo info = *reinterpret_cast<CommandTimeInfo const*>(p);
            streamer->md.has_time_spec = true;
            streamer->md.time_spec = uhd::time_spec_t(info.nsecs / 1000000000LL, (info.nsecs % 1000000000LL)/1e9);
            std::cout << "[multiusrp.cpp] Transmit streaming will be start at " << info.nsecs << "[nsecs]." << std::endl;
        }
    });
}


void endBurstTransmitImpl(TxStreamerHandler handler)
{
    auto streamer = handler.streamer;

    streamer->md.has_time_spec = false;
    streamer->md.start_of_burst = false;
    streamer->md.end_of_burst = true;
    streamer->streamer->send(streamer->buffptrs, 0, streamer->md);
    streamer->md.end_of_burst = false;
}


uint64_t burstTransmitImpl(TxStreamerHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    auto streamer = handler.streamer;

    for(size_t i = 0; i < streamer->buffptrs.size(); ++i)
        streamer->buffptrs[i] = reinterpret_cast<std::complex<float> const*>(signals[i]);

    uint64_t num = streamer->streamer->send(streamer->buffptrs, num_samples, streamer->md, 10.0);

    if(num > 0) {
        streamer->md.has_time_spec = false;
        streamer->md.start_of_burst = false;
    } else {
        std::cout << "[tx_burst.cpp] Cannot transmit from USRP" << std::endl;
    }
    return num;
}


void startContinuousReceiveImpl(RxStreamerHandler handler, uint8_t const* optArgs, uint64_t optArgsLength)
{
    // setup streaming
    uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
    stream_cmd.num_samps  = 0;
    stream_cmd.stream_now = true;

    // std::cout << "optArgsLength = " << optArgsLength << std::endl;

    forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
        if(tag == CommandTimeInfo::tag) {
            assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
            CommandTimeInfo info = *reinterpret_cast<CommandTimeInfo const*>(p);
            stream_cmd.stream_now = false;
            stream_cmd.time_spec = uhd::time_spec_t(info.nsecs / 1000000000LL, (info.nsecs % 1000000000LL)/1e9);
            std::cout << "[multiusrp.cpp] Receive streaming will be start at " << info.nsecs << "[nsecs]." << std::endl;
        }
    });

    handler.streamer->streamer->issue_stream_cmd(stream_cmd);
}


void stopContinuousReceiveImpl(RxStreamerHandler handler)
{
    uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS);
    handler.streamer->streamer->issue_stream_cmd(stream_cmd);

    // バッファーに溜まっている受信データを破棄する
    size_t numSamples = 128;
    std::vector<std::vector<std::complex<float>>> rembuf(handler.streamer->numChannel);
    for(size_t i = 0; i < handler.streamer->numChannel; ++i) {
        std::vector<std::complex<float>> v(numSamples);
        rembuf[i] = v;
    }

    size_t num = 0;
    do {
        num = handler.streamer->streamer->recv(rembuf, numSamples, handler.streamer->md, 0.1);
    } while(num != 0);
}


uint64_t continuousReceiveImpl(RxStreamerHandler handler, void** buffptr, uint64_t sizeofElement, uint64_t numSamples)
{
    uhd::ref_vector<void*> buf(buffptr, handler.streamer->numChannel);
    return handler.streamer->streamer->recv(buf, numSamples, handler.streamer->md, 10.0);
}



}
