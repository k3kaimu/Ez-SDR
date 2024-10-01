import sys
sys.path.append("..")

import ezsdr
import numpy as np
import matplotlib.pyplot as plt
import time

bpsk_constellation = np.array([1+0j, -1+0j])

nSamples = 2**10

signals = [
    np.repeat(np.random.choice(bpsk_constellation, nSamples//4), 4) * 0.01
]

def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    return np.argmax(rxy)

with ezsdr.EzSDRClient("127.0.0.1", 8888) as client:
    TX0 = ezsdr.CyclicTransmitter(client, "TX0")
    RX0 = ezsdr.CyclicReceiver(client, "RX0")

    TX0.setTransmitSignal(signals)
    TX0.stopTransmitLoop()
    RX0.stopReceiveLoop()
    RX0.changeAlignSize(len(signals[0]))
    # client.stopAllController()
    client.setParamToDevice("USRP0", "set_time_unknown_pps_to_zero", "[]")
    # client.startAllController()

    TX0.startTransmitLoop(ezsdr.onTime(0.1))
    RX0.startReceiveLoop(ezsdr.onTime(0.1))

    recv = RX0.receive(nSamples)
    plt.scatter(np.real(recv), np.imag(recv))
    plt.savefig("test_v3_TXRX_result.png")
    print(recv)
    print(calc_delay(signals[0], recv))

    for i in range(10):
        recv = RX0.receive(nSamples)
        print(calc_delay(signals[0], recv))
