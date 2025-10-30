// Reference: https://github.com/EttusResearch/uhd/blob/master/host/examples/rfnoc_replay_samples_from_file.cpp

#include <uhd/rfnoc/block_id.hpp>
#include <uhd/rfnoc/duc_block_control.hpp>
#include <uhd/rfnoc/mb_controller.hpp>
#include <uhd/rfnoc/radio_control.hpp>
#include <uhd/rfnoc/replay_block_control.hpp>
#include <uhd/rfnoc_graph.hpp>
#include <uhd/types/tune_request.hpp>
#include <uhd/utils/graph_utils.hpp>
#include <uhd/utils/math.hpp>
#include <string>
#include <nlohmann/json.hpp>
#include <chrono>

using namespace std::chrono_literals;

namespace looptx_rfnoc_replay_block
{


struct TxReplayStreamer
{
    int num_channels;
    std::vector<std::string> tx_args;
    std::vector<uint32_t> radio_id;
    std::vector<uint32_t> radio_chan;
    std::vector<uint32_t> replay_id;
    std::vector<uint32_t> replay_chan;
    std::vector<double> freq;
    std::vector<double> rate;
    std::vector<double> gain;
    std::vector<std::string> ant;
    std::vector<double> bw;
    uhd::tx_streamer::sptr streamer;
    std::vector<uhd::rfnoc::radio_control::sptr> radio_ctrl;
    std::vector<uhd::rfnoc::replay_block_control::sptr> replay_ctrl;
    std::vector<uhd::rfnoc::duc_block_control::sptr> duc_ctrl;
    std::vector<uint32_t> duc_chan;

    std::vector<uint32_t> replay_buff_addr;
    std::vector<uint32_t> replay_buff_size;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
};


struct Device
{
    std::string name;
    nlohmann::json config;
    std::string args;
    std::string tx_args;
    // uint32_t radio_id;
    // uint32_t radio_chan;
    // uint32_t replay_id;
    // uint32_t replay_chan;
    // double freq;
    // double rate;
    // double gain;
    // std::string ant;
    // double bw;
    std::vector<std::string> clockref;
    std::vector<std::string> timeref;

    uhd::rfnoc::rfnoc_graph::sptr graph;
    std::vector<std::shared_ptr<TxReplayStreamer>> tx_streamers;
};


struct DeviceHandler
{
    Device* dev;
};


struct TxStreamerHandler
{
    std::shared_ptr<TxReplayStreamer>* streamer;
};


uint32_t getNumUsedChannelsForReplay(nlohmann::json& config, uint32_t replay_id)
{
    uint32_t used_channels = 0;
    for (auto& e : config["tx-streamers"]) {
        auto rid = e.value("replay_id", std::vector<uint32_t>{0});
        for (auto id : rid) {
            if (id == replay_id) {
                used_channels++;
            }
        }
    }
    return used_channels;
}


std::shared_ptr<TxReplayStreamer> setupTxReplayStreamerGraph(Device& dev, nlohmann::json& config)
{
    auto tx_replay_streamer = std::make_shared<TxReplayStreamer>();


    tx_replay_streamer->tx_args = config.value("tx_args", std::vector<std::string>{});
    tx_replay_streamer->radio_id = config.value("radio_id", std::vector<uint32_t>{0});
    tx_replay_streamer->radio_chan = config.value("radio_ch", std::vector<uint32_t>{0});
    tx_replay_streamer->replay_id = config.value("replay_id", std::vector<uint32_t>{0});
    tx_replay_streamer->replay_chan = config.value("replay_ch", std::vector<uint32_t>{0});
    tx_replay_streamer->freq = config.value("freq", std::vector<double>{-1.0});
    tx_replay_streamer->rate = config.value("rate", std::vector<double>{-1.0});
    tx_replay_streamer->gain = config.value("gain", std::vector<double>{-1.0});
    tx_replay_streamer->ant = config.value("ant", std::vector<std::string>{""});
    tx_replay_streamer->bw = config.value("bw", std::vector<double>{-1.0});
    tx_replay_streamer->num_channels = tx_replay_streamer->radio_id.size();

    // tx_args, radio_id, radio_chan, replay_id, replay_chan, freq, rate, gain, ant, bw size check
    if(
       tx_replay_streamer->tx_args.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->radio_id.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->radio_chan.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->replay_id.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->replay_chan.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->freq.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->rate.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->gain.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->ant.size() != tx_replay_streamer->num_channels ||
       tx_replay_streamer->bw.size() != tx_replay_streamer->num_channels)
    {
        throw std::runtime_error("Mismatched size in TxReplayStreamer configuration vectors.");
    }

    auto graph = dev.graph;

    for(uint32_t i = 0; i < tx_replay_streamer->num_channels; ++i) {
        std::string tx_args = tx_replay_streamer->tx_args[i];
        uint32_t radio_id = tx_replay_streamer->radio_id[i];
        uint32_t radio_chan = tx_replay_streamer->radio_chan[i];
        uint32_t replay_id = tx_replay_streamer->replay_id[i];
        uint32_t replay_chan = tx_replay_streamer->replay_chan[i];

        // if (tx_replay_streamer->duc_ctrl[i]) {
        //     std::cout << "Using DUC Block:    " << tx_replay_streamer->duc_ctrl[i]->get_block_id() << ", channel "
        //             << tx_replay_streamer->duc_chan[i] << std::endl;
        // }
        // double freq = tx_replay_streamer->freq[i];
        // double rate = tx_replay_streamer->rate[i];
        // double gain = tx_replay_streamer->gain[i];
        // std::string ant = tx_replay_streamer->ant[i];
        // double bw = tx_replay_streamer->bw[i];

        // Create handle for radio object
        uhd::rfnoc::block_id_t radio_ctrl_id(0, "Radio", radio_id);
        auto radio_ctrl = graph->get_block<uhd::rfnoc::radio_control>(radio_ctrl_id);
        tx_replay_streamer->radio_ctrl.push_back(radio_ctrl);

        // Check if the replay block exists on this device
        uhd::rfnoc::block_id_t replay_ctrl_id(0, "Replay", replay_id);
        if (!graph->has_block(replay_ctrl_id)) {
            std::cout << "Unable to find block \"" << replay_ctrl_id << "\"" << std::endl;
            return nullptr;
        }
        auto replay_ctrl = graph->get_block<uhd::rfnoc::replay_block_control>(replay_ctrl_id);
        tx_replay_streamer->replay_ctrl.push_back(replay_ctrl);

                        // Report blocks
        std::cout << "Using Radio Block:  " << radio_ctrl_id << ", channel " << radio_chan
                << std::endl;
        std::cout << "Using Replay Block: " << replay_ctrl_id << ", channel " << replay_chan
                << std::endl;

        // Connect replay to radio
        auto edges = uhd::rfnoc::connect_through_blocks(graph, replay_ctrl_id, replay_chan, radio_ctrl_id, radio_chan);

        // Check for a DUC connected to the radio
        // size_t duc_chan = 0;
        for (auto& edge : edges) {
            auto blockid = uhd::rfnoc::block_id_t(edge.dst_blockid);
            if (blockid.match("DUC")) {
                tx_replay_streamer->duc_ctrl.push_back(graph->get_block<uhd::rfnoc::duc_block_control>(blockid));
                tx_replay_streamer->duc_chan.push_back(edge.dst_port);
                break;
            } else {
                tx_replay_streamer->duc_ctrl.push_back(nullptr);
                tx_replay_streamer->duc_chan.push_back(0);
            }
        }

        // Report blocks
        std::cout << "Using Radio Block:  " << radio_ctrl_id << ", channel " << radio_chan
                << std::endl;
        std::cout << "Using Replay Block: " << replay_ctrl_id << ", channel " << replay_chan
                << std::endl;
        if (tx_replay_streamer->duc_ctrl[i]) {
            std::cout << "Using DUC Block:    " << tx_replay_streamer->duc_ctrl[i]->get_block_id() << ", channel "
                    << tx_replay_streamer->duc_chan[i] << std::endl;
        }
    }


    /************************************************************************
     * Set up streamer to Replay block and commit graph
     ***********************************************************************/
    auto cpu_format = "fc32";
    auto wire_format = "sc16";
    uhd::device_addr_t streamer_args;
    uhd::stream_args_t stream_args(cpu_format, wire_format);
    uhd::tx_streamer::sptr tx_stream;
    uhd::tx_metadata_t tx_md;

    stream_args.args = streamer_args;
    tx_stream        = graph->create_tx_streamer(tx_replay_streamer->num_channels, stream_args);
    for(uint32_t i = 0; i < tx_replay_streamer->num_channels; ++i) {
        graph->connect(tx_stream, i, tx_replay_streamer->replay_ctrl[i]->get_block_id(), tx_replay_streamer->replay_chan[i]);
    }

    tx_replay_streamer->streamer = tx_stream;
    return tx_replay_streamer;
}


void setupTxReplayStreamerRadio(Device& dev, std::shared_ptr<TxReplayStreamer> tx_replay_streamer)
{
    // Apply any radio arguments provided
    for(uint32_t i = 0; i < tx_replay_streamer->num_channels; ++i) {
        auto tx_args = tx_replay_streamer->tx_args[i];
        auto freq = tx_replay_streamer->freq[i];
        auto rate = tx_replay_streamer->rate[i];
        auto gain = tx_replay_streamer->gain[i];
        auto ant = tx_replay_streamer->ant[i];
        auto bw = tx_replay_streamer->bw[i];
        auto radio_ctrl = tx_replay_streamer->radio_ctrl[i];
        auto radio_chan = tx_replay_streamer->radio_chan[i];
        auto duc_ctrl = tx_replay_streamer->duc_ctrl[i];
        auto duc_chan = tx_replay_streamer->duc_chan[i];
        auto replay_ctrl = tx_replay_streamer->replay_ctrl[i];
        auto replay_chan = tx_replay_streamer->replay_chan[i];

        if (tx_args.size() > 0) {
            radio_ctrl->set_tx_tune_args(tx_args, radio_chan);
        }

        // Set the center frequency
        if (freq < 0) {
            std::cerr << "Please specify the center frequency" << std::endl;
            return;
        }

        std::cout << std::fixed;
        std::cout << "Requesting TX Freq: " << (freq / 1e6) << " MHz..." << std::endl;
        radio_ctrl->set_tx_frequency(freq, radio_chan);
        std::cout << "Actual TX Freq: " << (radio_ctrl->get_tx_frequency(radio_chan) / 1e6)
                << " MHz..." << std::endl
                << std::endl;
        std::cout << std::resetiosflags(std::ios::fixed);

        // Set the sample rate
        if (rate >= 0) {
            std::cout << std::fixed;
            std::cout << "Requesting TX Rate: " << (rate / 1e6) << " Msps..." << std::endl;
            if (duc_ctrl) {
                std::cout << "DUC block found." << std::endl;
                duc_ctrl->set_input_rate(rate, duc_chan);
                std::cout << "  Interpolation value is "
                        << duc_ctrl->get_property<int>("interp", duc_chan) << std::endl;
                rate = duc_ctrl->get_input_rate(duc_chan);
            } else {
                rate = radio_ctrl->set_rate(rate);
            }
            std::cout << "Actual TX Rate: " << (rate / 1e6) << " Msps..." << std::endl
                    << std::endl;
            std::cout << std::resetiosflags(std::ios::fixed);
        }

        // Set the RF gain
        if (gain >= 0) {
            std::cout << std::fixed;
            std::cout << "Requesting TX Gain: " << gain << " dB..." << std::endl;
            radio_ctrl->set_tx_gain(gain, radio_chan);
            std::cout << "Actual TX Gain: " << radio_ctrl->get_tx_gain(radio_chan) << " dB..."
                    << std::endl
                    << std::endl;
            std::cout << std::resetiosflags(std::ios::fixed);
        }

        // Set the analog front-end filter bandwidth
        if (bw >= 0) {
            std::cout << std::fixed;
            std::cout << "Requesting TX Bandwidth: " << (bw / 1e6) << " MHz..." << std::endl;
            radio_ctrl->set_tx_bandwidth(bw, radio_chan);
            std::cout << "Actual TX Bandwidth: "
                    << (radio_ctrl->get_tx_bandwidth(radio_chan) / 1e6) << " MHz..."
                    << std::endl
                    << std::endl;
            std::cout << std::resetiosflags(std::ios::fixed);
        }

        // Set the antenna
        if (ant.size() > 0) {
            radio_ctrl->set_tx_antenna(ant, radio_chan);
        }
    }
}



DeviceHandler setupDevice(
    char const* name,
    char const* configJSON
)
{
    nlohmann::json config = nlohmann::json::parse(configJSON);

    std::string args = config.value("args", "");
    std::vector<std::string> clockref = config.value("clockref", std::vector<std::string>{});
    std::vector<std::string> timeref = config.value("timeref", std::vector<std::string>{});
    // uint32_t radio_id = config.value("radio_id", 0);
    // uint32_t radio_chan = config.value("radio_chan", 0);
    // uint32_t replay_id = config.value("replay_id", 0);
    // uint32_t replay_chan = config.value("replay_chan", 0);
    // double freq = config.value("freq", -1.0);
    // double rate = config.value("rate", -1.0);
    // double gain = config.value("gain", -1.0);
    // std::string ant = config.value("ant", "");
    // double bw = config.value("bw", -1.0);
    // std::string clockref = config.value("clockref", "");
    // std::string timeref = config.value("timeref", "");
    // auto cpu_format = "fc32";
    // auto wire_format = "sc16";

    Device* dev = new Device;
    dev->name = name;
    dev->config = config;
    dev->args = args;
    dev->clockref = clockref;
    dev->timeref = timeref;
    // dev->tx_args = tx_args;
    // dev->radio_id = radio_id;
    // dev->radio_chan = radio_chan;
    // dev->replay_id = replay_id;
    // dev->replay_chan = replay_chan;
    // dev->freq = freq;
    // dev->rate = rate;
    // dev->gain = gain;
    // dev->ant = ant;
    // dev->bw = bw;
    // dev->clockref = clockref;
    // dev->timeref = timeref;

    std::cout << "Creating the RFNoC graph with args: " << args << "..." << std::endl;
    auto graph = uhd::rfnoc::rfnoc_graph::make(args);
    dev->graph = graph;

    for(auto& e: config["tx-streamers"]) {
        dev->tx_streamers.push_back(setupTxReplayStreamerGraph(*dev, e));
    }

    dev->graph->commit();

    // キャプチャ開始アドレスの計算
    std::map<uint32_t, uint32_t> replay_id_count;
    for(auto& tx_streamer: dev->tx_streamers) {
        if (tx_streamer) {
            tx_streamer->replay_buff_addr.resize(tx_streamer->num_channels);
            tx_streamer->replay_buff_size.resize(tx_streamer->num_channels);

            for(size_t i = 0; i < tx_streamer->num_channels; ++i) {
                uint32_t numUsedChannels = getNumUsedChannelsForReplay(config, tx_streamer->replay_id[i]);

                if(replay_id_count.find(tx_streamer->replay_id[i]) == replay_id_count.end())
                    replay_id_count[tx_streamer->replay_id[i]] = 0;
                replay_id_count[tx_streamer->replay_id[i]] = replay_id_count[tx_streamer->replay_id[i]] + 1;

                // Calculate the number of 64-bit words and samples to replay
                size_t mem_size = tx_streamer->replay_ctrl[i]->get_mem_size();
                size_t mem_stride = mem_size / numUsedChannels;

                tx_streamer->replay_buff_addr[i] = replay_id_count[tx_streamer->replay_id[i]] * mem_stride;
            }
        }
    }

    /************************************************************************
     * Set up radio
     ***********************************************************************/
    // Set clock reference
    for(size_t i = 0; i < clockref.size(); ++i) {
        graph->get_mb_controller(i)->set_clock_source(clockref[i]);
    }

    for(size_t i = 0; i < timeref.size(); ++i) {
        graph->get_mb_controller(i)->set_time_source(timeref[i]);
    }

    for(auto& tx_streamer: dev->tx_streamers) {
        setupTxReplayStreamerRadio(*dev, tx_streamer);
    }

    // // Create handle for radio object
    // uhd::rfnoc::block_id_t radio_ctrl_id(0, "Radio", radio_id);
    // auto radio_ctrl = graph->get_block<uhd::rfnoc::radio_control>(radio_ctrl_id);
    // dev->radio_ctrl = radio_ctrl;

    // // Check if the replay block exists on this device
    // uhd::rfnoc::block_id_t replay_ctrl_id(0, "Replay", replay_id);
    // if (!graph->has_block(replay_ctrl_id)) {
    //     std::cout << "Unable to find block \"" << replay_ctrl_id << "\"" << std::endl;
    //     return DeviceHandler{nullptr};
    // }
    // auto replay_ctrl = graph->get_block<uhd::rfnoc::replay_block_control>(replay_ctrl_id);
    // dev->replay_ctrl = replay_ctrl;

    // // Connect replay to radio
    // auto edges = uhd::rfnoc::connect_through_blocks(graph, replay_ctrl_id, replay_chan, radio_ctrl_id, radio_chan);

    // // Check for a DUC connected to the radio
    // uhd::rfnoc::duc_block_control::sptr duc_ctrl;
    // size_t duc_chan = 0;
    // for (auto& edge : edges) {
    //     auto blockid = uhd::rfnoc::block_id_t(edge.dst_blockid);
    //     if (blockid.match("DUC")) {
    //         duc_ctrl = graph->get_block<uhd::rfnoc::duc_block_control>(blockid);
    //         duc_chan = edge.dst_port;
    //         break;
    //     }
    // }

    // // Report blocks
    // std::cout << "Using Radio Block:  " << radio_ctrl_id << ", channel " << radio_chan
    //           << std::endl;
    // std::cout << "Using Replay Block: " << replay_ctrl_id << ", channel " << replay_chan
    //           << std::endl;
    // if (duc_ctrl) {
    //     std::cout << "Using DUC Block:    " << duc_ctrl->get_block_id() << ", channel "
    //               << duc_chan << std::endl;
    // }


    // /************************************************************************
    //  * Set up streamer to Replay block and commit graph
    //  ***********************************************************************/
    // uhd::device_addr_t streamer_args;
    // uhd::stream_args_t stream_args(cpu_format, wire_format);
    // uhd::tx_streamer::sptr tx_stream;
    // uhd::tx_metadata_t tx_md;

    // stream_args.args = streamer_args;
    // tx_stream        = graph->create_tx_streamer(1, stream_args);
    // graph->connect(tx_stream, 0, replay_ctrl->get_block_id(), replay_chan);
    // graph->commit();
    // dev->streamer = tx_stream;



    // // Apply any radio arguments provided
    // if (tx_args.size() > 0) {
    //     radio_ctrl->set_tx_tune_args(tx_args, radio_chan);
    // }

    // // Set the center frequency
    // if (freq < 0) {
    //     std::cerr << "Please specify the center frequency with 'freq'" << std::endl;
    //     return DeviceHandler{nullptr};
    // }

    // std::cout << std::fixed;
    // std::cout << "Requesting TX Freq: " << (freq / 1e6) << " MHz..." << std::endl;
    // radio_ctrl->set_tx_frequency(freq, radio_chan);
    // std::cout << "Actual TX Freq: " << (radio_ctrl->get_tx_frequency(radio_chan) / 1e6)
    //           << " MHz..." << std::endl
    //           << std::endl;
    // std::cout << std::resetiosflags(std::ios::fixed);

    // // Set the sample rate
    // if (rate >= 0) {
    //     std::cout << std::fixed;
    //     std::cout << "Requesting TX Rate: " << (rate / 1e6) << " Msps..." << std::endl;
    //     if (duc_ctrl) {
    //         std::cout << "DUC block found." << std::endl;
    //         duc_ctrl->set_input_rate(rate, duc_chan);
    //         std::cout << "  Interpolation value is "
    //                   << duc_ctrl->get_property<int>("interp", duc_chan) << std::endl;
    //         rate = duc_ctrl->get_input_rate(duc_chan);
    //     } else {
    //         rate = radio_ctrl->set_rate(rate);
    //     }
    //     std::cout << "Actual TX Rate: " << (rate / 1e6) << " Msps..." << std::endl
    //               << std::endl;
    //     std::cout << std::resetiosflags(std::ios::fixed);
    // }

    // // Set the RF gain
    // if (gain >= 0) {
    //     std::cout << std::fixed;
    //     std::cout << "Requesting TX Gain: " << gain << " dB..." << std::endl;
    //     radio_ctrl->set_tx_gain(gain, radio_chan);
    //     std::cout << "Actual TX Gain: " << radio_ctrl->get_tx_gain(radio_chan) << " dB..."
    //               << std::endl
    //               << std::endl;
    //     std::cout << std::resetiosflags(std::ios::fixed);
    // }

    // // Set the analog front-end filter bandwidth
    // if (bw >= 0) {
    //     std::cout << std::fixed;
    //     std::cout << "Requesting TX Bandwidth: " << (bw / 1e6) << " MHz..." << std::endl;
    //     radio_ctrl->set_tx_bandwidth(bw, radio_chan);
    //     std::cout << "Actual TX Bandwidth: "
    //               << (radio_ctrl->get_tx_bandwidth(radio_chan) / 1e6) << " MHz..."
    //               << std::endl
    //               << std::endl;
    //     std::cout << std::resetiosflags(std::ios::fixed);
    // }

    // // Set the antenna
    // if (ant.size() > 0) {
    //     radio_ctrl->set_tx_antenna(ant, radio_chan);
    // }

    DeviceHandler handler = {dev};
    return handler;
}



TxStreamerHandler getTxStreamer(char const* name, DeviceHandler handler, uint32_t index)
{
    Device* dev = handler.dev;

    TxStreamerHandler tx_handler;
    tx_handler.streamer = &(dev->tx_streamers[index]);

    return tx_handler;
}


void destroyDevice(DeviceHandler& handler)
{
    Device* dev = handler.dev;
    delete dev;
    handler.dev = nullptr;
}


uint64_t setTransmitSignal(TxStreamerHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    auto& streamer = *handler.streamer;

    for(uint32_t i = 0; i < streamer->num_channels; ++i) {
        const size_t replay_word_size = streamer->replay_ctrl[i]->get_word_size(); // Size of words used by replay block

        // Calculate the number of 64-bit words and samples to replay
        size_t words_to_replay = (num_samples * sample_size) / replay_word_size;
        size_t samples_to_replay = num_samples;

        /************************************************************************
        * Configure replay block
        ***********************************************************************/
        // Configure a buffer in the on-board memory at address 0 that's equal in
        // size to the file we want to play back (rounded down to a multiple of
        // 64-bit words). Note that it is allowed to playback a different size or
        // location from what was recorded.
        uint32_t replay_buff_size = samples_to_replay * sample_size;
        streamer->replay_ctrl[i]->record(streamer->replay_buff_addr[i], replay_buff_size, streamer->replay_chan[i]);
        // streamer->replay_buff_addr = replay_buff_addr;
        streamer->replay_buff_size[i] = replay_buff_size;

        // Display replay configuration
        std::cout << "Replay file size:     " << replay_buff_size << " bytes (" << words_to_replay
            << " qwords, " << samples_to_replay << " samples)" << std::endl;

        std::cout << "Record base address:  0x" << std::hex
            << streamer->replay_ctrl[i]->get_record_offset(streamer->replay_chan[i]) << std::dec << std::endl;
        std::cout << "Record buffer size:   " << streamer->replay_ctrl[i]->get_record_size(streamer->replay_chan[i])
            << " bytes" << std::endl;
        std::cout << "Record fullness:      " << streamer->replay_ctrl[i]->get_record_fullness(streamer->replay_chan[i])
            << " bytes" << std::endl
            << std::endl;

        // Restart record buffer repeatedly until no new data appears on the Replay
        // block's input. This will flush any data that was buffered on the input.
        uint32_t fullness;
        std::cout << "Emptying record buffer..." << std::endl;
        do {
            streamer->replay_ctrl[i]->record_restart(streamer->replay_chan[i]);

            // Make sure the record buffer doesn't start to fill again
            auto start_time = std::chrono::steady_clock::now();
            do {
                fullness = streamer->replay_ctrl[i]->get_record_fullness(streamer->replay_chan[i]);
                if (fullness != 0)
                    break;
            } while (start_time + 250ms > std::chrono::steady_clock::now());
        } while (fullness);
        std::cout << "Record fullness:      " << streamer->replay_ctrl[i]->get_record_fullness(streamer->replay_chan[i])
            << " bytes" << std::endl
            << std::endl;
    }

    /************************************************************************
    * Send data to replay (== record the data)
    ***********************************************************************/
    std::cout << "Sending data to be recorded..." << std::endl;
    uhd::tx_metadata_t tx_md;
    tx_md.start_of_burst = true;
    tx_md.end_of_burst   = true;
    // We use a very big timeout here, any network buffering issue etc. is not
    // a problem for this application, and we want to upload all the data in one
    // send() call.
    size_t num_tx_samps = streamer->streamer->send(signals, num_samples, tx_md, 5);
    if (num_tx_samps != num_samples) {
        std::cout << "ERROR: Unable to send " << num_samples << " samples (sent "
            << num_tx_samps << ")" << std::endl;
        return false;
    }

    /************************************************************************
    * Wait for data to be stored in on-board memory
    ***********************************************************************/
    std::cout << "Waiting for recording to complete..." << std::endl;
    for(uint32_t i = 0; i < streamer->num_channels; ++i) {
        while (streamer->replay_ctrl[i]->get_record_fullness(streamer->replay_chan[i]) < streamer->replay_buff_size[i]) {
            std::this_thread::sleep_for(50ms);
        }
        size_t recorded_samples = streamer->replay_ctrl[i]->get_record_fullness(streamer->replay_chan[i]) / sample_size;
        std::cout << "Channel " << i << ": Recorded " << recorded_samples << " samples."
            << std::endl;
        
        if(recorded_samples != num_samples) {
            std::cout << "ERROR: Unable to record " << num_samples << " samples (recorded "
                << recorded_samples << ")" << std::endl;
            return 0;
        }
    }
    // return dev->replay_ctrl[i]->get_record_fullness(dev->replay_chan[i]) / sample_size;

    return num_tx_samps;
}



void startTransmit(TxStreamerHandler handler)
{
    auto& streamer = *handler.streamer;

    const bool repeat = true;
    uhd::time_spec_t time_spec = uhd::time_spec_t(0.0);
    if(streamer->has_time_spec)
        time_spec = streamer->time_spec;

    for(uint32_t i = 0; i < streamer->num_channels; ++i) {
        streamer->replay_ctrl[i]->play(streamer->replay_buff_addr[i], streamer->replay_buff_size[i], streamer->replay_chan[i], time_spec, repeat);
    }

    streamer->has_time_spec = false;
}


void stopTransmit(TxStreamerHandler handler)
{
    auto& streamer = *handler.streamer;
    for(uint32_t i = 0; i < streamer->num_channels; ++i)
        streamer->replay_ctrl[i]->stop(streamer->replay_chan[i]);
}


void setParam(DeviceHandler handler, char const* key, char const* jsonvalue)
{
    assert(0);
}


void setTimeNextPPS(DeviceHandler handler, int64_t fullsecs, double fracsecs)
{
    Device* dev = handler.dev;

    for (size_t i = 0; i < dev->graph->get_num_mboards(); ++i) {
        dev->graph->get_mb_controller(i)->get_timekeeper(0)->set_time_next_pps(uhd::time_spec_t(fullsecs, fracsecs));
    }
}


void getTimeLastPPS(DeviceHandler handler, int64_t& fullsecs, double& fracsecs)
{
    Device* dev = handler.dev;
    uhd::time_spec_t time = dev->graph->get_mb_controller(0)->get_timekeeper(0)->get_time_last_pps();

    fullsecs = time.get_full_secs();
    fracsecs = time.get_frac_secs();
}


uint32_t getNumChannels(TxStreamerHandler handler)
{
    auto& streamer = *handler.streamer;
    return streamer->num_channels;
}


// void setNextCommandTime(DeviceHandler handler, int64_t fullsecs, double fracsecs)
// {
//     Device* dev = handler.dev;
//     dev->has_time_spec = true;
//     dev->time_spec = uhd::time_spec_t(fullsecs, fracsecs);
// }

}


// # include <bits/stdc++.h>

// int main()
// {
//     auto device = looptx_rfnoc_replay_block::setupDevice("{\"args\": \"addr=192.168.41.31\", \"freq\": 2.45e9, \"gain\":10, \"rate\": 200e6 }");


        
//     double SAMPLE_RATE = 200.0e6;
//     double FREQUENCY   = 500.0e3;
//     double NUM_SAMPLES = 16000;
//     double AMPLITUDE   = 0.5;

//     std::vector<std::complex<short>> signal(NUM_SAMPLES);
//     for(size_t i = 0; i < NUM_SAMPLES; ++i) {
//         short I = (short)(( (1<<15) -1) * AMPLITUDE * std::cos(i / (SAMPLE_RATE / FREQUENCY) * 2 * M_PI));
//         short Q = (short)(( (1<<15) -1) * AMPLITUDE * std::sin(i / (SAMPLE_RATE / FREQUENCY) * 2 * M_PI));
//         signal[i] = std::complex<short>(I, Q);
//     }


//     void* buf_ptr = &(signal[0]);
//     setTransmitSignal(device, &buf_ptr, 4, NUM_SAMPLES);
//     startTransmit(device);
//     std::this_thread::sleep_for(std::chrono::minutes(5));
//     stopTransmit(device);
//     looptx_rfnoc_replay_block::destroyDevice(device);
//     return 0;
// }