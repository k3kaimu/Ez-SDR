#include <optional>
#include <cassert>


template <typename Fn>
void forEachOptArg(uint8_t const* bin, uint64_t len, const Fn& fn)
{
    while(len >= (8 + 4)) {
        uint64_t size = *reinterpret_cast<uint64_t const*>(bin);
        uint32_t tag = *reinterpret_cast<uint32_t const*>(bin + 8);
        if(len >= 12 + size) {
            fn(tag, bin + 12, size);
            bin = bin + 12 + size;
            len -= 12 + size;
        } else {
            len = 0;
        }
    }
}


#pragma pack(push,1)
struct  CommandTimeInfo
{
    static const uint32_t tag = 0x16C002AF;
    uint64_t nsecs;
};
#pragma pack(pop)


#pragma pack(push,1)
struct USRPStreamerChannelInfo
{
    static const uint32_t tag = 0x78640439;
    uint32_t index;
};
#pragma pack(pop)


struct OptArgsParsedResult
{
    std::vector<CommandTimeInfo> optCommandTimeInfo;
    std::vector<USRPStreamerChannelInfo> optUSRPStreamerChannelInfo;
};


OptArgsParsedResult parseAdditionalInfo(uint8_t const* optArgs, uint64_t optArgsLength)
{
    OptArgsParsedResult dst{};

    forEachOptArg(optArgs, optArgsLength, [&](uint32_t tag, uint8_t const* p, uint64_t plen){
        if(tag == CommandTimeInfo::tag) {
            assert(plen == 8 && sizeof(CommandTimeInfo) == 8);
            dst.optCommandTimeInfo.push_back(*reinterpret_cast<CommandTimeInfo const*>(p));
        } else if(tag == USRPStreamerChannelInfo::tag) {
            assert(plen == 4 && sizeof(USRPStreamerChannelInfo) ==  4);
            dst.optUSRPStreamerChannelInfo.push_back(*reinterpret_cast<USRPStreamerChannelInfo const*>(p));
        } else {
            assert(0);
        }
    });

    return dst;
}