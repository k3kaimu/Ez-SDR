import sys
sys.path.append("..")

import ezsdr
import numpy as np
import time

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nSamples = 2**10
qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)

def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    return np.argmax(rxy)


with ezsdr.EzSDRClient("127.0.0.1", 8888) as client:
    TX0 = ezsdr.CyclicTransmitter(client, "TX0")
    RX0 = ezsdr.CyclicReceiver(client, "RX0")

    signals = [
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]

    TX0.transmit(signals)

    # 1サンプルだけずらす
    RX0.changeAlignSize(nSamples-1)

    RX0.stopReceiveLoop()
    TX0.stopTransmitLoop()

    nReq = 100
    # 100個の受信リクエストを送る
    for i in range(nReq):
        RX0.receiveRequestOnly(nSamples-1)

    # 同期して送受信を始める
    ezsdr.syncUSRPLoopTXRX(client, ["USRP0"], [TX0], [RX0])

    for i in range(nReq):
        recv = RX0.receiveResponseOnly()[0]
        recv = np.hstack((recv, np.zeros(1, dtype=recv.dtype)))  # 1サンプル減ってる分を足す
        delay = calc_delay(signals[0], recv)
        print(f"recv {i}: delay = {delay}, diff = {delay - i}")     # 連続受信しているなら，1サンプルずつずれるはず
