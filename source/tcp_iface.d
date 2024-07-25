module tcp_iface;

// import core.sys.posix.netinet.in_;
// import core.sys.posix.sys.ioctl;
// import core.sys.posix.unistd;
// import core.sys.posix.sys.time;

// import core.stdc.stdlib;
// import core.stdc.stdio;
// import core.stdc.string;
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


class RestartWithConfigData : Exception
{
    string configJSON;

    this(string json, string file = __FILE__, ulong line = cast(ulong)__LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(json, file, line, nextInChain);
        this.configJSON = json;
    }
}


/**
TCPを監視して，イベントの処理をします
*/
void eventIOLoop(C, Alloc)(
    ref shared bool stop_signal_called,
    ushort port,
    ref Alloc alloc,
    IController[string] ctrls,
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
                        dbg.writefln("tag = %s", taglen.get);

                        auto msglen = client.rawReadValue!ulong();
                        if(msglen.isNull) continue Lconnect;
                        dbg.writefln("msglen = %s", msglen.get);

                        ubyte[] msgbuf = cast(ubyte[])alloc.allocate(msglen.get);
                        scope(exit) alloc.deallocate(msgbuf);
                        if(client.rawReadBuffer(msgbuf) != msglen) continue Lconnect;

                        if(tag == "@all") {
                            foreach(t, c; ctrls)
                                c.processMessage(msgbuf, (scope const(ubyte)[] buf){ client.rawWriteBuffer(buf); });
                        } else {
                            if(auto c = tag in ctrls)
                                c.processMessage(msgbuf, (scope const(ubyte)[] buf){ client.rawWriteBuffer(buf); });
                            else
                                writefln("[WARNIGN] cannot find tag '%s'", tag);
                        }
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
