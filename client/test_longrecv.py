import multiusrp
import numpy as np
import time
import datetime
import os

# サーバーIPとポート番号
IPADDR = "127.0.0.1";
PORT = 8888;

nTXUSRP = 1     # 送信機1台
nRXUSRP = 1     # 受信機1台

nSamples = 100*1024    # 1回当たりのサンプル数 100k
interval = 10*60        # 10分ごとに取得

result_dir = "recvdata"

qpsk_constellation = np.array([1+1j, -1+1j, -1-1j, 1-1j]) / np.sqrt(2)

def calc_delay(tx, rx):
    tx_freq = np.fft.fft(tx)
    rx_freq = np.fft.fft(rx)
    rxy = np.abs(np.fft.ifft(np.conj(tx_freq) * rx_freq))
    return np.argmax(rxy)

# gdb --args ./multiusrp --tx-args="addr0=192.168.10.211" --rx-args="addr0=192.168.10.213" --tx-rate=1e6 --rx-rate=1e6 --tx-freq=2.45e9 --rx-freq=2.45e9 --tx-gain=10 --rx-gain=30 --clockref=external --timeref=external --timesync=true --tx-channels="0" --rx-channels="0" --port=8888
with multiusrp.SimpleClient(IPADDR, PORT, nTXUSRP, nRXUSRP) as usrp:
    signals = [
        np.repeat(np.random.choice(qpsk_constellation, nSamples//4), 4),
    ]
    usrp.transmit(signals)
    usrp.changeRxAlignSize(nSamples)
    usrp.sync()

    while True:
        # USRP1台から信号を取得
        recv = usrp.receive(nSamples)[0]

        # 現在時間を取得してファイル名を構築
        filename = datetime.datetime.now().strftime('%Y%m%d_%H%M%S.dat')
        filepath = os.path.join(result_dir, filename)

        # 信号を保存
        recv.tofile(filepath)
        print("save to {}, delay = {} samples".format(filepath, calc_delay(signals[0], recv)))

        # 次の受信時間まで待つ
        time.sleep(interval)
