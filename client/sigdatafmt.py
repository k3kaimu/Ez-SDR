import socket
import numpy as np


# ソケットから信号を読む
def readSignalFromSock(sock, size = None):

    if size is None:
        # 受信サンプルのサイズを取得
        size = int.from_bytes(sock.recv(4), 'little');

    # 受信サンプルを取得
    data = bytearray();
    while len(data) < size*8:
        data += sock.recv(min(4096, size*8 - len(data)));

    # バイト列を複素数I+jQの配列へ変換
    data = np.frombuffer(data, dtype=np.float32);
    data = data[::2] + data[1::2] * 1j;
    return data;

# ソケットからInt32の値を読む
def readInt32FromSock(sock):
    return int.from_bytes(sock.recv(4), 'little');

# ソケットにInt32の値を書き込む
def writeInt32ToSock(sock, value):
    data = np.array([value], dtype=np.uint32).tobytes()
    sock.sendall(data)


# ソケットに信号を書き込む
def writeSignalToSock(sock, signal, withHeader = True):
    size = len(signal)

    # データをバイト列に変換する
    if size != 0:
        data = np.concatenate(np.vstack((np.real(signal), np.imag(signal))).T);
    else:
        data = np.array([])

    data = data.astype(np.float32).tobytes()

    # サンプル数をヘッダーとして付与
    header = np.array([size], dtype=np.uint32).tobytes()

    if withHeader:
        response = header + data
    else:
        response = data

    # クライアント側に返答
    txbytes = 0
    while txbytes != len(response):
        txbytes += sock.send(response[txbytes:])

