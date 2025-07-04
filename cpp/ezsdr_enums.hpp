#pragma once
#include <string_view>
#include <string>
#include <inttypes.h>

namespace ezsdr
{

enum class StreamerElementType : uint8_t
{
    isComplex = 0b10000000,
    isFloat   = 0b01000000,     // (a & isFloat) == 0 => isInt
    isComplexFloat = isComplex | isFloat,
    isComplexInt = isComplex,
    isRealFloat = isFloat,
    isRealInt = 0b00000000,
    ComplexFloat32 = isComplexFloat | 1,
    ComplexFloat64 = isComplexFloat | 2,
    ComplexInt8    = isComplexInt | 1,
    ComplexInt16   = isComplexInt | 2,
};


struct StreamerElementTypeString
{
    static constexpr auto ComplexFloat32 = "ComplexFloat32";
    static constexpr auto ComplexFloat64 = "ComplexFloat64";
    static constexpr auto ComplexInt8    = "ComplexInt8";
    static constexpr auto ComplexInt16   = "ComplexInt16";
};


StreamerElementType convertStreamerElementType(std::string_view const& type)
{
    if(type == StreamerElementTypeString::ComplexFloat32) {
        return StreamerElementType::ComplexFloat32;
    } else if(type == StreamerElementTypeString::ComplexFloat64) {
        return StreamerElementType::ComplexFloat64;
    } else if(type == StreamerElementTypeString::ComplexInt8) {
        return StreamerElementType::ComplexInt8;
    } else if(type == StreamerElementTypeString::ComplexInt16) {
        return StreamerElementType::ComplexInt16;
    } else {
        throw std::runtime_error("Invalid streamer element type.");
    }
}


}

