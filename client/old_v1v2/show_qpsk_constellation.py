import sys
sys.path.append("..")

import multiusrp
import numpy as np
import time
import matplotlib.pyplot as plt
from matplotlib import animation
import scipy

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 1
nRXUSRP = 1

nSamples = 2**10

# bpsk_constellation = np.array([1+0j, -1+0j])
qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)


def make_rrc_filter(Ntaps, Nos, beta):
    ts = np.linspace(-Ntaps/2, Ntaps/2-1, Ntaps)
    ps = ts / Nos
    hs = np.sin(np.pi * ps * (1 - beta)) + 4 * beta * ps * np.cos(np.pi * ps * (1 + beta))
    hs = hs / Nos / (np.pi * ps * (1 - (4 * beta * ps)**2))
    hs[Ntaps//2] = 1 / Nos * (1 + beta * (4 / np.pi - 1))
    hs[np.abs(ts)==(Nos / 4 / beta)] = beta / Nos / np.sqrt(2) * ((1 + 2/np.pi) * np.sin(np.pi/(4*beta)) + (1 - 2/np.pi) * np.cos(np.pi/(4*beta)))
    return hs


with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    signals = [
        np.repeat(np.random.choice(qpsk_constellation, nSamples//8), 8) * 0.1,
    ]

    rrcImpResp = make_rrc_filter(16, 8, 0.5)
    print(rrcImpResp)

    signals = [
        scipy.signal.lfilter(rrcImpResp, 1, signals[0])
    ]

    usrp.changeRxAlignSize(nSamples)
    usrp.transmit(signals)
    usrp.sync()

    fig = plt.figure()
    ax1 = fig.add_subplot(1, 2, 1)
    ax2 = fig.add_subplot(1, 2, 2)

    frame_count = 0
    starttime = 0
    recv100 = None
    usrp.receive(nSamples * 100, onlyRequest=True)
    mean_psd = np.zeros(nSamples, dtype=np.double)
    
    def plot(data):
        global frame_count
        global starttime
        global recv100
        global mean_psd

        if frame_count == 0:
            recv100 = usrp.receive(nSamples * 100, onlyResponse=True)[0]
            usrp.receive(nSamples * 100, onlyRequest=True)
            starttime = time.time()
        elif frame_count % 100 == 0:
            recv100 = usrp.receive(nSamples * 100, onlyResponse=True)[0]
            usrp.receive(nSamples * 100, onlyRequest=True)
            print("{} fps".format(frame_count / (time.time() - starttime)))

        # plt.cla()
        ax1.clear()
        ax2.clear()
        idx = frame_count % 100
        recv = recv100[nSamples*idx : nSamples*(idx+1)]


        if frame_count == 0:
            mean_psd = np.abs(np.fft.fftshift(np.fft.fft(recv * np.blackman(nSamples))))**2
        else:
            mean_psd = mean_psd * 0.9 + np.abs(np.fft.fftshift(np.fft.fft(recv)))**2 * 0.1

        ax1.scatter(np.real(recv), np.imag(recv))
        ax2.plot(np.linspace(-0.5, 0.5, nSamples), 10 * np.log10(mean_psd))
        # ax2.set_ylim([-70, 0])

        frame_count += 1
    
    ani = animation.FuncAnimation(fig, plot, interval=50, blit=False)
    plt.show()
