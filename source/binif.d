module binif;

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
import transmitter : TxRequest, TxResponse, TxRequestTypes, TxResponseTypes;
import receiver : RxRequest, RxResponse, RxRequestTypes, RxResponseTypes;


enum uint interfaceVersion = 2;

enum CommandID : ubyte
{
    shutdown = 0x51,            // 'Q'
    receive = 0x52,             // 'R'
    transmit = 0x54,            // 'T'
    changeRxAlignSize = 0x41,   // 'A'
    skipRx = 0x44,              // 'D'
    syncToPPS = 0x53,           // 'S',
    checkSetting = 0x43,        // 'C'
    checkVersion = 0x56,        // 'V'
    receiveNBReq = 0x72,        // 'r'
    receiveNBRes = 0x67,        // 'g'
    rxPowerThr = 0x70,          // 'p'
    clearCmdQueue = 0x71,       // 'q'
    txStopStreaming = 0x81,     //
    txStartStreaming = 0x82,    //
    rxStopStreaming = 0x83,     //
    rxStartStreaming = 0x84,    //
    txSetParam = 0x85,          //
    // rxSetParam = 0x86,          //
}


enum ParamID : ubyte
{
    gain = 0x01,
    freq = 0x02,
}


// 
RxRequestTypes!C.ApplyFilter makeFilterRequest(C, alias fn, T...)(T args)
{
    return RxRequestTypes!C.ApplyFilter((C[][] signal) => fn(args, signal));
}


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
                        size_t taglen = client.rawReadValue!ushort();
                        if(taglen.isNull || taglen == 0) continue Lconnect;
                        char[] tag = cast(char[]) alloc.allocate(taglen);
                        scope(exit) alloc.deallocate(tag);
                        string tag = client.rawReadString();
                        if(tag.isNull) continue Lconnect;

                        ulong msglen = client.rawReadValue!ulong();
                        if(msglen.isNull) continue Lconnect;

                        void[] msgbuf = alloc.allocate(msglen);
                        scope(exit) alloc.deallocate(msgbuf);
                        client.rawReadBuffer(msgbuf);

                        if(tag == "@") {
                            foreach(t, c; ctrls)
                                c.processMessage(socket, msgbuf);
                        } else {
                            if(auto c = tag in ctrls)
                                c.processMessage(socket, msgbuf);
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


/+
private
Nullable!CommandID readCommandID(File file) {
    ubyte[1] buf;
    if(file.rawRead(buf[]).length != 1)
        return typeof(return).init;
    else {
        switch(buf[0]) {
            import std.traits : EnumMembers;
            static foreach(m; EnumMembers!CommandID)
                case m: return typeof(return)(m);
            
            default:
                return typeof(return).init;
        }
    }
}


private
Nullable!T rawReadValue(T)(File file) {
    T[1] buf;
    if(file.rawRead(buf[]).length != 1)
        return typeof(return).init;
    else
        return typeof(return)(buf[0]);
}


private
Nullable!(T[]) rawReadArray(T)(File file, T[] buffer) {
    if(file.rawRead(buffer[]).length != buffer.length)
        return typeof(return).init;
    else
        return typeof(return)(buffer);
}
+/


/+
size_t numAvailableBytes(int sockfd) @nogc
{
    int count;
    ioctl(fd, FIONREAD, &count);
    return count;
}
+/


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


alias readCommandID = readEnum!CommandID;

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
