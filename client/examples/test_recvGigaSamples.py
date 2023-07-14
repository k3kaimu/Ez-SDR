import multiusrp
import numpy as np
import time

IPADDR = "127.0.0.1";
PORT = 8888;

nSamples = 2**20
qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)

def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    return np.argmax(rxy)

with multiusrp.SimpleClient(IPADDR, PORT, 1, 1) as usrp:
    signals = [
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]

    usrp.changeRxAlignSize(nSamples-1)
    usrp.transmit(signals)
    usrp.sync()

    # 連続して2**20 * 1000サンプル受信する命令を発行する
    nTimes = 1000
    usrp.receive(nSamples * nTimes, onlyRequest=True)

    # 先の命令のレスポンスは巨大すぎる（約8GB）ので1000回に分けて受信する
    for i in range(nTimes):
        recv = usrp.receive(nSamples, onlyResponse=True)[0]
        nDelay = calc_delay(signals[0], recv)
        print("{}th: delay = {} samples".format(i, nDelay))
