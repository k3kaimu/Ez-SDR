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

# gdb --args ./multiusrp --tx-args="addr0=192.168.10.211" --rx-args="addr0=192.168.10.213" --tx-rate=1e6 --rx-rate=1e6 --tx-freq=2.45e9 --rx-freq=2.45e9 --tx-gain=10 --rx-gain=30 --clockref=external --timeref=external --timesync=true --tx-channels="0" --rx-channels="0" --port=8888
with ezsdr.SimpleClient(IPADDR, PORT, 1, 1) as usrp:
    signals = [
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]

    usrp.changeRxAlignSize(1000)
    usrp.transmit(signals)

    print("sync, wait and receive")
    for i in range(10):
        usrp.sync()
        time.sleep(3)
        recv1 = usrp.receive(nSamples)
        print(calc_delay(signals[0], recv1[0]))

    print("sync and receive")
    for i in range(10):
        usrp.sync()
        recv1 = usrp.receive(nSamples)
        print(calc_delay(signals[0], recv1[0]))