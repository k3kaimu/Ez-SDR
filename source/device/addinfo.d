module device.addinfo;

import std.range;
import std.digest.crc;


enum bool isAdditionalInfo(T) = is(typeof(delegate(T t){
    immutable ubyte[4] tag = T.tag;
    size_t n = t.numBytes;
    t.writeTo(delegate(scope const(ubyte)[] bin){});
}));


void appendInfo(W, I)(ref W writer, I info)
{
    ulong[1] size = [info.numBytes];
    .put(writer, cast(ubyte[])size[]);
    .put(writer, I.tag[]);
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
        static immutable(ubyte[4]) tag = [1, 2, 3, 4];
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
        immutable ulong size = (cast(ulong[])binInfo[0 .. 8])[0];
        immutable ubyte[4] tag = (cast(ubyte[4][])binInfo[8 .. 12])[0];
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
    static immutable ubyte[4] tag = crc32Of("CommandTimeInfo");
    ulong nsec;

    mixin PODAdditionalInfoWriter!();
}

unittest
{
    static assert(CommandTimeInfo.tag.toHexString == "AF02C016");
}


struct USRPStreamerChannelInfo
{
    static immutable ubyte[4] tag = crc32Of("USRPStreamerChannelInfo");
    uint index;

    mixin PODAdditionalInfoWriter!();
}

unittest
{
    static assert(USRPStreamerChannelInfo.tag.toHexString == "39046478");
}
