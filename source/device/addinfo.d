module device.addinfo;

import std.range;
import std.digest.crc;


private
auto toInteger(size_t N)(ubyte[N] bin)
if(N == 1 || N == 2 || N == 4 || N == 8)
{
    static if(N == 1)
    {
        return bin[0];
    }
    else static if(N == 2)
    {
        return ((cast(ushort) bin[1]) << 8) + bin[0];
    }
    else static if(N == 4)
    {
        return ((cast(uint) bin[3]) << 24) + ((cast(uint) bin[2]) << 16) + ((cast(uint) bin[1]) << 8) + bin[0];
    }
    else static if(N == 8)
    {
        return ((cast(ulong) bin[7]) << 56) + ((cast(ulong) bin[6]) << 48) + ((cast(ulong) bin[5]) << 40) + ((cast(ulong) bin[4]) << 32);
            +  ((cast(ulong) bin[3]) << 24) + ((cast(ulong) bin[2]) << 16) + ((cast(ulong) bin[1]) <<  8) + bin[0];
    }
    else static assert(0);
}


enum bool isAdditionalInfo(T) = is(typeof(delegate(T t){
    immutable uint tag = T.tag;
    size_t n = t.numBytes;
    t.writeTo(delegate(scope const(ubyte)[] bin){});
}));


void appendInfo(W, I)(ref W writer, I info)
{
    ulong[1] size = [info.numBytes];
    .put(writer, cast(ubyte[])size[]);

    uint[1] tag = [I.tag];
    .put(writer, cast(ubyte[])tag[]);
    info.writeTo(writer);
}

unittest
{
    import std.range;
    import std.array;
    ubyte[] a;
    auto app = appender(&a);

    static struct TestInfo
    {
        static immutable uint tag = toInteger!4([1, 2, 3, 4]);
        size_t numBytes() { return 2; }
        void writeTo(W)(ref W writer)
        {
            ubyte[2] data = [0xff, 0xff];
            .put(writer, data[]);
        }
    }
    
    static assert(isAdditionalInfo!TestInfo);

    TestInfo info1;
    app.appendInfo(info1);
    assert(a.length == 8 + 4 + 2);
    assert(a == [2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0xff, 0xff]);
}


void forEachInfo(Fn)(scope const(ubyte)[] binInfo, Fn fn)
{
    while(binInfo.length >= (8 + 4)) {
        immutable ulong size = (cast(const(ulong)[])binInfo[0 .. 8])[0];
        immutable uint tag = (cast(const(uint)[])binInfo[8 .. 12])[0];
        fn(tag, binInfo[12 .. 12 + size]);
        binInfo = binInfo[12 + size  .. $];
    }
}


mixin template PODAdditionalInfoWriter()
{
    void writeTo(W)(ref W writer)
    {
        foreach(field; this.tupleof) {
            ubyte[typeof(field).sizeof] bin;
            *(cast(typeof(field)*)bin.ptr) = field;
            .put(writer, bin[]);
        }
    }
}


struct CommandTimeInfo
{
    static immutable uint tag = crc32Of("CommandTimeInfo").toInteger;
    ulong nsec;

    mixin PODAdditionalInfoWriter!();
}

unittest
{
    static assert(CommandTimeInfo.tag == 0x16C002AF);
}


struct USRPStreamerChannelInfo
{
    static immutable uint tag = crc32Of("USRPStreamerChannelInfo").toInteger;
    uint index;

    mixin PODAdditionalInfoWriter!();
}

unittest
{
    static assert(USRPStreamerChannelInfo.tag == 0x78640439);
}
