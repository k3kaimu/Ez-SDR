// Reference: https://github.com/EttusResearch/uhd/blob/master/host/examples/rfnoc_replay_samples_from_file.cpp

#include <uhd/rfnoc/block_id.hpp>
#include <uhd/rfnoc/duc_block_control.hpp>
#include <uhd/rfnoc/ddc_block_control.hpp>
#include <uhd/rfnoc/mb_controller.hpp>
#include <uhd/rfnoc/radio_control.hpp>
#include <uhd/rfnoc/replay_block_control.hpp>
#include <uhd/rfnoc_graph.hpp>
#include <uhd/types/tune_request.hpp>
#include <uhd/types/metadata.hpp>
#include <uhd/utils/graph_utils.hpp>
#include <uhd/utils/math.hpp>
#include <string>
#include <nlohmann/json.hpp>
#include <chrono>
#include <algorithm>

#include "../string.hpp"
#include "../asynctaskpool.hpp"
#include "../spinlock.hpp"
#include "../ezsdr_enums.hpp"

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
    ezsdr::StreamerElementType elementType;
    uhd::tx_streamer::sptr streamer;
    std::vector<uhd::rfnoc::replay_block_control::sptr> replay_ctrl;
    std::vector<uint32_t> replay_chan;

    std::vector<uint32_t> replay_buff_addr;
    std::vector<uint32_t> replay_buff_size;

    uhd::time_spec_t time_spec;


    uint64_t setTransmitSignal(void const* const* signals, uint64_t sample_size, uint64_t num_samples)
    {
        for(uint32_t i = 0; i < this->num_channels; ++i) {
            const size_t replay_word_size = this->replay_ctrl[i]->get_word_size(); // Size of words used by replay block

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
            this->replay_ctrl[i]->record(this->replay_buff_addr[i], replay_buff_size, this->replay_chan[i]);
            // this->replay_buff_addr = replay_buff_addr;
            this->replay_buff_size[i] = replay_buff_size;

            // Display replay configuration
            std::cout << "Replay file size:     " << replay_buff_size << " bytes (" << words_to_replay
                << " qwords, " << samples_to_replay << " samples)" << std::endl;

            std::cout << "Record base address:  0x" << std::hex
                << this->replay_ctrl[i]->get_record_offset(this->replay_chan[i]) << std::dec << std::endl;
            std::cout << "Record buffer size:   " << this->replay_ctrl[i]->get_record_size(this->replay_chan[i])
                << " bytes" << std::endl;
            std::cout << "Record fullness:      " << this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i])
                << " bytes" << std::endl
                << std::endl;

            // Restart record buffer repeatedly until no new data appears on the Replay
            // block's input. This will flush any data that was buffered on the input.
            uint32_t fullness;
            std::cout << "Emptying record buffer..." << std::endl;
            do {
                this->replay_ctrl[i]->record_restart(this->replay_chan[i]);

                // Make sure the record buffer doesn't start to fill again
                auto start_time = std::chrono::steady_clock::now();
                do {
                    fullness = this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]);
                    if (fullness != 0)
                        break;
                } while (start_time + 250ms > std::chrono::steady_clock::now());
            } while (fullness);
            std::cout << "Record fullness:      " << this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i])
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
        std::vector<void const*> buffs(this->num_channels);
        for(uint32_t i = 0; i < this->num_channels; ++i)
            buffs[i] = signals[i];

        size_t num_tx_samps = this->streamer->send(buffs, num_samples, tx_md, 5);
        if (num_tx_samps != num_samples) {
            std::cout << "ERROR: Unable to send " << num_samples << " samples (sent "
                << num_tx_samps << ")" << std::endl;
            return false;
        }

        /************************************************************************
        * Wait for data to be stored in on-board memory
        ***********************************************************************/
        std::cout << "Waiting for recording to complete..." << std::endl;
        for(uint32_t i = 0; i < this->num_channels; ++i) {
            while (this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]) < this->replay_buff_size[i]) {
                std::this_thread::sleep_for(50ms);
            }
            size_t recorded_samples = this->replay_ctrl[i]->get_record_fullness(this->replay_chan[i]) / sample_size;
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


    void startTransmit(uint8_t const* optArgs, uint64_t optArgsLength)
    {
        const bool repeat = true;
        this->time_spec = uhd::time_spec_t(0.0);    // play()はtime_specが0なら無視するので，デフォルト値を0にしておく

        forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
            std::cout << "tagid = " << tag << std::endl;
            if(tag == CommandTimeInfo::tag) {
                assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
                CommandTimeInfo info = *reinterpret_cast<CommandTimeInfo const*>(p);
                this->time_spec = uhd::time_spec_t(info.nsecs / 1000000000LL, (info.nsecs % 1000000000LL)/1e9);
                std::cout << "[uhd_rfnoc.cpp] Transmit streaming will be start at " << info.nsecs << "[nsecs]." << std::endl;
            }
        });

        for(uint32_t i = 0; i < this->num_channels; ++i) {
            this->replay_ctrl[i]->play(this->replay_buff_addr[i], this->replay_buff_size[i], this->replay_chan[i], time_spec, repeat);
            std::cout << "Started transmit on channel " << i << std::endl;
        }
    }


    void stopTransmit()
    {
        for(uint32_t i = 0; i < this->num_channels; ++i)
            this->replay_ctrl[i]->stop(this->replay_chan[i]);
    }


    void checkError()
    {
        for(uint32_t i = 0; i < this->num_channels; ++i){
            uhd::async_metadata_t async_md;
            bool has_md = this->replay_ctrl[i]->get_play_async_metadata(async_md, 0);

            // EVENT_CODE_OKとEVENT_CODE_BURST_ACK以外はエラーとみなす
            // EVENT_CODE_OKは4.7では未実装のため、とりあえずEVENT_CODE_BURST_ACKのみを成功とみなす
            if(has_md && !(/*async_md.event_code == uhd::async_metadata_t::event_code_t::EVENT_CODE_OK*/ false || async_md.event_code == uhd::async_metadata_t::event_code_t::EVENT_CODE_BURST_ACK)) {
                std::cout << "[uhd_rfnoc.cpp] Transmit error. uhd::async_metadata_t.event_code = " << async_md.event_code
                << ", description = ";
                // << async_md.to_pp_string()
                // << std::endl;

                // // to_pp_stringは4.7で未実装のため，自分でエラーコードを解釈して表示する
                // if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_BURST_ACK) {
                //     std::cout << "BURST_ACK(A burst was successfully transmitted.) ";
                // }
                if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_UNDERFLOW) {
                    std::cout << "UNDERFLOW(An internal send buffer has emptied.) ";
                }
                if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_SEQ_ERROR) {
                    std::cout << "SEQ_ERROR(Packet loss between host and device.) ";
                }
                if(async_md.event_code & uhd::async_metadata_t:: EVENT_CODE_TIME_ERROR) {
                    std::cout << "TIMEOUT(Packet had time that was late.) ";
                }
                if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_UNDERFLOW_IN_PACKET) {
                    std::cout << "UNDERFLOW_IN_PACKET(Underflow occurred inside a packet.) ";
                }
                if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_SEQ_ERROR_IN_BURST) {
                    std::cout << "SEQ_ERROR_IN_BURST(Packet loss within a burst.) ";
                }
                if(async_md.event_code & uhd::async_metadata_t::EVENT_CODE_USER_PAYLOAD) {
                    std::cout << "EVENT_CODE_USER_PAYLOAD(Some kind of custom user payload: ";
                    for (size_t i = 0; i < 4; ++i) {
                        std::cout << std::hex << static_cast<int>(async_md.user_payload[i]) << std::dec << ", ";
                    }
                    std::cout << ") ";
                }

                std::cout << std::endl;
            }
        }
    }
};


struct TxDefaultStreamer : Streamer
{
    std::string name;
    uhd::tx_streamer::sptr streamer;
    std::vector<std::complex<float> const*> buffptrs;
    int numChannel;
    ezsdr::StreamerElementType elementType;

    bool has_time_spec;
    uhd::time_spec_t time_spec;
    uhd::tx_metadata_t md;


    void beginBurstTransmit(uint8_t const* optArgs, uint64_t optArgsLength)
    {
        this->md.start_of_burst = true;
        this->md.end_of_burst = false;

        forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
            std::cout << "tagid = " << tag << std::endl;
            if(tag == CommandTimeInfo::tag) {
                assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
                CommandTimeInfo info = *reinterpret_cast<CommandTimeInfo const*>(p);
                this->md.has_time_spec = true;
                this->md.time_spec = uhd::time_spec_t(info.nsecs / 1000000000LL, (info.nsecs % 1000000000LL)/1e9);
                std::cout << "[uhd_rfnoc.cpp] Transmit streaming will be start at " << info.nsecs << "[nsecs]." << std::endl;
            }
        });
    }


    void endBurstTransmit()
    {
        this->md.has_time_spec = false;
        this->md.start_of_burst = false;
        this->md.end_of_burst = true;
        this->streamer->send(this->buffptrs, 0, this->md);
        this->md.end_of_burst = false;
    }


    uint64_t burstTransmit(void const* const* signals, uint64_t sample_size, uint64_t num_samples)
    {
        for(size_t i = 0; i < this->buffptrs.size(); ++i)
            this->buffptrs[i] = reinterpret_cast<std::complex<float> const*>(signals[i]);

        uint64_t num;
        if(this->md.has_time_spec) {
            // std::shared_lock<std::shared_mutex> lock(streamer->dev->timemtx);
            num = this->streamer->send(this->buffptrs, num_samples, this->md, 10.0);
        } else {
            num = this->streamer->send(this->buffptrs, num_samples, this->md, 10.0);
        }

        if(num > 0) {
            this->md.has_time_spec = false;
            this->md.start_of_burst = false;
        } else {
            std::cout << "[uhd_rfnoc.cpp] Cannot transmit from USRP" << std::endl;
        }
        return num;
    }
};


struct RxDefaultStreamer : Streamer
{
    std::string name;
    // Device* dev;
    uhd::rx_streamer::sptr streamer;
    std::vector<std::complex<float> const*> buffptrs;
    int numChannel;
    ezsdr::StreamerElementType elementType;

    uhd::rx_metadata_t md;

    void startContinuousReceive(uint8_t const* optArgs, uint64_t optArgsLength)
    {
        // setup streaming
        uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
        stream_cmd.num_samps  = 0;
        stream_cmd.stream_now = true;

        forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
            if(tag == CommandTimeInfo::tag) {
                assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
                CommandTimeInfo info = *reinterpret_cast<CommandTimeInfo const*>(p);
                stream_cmd.stream_now = false;
                stream_cmd.time_spec = uhd::time_spec_t(info.nsecs / 1000000000LL, (info.nsecs % 1000000000LL)/1e9);
                std::cout << "[uhd_rfnoc.cpp] Receive streaming will be start at " << info.nsecs << "[nsecs]." << std::endl;
            }
        });

        this->streamer->issue_stream_cmd(stream_cmd);
    }


    void stopContinuousReceive()
    {
        uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_STOP_CONTINUOUS);
        this->streamer->issue_stream_cmd(stream_cmd);

        // バッファーに溜まっている受信データを破棄する
        size_t numSamples = 128;
        std::vector<std::vector<std::complex<float>>> rembuf(this->numChannel);
        for(size_t i = 0; i < this->numChannel; ++i) {
            std::vector<std::complex<float>> v(numSamples);
            rembuf[i] = v;
        }

        size_t num = 0;
        do {
            num = this->streamer->recv(rembuf, numSamples, this->md, 0.1);
        } while(num != 0);
    }


    uint64_t continuousReceive(void** buffptr, uint64_t sizeofElement, uint64_t numSamples)
    {
        uhd::ref_vector<void*> buf(buffptr, this->numChannel);
        uint64_t num = this->streamer->recv(buf, numSamples, this->md, 0.1);

        if(this->md.error_code != uhd::rx_metadata_t::ERROR_CODE_NONE) {
            std::cout << "[uhd_rfnoc.cpp] Receive error: " << this->md.to_pp_string() << std::endl;
        }

        if(this->md.error_code == uhd::rx_metadata_t::ERROR_CODE_LATE_COMMAND) {
            std::cout << "[uhd_rfnoc.cpp] Restarting continuous receive due to late command..." << std::endl;
            uhd::stream_cmd_t stream_cmd(uhd::stream_cmd_t::STREAM_MODE_START_CONTINUOUS);
            stream_cmd.num_samps  = 0;
            stream_cmd.stream_now = true;
            this->streamer->issue_stream_cmd(stream_cmd);
        }

        return num;
    }
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

    AsyncTaskPool asyncTaskPool;
    std::shared_mutex timemtx;      // set_time_unknown_pps実行中に他の動作を抑制するためのmutex


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
        // std::cout << "Setting up RFNoC graph for Device: " << this->name << std::endl;

        auto graph = this->graph;
        auto conns = config.value("connections", std::vector<std::string>{});
        for(auto& conn_str: conns) {
            auto bap = parseConnection(conn_str);
            uhd::rfnoc::connect_through_blocks(graph, bap[0].id, bap[0].port, bap[1].id, bap[1].port);
            // std::cout << "\tConnected " << bap[0].id << ":" << bap[0].port << " => " << bap[1].id << ":" << bap[1].port << std::endl;
        }

        for(auto& e: config["tx-streamers"]) {
            std::string type = e.value("type", "default");
            auto bap_strs = e.value("connect_to", std::vector<std::string>{});
            std::vector<BlockAndPort> baps = {};
            for(auto& bap_str: bap_strs) {
                baps.push_back(parseBlockAndPort(bap_str));
            }

            auto srvfmt = e.value<std::string_view>("srvfmt", ezsdr::StreamerElementTypeString::ComplexFloat32);
            auto devfmt = e.value<std::string_view>("devfmt", ezsdr::StreamerElementTypeString::ComplexInt16);

            std::string srvfmt_uhd = ezsdr::convertTypeStringToUHD(srvfmt);
            std::string devfmt_uhd = ezsdr::convertTypeStringToUHD(devfmt);

            if(srvfmt_uhd == "") throw std::runtime_error(std::format("srvfmt = '{}' is invalid.", srvfmt));
            if(devfmt_uhd == "") throw std::runtime_error(std::format("devfmt = '{}' is invalid.", devfmt));

            uhd::device_addr_t streamer_args;
            uhd::stream_args_t stream_args(srvfmt_uhd, devfmt_uhd);

            stream_args.args = streamer_args;

            if(type == "default")
            {
                auto tx_streamer = graph->create_tx_streamer(baps.size(), stream_args);

                auto tx_default_streamer = new TxDefaultStreamer{};
                tx_default_streamer->numChannel = baps.size();
                tx_default_streamer->streamer = tx_streamer;
                tx_default_streamer->elementType = ezsdr::convertStreamerElementType(srvfmt);
                tx_default_streamer->buffptrs.resize(baps.size());

                for(size_t i = 0; i < baps.size(); ++i) {
                    // 指定ブロックから伸びているstatic connectionをすべて接続する
                    auto edges = uhd::rfnoc::get_block_chain(graph, baps[i].id, baps[i].port, false);
                    for(auto& edge: edges) {
                        // SEPブロックはスキップする
                        if(uhd::rfnoc::block_id_t(edge.src_blockid).match("SEP") || uhd::rfnoc::block_id_t(edge.dst_blockid).match("SEP"))
                            continue;

                        graph->connect(edge.src_blockid, edge.src_port, edge.dst_blockid, edge.dst_port);
                    }

                    // 末尾に接続する．ただし，末尾がSEPなら，SEPの手前に接続する
                    auto last_edge = edges.back();
                    auto last_blockid = uhd::rfnoc::block_id_t(last_edge.dst_blockid);
                    auto last_port = last_edge.dst_port;
                    if(last_blockid.match("SEP")) {
                        last_blockid = uhd::rfnoc::block_id_t(last_edge.src_blockid);
                        last_port = last_edge.src_port;
                    }

                    graph->connect(tx_streamer, i, last_blockid, last_port);
                }

                this->tx_streamer_objects.push_back(tx_default_streamer);
            }
            else if(type == "replay")
            {
                auto tx_streamer = graph->create_tx_streamer(baps.size(), stream_args);

                auto tx_replay_streamer = new TxReplayStreamer{};
                tx_replay_streamer->num_channels = baps.size();
                tx_replay_streamer->streamer = tx_streamer;
                tx_replay_streamer->elementType = ezsdr::convertStreamerElementType(srvfmt);
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
            else
            {
                throw std::runtime_error(std::format("TX Streamer type '{}' is not supported for UHD_RFNoC.", type));
            }
        }

        for(auto& e: config["rx-streamers"]) {
            std::string type = e.value("type", "default");
            auto bap_strs = e.value("connect_from", std::vector<std::string>{});
            std::vector<BlockAndPort> baps = {};
            for(auto& bap_str: bap_strs) {
                baps.push_back(parseBlockAndPort(bap_str));
            }

            auto srvfmt = e.value<std::string_view>("srvfmt", ezsdr::StreamerElementTypeString::ComplexFloat32);
            auto devfmt = e.value<std::string_view>("devfmt", ezsdr::StreamerElementTypeString::ComplexInt16);

            std::string srvfmt_uhd = ezsdr::convertTypeStringToUHD(srvfmt);
            std::string devfmt_uhd = ezsdr::convertTypeStringToUHD(devfmt);

            if(srvfmt_uhd == "") throw std::runtime_error(std::format("srvfmt = '{}' is invalid.", srvfmt));
            if(devfmt_uhd == "") throw std::runtime_error(std::format("devfmt = '{}' is invalid.", devfmt));

            uhd::device_addr_t streamer_args;
            uhd::stream_args_t stream_args(srvfmt_uhd, devfmt_uhd);

            stream_args.args = streamer_args;

            if(type == "default")
            {
                auto rx_streamer = graph->create_rx_streamer(baps.size(), stream_args);

                auto rx_default_streamer = new RxDefaultStreamer{};
                rx_default_streamer->numChannel = baps.size();
                rx_default_streamer->streamer = rx_streamer;
                rx_default_streamer->elementType = ezsdr::convertStreamerElementType(srvfmt);
                rx_default_streamer->buffptrs.resize(baps.size());

                for(size_t i = 0; i < baps.size(); ++i) {
                    // 指定ブロックから伸びているstatic connectionをすべて接続する
                    auto edges = uhd::rfnoc::get_block_chain(graph, baps[i].id, baps[i].port, true);
                    for(auto& edge: edges) {
                        // SEPブロックはスキップする
                        if(uhd::rfnoc::block_id_t(edge.src_blockid).match("SEP") || uhd::rfnoc::block_id_t(edge.dst_blockid).match("SEP"))
                            continue;

                        graph->connect(edge.src_blockid, edge.src_port, edge.dst_blockid, edge.dst_port);
                    }

                    // 末尾に接続する．ただし，末尾がSEPなら，SEPの手前に接続する
                    auto last_edge = edges.back();
                    auto last_blockid = uhd::rfnoc::block_id_t(last_edge.dst_blockid);
                    auto last_port = last_edge.dst_port;
                    if(last_blockid.match("SEP")) {
                        last_blockid = uhd::rfnoc::block_id_t(last_edge.src_blockid);
                        last_port = last_edge.src_port;
                    }

                    graph->connect(last_blockid, last_port, rx_streamer, i);
                }

                this->rx_streamer_objects.push_back(rx_default_streamer);
            }
            else
            {
                throw std::runtime_error(std::format("RX Streamer type '{}' is not supported for UHD_RFNoC.", type));
            }
        }


        std::cout << "RFNoC graph setup completed for '" << this->name << "' (args=" << config["args"] << ")" << " as follows." << std::endl;
        auto edges = graph->enumerate_active_connections();
        for (auto& edge : edges) {
            std::cout << "\t* " << edge.src_blockid << ":" << edge.src_port << " => "
                      << edge.dst_blockid << ":" << edge.dst_port << std::endl;
        }
        std::cout << std::endl;
    }


    void setupRadios(nlohmann::json& config)
    {
        // Apply any radio arguments provided
        for(auto& radio_config: config["radios"]) {
            auto radio_block_id_port_list = radio_config.value("for", std::vector<std::string>{});
            auto tx_args = radio_config.value("tx-args", std::string{""});
            auto tx_freq = radio_config.value("tx-freq", double{-1});
            auto tx_rate = radio_config.value("tx-rate", double{-1});
            auto tx_gain = radio_config.value("tx-gain", double{-1});
            auto tx_ant = radio_config.value("tx-ant", std::string{""});
            auto tx_bw = radio_config.value("tx-bw", double{-1});
            auto rx_args = radio_config.value("rx-args", std::string{""});
            auto rx_freq = radio_config.value("rx-freq", double{-1});
            auto rx_rate = radio_config.value("rx-rate", double{-1});
            auto rx_gain = radio_config.value("rx-gain", double{-1});
            auto rx_ant = radio_config.value("rx-ant", std::string{""});
            auto rx_bw = radio_config.value("rx-bw", double{-1});

            // auto radio_ctrl = this->graph->get_block<uhd::rfnoc::radio_control>(radio_block_id);

            for(auto& radio_block_id_port: radio_block_id_port_list) {
                std::cout << "Configuring " << radio_block_id_port << " of '" << this->name << "' (args=" << config["args"] << ")" << std::endl;
                auto bap = parseBlockAndPort(radio_block_id_port);
                auto radio_ctrl = this->graph->get_block<uhd::rfnoc::radio_control>(bap.id);
                if (!radio_ctrl) {
                    std::cerr << "Radio block " << bap.id << " not found in the RFNoC graph." << std::endl;
                    return;
                }

                if(tx_freq < 0 && rx_freq < 0) {
                    std::cerr << "Please specify the center frequency for " << bap.id << ":" << bap.port << std::endl;
                    return;
                }

                if(tx_freq >= 0) {
                    if(tx_args.size() > 0){
                        radio_ctrl->set_tx_tune_args(tx_args, bap.port);
                        std::cout << "\t* TX Tune Args: " << tx_args << std::endl;
                    }

                    // 中心周波数の設定
                    std::cout << std::fixed;
                    radio_ctrl->set_tx_frequency(tx_freq, bap.port);
                    std::cout << "\t* TX Freq: " << (radio_ctrl->get_tx_frequency(bap.port) / 1e6) << " MHz"
                            << " (Requested: " << (tx_freq / 1e6) << " MHz)"
                            << std::endl;
                    std::cout << std::resetiosflags(std::ios::fixed);

                    // サンプルレートの設定
                    if(tx_rate >= 0) {
                        auto duc_id = find_block(this->graph, bap.id, bap.port, "DUC");
                        uhd::rfnoc::duc_block_control::sptr duc_ctrl;
                        double actual_rate;

                        if(duc_id) {
                            duc_ctrl = this->graph->get_block<uhd::rfnoc::duc_block_control>(*duc_id);
                            duc_ctrl->set_input_rate(tx_rate, bap.port);
                            actual_rate = duc_ctrl->get_input_rate(bap.port);
                        } else {
                            actual_rate = radio_ctrl->set_rate(tx_rate);
                        }

                        std::cout << std::fixed;
                        std::cout << "\t* TX Rate: ";
                        std::cout << (actual_rate / 1e6) << " Msps"
                                << " (Requested: " << (tx_rate / 1e6) << " Msps)"
                                << std::endl;

                        if(duc_id) {
                            std::cout << "\t* DUC Interp: " << duc_ctrl->get_property<int>("interp", bap.port) << std::endl;
                        }

                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the RF gain
                    if (tx_gain >= 0) {
                        radio_ctrl->set_tx_gain(tx_gain, bap.port);

                        std::cout << std::fixed;
                        std::cout << "\t* TX Gain: "
                                << radio_ctrl->get_tx_gain(bap.port) << " dB"
                                << " (Requested: " << tx_gain << " dB)"
                                << std::endl;
                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the analog front-end filter bandwidth
                    if (tx_bw >= 0) {
                        radio_ctrl->set_tx_bandwidth(tx_bw, bap.port);

                        std::cout << std::fixed;
                        std::cout << "\t* TX Bandwidth: "
                                    << (radio_ctrl->get_tx_bandwidth(bap.port) / 1e6) << " MHz"
                                    << " (Requested: " << (tx_bw / 1e6) << " MHz)"
                                    << std::endl;
                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the antenna
                    if (tx_ant.size() > 0) {
                        radio_ctrl->set_tx_antenna(tx_ant, bap.port);

                        std::cout << "\t* TX Antenna: "
                                << radio_ctrl->get_tx_antenna(bap.port)
                                << " (Requested: " << tx_ant << ")"
                                << std::endl;
                    }
                }


                if(rx_freq >= 0) {
                    if(rx_args.size() > 0){
                        radio_ctrl->set_rx_tune_args(rx_args, bap.port);
                        std::cout << "\t* RX Tune Args: " << rx_args << std::endl;
                    }

                    // 中心周波数の設定
                    std::cout << std::fixed;
                    radio_ctrl->set_rx_frequency(rx_freq, bap.port);
                    std::cout << "\t* RX Freq: " << (radio_ctrl->get_rx_frequency(bap.port) / 1e6) << " MHz"
                            << " (Requested: " << (rx_freq / 1e6) << " MHz)"
                            << std::endl;
                    std::cout << std::resetiosflags(std::ios::fixed);

                    // サンプルレートの設定
                    if(rx_rate >= 0) {
                        auto ddc_id = find_block(this->graph, bap.id, bap.port, "DDC");
                        uhd::rfnoc::ddc_block_control::sptr ddc_ctrl;
                        double actual_rate;

                        if(ddc_id) {
                            ddc_ctrl = this->graph->get_block<uhd::rfnoc::ddc_block_control>(*ddc_id);
                            ddc_ctrl->set_output_rate(rx_rate, bap.port);
                            actual_rate = ddc_ctrl->get_output_rate(bap.port);
                        } else {
                            actual_rate = radio_ctrl->set_rate(rx_rate);
                        }

                        std::cout << std::fixed;
                        std::cout << "\t* RX Rate: ";
                        std::cout << (actual_rate / 1e6) << " Msps"
                                << " (Requested: " << (rx_rate / 1e6) << " Msps)"
                                << std::endl;

                        if(ddc_id) {
                            std::cout << "\t* DDC Decim: " << ddc_ctrl->get_property<int>("decim", bap.port) << std::endl;
                        }

                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the RF gain
                    if (rx_gain >= 0) {
                        radio_ctrl->set_rx_gain(rx_gain, bap.port);

                        std::cout << std::fixed;
                        std::cout << "\t* RX Gain: "
                                << radio_ctrl->get_rx_gain(bap.port) << " dB"
                                << " (Requested: " << rx_gain << " dB)"
                                << std::endl;
                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the analog front-end filter bandwidth
                    if (rx_bw >= 0) {
                        radio_ctrl->set_rx_bandwidth(rx_bw, bap.port);

                        std::cout << std::fixed;
                        std::cout << "\t* RX Bandwidth: "
                                    << (radio_ctrl->get_rx_bandwidth(bap.port) / 1e6) << " MHz"
                                    << " (Requested: " << (rx_bw / 1e6) << " MHz)"
                                    << std::endl;
                        std::cout << std::resetiosflags(std::ios::fixed);
                    }

                    // Set the antenna
                    if (rx_ant.size() > 0) {
                        radio_ctrl->set_rx_antenna(rx_ant, bap.port);

                        std::cout << "\t* RX Antenna: "
                                << radio_ctrl->get_rx_antenna(bap.port)
                                << " (Requested: " << rx_ant << ")"
                                << std::endl;
                    }
                }

                std::cout << std::endl;
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


struct TxDefaultStreamerHandler
{
    TxDefaultStreamer* streamer;
};


struct RxDefaultStreamerHandler
{
    RxDefaultStreamer* streamer;
};


DeviceHandler setupDevice(
    char const* name,
    char const* configJSON
)
{
    nlohmann::json config = nlohmann::json::parse(configJSON);

    std::string args = config.value("args", "");
    std::vector<std::string> clockref = config.value("clockref", std::vector<std::string>{});
    std::vector<std::string> timeref = config.value("timeref", std::vector<std::string>{});

    Device* dev = new Device;
    dev->name = name;
    dev->config = config;
    dev->args = args;
    dev->clockref = clockref;
    dev->timeref = timeref;

    std::cout << "Creating the RFNoC graph with args: " << args << "..." << std::endl;
    auto graph = uhd::rfnoc::rfnoc_graph::make(args);
    dev->graph = graph;
    dev->setupGraph(config);
    dev->graph->commit();

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


TxDefaultStreamerHandler getTxDefaultStreamer(char const* name, DeviceHandler handler, uint32_t index)
{
    Device* dev = handler.dev;

    TxDefaultStreamerHandler tx_handler;
    tx_handler.streamer = dynamic_cast<TxDefaultStreamer*>(dev->tx_streamer_objects[index]);

    return tx_handler;
}


RxDefaultStreamerHandler getRxDefaultStreamer(char const* name, DeviceHandler handler, uint32_t index)
{
    Device* dev = handler.dev;

    RxDefaultStreamerHandler rx_handler;
    rx_handler.streamer = dynamic_cast<RxDefaultStreamer*>(dev->rx_streamer_objects[index]);

    return rx_handler;
}


void destroyDevice(DeviceHandler& handler)
{
    Device* dev = handler.dev;

    for(auto& streamer: dev->tx_streamer_objects) {
        // TxReplayStreamerだったらstopTransmitを呼ぶ
        auto tx_replay_streamer = dynamic_cast<TxReplayStreamer*>(streamer);
        if(tx_replay_streamer) {
            tx_replay_streamer->stopTransmit();
        }
    }

    delete dev;
    handler.dev = nullptr;
}


void setParam(DeviceHandler handler, char const* key_, uint64_t keylen, char const* value, uint64_t valuelen, uint8_t const* info, uint64_t infolen)
{
    Device* dev = handler.dev;
    std::string_view key(key_, keylen);
    std::string_view jsonstr(value, valuelen);
    nlohmann::json val = nlohmann::json::parse(jsonstr);

    if(key == "set_time_unknown_pps_to_zero") {
        std::cout << "[uhd_rfnoc.cpp] set_time_unknown_pps_to_zero" << std::endl;
        dev->asyncTaskPool.removeDone();
        dev->asyncTaskPool.enqueue([dev](){
            std::cout << "[uhd_rfnoc.cpp] start set_time_unknown_pps_to_zero" << std::endl;
            std::lock_guard<std::shared_mutex> lock(dev->timemtx);
            // setTimeNextPPS(handler, 0, 0.0);

            for (size_t i = 0; i < dev->graph->get_num_mboards(); ++i) {
                dev->graph->get_mb_controller(i)->get_timekeeper(0)->set_time_next_pps(uhd::time_spec_t(0, 0.0));
            }

            std::cout << "[uhd_rfnoc.cpp] end set_time_unknown_pps_to_zero" << std::endl;
        });
    }

    if(key == "wait_set_time_unknown_pps") {
        std::cout << "[uhd_rfnoc.cpp] wait_set_time_unknown_pps" << std::endl;
        std::shared_lock<std::shared_mutex> lock(dev->timemtx);
        dev->asyncTaskPool.removeDone();
        std::cout << "[uhd_rfnoc.cpp] end wait_set_time_unknown_pps" << std::endl;
    }
}


ezsdr::String getParam(DeviceHandler handler, char const* key_, ulong keylen, uint8_t const* info, ulong infolen)
{
    Device* dev = handler.dev;
    std::string_view key(key_, keylen);
    nlohmann::json value;

    if(key == "wait_set_time_unknown_pps") {
        std::cout << "[uhd_rfnoc.cpp] wait_set_time_unknown_pps" << std::endl;
        std::shared_lock<std::shared_mutex> lock(dev->timemtx);
        dev->asyncTaskPool.removeDone();
        std::cout << "[uhd_rfnoc.cpp] end wait_set_time_unknown_pps" << std::endl;
    }

    return ezsdr::createString(value.dump());
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


uint64_t setTransmitSignal(TxReplayStreamerHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    return handler.streamer->setTransmitSignal(signals, sample_size, num_samples);
}


void startTransmit(TxReplayStreamerHandler handler, uint8_t const* optArgs, uint64_t optArgsLength)
{
    handler.streamer->startTransmit(optArgs, optArgsLength);
}

void stopTransmit(TxReplayStreamerHandler handler)
{
    handler.streamer->stopTransmit();
}


void checkTransmitError(TxReplayStreamerHandler handler)
{
    handler.streamer->checkError();
}


uint getNumChannels(TxReplayStreamerHandler handler)
{
    return handler.streamer->num_channels;
}


void beginBurstTransmit(TxDefaultStreamerHandler handler, uint8_t const* optArgs, uint64_t optArgsLength)
{
    handler.streamer->beginBurstTransmit(optArgs, optArgsLength);
}


void endBurstTransmit(TxDefaultStreamerHandler handler)
{
    handler.streamer->endBurstTransmit();
}


uint64_t burstTransmit(TxDefaultStreamerHandler handler, void const* const* signals, uint64_t sample_size, uint64_t num_samples)
{
    return handler.streamer->burstTransmit(signals, sample_size, num_samples);
}


uint getNumChannels(TxDefaultStreamerHandler handler)
{
    return handler.streamer->numChannel;
}


void startContinuousReceive(RxDefaultStreamerHandler handler, uint8_t const* optArgs, uint64_t optArgsLength)
{
    handler.streamer->startContinuousReceive(optArgs, optArgsLength);
}


void stopContinuousReceive(RxDefaultStreamerHandler handler)
{
    handler.streamer->stopContinuousReceive();
}


uint64_t continuousReceive(RxDefaultStreamerHandler handler, void** buffptr, uint64_t sizeofElement, uint64_t numSamples)
{
    return handler.streamer->continuousReceive(buffptr, sizeofElement, numSamples);
}


uint getNumChannels(RxDefaultStreamerHandler handler)
{
    return handler.streamer->numChannel;
}


}