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
#include <algorithm>

using namespace std::chrono_literals;

namespace uhd_rfnoc
{


// ブロックについて，使用されているポート番号とインデックスの対応表を取得する
// たとえば，ポート0,2,3が使用されている場合，{0:0,2:1,3:2}を返す
std::map<uint32_t, uint32_t> getUsedPortToIndex(uhd::rfnoc::rfnoc_graph::sptr graph, uhd::rfnoc::block_id_t const& block_id)
{
    std::map<uint32_t, uint32_t> port_usage;
    uint32_t max_ports = 0;
    for (const auto& conn : graph->enumerate_active_connections()) {
        uhd::rfnoc::block_id_t src_block_id(conn.src_blockid);
        if(src_block_id == block_id) {
            port_usage[conn.src_port]++;
            max_ports = std::max(max_ports, static_cast<uint32_t>(conn.src_port));
        }

        uhd::rfnoc::block_id_t dst_block_id(conn.dst_blockid);
        if(dst_block_id == block_id) {
            port_usage[conn.dst_port]++;
            max_ports = std::max(max_ports, static_cast<uint32_t>(conn.dst_port));
        }
    }

    std::map<uint32_t, uint32_t> port_to_index;
    uint32_t index = 0;
    for(uint32_t port = 0; port <= max_ports; ++port) {
        if(port_usage.find(port) != port_usage.end()) {
            port_to_index[port] = index++;
        }
    }

    return port_to_index;
}


struct BlockAndPort
{
    uhd::rfnoc::block_id_t id;
    uint32_t port;
};


BlockAndPort parseBlockAndPort(std::string const& str)
{
    BlockAndPort bap;
    auto pos = str.find(':');
    if (pos == std::string::npos) {
        bap.id = uhd::rfnoc::block_id_t(str);
        bap.port = 0;
    } else {
        bap.id = uhd::rfnoc::block_id_t(str.substr(0, pos));
        bap.port = std::stoul(str.substr(pos + 1));
    }

    return bap;
}


static inline std::string trim(const std::string& s) {
    auto start = s.find_first_not_of(" \t");
    auto end   = s.find_last_not_of(" \t");
    if (start == std::string::npos) return "";
    return s.substr(start, end - start + 1);
}


std::array<BlockAndPort, 2> parseConnection(std::string const& str)
{
    auto pos = str.find("=>");
    if (pos == std::string::npos) {
        throw std::runtime_error("Invalid connection string: " + str);
    }
    std::array<BlockAndPort, 2> result;
    result[0] = parseBlockAndPort(trim(str.substr(0, pos)));
    result[1] = parseBlockAndPort(trim(str.substr(pos + 2)));
    return result;
}



std::optional<uhd::rfnoc::block_id_t> find_block(
    uhd::rfnoc::rfnoc_graph::sptr graph,
    std::string const& neighbor_block_id,
    uint32_t neighbor_block_port,
    std::string const& target_block_type
)
{
    auto edges = graph->enumerate_active_connections();
    for (auto& edge : edges) {
        if(edge.src_blockid == neighbor_block_id && edge.src_port == neighbor_block_port) {
            auto blockid = uhd::rfnoc::block_id_t(edge.dst_blockid);
            if (blockid.match(target_block_type)) {
                return blockid;
            }
        }

        if(edge.dst_blockid == neighbor_block_id && edge.dst_port == neighbor_block_port) {
            auto blockid = uhd::rfnoc::block_id_t(edge.src_blockid);
            if (blockid.match(target_block_type)) {
                return blockid;
            }
        }
    }

    return std::nullopt;
}




struct Streamer
{
    virtual ~Streamer() = default;
};


struct TxReplayStreamer : Streamer
{
    int num_channels;
    uhd::tx_streamer::sptr streamer;
    std::vector<uhd::rfnoc::replay_block_control::sptr> replay_ctrl;
    std::vector<uint32_t> replay_chan;

    std::vector<uint32_t> replay_buff_addr;
    std::vector<uint32_t> replay_buff_size;

    bool has_time_spec;
    uhd::time_spec_t time_spec;


    // uint64_t setTransmitSignal(void const* const* signals, uint64_t sample_size, uint64_t num_samples)
    // {
    //     for(uint32_t i = 0; i < this->num_channels; ++i) {
    //         const size_t replay_word_size = this->replay_ctrl[i]->get_word_size(); // Size of words used by replay block

    //         // Calculate the number of 64-bit words and samples to replay
    //         size_t words_to_replay = (num_samples * sample_size) / replay_word_size;
    //         size_t samples_to_replay = num_samples;

    //         /************************************************************************
    //         * Configure replay block
    //         ***********************************************************************/
    //         // Configure a buffer in the on-board memory at address 0 that's equal in
    //         // size to the file we want to play back (rounded down to a multiple of
    //         // 64-bit words). Note that it is allowed to playback a different size or
    //         // location from what was recorded.
    //         uint32_t replay_buff_size = samples_to_replay * sample_size;
    //         this->replay_ctrl[i]->record(this->replay_buff_addr[i], replay_buff_size, this->replay_chan[i]);
    //         // this->replay_buff_addr = replay_buff_addr;
    //         this->replay_buff_size[i] = replay_buff_size;

    //         // Display replay configuration
    //         std::cout << "Replay file size:     " << replay_buff_size << " bytes (" << words_to_replay
    //             << " qwords, " << samples_to_replay << " samples)" << std::endl;

    //         std::cout << "Record base address:  0x" << std::hex
    //             << this->replay_ctrl[i]->get_record_offset(this->replay_chan[i]) << std::dec << std::endl;
    //         std::cout << "Record buffer size:   " << this->replay_ctrl[i]->get_record_size(this->replay_chan[i])
    //             << " bytes" << std::endl;
    //         std::cout << "Record fullness:      " << this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i])
    //             << " bytes" << std::endl
    //             << std::endl;

    //         // Restart record buffer repeatedly until no new data appears on the Replay
    //         // block's input. This will flush any data that was buffered on the input.
    //         uint32_t fullness;
    //         std::cout << "Emptying record buffer..." << std::endl;
    //         do {
    //             this->replay_ctrl[i]->record_restart(this->replay_chan[i]);

    //             // Make sure the record buffer doesn't start to fill again
    //             auto start_time = std::chrono::steady_clock::now();
    //             do {
    //                 fullness = this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]);
    //                 if (fullness != 0)
    //                     break;
    //             } while (start_time + 250ms > std::chrono::steady_clock::now());
    //         } while (fullness);
    //         std::cout << "Record fullness:      " << this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i])
    //             << " bytes" << std::endl
    //             << std::endl;
    //     }

    //     /************************************************************************
    //     * Send data to replay (== record the data)
    //     ***********************************************************************/
    //     std::cout << "Sending data to be recorded..." << std::endl;
    //     uhd::tx_metadata_t tx_md;
    //     tx_md.start_of_burst = true;
    //     tx_md.end_of_burst   = true;
    //     // We use a very big timeout here, any network buffering issue etc. is not
    //     // a problem for this application, and we want to upload all the data in one
    //     // send() call.
    //     std::vector<void const*> buffs(this->num_channels);
    //     for(uint32_t i = 0; i < this->num_channels; ++i)
    //         buffs[i] = signals[i];

    //     size_t num_tx_samps = this->streamer->send(buffs, num_samples, tx_md, 5);
    //     if (num_tx_samps != num_samples) {
    //         std::cout << "ERROR: Unable to send " << num_samples << " samples (sent "
    //             << num_tx_samps << ")" << std::endl;
    //         return false;
    //     }

    //     /************************************************************************
    //     * Wait for data to be stored in on-board memory
    //     ***********************************************************************/
    //     std::cout << "Waiting for recording to complete..." << std::endl;
    //     for(uint32_t i = 0; i < this->num_channels; ++i) {
    //         while (this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]) < this->replay_buff_size[i]) {
    //             std::this_thread::sleep_for(50ms);
    //         }
    //         size_t recorded_samples = this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]) / sample_size;
    //         std::cout << "Channel " << i << ": Recorded " << recorded_samples << " samples."
    //             << std::endl;
            
    //         if(recorded_samples != num_samples) {
    //             std::cout << "ERROR: Unable to record " << num_samples << " samples (recorded "
    //                 << recorded_samples << ")" << std::endl;
    //             return 0;
    //         }
    //     }
    //     // return dev->replay_ctrl[i]->get_record_fullness(dev->replay_chan[i]) / sample_size;

    //     return num_tx_samps;
    // }


    // void startTransmit()
    // {
    //     const bool repeat = true;
    //     uhd::time_spec_t time_spec = uhd::time_spec_t(0.0);
    //     if(this->has_time_spec)
    //         time_spec = this->time_spec;

    //     for(uint32_t i = 0; i < this->num_channels; ++i) {
    //         this->replay_ctrl[i]->play(this->replay_buff_addr[i], this->replay_buff_size[i], this->replay_chan[i], time_spec, repeat);
    //     }

    //     this->has_time_spec = false;
    // }


    // void stopTransmit()
    // {
    //     for(uint32_t i = 0; i < this->num_channels; ++i)
    //         this->replay_ctrl[i]->stop(this->replay_chan[i]);
    // }
};


struct Device
{
    std::string name;
    nlohmann::json config;
    std::string args;
    std::vector<std::string> clockref;
    std::vector<std::string> timeref;

    uhd::rfnoc::rfnoc_graph::sptr graph;
    std::vector<Streamer*> tx_streamer_objects;
    std::vector<Streamer*> rx_streamer_objects;


    ~Device()
    {
        for(auto& streamer: tx_streamer_objects) {
            delete streamer;
        }
        tx_streamer_objects.clear();

        for(auto& streamer: rx_streamer_objects) {
            delete streamer;
        }
        rx_streamer_objects.clear();
    }


    void setupGraph(nlohmann::json& config)
    {
        std::cout << "Setting up RFNoC graph for Device: " << this->name << std::endl;

        auto graph = this->graph;
        auto conns = config.value("connections", std::vector<std::string>{});
        for(auto& conn_str: conns) {
            auto bap = parseConnection(conn_str);
            uhd::rfnoc::connect_through_blocks(graph, bap[0].id, bap[0].port, bap[1].id, bap[1].port);
            std::cout << "\tConnected " << bap[0].id << ":" << bap[0].port << " => " << bap[1].id << ":" << bap[1].port << std::endl;
        }

        for(auto& e: config["tx-streamers"]) {
            auto bap_strs = e.value("connect_to", std::vector<std::string>{});
            std::vector<BlockAndPort> baps = {};
            for(auto& bap_str: bap_strs) {
                baps.push_back(parseBlockAndPort(bap_str));
            }

            auto cpu_format = "fc32";
            auto wire_format = "sc16";
            uhd::device_addr_t streamer_args;
            uhd::stream_args_t stream_args(cpu_format, wire_format);

            stream_args.args = streamer_args;
            auto tx_streamer = graph->create_tx_streamer(baps.size(), stream_args);

            auto tx_replay_streamer = new TxReplayStreamer{};
            tx_replay_streamer->num_channels = baps.size();
            tx_replay_streamer->streamer = tx_streamer;
            for(size_t i = 0; i < baps.size(); ++i) {
                graph->connect(tx_streamer, i, baps[i].id, baps[i].port);
                std::cout << "Connected TX streamer to " << baps[i].id << ":" << baps[i].port << std::endl;

                auto reply_ctrl = graph->get_block<uhd::rfnoc::replay_block_control>(baps[i].id);
                tx_replay_streamer->replay_ctrl.push_back(reply_ctrl);
                tx_replay_streamer->replay_chan.push_back(baps[i].port);

                auto port_to_index = getUsedPortToIndex(graph, baps[i].id);
                size_t mem_stride = reply_ctrl->get_mem_size() / port_to_index.size();
                tx_replay_streamer->replay_buff_addr.push_back(mem_stride * port_to_index[baps[i].port]);
                tx_replay_streamer->replay_buff_size.push_back(0);

                std::cout << "Using Replay Block: " << baps[i].id << ", channel " << baps[i].port
                << ", Memory Address: " << tx_replay_streamer->replay_buff_addr.back()
                << " to " << tx_replay_streamer->replay_buff_addr.back() + mem_stride << std::endl;
            }

            this->tx_streamer_objects.push_back(tx_replay_streamer);
        }
    }


    void setupRadios(nlohmann::json& config)
    {
        // Apply any radio arguments provided
        for(auto& e: config["radios"].items()) {
            std::string radio_block_id = e.key();
            nlohmann::json radio_config = e.value();

            auto tx_used_channels = radio_config.value("tx-channels", std::vector<uint32_t>{});
            auto tx_args = radio_config.value("tx-args", std::vector<std::string>{});
            auto tx_freq = radio_config.value("tx-freq", std::vector<double>{});
            auto tx_rate = radio_config.value("tx-rate", std::vector<double>{});
            auto tx_gain = radio_config.value("tx-gain", std::vector<double>{});
            auto tx_ant = radio_config.value("tx-ant", std::vector<std::string>{});
            auto tx_bw = radio_config.value("tx-bw", std::vector<double>{});
            auto rx_used_channels = radio_config.value("rx-channels", std::vector<uint32_t>{});
            auto rx_args = radio_config.value("rx-args", std::vector<std::string>{});
            auto rx_freq = radio_config.value("rx-freq", std::vector<double>{});
            auto rx_rate = radio_config.value("rx-rate", std::vector<double>{});
            auto rx_gain = radio_config.value("rx-gain", std::vector<double>{});
            auto rx_ant = radio_config.value("rx-ant", std::vector<std::string>{});
            auto rx_bw = radio_config.value("rx-bw", std::vector<double>{});

            auto radio_ctrl = this->graph->get_block<uhd::rfnoc::radio_control>(radio_block_id);

            for(size_t i = 0; i < tx_used_channels.size(); ++i) {
                uint32_t radio_chan = tx_used_channels[i];
                std::string arg = (i < tx_args.size()) ? tx_args[i] : "";
                double freq = (i < tx_freq.size()) ? tx_freq[i] : -1;
                double rate = (i < tx_rate.size()) ? tx_rate[i] : -1;
                double gain = (i < tx_gain.size()) ? tx_gain[i] : -1;
                std::string ant = (i < tx_ant.size()) ? tx_ant[i] : "";
                double bw = (i < tx_bw.size()) ? tx_bw[i] : -1;

                if(freq < 0) {
                    std::cerr << "Please specify the center frequency for TX channel " << radio_chan << " on " << radio_block_id << std::endl;
                    return;
                }

                std::cout << "Setting up TX Radio Block: " << radio_block_id << ", channel: " << radio_chan << std::endl;

                if(arg.size() > 0)
                    radio_ctrl->set_tx_tune_args(arg, radio_chan);

                // 中心周波数の設定
                std::cout << std::fixed;
                std::cout << "Requesting TX Freq: " << (freq / 1e6) << " MHz..." << std::endl;
                radio_ctrl->set_tx_frequency(freq, radio_chan);
                std::cout << "Actual TX Freq: " << (radio_ctrl->get_tx_frequency(radio_chan) / 1e6)
                        << " MHz..." << std::endl
                        << std::endl;
                std::cout << std::resetiosflags(std::ios::fixed);

                // サンプルレートの設定
                if(rate >= 0) {
                    std::cout << std::fixed;
                    std::cout << "Requesting TX Rate: " << (rate / 1e6) << " Msps..." << std::endl;

                    auto duc_id = find_block(this->graph, radio_block_id, radio_chan, "DUC");
                    if(duc_id) {
                        auto duc_ctrl = this->graph->get_block<uhd::rfnoc::duc_block_control>(*duc_id);
                        std::cout << "DUC block found: " << *duc_id << std::endl;
                        duc_ctrl->set_input_rate(rate, radio_chan);
                        std::cout << "  Interpolation value is "
                                << duc_ctrl->get_property<int>("interp", radio_chan) << std::endl;
                        rate = duc_ctrl->get_input_rate(radio_chan);
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
    }
};


struct DeviceHandler
{
    Device* dev;
};


struct TxReplayStreamerHandler
{
    TxReplayStreamer* streamer;
};


// struct TxDefaultStreamerHandler
// {
//     std::shared_ptr<TxDefaultStreamer>* streamer;
// };


// struct RxDefaultStreamerHandler
// {
//     std::shared_ptr<RxDefaultStreamer>* streamer;
// };


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
    dev->setupGraph(config);
    dev->graph->commit();

    // // キャプチャ開始アドレスの計算
    // std::map<uint32_t, uint32_t> replay_id_count;
    // for(auto& tx_streamer: dev->tx_streamers) {
    //     if (tx_streamer) {
    //         tx_streamer->replay_buff_addr.resize(tx_streamer->num_channels);
    //         tx_streamer->replay_buff_size.resize(tx_streamer->num_channels);

    //         for(size_t i = 0; i < tx_streamer->num_channels; ++i) {
    //             uint32_t numUsedChannels = getNumUsedChannelsForReplay(config, tx_streamer->replay_id[i]);

    //             if(replay_id_count.find(tx_streamer->replay_id[i]) == replay_id_count.end())
    //                 replay_id_count[tx_streamer->replay_id[i]] = 0;
    //             replay_id_count[tx_streamer->replay_id[i]] = replay_id_count[tx_streamer->replay_id[i]] + 1;

    //             // Calculate the number of 64-bit words and samples to replay
    //             size_t mem_size = tx_streamer->replay_ctrl[i]->get_mem_size();
    //             size_t mem_stride = mem_size / numUsedChannels;

    //             tx_streamer->replay_buff_addr[i] = (replay_id_count[tx_streamer->replay_id[i]]-1) * mem_stride;
    //         }
    //     }
    // }

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

    dev->setupRadios(config);

    // for(auto& tx_streamer: dev->tx_streamers) {
    //     setupTxReplayStreamerRadio(*dev, tx_streamer);
    // }

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



TxReplayStreamerHandler getTxReplayStreamer(char const* name, DeviceHandler handler, uint32_t index)
{
    Device* dev = handler.dev;

    TxReplayStreamerHandler tx_handler;
    tx_handler.streamer = dynamic_cast<TxReplayStreamer*>(dev->tx_streamer_objects[index]);

    return tx_handler;
}


void destroyDevice(DeviceHandler& handler)
{
    Device* dev = handler.dev;
    delete dev;
    handler.dev = nullptr;
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


uint32_t getNumChannels(TxReplayStreamerHandler handler)
{
    auto& streamer = *handler.streamer;
    return streamer.num_channels;
}


// void setNextCommandTime(DeviceHandler handler, int64_t fullsecs, double fracsecs)
// {
//     Device* dev = handler.dev;
//     dev->has_time_spec = true;
//     dev->time_spec = uhd::time_spec_t(fullsecs, fracsecs);
// }



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



uint64_t setTransmitSignal(TxReplayStreamerHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    auto streamer = handler.streamer;

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
    std::vector<void const*> buffs(streamer->num_channels);
    for(uint32_t i = 0; i < streamer->num_channels; ++i)
        buffs[i] = signals[i];

    size_t num_tx_samps = streamer->streamer->send(buffs, num_samples, tx_md, 5);
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


void startTransmit(TxReplayStreamerHandler handler)
{
    auto streamer = handler.streamer;

    const bool repeat = true;
    uhd::time_spec_t time_spec = uhd::time_spec_t(0.0);
    if(streamer->has_time_spec)
        time_spec = streamer->time_spec;

    for(uint32_t i = 0; i < streamer->num_channels; ++i) {
        streamer->replay_ctrl[i]->play(streamer->replay_buff_addr[i], streamer->replay_buff_size[i], streamer->replay_chan[i], time_spec, repeat);
        std::cout << "Started transmit on channel " << i << std::endl;
    }

    streamer->has_time_spec = false;
}


void stopTransmit(TxReplayStreamerHandler handler)
{
    auto streamer = handler.streamer;
    for(uint32_t i = 0; i < streamer->num_channels; ++i)
        streamer->replay_ctrl[i]->stop(streamer->replay_chan[i]);
}


}