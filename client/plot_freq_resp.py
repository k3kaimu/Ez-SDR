import multiusrp
import numpy as np
import time
import matplotlib.pyplot as plt
import datetime

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 1     # 送信機2台
nRXUSRP = 1     # 受信機2台

bpsk_constellation = np.array([1+0j, -1+0j])
qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)

nOS = 4                 # OFDMのオーバーサンプリング率
nSC = 256               # OFDMの有効サブキャリア数
nFFT = nSC * nOS        # OFDM変調のFFTサイズ
nCP = nFFT//4           # CPのサイズ


# OFDM変調
def mod_ofdm(scs):
    nSYM = len(scs)//nSC
    scs = scs.reshape([nSYM, nSC])
    scs = np.hstack((np.zeros((nSYM,1)), scs[:,:nSC//2], np.zeros((nSYM, nFFT - nSC - 1)), scs[:,nSC//2:]))
    sym = np.fft.ifft(scs, norm="ortho")        # IFFT
    sym = np.hstack((sym[:,nFFT-nCP:], sym))    # add CP
    return sym.reshape((nFFT+nCP)*nSYM)


# OFDM復調
def demod_ofdm(sym):
    nSYM = len(sym)//(nFFT + nCP)
    sym = sym.reshape([nSYM, nFFT + nCP])
    sym = sym[:,nCP:]                           # remove CP
    scs = np.fft.fft(sym, norm="ortho")         # FFT
    scs = np.hstack((scs[:,1:nSC//2+1], scs[:,nFFT-nSC//2:]))
    return scs.reshape(nSYM * nSC)


def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    idx = np.argmax(rxy)

    if idx > len(tx)//2:
        return -(len(tx) - idx)
    else:
        return idx


with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    # 1回の送受信で100シンボル伝送する
    nTxSYM = 100

    # BPSK,QPSK変調したサブキャリア
    subcarriers = [
        np.random.choice(qpsk_constellation, nSC*nTxSYM),
    ]

    # OFDM変調した信号
    modulated = mod_ofdm(subcarriers[0])
    numModSig = len(modulated)

    modulated = [
        np.hstack((modulated, np.zeros(1024)))
    ]

    usrp.changeRxAlignSize(len(modulated[0]))   # USRPの受信バッファのサイズを信号長に合わせる
    usrp.transmit(modulated)                    # 送信信号を設定する
    usrp.sync()

    time_start = time.time()
    dt_now = datetime.datetime.now()
    timelist = []
    chresplist = []

    for iTrial in range(1000):
        time.sleep(10)

        # チャネル推定用に受信
        recv = usrp.receive(len(modulated[0]))[0]

        # 遅延時間計算
        numDelay = calc_delay(modulated, recv)
        print("delay = {} samples".format(numDelay))

        # 切り出す
        demodulated = demod_ofdm(recv[numDelay : numDelay + numModSig])

        # チャネル推定
        channel_resp = np.mean((demodulated[0] / subcarriers[0]).reshape([nTxSYM, nSC]), axis=0)

        chresplist.append(channel_resp)
        timelist.append(time.time() - time_start)

    chresplist = np.array(chresplist)
    for k in [1, 10, 20, 40, 60]:
        fig = plt.figure()
        ax = fig.add_subplot(1, 1, 1)
        ax.plot(timelist, np.angle(chresplist[:, k]))
        ax.set_ylim([-3.2, 3.2])
        ax.set_xlabel("Time [s]")
        ax.set_ylabel("Phase of the {}th Subcarrier (rad)".format(k))
        plt.savefig("freq_resp_angle_k{}_{}.pdf".format(k, dt_now.strftime('%Y%m%d_%H%M%S')))
