module tcp_iface;

import core.thread;
import core.atomic;

import std.algorithm;
import std.socket;
import std.traits;
import std.experimental.allocator;
import std.stdio;
import std.typecons;
import std.complex;
import std.exception;
import std.sumtype;

import utils;
import msgqueue;
import controller;
import dispatcher;


class RestartWithConfigData : Exception
{
    string configJSON;

    this(string json, string file = __FILE__, ulong line = cast(ulong)__LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(json, file, line, nextInChain);
        this.configJSON = json;
    }
}


struct MessageBuilder
{
    enum ASYNC_ID = 0xFFFF_FFFF_FFFF_FFFF;

    UniqueArray!char _src;
    UniqueArray!char _dst;
    ulong id;
    UniqueArray!ubyte _payload;

    this(scope string src, scope string dst, ulong id, scope const(ubyte)[] msg = null)
    {
        _src = UniqueArray!char(src);
        _dst = UniqueArray!char(dst);
        this.id = id;

        if(msg !is null)
            _payload = UniqueArray!ubyte(msg);
    }

    const(char)[] src() const { return _src.array; }
    const(char)[] dst() const { return _dst.array; }
    const(ubyte)[] payload() const { return _payload.array; }


    void writeTo(scope void delegate(scope const(ubyte)[]) writer)
    {
        rawWriteValue!ulong(writer, this.src.length);
        writer((cast(ubyte*)this.src.ptr)[0 .. this.src.length]);

        rawWriteValue!ulong(writer, this.dst.length);
        writer((cast(ubyte*)this.dst.ptr)[0 .. this.dst.length]);

        rawWriteValue!ulong(writer, this.id);

        rawWriteValue!ulong(writer, this.payload.length);
        writer(this.payload);
    }


    static
    MessageBuilder readFrom(scope void delegate(scope ubyte[]) reader)
    {
        MessageBuilder ret;
        size_t srclen = rawReadValue!ulong(reader);
        ret._src = UniqueArray!char(srclen);
        reader(cast(ubyte[]) ret._src.array);

        size_t dstlen = rawReadValue!ulong(reader);
        ret._dst = UniqueArray!char(dstlen);
        reader(cast(ubyte[]) ret._dst.array);

        ret.id = rawReadValue!ulong(reader);

        size_t msglen = rawReadValue!ulong(reader);
        ret._payload = UniqueArray!ubyte(msglen);
        reader(ret._payload.array);

        return ret;
    }
    

    void put(scope const(ubyte)[] msg)
    {
        _payload.resize(_payload.length + msg.length);
        _payload.array[$ - msg.length .. $] = msg[];
    }

    
    MessageBuilder makeReply(string src = null, string dst = null) const
    {
        MessageBuilder ret;
        ret._src = src is null ? this._dst.dup : UniqueArray!char(src);
        ret._dst = dst is null ? this._src.dup : UniqueArray!char(dst);
        ret.id = this.id;
        return ret;
    }


    static
    MessageBuilder makeAsyncMessage(scope string src, scope string dst)
    {
        return MessageBuilder(src, dst, ASYNC_ID, null);
    }
}

unittest
{
    MessageBuilder builder = MessageBuilder("SRC", "DST", 3);
    assert(builder.src == "SRC");
    assert(builder.dst == "DST");
    assert(builder.id == 3);
    assert(builder.payload.length == 0);

    auto reply1 = builder.makeReply();
    assert(reply1.src == "DST");
    assert(reply1.dst == "SRC");
    assert(reply1.id == 3);

    auto reply2 = builder.makeReply("newSrc");
    assert(reply2.src == "newSrc");
    assert(reply2.dst == "SRC");
    assert(reply2.id == 3);

    auto reply3 = builder.makeReply(null, "newDst");
    assert(reply3.src == "DST");
    assert(reply3.dst == "newDst");
    assert(reply3.id == 3);
}

unittest
{
    MessageBuilder builder = MessageBuilder("src", "dst", 3);
    builder.put(cast(ubyte[])[1, 2, 3]);
    assert(builder.payload == cast(ubyte[])[1, 2, 3]);

    builder.put(cast(ubyte[])[4, 5, 6]);
    assert(builder.payload == cast(ubyte[])[1, 2, 3, 4, 5, 6]);

    ubyte[] msg;
    builder.writeTo((scope const(ubyte)[] arr){ msg ~= arr; });

    import utils;
    BinaryReader reader = BinaryReader(msg);
    assert(reader.tryDeserializeArray!char.enforceIsNotNull.get == "src");
    assert(reader.tryDeserializeArray!char.enforceIsNotNull.get == "dst");
    assert(reader.tryDeserialize!ulong.enforceIsNotNull.get == 3);
    assert(reader.tryDeserializeArray!ubyte.enforceIsNotNull.get == cast(ubyte[])[1, 2, 3, 4, 5, 6]);

    MessageBuilder parsed = MessageBuilder.readFrom((scope ubyte[] arr){
        assert(arr.length <= msg.length);
        arr[0 .. $] = msg[0 .. arr.length];
        msg = msg[arr.length .. $];
    });
    assert(parsed.src == "src");
    assert(parsed.dst == "dst");
    assert(parsed.id == 3);
    assert(parsed.payload == cast(ubyte[])[1, 2, 3, 4, 5, 6]);
}


/**
TCPを監視して，イベントの処理をします
*/
void eventIOLoop(C, Alloc)(
    ref shared bool stop_signal_called,
    ushort port,
    ref Alloc alloc,
    MessageDispatcher dispatcher
)
{
    alias dbg = debugMsg!"eventIOLoop";

    size_t tryCount = 0;
    while(!stop_signal_called && tryCount < 10)
    {
        scope(exit) {
            ++tryCount;
            dbg.writefln!"retry... (%s)"(tryCount);
            Thread.sleep(10.seconds);
        }
        try {

            auto socket = new TcpSocket(AddressFamily.INET);
            scope(exit) {
                // socket.shutdown();
                socket.close();
                dbg.writefln("END eventIOLoop");
            }

            socket.bind(new InternetAddress("127.0.0.1", port));
            socket.listen(10);
            dbg.writefln("START EVENT LOOP");

            alias C = Complex!float;

            Lconnect: while(!stop_signal_called) {
                try {
                    Disposer.instance.tryDisposeAll();
                    writeln("PLEASE COMMAND");

                    auto client = socket.accept();
                    writeln("CONNECTED");

                    while(!stop_signal_called && client.isAlive) {
                        auto taglen = client.rawReadValue!ushort();
                        if(taglen.isNull || taglen == 0) continue Lconnect;
                        dbg.writefln("taglen = %s", taglen.get);

                        char[] tag = cast(char[]) alloc.allocate(taglen.get);
                        scope(exit) alloc.deallocate(tag);
                        if(client.rawReadBuffer(tag) != taglen) continue Lconnect;
                        dbg.writefln("tag = %s", tag);

                        auto msglen = client.rawReadValue!ulong();
                        if(msglen.isNull) continue Lconnect;
                        dbg.writefln("msglen = %s", msglen.get);

                        ubyte[] msgbuf = cast(ubyte[])alloc.allocate(msglen.get);
                        scope(exit) alloc.deallocate(msgbuf);
                        if(client.rawReadBuffer(msgbuf) != msglen) continue Lconnect;

                        dispatcher.dispatch(tag, msgbuf, (scope const(ubyte)[] buf){ client.rawWriteBuffer(buf); });
                    }
                } catch(Exception ex) {
                    writeln(ex);
                }
            }
        
        } catch(Throwable ex) {
            writeln(ex);
        }
    }
}


private
T enforceNotNull(T)(Nullable!T value)
{
    enforce(!value.isNull, "value is null");
    return value.get;
}


size_t rawReadBuffer(Socket sock, scope void[] buffer)
{
    auto origin = buffer;

    size_t tot = 0;
    while(buffer.length != 0) {
        immutable size = sock.receive(buffer);
        tot += size;

        if(size == 0)
            return tot;

        buffer = buffer[size .. $];
    }

    // writefln!"rawReadBuffer: %(%X%)"(cast(ubyte[])origin);

    return tot;
}


size_t rawWriteBuffer(Socket sock, scope const(void)[] buffer)
{
    size_t tot = 0;
    while(buffer.length != 0) {
        immutable size = sock.send(buffer);
        enforce(size != Socket.ERROR, "Error on rawWriteBuffer");

        tot += size;

        if(size == 0)
            return tot;

        buffer = buffer[size .. $];
    }

    return tot; 
}


Nullable!T rawReadValue(T)(Socket sock)
if(!hasIndirections!T)
{
    T dst;
    size_t size = rawReadBuffer(sock, (cast(void*)&dst)[0 .. T.sizeof]);
    if(size != T.sizeof)
        return Nullable!T.init;
    else
        return nullable(dst);
}


bool rawReadArray(T)(Socket sock, scope T[] buf)
if(!hasIndirections!T)
{
    size_t size = rawReadBuffer(sock, cast(void[])buf);
    if(size != T.sizeof * buf.length)
        return false;
    else
        return true;
}


Nullable!string rawReadString(Socket sock, size_t len)
{
    char[] buf = new char[len];
    bool done = rawReadArray(sock, buf);
    if(done)
        return nullable(cast(string)buf);
    else
        return Nullable!string.init;
}


bool rawWriteValue(T)(Socket sock, T value)
if(!hasIndirections!T)
{
    immutable size = rawWriteBuffer(sock, (cast(void*)&value)[0 .. T.sizeof]);

    if(size != T.sizeof)
        return false;
    else
        return true;
}


bool rawWriteArray(T)(Socket sock, in T[] buf)
if(!hasIndirections!T)
{
    immutable size = rawWriteBuffer(sock, cast(void[])buf);

    if(size != T.sizeof * buf.length)
        return false;
    else
        return true;
}


// alias readCommandID = readEnum!CommandID;

private
Nullable!Enum readEnum(Enum)(Socket sock)
{
    auto value = rawReadValue!ubyte(sock);
    if(value.isNull)
        return typeof(return).init;
    else {
        switch(value.get) {
            import std.traits : EnumMembers;
            static foreach(m; EnumMembers!Enum)
                case m: return typeof(return)(m);
            
            default:
                return typeof(return).init;
        }
    }
}


private
void binaryDump(Socket sock, ref shared bool stop_signal_called)
{
    while(!stop_signal_called) {
        auto v = rawReadValue!ubyte(sock);
        if(!v.isNull)
            writef("%X", v.get);

        stdout.flush();
    }
}


private
void rawWriteValue(T)(scope void delegate(scope const(ubyte)[]) writer, T value)
{
    writer((cast(ubyte*)&value)[0 .. T.sizeof]);
}


private
T rawReadValue(T)(scope void delegate(scope ubyte[]) reader)
{
    T dst;
    reader((cast(ubyte*)&dst)[0 .. T.sizeof]);
    return dst;
}
