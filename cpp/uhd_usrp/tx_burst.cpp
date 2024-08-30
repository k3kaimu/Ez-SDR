#include <uhd/usrp/multi_usrp.hpp>
#include <nlohmann/json.hpp>
#include <string>
#include <format>
#include <type_traits>


namespace uhd_usrp_tx_burst
{


struct Device
{
    nlohmann::json config;
    std::string args;
    std::string subdev;
    std::vector<size_t> channels;
    double freq;
    double lo_offset;
    double rate;
    double gain;
    std::string ant;
    double bw;
    std::string clockref;
    std::string timeref;
    bool tuningIntN;

    uhd::usrp::multi_usrp::sptr usrp;
    uhd::tx_streamer::sptr streamer;
    // std::vector<std::vector<std::complex<float>>> buffers;
    std::vector<std::complex<float> const*> buffptrs;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
    uhd::tx_metadata_t md;
};


struct DeviceHandler
{
    Device* dev;
};


DeviceHandler setupDevice(char const* configJSON)
{
    nlohmann::json config = nlohmann::json::parse(configJSON);

    std::string args = config.value("args", "");
    std::string subdev = config.value("subdev", "");
    double freq = config.value("freq", -1.0);
    double lo_offset = config.value("lo_offset", 0.0);
    double rate = config.value("rate", -1.0);
    double gain = config.value("gain", -1.0);
    std::string ant = config.value("ant", "");
    double bw = config.value("bw", -1.0);
    std::string clockref = config.value("clockref", "");
    std::string timeref = config.value("timeref", "");
    bool has_int_n = config.contains("int_n");
    auto cpu_format = "fc32";
    auto wire_format = "sc16";
    std::vector<size_t> channels = config.value("channels", std::vector<size_t>{});

    Device* dev = new Device;
    dev->config = config;
    dev->args = args;
    dev->subdev = subdev;
    dev->freq = freq;
    dev->lo_offset = lo_offset;
    dev->rate = rate;
    dev->gain = gain;
    dev->ant = ant;
    dev->bw = bw;
    dev->clockref = clockref;
    dev->timeref = timeref;
    dev->channels = channels;
    dev->tuningIntN = has_int_n;

    // create a usrp device
    std::cout << std::endl;
    std::cout << "Creating the usrp device" << std::endl;
    uhd::usrp::multi_usrp::sptr usrp = uhd::usrp::multi_usrp::make(args);
    dev->usrp = usrp;

    // Lock mboard clocks
    if (clockref.size() > 0) {
        usrp->set_clock_source(clockref);
    }

    // always select the subdevice first, the channel mapping affects the other settings
    if (subdev.size() > 0)
        usrp->set_tx_subdev_spec(subdev);

    std::cout << "Using Device: " << usrp->get_pp_string() << std::endl;

    // detect which channels to use
    for (size_t ch = 0; ch < channels.size(); ch++) {
        size_t chan = channels[ch];
        if (chan >= usrp->get_tx_num_channels()) {
            throw std::runtime_error("Invalid channel(s) specified.");
        }
    }

    // set the tx sample rate
    std::cout << std::format("Setting TX Rate: {} Msps...", rate / 1e6) << std::endl;
    usrp->set_tx_rate(rate);
    std::cout << std::format("Actual TX Rate: {} Msps...", usrp->get_tx_rate() / 1e6)
              << std::endl
              << std::endl;

    // set the center frequency
    if (freq < 0) {
        std::cerr << "Please specify the center frequency with --freq" << std::endl;
        return DeviceHandler{nullptr};
    }

    std::cout << "Requesting TX Freq: " << freq / 1e6 << " MHz..." << std::endl;
    std::cout << "Requesting TX LO Offset: " << lo_offset / 1e6 << " MHz..." << std::endl;

    for (size_t i = 0; i < channels.size(); i++) {
        uhd::tune_request_t tune_request;
        tune_request = uhd::tune_request_t(freq, lo_offset);

        if (has_int_n)
            tune_request.args = uhd::device_addr_t("mode_n=integer");
        usrp->set_tx_freq(tune_request, channels[i]);
    }
    std::cout << "Actual TX Freq: " << (usrp->get_tx_freq(channels.front()) / 1e6)
              << " MHz..." << std::endl
              << std::endl;

    std::cout << "Requesting TX Gain: " << gain << " dB ..." << std::endl;
    for (size_t i = 0; i < channels.size(); i++)
        usrp->set_tx_gain(gain, channels[i]);
    std::cout << "Actual TX Gain: " << (usrp->get_tx_gain(channels.front())) << "..."
              << std::endl
              << std::endl;

    // set the analog frontend filter bandwidth
    if (bw > 0) {
        std::cout << "Requesting TX Bandwidth: " << (bw / 1e6) << " MHz..." << std::endl;
        usrp->set_tx_bandwidth(bw);
        std::cout << "Actual TX Bandwidth: "
                  << usrp->get_tx_bandwidth(channels.front()) / 1e6 << " MHz..."
                  << std::endl
                  << std::endl;
    }

    // create a transmit streamer
    uhd::stream_args_t stream_args("fc32"); // complex floats
    stream_args.channels             = channels;
    uhd::tx_streamer::sptr tx_stream = usrp->get_tx_stream(stream_args);
    dev->streamer = tx_stream;
    dev->buffptrs.resize(channels.size());

    uhd::tx_metadata_t md;
    md.has_time_spec = false;
    dev->md = md;

    DeviceHandler ret;
    ret.dev = dev;
    return ret;
}


void destroyDevice(DeviceHandler& handler)
{
    Device* dev = handler.dev;
    delete dev;
    handler.dev = nullptr;
}


uint64_t numTxStream(DeviceHandler handler)
{
    return handler.dev->channels.size();
}


void setTimeNextPPS(DeviceHandler handler, long fullsec, double fracsec)
{
    handler.dev->usrp->set_time_next_pps(uhd::time_spec_t(fullsec, fracsec));
}


void getTimeLastPPS(DeviceHandler handler, long& fullsec, double& fracsec)
{
    auto time = handler.dev->usrp->get_time_last_pps();
    fullsec = time.get_full_secs();
    fracsec = time.get_frac_secs();
}


void setNextCommandTime(DeviceHandler handler, int64_t fullsecs, double fracsecs)
{
    Device* dev = handler.dev;
    dev->md.has_time_spec = true;
    dev->md.time_spec = uhd::time_spec_t(fullsecs, fracsecs);
}


void beginBurstTransmit(DeviceHandler handler)
{
    auto dev = handler.dev;

    dev->md.start_of_burst = true;
    dev->md.end_of_burst = false;
    dev->streamer->send(dev->buffptrs, 0, dev->md, 0.01);
    dev->md.start_of_burst = false;
    dev->md.end_of_burst = false;
}


void endBurstTransmit(DeviceHandler handler)
{
    auto dev = handler.dev;

    dev->md.has_time_spec = false;
    dev->md.start_of_burst = false;
    dev->md.end_of_burst = true;
    dev->streamer->send(dev->buffptrs, 0, dev->md);
    dev->md.end_of_burst = false;
}


template <typename T, size_t N> using StaticArray = T[N];
template <typename T> using Const = std::add_const<T>::type;
template <typename T> using Ptr = std::add_pointer<T>::type;

uint64_t burstTransmit(DeviceHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    auto dev = handler.dev;

    for(size_t i = 0; i < dev->buffptrs.size(); ++i)
        dev->buffptrs[i] = reinterpret_cast<std::complex<float> const*>(signals[i]);

    uint64_t num = dev->streamer->send(dev->buffptrs, num_samples, dev->md, 0.01);

    if(num == 0) {
        std::cout << "[tx_burst.cpp] Cannot transmit from USRP" << std::endl;
    }
    return num;
}


}


namespace uhd_usrp_rx_continuous
{


struct Device
{
    nlohmann::json config;
    std::string args;
    std::string subdev;
    std::vector<size_t> channels;
    double freq;
    double lo_offset;
    double rate;
    double gain;
    std::string ant;
    double bw;
    std::string clockref;
    std::string timeref;
    bool tuningIntN;

    uhd::usrp::multi_usrp::sptr usrp;
    uhd::rx_streamer::sptr streamer;
    std::vector<char*> buffptrs;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
    uhd::rx_metadata_t md;
};


}
