module correlator;

import std.container;
import std.complex;
import std.exception;
import carbon.math;
import std.range;
import std.algorithm;

import dffdd.dsp.convolution;
import dffdd.utils.fft;
import std.meta;
import std.stdio;
import std.typecons;


ConvResult!ptrdiff_t peakSearch(const(Complex!float)[] needle, const(Complex!float)[] haystack, float dbThr = 30)
{
    immutable blockSize = needle.length;
    enforce(blockSize.isPowOf2, "Invalid Argument: blockSize is not a power number of 2.");

    auto fftw = makeFFTWObject!Complex(blockSize);

    Array!(Complex!float) sendFreq_, recvTime_, recvFreq_, rsltTime_;
    Complex!float[] sendFreq, recvTime, recvFreq, rsltTime;
    foreach(varname; AliasSeq!("sendFreq", "recvTime", "recvFreq", "rsltTime")){
        mixin(varname~"_") = Array!(Complex!float)(Complex!float(0, 0).repeat.take(blockSize));
        mixin(varname ~ ` = (&(` ~ varname ~ `_[0]))[0 .. blockSize];`);
    }

    .fft!float(fftw, needle, sendFreq);

    // 事前にrecvTimeの後半に信号を詰めておく
    recvTime[$/2 .. $] = haystack[0 .. blockSize / 2];
    haystack = haystack[blockSize / 2 .. $];

    size_t iterIdx = 0;
    while(haystack.length >= blockSize / 2)
    {
        // recvTimeを半分つめて，後ろに次の信号を格納
        recvTime[0 .. $/2] = recvTime[$/2 .. $];
        recvTime[$/2 .. $] = haystack[0 .. blockSize / 2];
        haystack = haystack[blockSize / 2 .. $];

        .fft!float(fftw, recvTime, recvFreq);

        ConvResult!size_t res = fftw.findConvolutionPeak(sendFreq, recvFreq, rsltTime, dbThr, true);
        if(!res.index.isNull){
            typeof(return) dst;
            dst.snr = res.snr;
            writefln("iteration %s: find offset: %s -> %s, snr: %s.", iterIdx, iterIdx*blockSize/2+res.index.get, iterIdx*blockSize/2+res.index.get, res.snr);
            dst.index = Nullable!ptrdiff_t(iterIdx*blockSize/2+res.index.get);
            return dst;
        }

        ++iterIdx;
    }

    ConvResult!ptrdiff_t null_;
    return null_;
}


//void readRawComplex(File file, cfloat[] buf, Complex!float[] output)
//{
//    enforce(file.rawRead(buf).length == buf.length);
//    buf.copyToComplexArray(output);
//}


//void readRawComplexHalf(File file, cfloat[] buf, Complex!float[] output)
//{
//    output[0 .. $/2] = output[$/2 .. $];
//    readRawComplex(file, buf[$/2 .. $], output[$/2 .. $]);
//}


//void copyToComplexArray(in cfloat[] input, Complex!float[] output)
//in{
//    assert(input.length <= output.length);
//}
//body{
//    foreach(i, e; input) output[i] = complex!float(e.re, e.im);
//}
