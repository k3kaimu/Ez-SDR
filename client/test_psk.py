import multiusrp
import numpy as np
import time

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 2
nRXUSRP = 2

nSamples = 2**10

bpsk_constellation = np.array([1+0j, -1+0j])
qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)

def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    return np.argmax(rxy)


with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    signals = [
        np.repeat(np.random.choice(bpsk_constellation, nSamples//4), 4),
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]

    rxAlignSize = 1000
    usrp.changeRxAlignSize(rxAlignSize)
    usrp.transmit(signals)
    time.sleep(1)

    recv1 = usrp.receive(nSamples)
    recv2 = usrp.receive(nSamples)

    print("Tx: nSamples = {}, Rx: rxAlignSize = {}".format(nSamples, rxAlignSize))
    print("1st: delay[0]: {} samples".format(calc_delay(signals[0], recv1[0])))
    print("1st: delay[1]: {} samples".format(calc_delay(signals[1], recv1[1])))
    print("2nd: delay[0]: {} samples".format(calc_delay(signals[0], recv2[0])))
    print("2nd: delay[1]: {} samples".format(calc_delay(signals[1], recv2[1])))
    print("")

    rxAlignSize = nSamples
    usrp.changeRxAlignSize(rxAlignSize)

    recv1 = usrp.receive(nSamples)
    recv2 = usrp.receive(nSamples)

    print("Tx: nSamples = {}, Rx: rxAlignSize = {}".format(nSamples, rxAlignSize))
    print("1st: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv1[0])))
    print("1st: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv1[1])))
    print("2nd: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv2[0])))
    print("2nd: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv2[1])))
    print("")

    usrp.sync()
    recv1 = usrp.receive(nSamples)
    recv2 = usrp.receive(nSamples)

    print("Tx: nSamples = {}, Rx: rxAlignSize = {}, After Synchronization".format(nSamples, rxAlignSize))
    print("1st: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv1[0])))
    print("1st: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv1[1])))
    print("2nd: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv2[0])))
    print("2nd: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv2[1])))
    print("")

    recv1 = usrp.receive(nSamples)
    recv2 = usrp.receive(nSamples)

    print("Tx: nSamples = {}, Rx: rxAlignSize = {}, After Synchronization".format(nSamples, rxAlignSize))
    print("1st: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv1[0])))
    print("1st: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv1[1])))
    print("2nd: tx[0] to rx[0]: delay = {} samples".format(calc_delay(signals[0], recv2[0])))
    print("2nd: tx[1] to rx[1]: delay = {} samples".format(calc_delay(signals[1], recv2[1])))

    # for i in range(nSamples):
    #     print("{},{},{},{},{},{},{},{},{}".format(i, np.real(recv1[0][i]),np.imag(recv1[0][i]),np.real(recv1[1][i]),np.imag(recv1[1][i]), np.real(recv2[0][i]),np.imag(recv2[0][i]),np.real(recv2[1][i]),np.imag(recv2[1][i])))



