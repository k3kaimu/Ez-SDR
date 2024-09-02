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


enum bool isOptArg(T) = is(typeof(delegate(T t){
    immutable uint tag = T.tag;
    size_t n = t.numBytes;
    t.writeTo(delegate(scope const(ubyte)[] bin){});
}));


void putOptArg(W, T)(ref W writer, T optArg)
{
    ulong[1] size = [optArg.numBytes];
    .put(writer, cast(ubyte[])size[]);

    uint[1] tag = [T.tag];
    .put(writer, cast(ubyte[])tag[]);
    optArg.writeTo(writer);
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
    
    static assert(isOptArg!TestInfo);

    TestInfo info1;
    app.putOptArg(info1);
    assert(a.length == 8 + 4 + 2);
    assert(a == [2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 0xff, 0xff]);
}


void forEachOptArg(Fn)(scope const(ubyte)[] binOptArgs, Fn fn)
{
    while(binOptArgs.length >= (8 + 4)) {
        immutable ulong size = (cast(const(ulong)[])binOptArgs[0 .. 8])[0];
        immutable uint tag = (cast(const(uint)[])binOptArgs[8 .. 12])[0];
        fn(tag, binOptArgs[12 .. 12 + size]);
        binOptArgs = binOptArgs[12 + size  .. $];
    }
}


mixin template PODOptArgWriter()
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

    mixin PODOptArgWriter!();
}

unittest
{
    static assert(CommandTimeInfo.tag == 0x16C002AF);
}


struct USRPStreamerChannelInfo
{
    static immutable uint tag = crc32Of("USRPStreamerChannelInfo").toInteger;
    uint index;

    mixin PODOptArgWriter!();
}

unittest
{
    static assert(USRPStreamerChannelInfo.tag == 0x78640439);
}
