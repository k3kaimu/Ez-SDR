import sys
sys.path.append("..")


import argparse
import socket
import numpy as np
import sigdatafmt

argparser = argparse.ArgumentParser()
argparser.add_argument('--ipaddr', default="127.0.0.1")
argparser.add_argument('--port', default=8888, type=int)
argparser.add_argument('--sigma2', default=0, type=float)


args = argparser.parse_args()

# サーバーIPとポート番号
IPADDR = args.ipaddr;
PORT = args.port;

noiseSigma2 = args.sigma2

sock_sv = socket.socket(socket.AF_INET,socket.SOCK_STREAM);
sock_sv.bind((IPADDR, PORT));
sock_sv.listen();

# 現在送信中の信号を保存しておくための変数
txSignal = np.array([], dtype=np.complex64);

while True:
    sock_cl, addr = sock_sv.accept();
    print("[Connected from {}]".format(addr));
    rxAlignSize = 1024

    try:
        while True:
            # クライアントからのメッセージを1バイト受信
            data = sock_cl.recv(1);
            # print(data)

            if len(data) == 0:
                # コネクションが切断されているので次の接続を待つ
                print("[Disconnected]");
                break;
            elif data == b'T':
                print("[Transmit command]");

                # クライアントからのデータを読み込む
                _ = sigdatafmt.readInt32FromSock(sock_cl)
                data = sigdatafmt.readSignalFromSock(sock_cl)
                print("\tFirst 10 elements: {}".format(data[:10]));
                print("\tLast 10 elements: {}".format(data[-10:]));

                # 現在送信中の信号として保存しておく
                txSignal = data.copy();

            elif data == b'R':
                print("[Receive command]")

                # クライアントからのデータを読み込む
                _ = sigdatafmt.readInt32FromSock(sock_cl)
                nsamples = sigdatafmt.readInt32FromSock(sock_cl)

                # サーバー側では受信データをクライアントに返す
                data = np.tile(txSignal.copy(), nsamples//len(txSignal) + 1)
                data = data[:nsamples]

                data += np.random.normal(loc=0, scale=np.sqrt(noiseSigma2/2), size=nsamples) + 1j*np.random.normal(loc=0, scale=np.sqrt(noiseSigma2/2), size=nsamples)

                # クライアントに信号を送る
                sigdatafmt.writeSignalToSock(sock_cl, data, withHeader=False)

            elif data == b'A':
                _ = sigdatafmt.readInt32FromSock(sock_cl)
                rxAlignSize = sigdatafmt.readInt32FromSock(sock_cl)

            else:
                print("[Undefined command]")

    finally:
        sock_cl.close()