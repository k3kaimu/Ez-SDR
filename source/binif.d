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
    size_t[] nTXUSRPs,
    size_t[] nRXUSRPs,
    string cpufmt,
    UniqueMsgQueue!(TxRequest!C, TxResponse!C).Commander[] txMsgQueue,
    UniqueMsgQueue!(RxRequest!C, RxResponse!C).Commander[] rxMsgQueue,
)
{
    alias dbg = debugMsg!"eventIOLoop";


    size_t pushReceiveRequest(Socket client)
    {
        immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
        dbg.writefln("RX: Receiver Index = %s", ridx);

        immutable size_t numSamples = client.rawReadValue!uint.enforceNotNull;
        dbg.writefln("RX: numSamples = %s", numSamples);

        C[][] buffer = alloc.makeMultidimensionalArray!C(nRXUSRPs[ridx], numSamples);
        RxRequest!C req = RxRequestTypes!C.Receive(buffer);

        dbg.writefln("RX: Push Request");
        rxMsgQueue[ridx].pushRequest(req);

        return ridx;
    }


    void popReceiveResponse(Socket client, size_t ridx, Flag!"isBlocking" isBlocking)
    {
        bool doneRecv = false;
        do {
            if(!isBlocking && rxMsgQueue[ridx].emptyResponse)
                break;

            dbg.writefln("RX: Wait...");
            while(rxMsgQueue[ridx].emptyResponse) {
                Thread.sleep(10.msecs);
            }

            auto reqres = cast()rxMsgQueue[ridx].popResponse();
            (cast()reqres.res).match!(
                (RxResponseTypes!C.Receive r) {
                    dbg.writefln("RX: Coming!");

                    if(!isBlocking) {
                        // ブロッキングじゃないリクエストに対しては，まずは成功したことを通知するために信号の長さを送る
                        client.rawWriteValue!uint(cast(uint )r.buffer[0].length);
                    }

                    foreach(i; 0 .. nRXUSRPs[ridx])
                        enforce(client.rawWriteArray(r.buffer[i]));

                    alloc.disposeMultidimensionalArray(r.buffer);
                    doneRecv = true;
                }
            )();
        } while(!doneRecv && isBlocking);

        if(!doneRecv && !isBlocking) {
            client.rawWriteValue!uint(0);
        }
    }


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
                    // auto cid = stdin.readCommandID();
                    auto client = socket.accept();
                    writeln("CONNECTED");

                    while(!stop_signal_called && client.isAlive) {
                        // binaryDump(client, stop_signal_called);
                        auto cid = client.readCommandID();
                        if(!cid.isNull) {
                            writeln(cid.get);
                            final switch(cid.get) {
                                case CommandID.shutdown:
                                    stop_signal_called = true;
                                    return;

                                case CommandID.receive:
                                    size_t ridx = pushReceiveRequest(client);
                                    popReceiveResponse(client, ridx, Yes.isBlocking);
                                    break;

                                case CommandID.receiveNBReq:
                                    pushReceiveRequest(client);
                                    break;
                                
                                case CommandID.receiveNBRes:
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    popReceiveResponse(client, ridx, No.isBlocking);
                                    break;

                                case CommandID.transmit:
                                    immutable size_t tidx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Transmitter Index = %s", tidx);
                                    immutable size_t numSamples = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"TX: %s samples"(numSamples);

                                    C[][] buffer = alloc.makeMultidimensionalArray!C(nTXUSRPs[tidx], numSamples);
                                    foreach(i; 0 .. nTXUSRPs[tidx]) {
                                        enforce(client.rawReadArray(buffer[i]));
                                        dbg.writefln!"TX: Read Done %s, len = %s"(i, buffer[i].length);
                                        dbg.writefln!"\tFirst 5 elements: %s"(buffer[i][0 .. min(5, $)]);
                                        dbg.writefln!"\tLast 5 elements: %s"(buffer[i][$ < 5 ? 0 : $-5 .. $]);
                                    }

                                    dbg.writefln("TX: Push MsgQueue");

                                    // C[][] buffer = client.rawReadArray().enforceNotNull;
                                    TxRequest!C req = TxRequestTypes!C.Transmit(buffer);
                                    txMsgQueue[tidx].pushRequest(req);
                                    break;

                                case CommandID.changeRxAlignSize:
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    immutable size_t newAlign = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"changeRxAlignSize: %s samples"(newAlign);

                                    RxRequest!C req = RxRequestTypes!C.ChangeAlignSize(newAlign);
                                    rxMsgQueue[ridx].pushRequest(req);
                                    break;

                                case CommandID.skipRx:
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    immutable size_t delaySamples = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"skipRx: %s samples"(delaySamples);

                                    RxRequest!C req = RxRequestTypes!C.Skip(delaySamples);
                                    rxMsgQueue[ridx].pushRequest(req);
                                    break;

                                case CommandID.syncToPPS:
                                    dbg.writeln("syncToPPS");

                                    // 送受信で準備できたかを相互チェックするための配列
                                    auto isReady = alloc.makeArray!(shared(bool))(nTXUSRPs.length + nRXUSRPs.length);
                                    auto isDone = alloc.makeArray!(shared(bool))(nTXUSRPs.length + nRXUSRPs.length);

                                    foreach(i; 0 .. nTXUSRPs.length) {
                                        TxRequest!C txreq = TxRequestTypes!C.SyncToPPS(i, isReady, isDone);
                                        txMsgQueue[i].pushRequest(txreq);
                                    }

                                    foreach(i; 0 .. nRXUSRPs.length) {
                                        RxRequest!C rxreq = RxRequestTypes!C.SyncToPPS(i + nTXUSRPs.length, isReady, isDone);
                                        rxMsgQueue[i].pushRequest(rxreq);
                                    }
                                    break;

                                case CommandID.checkSetting:
                                    dbg.writeln("checkSetting");
                                    client.rawWriteValue!uint(cast(uint)nTXUSRPs.length);
                                    foreach(e; nTXUSRPs) client.rawWriteValue!uint(cast(uint) e);
                                    client.rawWriteValue!uint(cast(uint)nRXUSRPs.length);
                                    foreach(e; nRXUSRPs) client.rawWriteValue!uint(cast(uint) e);

                                    char[16] fmtstr;
                                    fmtstr[] = 0x00;
                                    fmtstr[0 .. cpufmt.length] = cpufmt[];
                                    client.rawWriteValue!(char[16])(fmtstr);
                                    break;

                                case CommandID.checkVersion:
                                    dbg.writeln("checkVersion");
                                    client.rawWriteValue!uint(interfaceVersion);
                                    break;

                                case CommandID.rxPowerThr:
                                    dbg.writefln("powerThr");
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    float peak = client.rawReadValue!float().enforceNotNull;
                                    float mean = client.rawReadValue!float().enforceNotNull;
                                    dbg.writefln!"%s, %s"(peak, mean);

                                    RxRequest!C filterReq;
                                    if(peak > 0 && mean > 0) {
                                        filterReq = makeFilterRequest!(C, (a, b, sigs){
                                            // 平均電力を算出するために全信号の合計電力を計算する
                                            float sumPower = 0;
                                            foreach(sig; sigs)
                                                foreach(e; sig) {
                                                    auto p = sqAbs(e);
                                                    if(p > peak) return true;     // ピーク電力がpeakを超えたのでfilterを通過
                                                    sumPower += p;
                                                }

                                            // 平均電力がmeanを超えたか
                                            if(sumPower / sigs.length / sigs[0].length > mean)
                                                return true;
                                            else
                                                return false;
                                        })(peak, mean);
                                    } else {
                                        filterReq = RxRequestTypes!C.ApplyFilter(null);
                                    }

                                    rxMsgQueue[ridx].pushRequest(filterReq);
                                    break;

                                case CommandID.clearCmdQueue:
                                    dbg.writefln("clearCmdQueue");
                                    foreach(i; 0 .. nTXUSRPs.length) {
                                        TxRequest!C txccq = TxRequestTypes!C.ClearCmdQueue();
                                        txMsgQueue[i].pushRequest(txccq);
                                    }
                                    foreach(i; 0 .. nRXUSRPs.length) {
                                        RxRequest!C rxccq = RxRequestTypes!C.ClearCmdQueue();
                                        rxMsgQueue[i].pushRequest(rxccq);
                                    }
                                    break;

                                case CommandID.txStopStreaming:
                                    dbg.writefln("txStopStreaming");
                                    immutable size_t tidx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("TX: Transmitter Index = %s", tidx);
                                    TxRequest!C txreq = TxRequestTypes!C.StopStreaming(null);
                                    txMsgQueue[tidx].pushRequest(txreq);
                                    break;
                                
                                case CommandID.txStartStreaming:
                                    dbg.writefln("txStartStreaming");
                                    immutable size_t tidx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("TX: Transmitter Index = %s", tidx);
                                    TxRequest!C txreq = TxRequestTypes!C.StartStreaming();
                                    txMsgQueue[tidx].pushRequest(txreq);
                                    break;

                                case CommandID.rxStopStreaming:
                                    dbg.writefln("rxStopStreaming");
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    RxRequest!C txreq = RxRequestTypes!C.StopStreaming(null);
                                    rxMsgQueue[ridx].pushRequest(txreq);
                                    break;
                                
                                case CommandID.rxStartStreaming:
                                    dbg.writefln("rxStartStreaming");
                                    immutable size_t ridx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: Receiver Index = %s", ridx);
                                    RxRequest!C txreq = RxRequestTypes!C.StartStreaming();
                                    rxMsgQueue[ridx].pushRequest(txreq);
                                    break;

                                case CommandID.txSetParam:
                                    dbg.writefln("txSetParam");
                                    immutable size_t tidx = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("TX: Transmitter Index = %s", tidx);
                                    immutable ParamID type = client.readEnum!ParamID.enforceNotNull;
                                    immutable double param = client.rawReadValue!double.enforceNotNull;
                                    dbg.writefln("TX: type = %s, param = %s", type, param);

                                    string stype;
                                    final switch(type) {
                                        case ParamID.gain:
                                            stype = "gain";
                                            break;
                                        case ParamID.freq:
                                            stype = "freq";
                                            break;
                                    }

                                    shared(double)[] paramArray = alloc.makeArray!(shared(double))(nTXUSRPs[tidx]);
                                    paramArray[] = param;
                                    shared(bool)* isDone = alloc.make!(shared(bool))(),
                                                  isError = alloc.make!(shared(bool))();
                                    scope(exit) {
                                        alloc.dispose(cast(double[])paramArray);
                                        alloc.dispose(isDone);
                                        alloc.dispose(isError);
                                    }

                                    TxRequest!C txreq = TxRequestTypes!C.SetParam(stype, paramArray, isDone, isError);
                                    txMsgQueue[tidx].pushRequest(txreq);

                                    // 結果が返ってくるまで待つ
                                    immutable bool waitResult = waitDone(*isDone, null, stop_signal_called);
                                    if(!waitResult || atomicLoad(*isError)) {
                                        // 待機が中断されたか，エラーフラグが立っているならクライアントに返す値をnanにする
                                        foreach(ref e; paramArray)
                                            e = typeof(e).nan;
                                    }

                                    // クライアントに結果を返す
                                    client.rawWriteValue!uint(cast(uint)nTXUSRPs[tidx]);
                                    foreach(e; paramArray)
                                        client.rawWriteValue!double(e);
                                    break;
                            }
                        } else {
                            continue Lconnect;
                        }


                        foreach(ref q; txMsgQueue) {
                            while(!q.emptyResponse) {
                                auto reqres = q.popResponse();

                                (cast()reqres.res).match!(
                                    (TxResponseTypes!C.TransmitDone g) {
                                        alloc.disposeMultidimensionalArray(g.buffer);
                                    },

                                )();
                            }
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


/+
void socketLoop(Alloc)(
        ref shared(bool) stop_signal_called,
        short port,
        ref Alloc alloc,
        // ref shared RWQueue!(const(shared(Complex!float[])[])) txsupplier,
        // ref shared RWQueue!(const(shared(Complex!float[])[])) txdustreporter,
        // ref shared RWQueue!(const(shared(Complex!float[])[])) rxsupplier,
        // ref shared RWQueue!(const(shared(Complex!float[])[])) rxreporter,
        // ref shared MsgQueue!(shared(RxRequest)*, shared(RxResponse)*) txMsgQueue,
        ref shared MsgQueue!(shared(RxRequest)*, shared(RxResponse)*) rxMsgQueue,
)
{
    /+
    // ソケットアドレス構造体
    sockaddr_in sockAddr, clientAddr;
    memset(&sockAddr, 0, sockAddr.sizeof);
    memset(&clientAddr, 0, clientAddr.sizeof);

    socklen_t socklen = clientAddr.sizeof;

    // インターネットドメインのTCPソケットを作成
    auto sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd == -1) {
        writefln("failed to socket");
        return;
    }
    scope(exit) {
        close(sockfd);
    }

    {
        // ノンブロッキング化
        int val1 = 1;
        if(ioctl(sockfd, FIONBIO, &val1) == -1) {
            writefln("failed to ioctl");
            return;
        }
    }

    // ソケットアドレス構造体を設定
    sockAddr.sin_family = AF_INET;          // インターネットドメイン(IPv4)
    sockAddr.sin_addr.s_addr = INADDR_ANY;  // 全てのアドレスからの接続を受け入れる(=0.0.0.0)
    sockAddr.sin_port = htons(port);  // 接続を待ち受けるポート

    // 上記設定をソケットに紐づける
    if(bind(sockfd, cast(const(sockaddr)*)&sockAddr, sockAddr.sizeof) == -1) {
        printf("failed to bind\n");
        return;
    }

    // ソケットに接続待ちを設定する。10はバックログ、同時に何個迄接続要求を受け付けるか。
    if (listen(sockfd, 10) == -1) {
        printf("failed to listen\n");
        return;
    }


    Flag!"disconnected" listenTCP(int fd)
    {
        auto cmdType = readFromSock!ubyte(fd);
        if(cmdType.isNull) {
            return Yes.disconnected;
        }

        writeln("cmdType = %s", cmdType.get);

        auto msgSize = readFromSock!uint(fd);
        if(msgSize.isNull) {
            return Yes.disconnected;
        }

        printf("buf_len = %d\n", msgSize.get * 4);

        auto buf = alloc.makeArray!(short[2])(msgSize.get);

        // データ本体の受信
        if(!readArrayFromSock(fd, buf)) {
            return Yes.disconnected;
        }

        import std.stdio;
        writefln("received data:%s", buf);

        if(! sendToSock!uint(fd, cast(uint)buf.length))
            return Yes.disconnected;

        if(! sendArrayToSock(fd, buf))
            return Yes.disconnected;

        return No.disconnected;
    }

    // クライアントのfile descripter
    int fd_client = -1;
    scope(exit) {
        if(fd_client != -1) {
            close(fd_client);
            fd_client = -1;
        }
    }

    // 無限ループのサーバー処理
    while(! stop_signal_called) {
        // printf("accept wating...\n");
        // // 接続受付処理。接続が来るまで無限に待つ。recvのタイムアウト設定時はそれによる。シグナル来ても切れるけど。
        // auto fd_other = accept(sockfd, cast(sockaddr*)&clientAddr, &socklen);
        // if (fd_other == -1) {
        //     printf("failed to accept\n");
        //     continue;
        // }
        // scope(exit) {
        //     close(fd_other);
        //     fd_other = -1;
        // }

        if(fd_client == -1) {
            // 接続が来ているか確認
            fd_client = accept(sockfd, cast(sockaddr*)&clientAddr, &socklen);
            if(fd_client != -1)
                printf("connected!");
        }

        if(fd_client != -1 && numAvailableBytes(fd_client)) {

        }

        // 接続受付
        {
            auto fd_other = accept(sockfd, cast(sockaddr*)&clientAddr, &socklen);
            printf("connected!");

            if(fd_other != -1) {
                scope(exit) {
                    printf("Shutdown connection\n");
                    close(fd_other);
                }
                while(listenTCP(fd_other) == No.disconnected) {};
            }
        }

        // コマンドイベント処理
        {
            while(!rxMsgQueue.emptyResponse) {
                auto resp = rxMsgQueue.popResponse();
                printf("POP from rxMsgQueue\n");
            }
        }

        printf("SLEEP");
        Thread.sleep(100.msecs);
    }+/
}
+/