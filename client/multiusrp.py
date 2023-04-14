import socket
import numpy as np
import scipy
from collections import namedtuple
import sigdatafmt


# class MockServer:
#     def __init__(self, ipaddr, port):
#         self.ipaddr = ipaddr
#         self.port = port
#         if self.ipaddr is not None:
#             self.sock_sv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
#             self.sock_sv.bind((ipaddr, port))

#     def onIncomingTransmitCommand(self, signal):
#         self.savedSignal = signal
    
#     def onIncomingReceiveCommand(self):
#         return self.savedSignal.copy()

#     def run(self):
#         bStop = False
#         if self.ipaddr is not None:
#             self.sock_sv.listen()
#             while not bStop:
#                 sock_cl, addr = self.sock_sv.accept();
#                 print("[Connected from {}]".format(addr));
#                 try:
#                     while not bStop:
#                         # クライアントからのメッセージを1バイト受信
#                         # 1バイト目がb'T'（0x54）なら送信，b'R'（0x52）なら受信
#                         data = sock_cl.recv(1);
#                         # print(data)

#                         if len(data) == 0:
#                             # コネクションが切断されているので次の接続を待つ
#                             print("[Disconnected]");
#                             break;
#                         elif data == b'T':
#                             print("[Transmit command]");

#                             # クライアントからのデータ取得
#                             data = readSignalFromSock(sock_cl)
#                             print("\tFirst 10 elements: {}".format(data[:10]));
#                             print("\tLast 10 elements: {}".format(data[-10:]));

#                             # 現在送信中の信号として保存しておく
#                             self.onIncomingTransmitCommand(data);

#                             # クライアントへ返答する受信データ
#                             recvdata = self.onIncomingReceiveCommand();
#                             print("[Response]")
#                             print("\tFirst 10 elements: {}".format(recvdata[:10]));
#                             print("\tLast 10 elements: {}".format(recvdata[-10:]));
#                             writeSignalToSock(sock_cl, recvdata);

#                         elif data == b'R':
#                             print("[Receive command]")

#                             # サーバー側では受信データをクライアントに返す
#                             # このリファレンス実装では以前に受け取っている送信データをそのまま返す
#                             data = self.onIncomingReceiveCommand();
#                             print("[Response]")
#                             print("\tFirst 10 elements: {}".format(data[:10]));
#                             print("\tLast 10 elements: {}".format(data[-10:]));
#                             writeSignalToSock(sock_cl, data);

#                         elif data == b'Q':
#                             bStop = True

#                         else:
#                             print("[Undefined command]")

#                 finally:
#                     sock_cl.close()


class SimpleClient:
    def __init__(self, ipaddr, port, nTXUSRP, nRXUSRP):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.ipaddr = ipaddr
        self.port = port
        self.mockserver = None
        self.nTXUSRP = nTXUSRP
        self.nRXUSRP = nRXUSRP
        # self.doClip = True
        # self.txMaxPowerdBm = None      # I/Q相両方が32767のときの送信電力
        # self.rxMaxPowerdBm = None      # I/Q相両方が32767のときの受信電力

    def __enter__(self):
        if self.ipaddr is not None:
            self.sock.__enter__();
            self.sock.connect((self.ipaddr, self.port));
        return self

    def __exit__(self, *args):
        if self.ipaddr is not None:
            self.sock.close()
            self.sock.__exit__(args)

    def connect(self):
        if self.ipaddr is not None:
            self.sock.connect((self.ipaddr, self.port));

    def connectToMockServer(self, mockserver):
        self.mockserver = mockserver

    def transmit(self, signals):
        if self.mockserver is None:
            self.sock.sendall(b'T');
            for i in range(self.nTXUSRP):
                if i == 0:
                    sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=True)
                else:
                    sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=False)

        else:
            self.mockserver.onIncomingTransmitCommand(signal)
            return self.mockserver.onIncomingReceiveCommand()

    def receive(self, nsamples):
        if self.mockserver is None:
            self.sock.sendall(b'R');
            sigdatafmt.writeInt32ToSock(self.sock, nsamples)

            ret = []
            for i in range(self.nRXUSRP):
                ret.append(sigdatafmt.readSignalFromSock(self.sock, nsamples))
            
            return np.array(ret)
        else:
            return self.mockserver.onIncomingReceiveCommand()

    def shutdown():
        sock.sendall(b'Q');
