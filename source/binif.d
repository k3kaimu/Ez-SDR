module binif;

// import core.sys.posix.netinet.in_;
// import core.sys.posix.sys.ioctl;
// import core.sys.posix.unistd;
// import core.sys.posix.sys.time;

// import core.stdc.stdlib;
// import core.stdc.stdio;
// import core.stdc.string;
import core.thread;

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


enum CommandID : ubyte
{
    shutdown = 0x51,            // 'Q'
    receive = 0x52,             // 'R'
    transmit = 0x54,            // 'T'
    changeRxAlignSize = 0x41,   // 'A'
    skipRx = 0x44,              // 'D'
    syncToPPS = 0x53,           // 'S',
    checkSetting = 0x43,        // 'C'
}


/**
TCPを監視して，イベントの処理をします
*/
void eventIOLoop(C, Alloc)(
    ref shared bool stop_signal_called,
    ushort port,
    ref Alloc alloc,
    size_t nTXUSRP,
    size_t nRXUSRP,
    string cpufmt,
    ref shared UniqueMsgQueue!(TxRequest!C, TxResponse!C) txMsgQueue,
    ref shared UniqueMsgQueue!(RxRequest!C, RxResponse!C) rxMsgQueue,
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
                                    immutable size_t numSamples = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln("RX: numSamples = %s", numSamples);

                                    C[][] buffer = alloc.makeMultidimensionalArray!C(nRXUSRP, numSamples);
                                    RxRequest!C req = RxRequestTypes!C.Receive(buffer);

                                    dbg.writefln("RX: Push Request");
                                    rxMsgQueue.pushRequest(req);

                                    bool doneRecv = false;
                                    while(!doneRecv) {
                                        dbg.writefln("RX: Wait...");
                                        while(rxMsgQueue.emptyResponse) {
                                            Thread.sleep(10.msecs);
                                        }

                                        auto reqres = cast()rxMsgQueue.popResponse();
                                        (cast()reqres[1]).match!(
                                            (RxResponseTypes!C.Receive r) {
                                                dbg.writefln("RX: Coming!");

                                                foreach(i; 0 .. nRXUSRP)
                                                    enforce(client.rawWriteArray(r.buffer[i]));

                                                alloc.disposeMultidimensionalArray(r.buffer);
                                                doneRecv = true;
                                            }
                                        )();
                                    }
                                    break;

                                case CommandID.transmit:
                                    immutable size_t numSamples = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"TX: %s samples"(numSamples);

                                    C[][] buffer = alloc.makeMultidimensionalArray!C(nTXUSRP, numSamples);
                                    foreach(i; 0 .. nTXUSRP) {
                                        enforce(client.rawReadArray(buffer[i]));
                                        dbg.writefln!"TX: Read Done %s, len = %s"(i, buffer[i].length);
                                        dbg.writefln!"\tFirst 5 elements: %s"(buffer[i][0 .. min(5, $)]);
                                        dbg.writefln!"\tLast 5 elements: %s"(buffer[i][$ < 5 ? 0 : $-5 .. $]);
                                    }

                                    dbg.writefln("TX: Push MsgQueue");

                                    // C[][] buffer = client.rawReadArray().enforceNotNull;
                                    TxRequest!C req = TxRequestTypes!C.Transmit(buffer);
                                    txMsgQueue.pushRequest(req);
                                    break;

                                case CommandID.changeRxAlignSize:
                                    immutable size_t newAlign = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"changeRxAlignSize: %s samples"(newAlign);

                                    RxRequest!C req = RxRequestTypes!C.ChangeAlignSize(newAlign);
                                    rxMsgQueue.pushRequest(req);
                                    break;

                                case CommandID.skipRx:
                                    immutable size_t delaySamples = client.rawReadValue!uint.enforceNotNull;
                                    dbg.writefln!"skipRx: %s samples"(delaySamples);

                                    RxRequest!C req = RxRequestTypes!C.Skip(delaySamples);
                                    rxMsgQueue.pushRequest(req);
                                    break;

                                case CommandID.syncToPPS:
                                    dbg.writeln("syncToPPS");

                                    immutable useBothTxRx = (nTXUSRP != 0) && (nRXUSRP != 0);

                                    // 送受信で準備できたかを相互チェックするための配列
                                    auto isReady = alloc.makeArray!(shared(bool))(useBothTxRx ? 2 : 1);

                                    if(nTXUSRP != 0) {
                                        TxRequest!C txreq = TxRequestTypes!C.SyncToPPS(0, isReady);
                                        txMsgQueue.pushRequest(txreq);
                                    }

                                    if(nRXUSRP != 0) {
                                        RxRequest!C rxreq = RxRequestTypes!C.SyncToPPS(useBothTxRx ? 1 : 0, isReady);
                                        rxMsgQueue.pushRequest(rxreq);
                                    }
                                    break;

                                case CommandID.checkSetting:
                                    dbg.writeln("checkSetting");
                                    client.rawWriteValue!uint(nTXUSRP);
                                    client.rawWriteValue!uint(nRXUSRP);

                                    char[16] fmtstr;
                                    fmtstr[] = 0x00;
                                    fmtstr[0 .. cpufmt] = cpufmt[];
                                    client.rawWriteValue!(char[16])(fmtstr);
                                    break;
                            }
                        } else {
                            continue Lconnect;
                        }


                        while(!txMsgQueue.emptyResponse) {
                            auto reqres = txMsgQueue.popResponse();

                            (cast()reqres[1]).match!(
                                (TxResponseTypes!C.TransmitDone g) {
                                    alloc.disposeMultidimensionalArray(g.buffer);
                                }
                            )();
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