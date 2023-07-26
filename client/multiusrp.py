import socket
import numpy as np
import scipy
from collections import namedtuple
import sigdatafmt


class SimpleClient:
    def __init__(self, ipaddr, port, nTXUSRPs, nRXUSRPs):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.ipaddr = ipaddr
        self.port = port
        # self.mockserver = None
        if type(nTXUSRPs) is int:
            self.nTXUSRPs = [nTXUSRPs]
        else:
            self.nTXUSRPs = nTXUSRPs
        
        if type(nRXUSRPs) is int:
            self.nRXUSRPs = [nRXUSRPs]
        else:
            self.nRXUSRPs = nRXUSRPs

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

    def transmit(self, signals, **kwargs):
        tidx = kwargs.get("tidx", 0)

        self.sock.sendall(b'T');
        sigdatafmt.writeInt32ToSock(self.sock, tidx)
        for i in range(self.nTXUSRPs[tidx]):
            if i == 0:
                sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=True)
            else:
                sigdatafmt.writeSignalToSock(self.sock, signals[i], withHeader=False)

    def receive(self, nsamples, **kwargs):
        ridx = kwargs.get("ridx", 0)

        if ('onlyResponse' not in kwargs) or (not kwargs['onlyResponse']):
            self.sock.sendall(b'R');
            sigdatafmt.writeInt32ToSock(self.sock, ridx)
            sigdatafmt.writeInt32ToSock(self.sock, nsamples)

        if ('onlyRequest' not in kwargs) or (not kwargs['onlyRequest']):
            ret = []
            for i in range(self.nRXUSRPs[ridx]):
                ret.append(sigdatafmt.readSignalFromSock(self.sock, nsamples))
            
            return np.array(ret)
        else:
            return None

    def receiveNBRequest(self, nsamples, **kwargs):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'r');
        sigdatafmt.writeInt32ToSock(self.sock, ridx)
        sigdatafmt.writeInt32ToSock(self.sock, nsamples)
    
    def receiveNBResponse(self, **kwargs):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'g');
        sigdatafmt.writeInt32ToSock(self.sock, ridx)
        nsamples = sigdatafmt.readInt32FromSock(self.sock)
        if nsamples == 0:
            return (False, np.array([]))

        ret = []
        for i in range(self.nRXUSRPs[ridx]):
            ret.append(sigdatafmt.readSignalFromSock(self.sock, nsamples))
        
        return (True, np.array(ret))

    def receiveNBResponseToFn(self, fn, bufferSize=0, **kwargs):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'g');
        sigdatafmt.writeInt32ToSock(ridx)
        nsamples = sigdatafmt.readInt32FromSock(self.sock)
        if nsamples == 0:
            return False

        if bufferSize == 0:
            for i in range(self.nRXUSRPs[ridx]):
                fn(i, 0, sigdatafmt.readSignalFromSock(self.sock, nsamples))
        else:
            for i in range(self.nRXUSRPs[ridx]):
                nrecv = 0
                j = 0
                while nrecv < nsamples:
                    psize = min(bufferSize, nsamples - nrecv)
                    fn(i, j, sigdatafmt.readSignalFromSock(self.sock, psize))
                    nrecv += psize
                    j += 1

        return True

    def shutdown(self):
        self.sock.sendall(b'Q');

    def changeRxAlignSize(self, newAlign, **kwargs):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'A')
        sigdatafmt.writeInt32ToSock(self.sock, ridx)
        sigdatafmt.writeInt32ToSock(self.sock, newAlign)
    
    def skipRx(self, delay):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'D')
        sigdatafmt.writeInt32ToSock(self.sock, ridx)
        sigdatafmt.writeInt32ToSock(self.sock, delay)

    def sync(self):
        self.sock.sendall(b'S')

    def rxPowerThr(self, p, m):
        ridx = kwargs.get("ridx", 0)
        self.sock.sendall(b'p')
        sigdatafmt.writeInt32ToSock(self.sock, ridx)
        sigdatafmt.writeFloat32ToSock(self.sock, p)
        sigdatafmt.writeFloat32ToSock(self.sock, m)

    def clearCmdQueue(self):
        self.sock.sendall(b'q')


class SimpleMockClient:
    def __init__(self, nTXUSRP, nRXUSRP, impRespMatrix=np.array([[[1]]]), SIGMA2=0, delay=0):
        self.nTXUSRP = nTXUSRP
        self.nRXUSRP = nRXUSRP
        self.sampleIndex = 0
        self.alignSize = 4096
        self.txsignals = np.zeros((nTXUSRP, 4096), dtype=np.complex64)
        self.impRespMatrix = impRespMatrix
        self.rxsignals = np.zeros((nRXUSRP, 4096), dtype=np.complex64)
        self.SIGMA2 = SIGMA2
        self.delay = delay
    
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
                irFreq = np.fft.fft(np.hstack((np.zeros(self.delay), self.impRespMatrix[i, j], np.zeros(N)))[:N])
                rxFreq = txFreq * irFreq
                self.rxsignals[j,:] = self.rxsignals[j,:] + np.fft.ifft(rxFreq)
    
    def transmit(self, signals):
        self.txsignals = signals
        self.makeRxSignals()

    def receive(self, nsamples, **kwargs):
        if ('onlyRequest' not in kwargs) or (not kwargs['onlyRequest']):
            return self.receiveImpl(nsamples)
        else:
            return None
    
    def receiveImpl(self, nsamples):
        dst = np.zeros((self.nRXUSRP, nsamples), dtype=np.complex128)

        # 次のアライメント（受信バッファの先頭）を計算する
        self.sampleIndex += self.alignSize - (self.sampleIndex % self.alignSize)

        N = len(self.rxsignals[0])
        D = self.sampleIndex % N
        for i in range(self.nRXUSRP):
            dst[i,:] = np.tile(self.rxsignals[i], (D + nsamples)//N + 1)[D : D+nsamples]
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
