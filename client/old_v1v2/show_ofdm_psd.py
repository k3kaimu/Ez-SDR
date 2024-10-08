import sys
sys.path.append("..")

import multiusrp
import numpy as np
import time
import matplotlib.pyplot as plt
from matplotlib import animation
import scipy.signal

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 1
nRXUSRP = 1

txGain = 0.1

bpsk_constellation = np.array([1+0j, -1+0j])

nOS = 4                 # OFDMのオーバーサンプリング率
nSC = 256               # OFDMの有効サブキャリア数
nFFT = nSC * nOS        # OFDM変調のFFTサイズ
nCP = 0                 # CPのサイズ

# OFDM変調
def mod_ofdm(scs):
    nSYM = len(scs)//nSC
    scs = scs.reshape([nSYM, nSC])
    scs = np.hstack((np.zeros((nSYM,1)), scs[:,:nSC//2], np.zeros((nSYM, nFFT - nSC - 1)), scs[:,nSC//2:]))
    sym = np.fft.ifft(scs, norm="ortho")        # IFFT
    # sym = np.hstack((sym[:,nFFT-nCP:], sym))    # add CP
    return sym.reshape((nFFT+nCP)*nSYM)

# OFDM復調
def demod_ofdm(sym, returnAllSC = False):
    nSYM = len(sym)//(nFFT + nCP)
    sym = sym.reshape([nSYM, nFFT + nCP])
    sym = sym[:,nCP:]                           # remove CP
    scs = np.fft.fft(sym, norm="ortho")         # FFT
    return scs

    

# BPSK,QPSK変調したサブキャリア
subcarriers = np.random.choice(bpsk_constellation, nSC)

# OFDM変調した信号
modulated = np.tile(mod_ofdm(subcarriers) * txGain, 100)

with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    usrp.transmit([modulated])

    fig = plt.figure()
    ax1 = fig.add_subplot(1, 2, 1)
    ax2 = fig.add_subplot(1, 2, 2)

    nSamples = nFFT * 100

    frame_count = 0
    mean_psd = np.zeros(nFFT, dtype=np.double)

    def plot(data):
        global frame_count
        global mean_psd

        recvSignal = usrp.receive(nSamples)[0]
        sp = np.mean(np.abs(demod_ofdm(recvSignal))**2, axis=0)
        sp = np.fft.fftshift(sp)

        # plt.cla()
        ax1.clear()
        ax2.clear()

        ax2.plot(np.linspace(-nOS/2, nOS/2, nFFT), 10 * np.log10(sp))
        frame_count += 1
    
    ani = animation.FuncAnimation(fig, plot, interval=50, blit=False)
    plt.show()
