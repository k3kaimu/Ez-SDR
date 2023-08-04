import socket
import numpy as np
import struct
import zlib

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


def writeFloat32ToSock(sock, value):
    data = np.array([value], dtype=np.float32).tobytes()
    sock.sendall(data)


def getMinStep(rsignal):
    rsignal = np.abs(rsignal)
    return np.min(rsignal[rsignal != 0])

def compress(signal):
    scale = 32767
    minStep = getMinStep(np.real(signal[:min(10000000, len(signal))]))

    # get min
    if minStep < (1/32766) and minStep > (1/32768):
        scale = 1/minStep

    data = np.hstack((np.real(signal), np.imag(signal))).astype(np.float32)
    data *= scale
    data = data.astype(np.int16)
    data += 2**7
    data = data.tobytes()
    header = np.array([scale], dtype=np.float32).tobytes()
    data = header + data[::2] + data[1::2]
    return zlib.compress(data)


def decompress(data):
    data = zlib.decompress(data)
    scale = np.frombuffer(data[:4], np.float32)[0]
    data = data[4:]
    bdata = bytearray(len(data))
    bdata[0::2] = data[:len(data)//2]
    bdata[1::2] = data[len(data)//2:]
    data = np.frombuffer(bdata, dtype=np.int16)
    data = data - 2**7
    data = data.astype(np.float32) / scale
    return data[:len(data)//2] + data[len(data)//2:] * 1j
