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

with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    signals = [
        np.repeat(np.random.choice(bpsk_constellation, nSamples//4), 4),
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]

    usrp.transmit(signals)
    usrp.changeRxAlignSize(nSamples)
    time.sleep(1)

    recv1 = usrp.receive(nSamples)
    recv2 = usrp.receive(nSamples)
    for i in range(nSamples):
        print("{},{},{},{},{},{},{},{},{}".format(i, np.real(recv1[0][i]),np.imag(recv1[0][i]),np.real(recv1[1][i]),np.imag(recv1[1][i]), np.real(recv2[0][i]),np.imag(recv2[0][i]),np.real(recv2[1][i]),np.imag(recv2[1][i])))
