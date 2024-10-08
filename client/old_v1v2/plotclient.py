import sys
sys.path.append("..")

import multiusrp
import numpy as np
import time

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8889;
nTXUSRP = 1
nRXUSRP = 1
nSamples = 2**13
bpsk_constellation = np.array([1, -1])


if __name__ == "__main__":
    with multiusrp.SimpleClientWithTimeSeriesPlot(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:
        signals = [
            np.tile(np.linspace(0, 1, nSamples//8), 8)
        ]

        rxAlignSize = nSamples
        usrp.changeRxAlignSize(rxAlignSize)
        usrp.transmit(signals)
        # usrp.sync()

        for _ in range(1000):
            recv1 = usrp.receive(nSamples)
