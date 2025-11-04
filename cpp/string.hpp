#pragma once

namespace ezsdr
{

struct String
{
    std::string* _str;
};


String createString(std::string_view str)
{
    String dst;
    dst._str = new std::string(str);
    return dst;
}


String createString(char const* str, uint64_t len)
{
    String dst;
    dst._str = new std::string(str, len);
    return dst;
}


void destroyString(String str)
{
    if(str._str == nullptr)
        return;

    delete str._str;
    str._str = nullptr;
}


uint64_t getStringLength(String str)
{
    if(str._str == nullptr)
        return 0;

    return str._str->length();
}

char* getStringData(String str)
{
    if(str._str == nullptr)
        return nullptr;

    return str._str->data();
}

}