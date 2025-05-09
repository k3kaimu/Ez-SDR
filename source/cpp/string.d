module cpp.string;

extern(C++, "ezsdr") nothrow @nogc
{

    struct String { void* _payload; }

    String createString(const(char)* str, ulong len);
    void destroyString(String str);
    ulong getStringLength(String str);
    char* getStringData(String str);

}


char[] toSlice(String str) nothrow @nogc
{
    auto len = getStringLength(str);
    auto ptr = getStringData(str);
    return ptr[0 .. len];
}
