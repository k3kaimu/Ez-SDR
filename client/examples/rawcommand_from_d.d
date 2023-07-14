import std.complex;
import std.socket;
import std.stdio;

void main()
{
    auto sock = new TcpSocket(new InternetAddress("127.0.0.1", 8888));

    // 1024サンプル受信する命令を送る
    sock.send("R");
    sock.send([cast(uint)1024]);

    // 1024サンプル受信する
    auto buf = new Complex!float[1024];
    sock.receive(buf);
    writeln(buf);
}
