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


immutable string ifaceVersion = "3.0.11";


class RestartWithConfigData : Exception
{
    string configJSON;

    this(string json, string file = __FILE__, ulong line = cast(ulong)__LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(json, file, line, nextInChain);
        this.configJSON = json;
    }
}


class ProtocolError : Exception
{
    this(string msg, string file = __FILE__, ulong line = cast(ulong)__LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
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
    alias console = consoleMsg!"eventIOLoop";

    size_t tryCount = 0;
    while(!atomicLoad(stop_signal_called) && tryCount < 10)
    {
        scope(exit)
            ++tryCount;

        if(tryCount > 0) {
            dbg.writefln("Retrying to start eventIOLoop... (attempt %s)", tryCount);
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

            auto readSet = new SocketSet(1);

            console.write("Waiting for client connection...");
            Lconnect: while(!atomicLoad(stop_signal_called)) {
                try {
                    Disposer.instance.tryDisposeAll();

                    {
                        readSet.reset();
                        readSet.add(socket);

                        // ready == 0: timeout, ready == -1: error or interrupted
                        // ready > 0: number of ready sockets (should be 1 in this case)
                        int ready = Socket.select(readSet, null, null, 1.seconds);
                        if(ready == 0 || ready == -1) {
                            if(ready == -1)
                                dbg.writeln("\nInterrupted");

                            continue Lconnect;
                        }
                    }
                    console.writeln();

                    auto client = socket.accept();
                    scope(exit) client.close();
                    client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 1.seconds);
                    console.writeln("Checking client...");

                    // クライアントのバージョンチェック
                    try {
                        {
                            size_t len = rawReadValue!ushort(client).enforceProtocol!"!a.isNull && a.get > 0"( "Failed to read client version length").get;
                            string clientVersion = rawReadString(client, len).enforceProtocol!"!a.isNull"("Failed to read client version").get;
                            if(clientVersion != ifaceVersion) {
                                throw new ProtocolError("Client interface version mismatch: expected " ~ ifaceVersion ~ ", got " ~ clientVersion);
                            } else {
                                dbg.writefln("Client interface version: %s", clientVersion);
                            }
                        }

                        console.writeln("Client connected. Waiting for message...");

                        LnextMsg: while(!atomicLoad(stop_signal_called) && client.isAlive) {
                            {
                                readSet.reset();
                                readSet.add(client);
                                int ready = Socket.select(readSet, null, null, 1.seconds);
                                if(ready == 0) {
                                    // timeout
                                    continue LnextMsg;
                                } else if(ready == -1) {
                                    // error or interrupted
                                    console.writeln("\nClient socket error or interrupted");
                                    continue Lconnect;
                                    break;
                                }
                            }

                            auto taglen = client.rawReadValue!ushort();
                            if(taglen.isNull) {
                                // 接続が切れた可能性がある
                                console.writeln("Failed to read tag length. Client may have disconnected.");
                                continue Lconnect;
                            }

                            dbg.writefln("taglen = %s", taglen.get);
                            enforceProtocol!"a > 0"(taglen.get, "Failed to read tag length");

                            char[] tag = cast(char[]) alloc.allocate(taglen.get);
                            scope(exit) alloc.deallocate(tag);
                            if(client.rawReadBuffer(tag) != taglen.get) throw new ProtocolError("Failed to read tag buffer");
                            dbg.writefln("tag = %s", tag);

                            ulong msglen = client.rawReadValue!ulong().enforceProtocol!"!a.isNull"("Failed to read message length").get;
                            dbg.writefln("msglen = %s", msglen);

                            ubyte[] msgbuf = cast(ubyte[])alloc.allocate(msglen);
                            scope(exit) alloc.deallocate(msgbuf);
                            if(client.rawReadBuffer(msgbuf) != msglen) throw new ProtocolError("Failed to read message buffer");

                            dispatcher.dispatch(tag, msgbuf, (scope const(ubyte)[] buf){ client.rawWriteBuffer(buf); });

                            dbg.writefln("Message dispatched: tag = %s, msglen = %s", tag, msglen);
                            console.writefln("waiting for next message...");
                        }
                    } catch(ProtocolError ex) {
                        console.writeln("Protocol error: ", ex.msg);
                        console.writeln("Disconnecting client...");
                        continue Lconnect;
                    }
                } catch(Exception ex) {
                    console.writeln(ex);
                }
            }

            console.flush();
        
        } catch(Throwable ex) {
            console.writeln(ex);
        }
    }
}

unittest
{
    shared bool stop_signal_called = false;
    scope(exit) atomicStore(stop_signal_called, true);

    class TestController : ControllerImpl!IControllerThread
    {
        override
        void processMessage(scope const(ubyte)[] msgbuf, void delegate(scope const(ubyte)[]) writer) 
        {
            copiedMessage = msgbuf.dup;
        }


        override
        void spawnDeviceThreads() {}

        ubyte[] copiedMessage;
    }

    immutable string testTag = "TEST";
    auto controller = new TestController();
    auto t = new Thread({
        auto dispatcher = new MessageDispatcher(null, [testTag: controller]);
        eventIOLoop!(Complex!float)(stop_signal_called, 8080, theAllocator, dispatcher);
    }).start();

    // 別スレッドでTCPクライアントを作って接続テスト
    Thread.sleep(1.seconds);
    auto client = new TcpSocket(AddressFamily.INET);
    client.connect(new InternetAddress("127.0.0.1", 8080));
    scope(exit) client.close();

    // クライアントのバージョンチェック
    client.rawWriteValue!ushort(ifaceVersion.length);
    client.rawWriteBuffer(cast(ubyte[])ifaceVersion);
    client.rawWriteValue!ushort(testTag.length);
    client.rawWriteBuffer(cast(ubyte[])testTag);
    ubyte[] testMsg = [1, 2, 3, 4, 5];
    client.rawWriteValue!ulong(testMsg.length);
    client.rawWriteBuffer(testMsg);
    Thread.sleep(200.msecs);
    assert(controller.copiedMessage == testMsg);

    Thread.sleep(1.seconds);
    atomicStore(stop_signal_called, true);
    t.join();
}


private
T enforceProtocol(alias pred, T)(T value, string msg, string file = __FILE__, ulong line = cast(ulong)__LINE__)
{
    import std.functional : unaryFun;

    if(!unaryFun!pred(value))
        throw new ProtocolError(msg, file, line);

    return value;
}


size_t rawReadBuffer(Socket sock, scope void[] buffer)
{
    auto origin = buffer;

    size_t tot = 0;
    while(buffer.length != 0) {
        immutable long size = sock.receive(buffer);
        if(size == Socket.ERROR || size <= 0)
            return tot;

        tot += size;
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
