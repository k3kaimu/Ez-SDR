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

    def shutdown(self):
        self.sock.sendall(b'Q');

    def changeRxAlignSize(self, newAlign):
        self.sock.sendall(b'A')
        sigdatafmt.writeInt32ToSock(self.sock, newAlign)
    
    def skipRx(self, delay):
        self.sock.sendall(b'D')
        sigdatafmt.writeInt32ToSock(self.sock, delay)


class SimpleMockClient:
    def __init__(self, nTXUSRP, nRXUSRP, impRespMatrix):
        self.nTXUSRP = nTXUSRP
        self.nRXUSRP = nRXUSRP
        self.sampleIndex = 0
        self.alignSize = 4096
        self.signals = np.zeros(nTXUSRP, 4096)
        self.impRespMatrix = impRespMatrix
    
    def __enter__(self):
        self.sampleIndex = 0
        self.alignSize = 4096
        return self

    def __exit__(self, *args):
        pass
    
    def connect(self):
        pass
    
    def transmit(self, signals):
        self.signals = signals
    
    def receive(self, nsamples):
        dst = np.zeros((self.nRXUSPR, nsamples), dtype=np.complex128)

        # 次のアライメント（受信バッファの先頭）を計算する
        self.sampleIndex = self.sampleIndex + self.alignSize - (self.sampleIndex % self.alignSize)

        N = len(self.signals[0])
        D = self.sampleIndex % N
        for i in range(self.nTXUSRP):
            tx_freq = np.fft.fft(np.roll(self.signals[i], -D), norm="ortho")
            for j in range(self.nRXUSPR):
                h_freq = np.fft.fft(np.hstack((impRespMatrix[i, j], np.zeros(N, np.complex128)))[:N], norm="ortho")
                rx_freq = tx_freq * h_freq
                rx_time = np.fft.ifft(rx_freq, norm="ortho")
                dst[j] += np.tile(rx_time, nsamples // N + 1)[:nsamples]

        self.sampleIndex += nsamples
        return dst

    def shutdown(self):
        pass
    
    def changeRxAlignSize(self, newAlign):
        self.alignSize = newAlign

    def skipRx(self, delay):
        D = delay % N
        for i in range(self.nTXUSRP):
            self.signals[i] = np.roll(self.signals[i], -D)
