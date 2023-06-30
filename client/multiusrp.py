import socket
import numpy as np
import scipy
from collections import namedtuple
import sigdatafmt


class SimpleClient:
    def __init__(self, ipaddr, port, nTXUSRP, nRXUSRP):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.ipaddr = ipaddr
        self.port = port
        # self.mockserver = None
        self.nTXUSRP = nTXUSRP
        self.nRXUSRP = nRXUSRP
        # self.doClip = True
        # self.txMaxPowerdBm = None      # I/Q相両方が32767のときの送信電力
        # self.rxMaxPowerdBm = None      # I/Q相両方が32767のときの受信電力

    def __enter__(self):
        if self.ipaddr is not None:
            self.sock.__enter__();
            self.sock.connect((self.ipaddr, self.port));
        return self

    def __exit__(self, *args):
        if self.ipaddr is not None:
            self.sock.close()
            self.sock.__exit__(args)

    def connect(self):
        if self.ipaddr is not None:
            self.sock.connect((self.ipaddr, self.port));

    def transmit(self, signals):
        self.sock.sendall(b'T');
        for i in range(self.nTXUSRP):
            if i == 0:
                sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=True)
            else:
                sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=False)

    def receive(self, nsamples, **kwargs):
        if ('onlyResponse' not in kwargs) or (not kwargs['onlyResponse']):
            self.sock.sendall(b'R');
            sigdatafmt.writeInt32ToSock(self.sock, nsamples)

        if ('onlyRequest' not in kwargs) or (not kwargs['onlyRequest']):
            ret = []
            for i in range(self.nRXUSRP):
                ret.append(sigdatafmt.readSignalFromSock(self.sock, nsamples))
            
            return np.array(ret)
        else:
            return None

    def receiveNBRequest(self, nsamples):
        self.sock.sendall(b'r');
        sigdatafmt.writeInt32ToSock(self.sock, nsamples)
    
    def receiveNBResponse(self):
        self.sock.sendall(b'g');
        nsamples = sigdatafmt.readInt32FromSock(self.sock)
        if nsamples == 0:
            return (False, np.array([]))

        ret = []
        for i in range(self.nRXUSRP):
            ret.append(sigdatafmt.readSignalFromSock(self.sock, nsamples))
        
        return (True, np.array(ret))

    def shutdown(self):
        self.sock.sendall(b'Q');

    def changeRxAlignSize(self, newAlign):
        self.sock.sendall(b'A')
        sigdatafmt.writeInt32ToSock(self.sock, newAlign)
    
    def skipRx(self, delay):
        self.sock.sendall(b'D')
        sigdatafmt.writeInt32ToSock(self.sock, delay)

    def sync(self):
        self.sock.sendall(b'S')

    def rxPowerThr(self, p, m):
        self.sock.sendall(b'p')
        sigdatafmt.writeFloat32ToSock(self.sock, p)
        sigdatafmt.writeFloat32ToSock(self.sock, m)

    def clearCmdQueue(self):
        self.sock.sendall(b'q')


class SimpleMockClient:
    def __init__(self, nTXUSRP, nRXUSRP, impRespMatrix, SIGMA2):
        self.nTXUSRP = nTXUSRP
        self.nRXUSRP = nRXUSRP
        self.sampleIndex = 0
        self.alignSize = 4096
        self.txsignals = np.zeros((nTXUSRP, 4096), dtype=np.complex64)
        self.impRespMatrix = impRespMatrix
        self.rxsignals = np.zeros((nRXUSRP, 4096), dtype=np.complex64)
        self.SIGMA2 = SIGMA2
    
    def __enter__(self):
        self.sampleIndex = 0
        self.alignSize = 4096
        return self

    def __exit__(self, *args):
        pass
    
    def connect(self):
        pass

    def makeRxSignals(self):
        self.rxsignals = np.zeros((self.nRXUSRP, len(self.txsignals[0])), dtype=np.complex64)
        N = len(self.txsignals[0])
        for i in range(self.nTXUSRP):
            for j in range(self.nRXUSRP):
                txFreq = np.fft.fft(self.txsignals[i])
                irFreq = np.fft.fft(np.hstack((self.impRespMatrix[i, j], np.zeros(N)))[:N])
                rxFreq = txFreq * irFreq
                self.rxsignals[j,:] = self.rxsignals[j,:] + np.fft.ifft(rxFreq)
    
    def transmit(self, signals):
        self.txsignals = signals
        self.makeRxSignals()

    def receive(self, nsamples, **kwargs):
        if ('onlyResponse' not in kwargs) or (not kwargs['onlyResponse']):
            return None

        if ('onlyRequest' not in kwargs) or (not kwargs['onlyRequest']):
            return self.receiveImpl(nsamples)
        else:
            return None
    
    def receiveImpl(self, nsamples):
        dst = np.zeros((self.nRXUSRP, nsamples), dtype=np.complex128)

        # 次のアライメント（受信バッファの先頭）を計算する
        self.sampleIndex = self.sampleIndex + self.alignSize - (self.sampleIndex % self.alignSize)

        N = len(self.rxsignals[0])
        D = self.sampleIndex % N
        for i in range(self.nRXUSRP):
            dst[i,:] = np.tile(self.rxsignals[i], (D + nsamples)//N + 1)[:nsamples]
            dst[i,:] += np.random.normal(0, np.sqrt(self.SIGMA2/2), size=nsamples) + np.random.normal(0, np.sqrt(self.SIGMA2/2), size=nsamples)*1j

        self.sampleIndex += nsamples
        return dst

    def shutdown(self):
        pass
    
    def changeRxAlignSize(self, newAlign):
        self.alignSize = newAlign

    def skipRx(self, delay):
        D = delay % N
        for i in range(self.nTXUSRP):
            self.signals[i] = np.roll(self.signals[i], -D)

    def sync(self):
        self.sampleIndex = 0
