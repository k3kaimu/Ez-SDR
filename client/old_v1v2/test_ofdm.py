import multiusrp
import numpy as np
import time

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 2     # 送信機2台
nRXUSRP = 2     # 受信機2台

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


with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:

    # 1回の送受信で100シンボル伝送する
    nTxSYM = 100

    # BPSK,QPSK変調したサブキャリア
    subcarriers = [
        np.random.choice(bpsk_constellation, nSC*nTxSYM),
        np.random.choice(qpsk_constellation, nSC*nTxSYM),
    ]

    # OFDM変調した信号
    modulated = [
        mod_ofdm(subcarriers[0]),
        mod_ofdm(subcarriers[1]),
    ]

    usrp.changeRxAlignSize(len(modulated[0]))   # USRPの受信バッファのサイズを信号長に合わせる
    usrp.transmit(modulated)                    # 送信信号を設定する
    usrp.sync()                                 # 送受信機で同期を取る

    # チャネル推定用に受信
    recv = usrp.receive(len(modulated[0]))

    demodulated = [
        demod_ofdm(recv[0]),
        demod_ofdm(recv[1]),
    ]

    # チャネル推定
    channel_resp = [
        np.mean((demodulated[0] / subcarriers[0]).reshape([nTxSYM, nSC]), axis=0),
        np.mean((demodulated[1] / subcarriers[1]).reshape([nTxSYM, nSC]), axis=0),
    ]

    # 測定用に受信
    recv = usrp.receive(len(modulated[0]))

    # 復調&等化
    demodulated = [
        demod_ofdm(recv[0]) / np.tile(channel_resp[0], nTxSYM),
        demod_ofdm(recv[1]) / np.tile(channel_resp[1], nTxSYM),
    ]

    # 受信結果表示（先頭1シンボルだけ）
    for i in range(nSC):
        print("{},{},{},{},{}".format(i, np.real(demodulated[0][i]), np.imag(demodulated[0][i]), np.real(demodulated[1][i]), np.imag(demodulated[1][i])))
