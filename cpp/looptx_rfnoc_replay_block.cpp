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



namespace looptx_rfnoc_replay_block
{


struct Device
{
    nlohmann::json config;
    uhd::rfnoc::rfnoc_graph::sptr graph;
    uhd::tx_streamer::sptr streamer;
};


struct DeviceHandler;


DeviceHandler* setupDevice(
    char const* configJSON,
    char const* cpu_format,
    char const* wire_format
)
{
    nlohmann::json config = nlohmann::json::parse(configJSON);

    std::string args = config.value("args", "");
    std::string tx_args = config.value("tx_args", "");
    uint32_t radio_id = config.value("radio_id", 0);
    uint32_t radio_chan = config.value("radio_chan", 0);
    uint32_t replay_id = config.value("replay_id", 0);
    uint32_t replay_chan = config.value("replay_chan", 0);
    double freq = config.value("freq", -1.0);
    double rate = config.value("rate", -1.0);
    double gain = config.value("gain", -1.0);
    std::string ant = config.value("ant", "");
    double bw = config.value("bw", -1.0);
    std::string clockref = config.value("clockref", "");
    std::string timeref = config.value("timeref", "");

    Device* dev = new Device;
    dev->config = config;

    std::cout << "Creating the RFNoC graph with args: " << args << "..." << std::endl;
    auto graph = uhd::rfnoc::rfnoc_graph::make(args);
    dev->graph = graph;

    // Create handle for radio object
    uhd::rfnoc::block_id_t radio_ctrl_id(0, "Radio", radio_id);
    auto radio_ctrl = graph->get_block<uhd::rfnoc::radio_control>(radio_ctrl_id);

    // Check if the replay block exists on this device
    uhd::rfnoc::block_id_t replay_ctrl_id(0, "Replay", replay_id);
    if (!graph->has_block(replay_ctrl_id)) {
        std::cout << "Unable to find block \"" << replay_ctrl_id << "\"" << std::endl;
        return nullptr;
    }
    auto replay_ctrl = graph->get_block<uhd::rfnoc::replay_block_control>(replay_ctrl_id);

    // Connect replay to radio
    auto edges = uhd::rfnoc::connect_through_blocks(graph, replay_ctrl_id, replay_chan, radio_ctrl_id, radio_chan);

    // Check for a DUC connected to the radio
    uhd::rfnoc::duc_block_control::sptr duc_ctrl;
    size_t duc_chan = 0;
    for (auto& edge : edges) {
        auto blockid = uhd::rfnoc::block_id_t(edge.dst_blockid);
        if (blockid.match("DUC")) {
            duc_ctrl = graph->get_block<uhd::rfnoc::duc_block_control>(blockid);
            duc_chan = edge.dst_port;
            break;
        }
    }

    // Report blocks
    std::cout << "Using Radio Block:  " << radio_ctrl_id << ", channel " << radio_chan
              << std::endl;
    std::cout << "Using Replay Block: " << replay_ctrl_id << ", channel " << replay_chan
              << std::endl;
    if (duc_ctrl) {
        std::cout << "Using DUC Block:    " << duc_ctrl->get_block_id() << ", channel "
                  << duc_chan << std::endl;
    }


    /************************************************************************
     * Set up streamer to Replay block and commit graph
     ***********************************************************************/
    uhd::device_addr_t streamer_args;
    uhd::stream_args_t stream_args(cpu_format, wire_format);
    uhd::tx_streamer::sptr tx_stream;
    uhd::tx_metadata_t tx_md;

    stream_args.args = streamer_args;
    tx_stream        = graph->create_tx_streamer(1, stream_args);
    graph->connect(tx_stream, 0, replay_ctrl->get_block_id(), replay_chan);
    graph->commit();
    dev->streamer = tx_stream;

    /************************************************************************
     * Set up radio
     ***********************************************************************/
    // Set clock reference
    if (clockref.size() > 0) {
        // Lock mboard clocks
        for (size_t i = 0; i < graph->get_num_mboards(); ++i) {
            graph->get_mb_controller(i)->set_clock_source(clockref);
        }
    }


    if(timeref.size() > 0) {
        // set time source
        for (size_t i = 0; i < graph->get_num_mboards(); ++i) {
            graph->get_mb_controller(i)->set_time_source(timeref);
        }
    }

    // Apply any radio arguments provided
    if (tx_args.size() > 0) {
        radio_ctrl->set_tx_tune_args(tx_args, radio_chan);
    }

    // Set the center frequency
    if (freq < 0) {
        std::cerr << "Please specify the center frequency with 'freq'" << std::endl;
        return nullptr;
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

    return reinterpret_cast<DeviceHandler*>(dev);
}


void destroyDevice(DeviceHandler*& handler)
{
    Device* dev = reinterpret_cast<Device*>(handler);
    delete dev;
    handler = nullptr;
}



void test1()
{
    DeviceHandler* dst = setupDevice("{                      \
            \"args\": \"addr0=192.168.10.34\",              \
            \"timesync\": true,                             \
            \"timeref\": \"external\",                      \
            \"clockref\": \"external\",                     \
            \"rate\": 10e6,                                 \
            \"freq\": 2.4e9,                                \
            \"gain\": 30,                                   \
            \"channels\": \"0\",                            \
            \"subdev\": \"A:0\",                            \
            \"ant\": \"TX/RX\"                              \
        }",
            "fc32", "sc16");
    
    destroyDevice(dst);
}


}


// int main()
// {
//     looptx_rfnoc_replay_block::test1();
//     return 0;
// }