//
// Copyright 2010-2012,2014-2015 Ettus Research LLC
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import std.complex;
import std.math;
import std.stdio;
import std.path;
import std.format;
import std.string;
import std.getopt;
import std.range;
import std.algorithm;
import std.conv;
import std.exception;
import std.meta;
import uhd.usrp;
import uhd.capi;
import uhd.utils;
import core.time;
import core.thread;
import core.atomic;
import core.memory;

import deimos.zmq.zmq;
import zhelper;
import correlator;
import dffdd.utils.fft;

import lock_free.rwqueue;


enum size_t SYMBOL_SIZE = 4096;
enum size_t NUM_TRAINING_SYMBOL = 32;


/***********************************************************************
 * Signal handlers
 **********************************************************************/
shared bool stop_signal_called = false;
extern(C) void sig_int_handler(int) nothrow @nogc @system
{
    stop_signal_called = true;
}

/***********************************************************************
 * Utilities
 **********************************************************************/
//! Change to filename, e.g. from usrp_samples.dat to usrp_samples.00.dat,
//  but only if multiple names are to be generated.
string generate_out_filename(string base_fn, size_t n_names, size_t this_name)
{
    if (n_names == 1) {
        return base_fn;
    }

    return base_fn.setExtension(format("%02d.%s", base_fn.extension));
}


/***********************************************************************
 * transmit_worker function
 * A function to be used as a boost::thread_group thread for transmitting
 **********************************************************************/
void transmit_worker(
    ref shared(RWQueue!(const(shared(Complex!float))[][2])) txSignalQueue,
    ref TxStreamer tx_streamer,
    ref TxMetaData metadata
){
    Complex!float[][2] initialBuffers;
    foreach(ch; 0 .. 2){
        initialBuffers[ch] = new Complex!float[4096];
        foreach(ref e; initialBuffers[ch])
            e = Complex!float(0, 0);
    }

    TxMetaData afterFirstMD = TxMetaData(false, 0, 0, false, false);
    TxMetaData endMD = TxMetaData(false, 0, 0, false, true);
    VUHDException error;

    tx_streamer.send(cast(Complex!float[][])[null,null], metadata, 0.1);
    const(shared(Complex!float))[][2] txbufs;
    const(shared(Complex!float))[][2] lastTxSignal = cast(shared)initialBuffers;
    () @nogc {
        //send data until the signal handler gets called
        while(!stop_signal_called){
            if(txbufs[0].length == 0){
                if(txSignalQueue.empty)
                    txbufs = lastTxSignal;
                else{
                    txbufs = txSignalQueue.pop();
                    lastTxSignal = txbufs;
                }
            }

            //send the entire contents of the buffer
            size_t txsize;
            if(auto err = tx_streamer.send(cast(Complex!float[][])txbufs[], afterFirstMD, 0.1, txsize)){
                error = err;
                return;
            }

            foreach(ch; 0 .. 2)
                txbufs[ch] = txbufs[ch][txsize .. $];
        }
    }();

    //send a mini EOB packet
    foreach(ref e; txbufs) e.length = 0;
    tx_streamer.send(cast(Complex!float[][])txbufs[], endMD, 0.1);

    if(error)
        throw error.makeException();
}


/***********************************************************************
 * recv_to_file function
 **********************************************************************/
void recv_to_file(
    ref USRP usrp,
    string cpu_format,
    string wire_format,
    string file,
    float settling_time,
    ref shared RWQueue!(Complex!float[]) supplyBufferQueue,
    ref shared RWQueue!(Complex!float[]) reportBufferQueue,
    ref shared RWQueue!(double) powerQueue,
){
    int num_total_samps = 0;
    //create a receive streamer
    writeln("CPU_FORMAT: ", cpu_format);
    writeln("WIRE_FORMAT: ", wire_format);
    StreamArgs stream_args = StreamArgs(cpu_format, wire_format, "", [0]);
    RxStreamer rx_stream = usrp.makeRxStreamer(stream_args);

    // Prepare buffers for received samples and metadata
    RxMetaData md = makeRxMetaData();
    Complex!float[] garbageBuffer = new Complex!float[4096];

    // Create one ofstream object per channel
    import core.stdc.stdio : FILE, fwrite, fopen, fclose;
    string this_filename = file;
    FILE* outfile = fopen(this_filename.toStringz, "wb");
    if(outfile is null) throw new Exception("Cannot open file: " ~ this_filename);
    scope(exit){
        fclose(outfile);
        outfile = null;
    }

    bool overflow_message = true;
    float timeout = settling_time + 0.1f; //expected settling time + padding for first recv

    //setup streaming
    StreamCommand stream_cmd = StreamCommand.startContinuous;
    stream_cmd.streamNow = true;
    stream_cmd.timeSpec = (cast(long)floor(settling_time*1E6)).usecs;
    rx_stream.issue(stream_cmd);


    shared(Complex!float)[] nowTargetBuffer;
    shared(Complex!float)[] targetBuffer;
    VUHDException error;
    () @nogc {
        while(! stop_signal_called) {
            size_t num_rx_samps;
            if(auto err = rx_stream.recv(garbageBuffer, md, timeout, num_rx_samps)){
                error = err;
                return;
            }
            immutable received_samples = num_rx_samps;
            timeout = 0.1f; //small timeout for subsequent recv

            md.ErrorCode errorCode;
            if(auto uhderr = md.getErrorCode(errorCode)){
                error = uhderr;
                return;
            }
            if (errorCode == md.ErrorCode.TIMEOUT) {
                import core.stdc.stdio : puts;
                puts("Timeout while streaming");
                break;
            }
            if (errorCode == md.ErrorCode.OVERFLOW) {
                if (overflow_message){
                    import core.stdc.stdio : fprintf, stderr;
                    overflow_message = false;
                    fprintf(stderr, "Got an overflow indication.");
                }
                continue;
            }
            if (errorCode != md.ErrorCode.NONE){
                import core.stdc.stdio : fprintf, stderr;
                md.printError();
                fprintf(stderr, "Unknown error.");
            }

            {
                while(num_rx_samps > 0){
                    if(nowTargetBuffer is null) {
                        if(! supplyBufferQueue.empty) {
                            nowTargetBuffer = supplyBufferQueue.pop();
                            targetBuffer = nowTargetBuffer;
                        }else{
                            break;
                        }
                    }

                    size_t len = min(targetBuffer.length, num_rx_samps);
                    targetBuffer[0 .. len] = garbageBuffer[0 .. len];
                    targetBuffer = targetBuffer[len .. $];
                    num_rx_samps -= len;
                    if(targetBuffer.length == 0){
                        reportBufferQueue.push(nowTargetBuffer);
                        nowTargetBuffer = null;
                        targetBuffer = null;
                    }
                }
            }

            // fwrite(cast(Complex!float*)garbageBuffer.ptr, (Complex!float).sizeof, received_samples, outfile);
            double sigpower = garbageBuffer[0 .. min(received_samples, 4096)].map!`cast(real)(a.re^^2 + a.im^^2)`.sum();
            if(! powerQueue.full) powerQueue.push(sigpower);
        }
    }();

    // Shut down receiver
    rx_stream.issue(StreamCommand.stopContinuous);

    if(error)
        throw error.makeException();
}


/***********************************************************************
 * Main function
 **********************************************************************/
void main(string[] args){
    // uhd_set_thread_priority(uhd_default_thread_priority, true);

    //transmit variables to be set by po
    string[] txfiles;
    string tx_args, /*wave_type,*/ tx_ant, tx_subdev, ref_, otw, tx_channels;
    double tx_rate, tx_freq, tx_gain, /*wave_freq,*/ tx_bw;
    float ampl;

    //receive variables to be set by po
    string rx_args, file, type, rx_ant, rx_subdev, rx_channels;
    size_t total_num_samps, spb;
    double rx_rate, rx_freq, rx_gain, rx_bw;
    float settling;
    bool tx_int_n, rx_int_n;

    // set default values
    file = "usrp_samples.dat";
    type = "short";
    ampl = 0.3;
    settling = 1;
    otw = "sc16";
    // wave_freq = 0;

    auto helpInformation = getopt(
        args,
        "tx-args",  "uhd transmit device address args",             &tx_args,
        "rx-args",  "uhd receive device address args",              &rx_args,
        "file",     "name of the file to write binary samples to",  &file,
        "type",     "sample type in file: double, float, or short", &type,
        "nsamps",   "total number of samples to receive",           &total_num_samps,
        "settling", "total time (seconds) before receiving",        &settling,
        "tx-rate",  "rate of transmit outgoing samples",            &tx_rate,
        "rx-rate",  "rate of receive incoming samples",             &rx_rate,
        "tx-freq",  "transmit RF center frequency in Hz",           &tx_freq,
        "rx-freq",  "receive RF center frequency in Hz",            &rx_freq,
        "ampl",     "amplitude of the waveform [0 to 0.7]",         &ampl,
        "tx-gain",  "gain for the transmit RF chain",               &tx_gain,
        "rx-gain",  "gain for the receive RF chain",                &rx_gain,
        "tx-ant",   "transmit antenna selection",                   &tx_ant,
        "rx-ant",   "receive antenna selection",                    &rx_ant,
        "tx-subdev",    "transmit subdevice specification",         &tx_subdev,
        "rx-subdev",    "receive subdevice specification",          &rx_subdev,
        "tx-bw",    "analog transmit filter bandwidth in Hz",       &tx_bw,
        "rx-bw",    "analog receive filter bandwidth in Hz",        &rx_bw,
        "txfiles",  "transmit waveform file",                       &txfiles, 
        // "wave-type",    "waveform type (CONST, SQUARE, RAMP, SINE)",    &wave_type,
        // "wave-freq",    "waveform frequency in Hz",                 &wave_freq,
        "ref",      "clock reference (internal, external, mimo)",   &ref_,
        "otw",      "specify the over-the-wire sample mode",        &otw,
        "tx-channels",  `which TX channel(s) to use (specify "0", "1", "0,1", etc)`,    &tx_channels,
        "rx-channels",  `which RX channel(s) to use (specify "0", "1", "0,1", etc)`,    &rx_channels,
        "tx_int_n", "tune USRP TX with integer-N tuing", &tx_int_n,
        "rx_int_n", "tune USRP RX with integer-N tuing", &rx_int_n,
    );

    if(helpInformation.helpWanted){
        defaultGetoptPrinter("UHD TXRX Loopback to File.", helpInformation.options);
        return;
    }

    writefln("Creating the transmit usrp device with: %s...", tx_args);
    USRP tx_usrp = USRP(tx_args);
    writefln("Creating the receive usrp device with: %s...", rx_args);
    USRP rx_usrp = USRP(rx_args);

    immutable(size_t)[] tx_channel_nums = tx_channels.splitter(',').map!(to!size_t).array();
    enforce(tx_channel_nums.length == txfiles.length, "The number of channels is not equal to the number of txfiles.");
    foreach(e; tx_channel_nums) enforce(e < tx_usrp.txNumChannels, "Invalid TX channel(s) specified.");

    immutable(size_t)[] rx_channel_nums = rx_channels.splitter(',').map!(to!size_t).array();
    foreach(e; rx_channel_nums) enforce(e < rx_usrp.rxNumChannels, "Invalid RX channel(s) specified.");

    //Lock mboard clocks
    tx_usrp.clockSource = ref_;
    rx_usrp.clockSource = ref_;
    // rx_usrp.clockSource = "internal";

    //always select the subdevice first, the channel mapping affects the other settings
    if(! tx_subdev.empty) tx_usrp.txSubdevSpec = tx_subdev;
    if(! rx_subdev.empty) rx_usrp.rxSubdevSpec = rx_subdev;

    static if(0){
        writeln("Using TX Device: ", tx_usrp);
        writeln("Using RX Device: ", rx_usrp);
    }

    //set the transmit sample rate
    if (tx_rate.isNaN){
        writeln("Please specify the transmit sample rate with --tx-rate");
        return;
    }

    writefln("Setting TX Rate: %f Msps...", tx_rate/1e6);
    tx_usrp.txRate = tx_rate;
    writefln("Actual TX Rate: %f Msps...", tx_usrp.txRate/1e6);

    //set the receive sample rate
    if (rx_rate.isNaN){
        writeln("Please specify the sample rate with --rx-rate");
        return;
    }
    writefln("Setting RX Rate: %f Msps...", rx_rate/1e6);
    rx_usrp.rxRate = rx_rate;
    writefln("Actual RX Rate: %f Msps...", rx_usrp.rxRate/1e6);

    //set the transmit center frequency
    if (tx_freq.isNaN) {
        writeln("Please specify the transmit center frequency with --tx-freq");
        return;
    }

    // for(size_t ch = 0; ch < tx_channel_nums.size(); ch++) {
    foreach(channel; tx_channel_nums){
        if (tx_channel_nums.length > 1) {
            writefln("Configuring TX Channel %s", channel);
        }
        writefln("Setting TX Freq: %f MHz...", tx_freq/1e6);
        TuneRequest tx_tune_request = TuneRequest(tx_freq);
        if(tx_int_n) tx_tune_request.args = "mode_n=integer";
        tx_usrp.tuneTxFreq(tx_tune_request, channel);
        writefln("Actual TX Freq: %f MHz...", tx_usrp.getTxFreq(channel)/1e6);

        //set the rf gain
        if (! tx_gain.isNaN) {
            writefln("Setting TX Gain: %f dB...", tx_gain);
            tx_usrp.setTxGain(tx_gain, channel);
            writefln("Actual TX Gain: %f dB...", tx_usrp.getTxGain(channel));
        }

        //set the analog frontend filter bandwidth
        if (! tx_bw.isNaN){
            writefln("Setting TX Bandwidth: %f MHz...", tx_bw);
            tx_usrp.setTxBandwidth(tx_bw, channel);
            writefln("Actual TX Bandwidth: %f MHz...", tx_usrp.getTxBandwidth(channel));
        }

        //set the antenna
        if (! tx_ant.empty) tx_usrp.setTxAntenna(tx_ant, channel);
    }

    foreach(channel; rx_channel_nums){
        if (rx_channel_nums.length > 1) {
            writeln("Configuring RX Channel ", channel);
        }

        //set the receive center frequency
        if (rx_freq.isNaN){
            stderr.writeln("Please specify the center frequency with --rx-freq");
            return;
        }
        writefln("Setting RX Freq: %f MHz...", rx_freq/1e6);
        TuneRequest rx_tune_request = TuneRequest(rx_freq);
        if(rx_int_n) rx_tune_request.args = "mode_n=integer";
        rx_usrp.tuneRxFreq(rx_tune_request, channel);
        writefln("Actual RX Freq: %f MHz...", rx_usrp.getRxFreq(channel)/1e6);

        //set the receive rf gain
        if (! rx_gain.isNaN){
            writefln("Setting RX Gain: %f dB...", rx_gain);
            rx_usrp.setRxGain(rx_gain, channel);
            writefln("Actual RX Gain: %f dB...", rx_usrp.getRxGain(channel));
        }

        //set the receive analog frontend filter bandwidth
        if (! rx_bw.isNaN){
            writefln("Setting RX Bandwidth: %f MHz...", rx_bw/1e6);
            rx_usrp.setRxBandwidth(rx_bw, channel);
            writefln("Actual RX Bandwidth: %f MHz...", rx_usrp.getRxBandwidth(channel)/1e6);
        }
    }
    //set the receive antenna
    writeln("DONE");
    if (! rx_ant.empty) rx_usrp.rxAntenna = rx_ant;

    //create a transmit streamer
    //linearly map channels (index0 = channel0, index1 = channel1, ...)
    writeln("Create Streaming Object");
    StreamArgs stream_args = StreamArgs("fc32", otw, "", tx_channel_nums);
    auto tx_stream = tx_usrp.makeTxStreamer(stream_args);

    //setup the metadata flags
    writeln("Make TxMetaData");
    TxMetaData md = TxMetaData(true, 0, 0.1, true, false);

    writeln("Check Ref and LO Lock detect");
    //Check Ref and LO Lock detect
    string[] tx_sensor_names, rx_sensor_names;
    // tx_sensor_names = tx_usrp->get_tx_sensor_names(0);
    // foreach(sensor; tx_usrp.getTxSensorNames(0)) tx_sensor_names ~= sensor.dup;
    foreach(i, ref usrp; AliasSeq!(tx_usrp, rx_usrp)){
        foreach(sname; usrp.getTxSensorNames(0)){
            if(sname == "lo_locked"){
                SensorValue lo_locked = tx_usrp.getTxSensor(sname, 0);
                static if(0) writefln("Checking %s: %s ...", i == 0 ? "TX" : "RX", lo_locked);
                enforce(cast(bool)lo_locked);
            }
        }
    }

    foreach(i, ref usrp; AliasSeq!(tx_usrp, rx_usrp)){
        foreach(sname; usrp.getMboardSensorNames(0)){
            if((ref_ == "mimo" && sname == "mimo_locked") || (ref_ == "external" && sname == "ref_locked")){
                SensorValue locked = tx_usrp.getTxSensor(sname, 0);
                static if(0) writefln("Checking %s: %s ...", i == 0 ? "TX" : "RX", locked);
                enforce(cast(bool)locked);
            }
        }
    }

    if (total_num_samps == 0){
        import core.stdc.signal;
        signal(SIGINT, &sig_int_handler);
        writeln("Press Ctrl + C to stop streaming...");
    }

    //reset usrp time to prepare for transmit/receive
    Thread.sleep(1.seconds);
    tx_usrp.setTimeSource("mimo", 1);
    // writeln("Setting device timestamp to 0...");
    // tx_usrp.setTimeUnknownPPS(0.seconds);

    Thread.sleep(1.seconds);
    scope(exit)
        stop_signal_called = true;
    writeln("START");


    auto fftw = makeFFTWObject!Complex(SYMBOL_SIZE);

    //start transmit worker thread
    // boost::thread_group transmit_thread;
    // transmit_thread.create_thread(boost::bind(&transmit_worker, buff, wave_table, tx_stream, md, step, index, num_channels));
    enforce(txfiles.length == tx_channel_nums.length);
    shared(Complex!float[])[] waveTable;
    foreach(i, filename; txfiles){
        import std.file : read;
        auto signal = cast(Complex!float[])read(filename);
        foreach(ref e; signal) e *= ampl;
        waveTable ~= cast(shared)signal;
        enforce(signal.length == SYMBOL_SIZE);
    }

    Complex!float[] subTxWaveTable = new Complex!float[SYMBOL_SIZE];
    shared(Complex!float[]) zeros = cast(shared)iota(SYMBOL_SIZE).map!(a => Complex!float(0)).array();
    Complex!float[] supplyContinuedBuffer = new Complex!float[SYMBOL_SIZE * 128];
    shared(Complex!float[])[2] trainingSignals = (){
        Complex!float[][2] signals;
        foreach(phase; [0, 1]){
            foreach(i; 0 .. NUM_TRAINING_SYMBOL){
                signals[0] ~= phase == 0 ? waveTable[1] : zeros;
                signals[1] ~= phase == 1 ? waveTable[1] : zeros;
            }
        }

        return cast(shared(Complex!float[])[2])signals;
    }();

    // immutable real inputDeltaTheta = 10.0L / SYMBOL_SIZE * 2*PI;
    // immutable(Complex!float)[] sineWave = (){
    //     Complex!float[] buf;
    //     foreach(i; 0 .. SYMBOL_SIZE)
    //         buf ~= cast(Complex!float)std.complex.expi(inputDeltaTheta * i) * ampl;
    //     return cast(immutable)buf;
    // }();

    shared RWQueue!(const(shared(Complex!float))[][2]) txqueue;
    txqueue.push([waveTable[0], zeros]);
    auto transmit_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            transmit_worker(txqueue, tx_stream, md);
        catch(Exception ex){
            writeln(ex);
        }
    });
    transmit_thread.start();

    //recv to file
    shared RWQueue!(Complex!float[]) supplyBufferQueue;
    shared RWQueue!(Complex!float[]) reportedSignal;
    shared RWQueue!(double) powerQueue;
    auto receive_thread = new Thread(delegate(){
        scope(exit) stop_signal_called = true;

        try
            recv_to_file(rx_usrp, "fc32", otw, file, settling, supplyBufferQueue, reportedSignal, powerQueue);
        catch(Exception ex){
            writeln(ex);
        }
    });
    receive_thread.start();

    // ESTIMATION
    auto printPowerThread = new Thread(delegate() @nogc {
        scope(exit) stop_signal_called = true;

        while(! stop_signal_called) {
            while(powerQueue.empty && ! stop_signal_called)
                Thread.sleep(1.msecs);

            double value = powerQueue.pop();
            double db = 10*log10(value);
            printf("%f\n", db);
            Thread.sleep(200.msecs);
            while(! powerQueue.empty) powerQueue.pop();
        }
    });
    printPowerThread.start();

    GC.disable();
    Thread.sleep(5.seconds);
    // immutable deltaThetaOfFreqOffset = estimateFrequencyOffset(txqueue, supplyBufferQueue, reportedSignal, inputDeltaTheta, sineWave, zeros, supplyContinuedBuffer);
    // writeln("DELTA THETA: ", deltaThetaOfFreqOffset);
    // Thread.sleep(2.seconds);
    estimateAndSetSignal(fftw, txqueue, supplyBufferQueue, reportedSignal,
        cast(Complex!float[][2])trainingSignals,
        cast(Complex!float[])waveTable[1],
        cast(Complex!float[])waveTable[0],
        cast(Complex!float[])zeros, supplyContinuedBuffer, 0);
    Thread.sleep(10.seconds);

    //clean up transmit worker
    stop_signal_called = true;
    transmit_thread.join();
    receive_thread.join();
    printPowerThread.join();
    //GC.enable();

    //finished
    writeln("\nDone!\n");
}


void estimateAndSetSignal(
    ref FFTWObject!Complex fftw,
    ref shared RWQueue!(const(shared(Complex!float))[][2]) txqueue,
    ref shared RWQueue!(Complex!float[]) rxsupplier,
    ref shared RWQueue!(Complex!float[]) rxreporter,
    const(Complex!float[])[2] trainingSignals,
    const(Complex!float)[] trainingSymbol,
    const(Complex!float)[] transmitSymbol,
    const(Complex!float)[] zeros,
    Complex!float[] rxbuffer,
    real deltaThetaOfFreqOffset,
)
{
    //Thread.sleep(5.seconds);
    if(!rxreporter.empty){
        printf("ERROR on line:%d",  cast(int)__LINE__);
        return;
    }

    rxsupplier.push(cast(shared)rxbuffer);

    puts("SEND TRAINING SIGNAL\n");
    txqueue.push(cast(shared)trainingSignals);
    txqueue.push(cast(shared)[zeros, zeros]);

    // 信号が受信されるまで待つ
    while(rxreporter.empty && ! stop_signal_called) {
        Thread.sleep(100.msecs);
    }
    if(stop_signal_called) return;
    if(! txqueue.empty){
        printf("ERROR on line:%d",  cast(int)__LINE__);
        return;
    }
    rxreporter.pop();   // 信号を取り出しておく

    puts("START ESTIMATE\n");

    // 周波数を補正する
    foreach(i, ref e; rxbuffer)
        e *= std.complex.expi(i * deltaThetaOfFreqOffset * -1);

    // SNR=30dBを達成するピークを探す
    auto peakResult = peakSearch(trainingSymbol, rxbuffer, 30);
    if(peakResult.index.isNull){
        printf("ERROR on line:%d",  cast(int)__LINE__);
        return;
    }

    // ピークの位置から探す
    rxbuffer = rxbuffer[peakResult.index.get() .. $];
    auto recv0s = rxbuffer[0 .. SYMBOL_SIZE * NUM_TRAINING_SYMBOL];
    auto recv1s = rxbuffer[SYMBOL_SIZE * NUM_TRAINING_SYMBOL .. SYMBOL_SIZE * NUM_TRAINING_SYMBOL * 2];

    // 受信シンボルで平均を取る
    foreach(ref rs; AliasSeq!(recv0s, recv1s)){
        foreach(i; 1 .. NUM_TRAINING_SYMBOL){
            foreach(j; 0 .. SYMBOL_SIZE)
                rs[j] += rs[i*SYMBOL_SIZE + j];
        }
    }

    // 送信信号をfftしたもの
    Complex!float[SYMBOL_SIZE] sendSpec;
    .fft!float(fftw, trainingSymbol, sendSpec[]);

    Complex!float[SYMBOL_SIZE] recv0Spec;
    .fft!float(fftw, recv0s[0 .. SYMBOL_SIZE], recv0Spec[]);

    Complex!float[SYMBOL_SIZE] recv1Spec;
    .fft!float(fftw, recv1s[0 .. SYMBOL_SIZE], recv1Spec[]);

    foreach(i; 0 .. SYMBOL_SIZE){
        recv0Spec[i] /= sendSpec[i];
        recv1Spec[i] /= sendSpec[i];
    }

    fftw.inputs!float[] = transmitSymbol[];
    fftw.fft!float();
    foreach(i; 0 .. SYMBOL_SIZE)
        fftw.inputs!float[i] = fftw.outputs!float[i] * recv0Spec[i] / recv1Spec[i] * -1;
    fftw.ifft!float();

    writeln("RESEND");
    txqueue.push(cast(immutable(Complex!float[])[2])[transmitSymbol, fftw.outputs!float.dup]);
}



// real estimateFrequencyOffset(
//     ref shared RWQueue!(immutable(Complex!float)[][2]) txqueue,
//     ref shared RWQueue!(Complex!float[]) rxsupplier,
//     ref shared RWQueue!(Complex!float[]) rxreporter,
//     real inputDeltaTheta,
//     immutable(Complex!float)[] sineWave,
//     immutable(Complex!float)[] zeros,
//     Complex!float[] rxbuffer,
// )
// {
//     writeln("START FREQUENCY OFFSET ESTIMATING");
//     writeln("TRANSMIT SINE WAVE");
//     txqueue.push([sineWave, zeros]);
//     Thread.sleep(1.seconds);

//     rxsupplier.push(cast(shared)rxbuffer);
//     // 信号が受信されるまで待つ
//     while(rxreporter.empty && ! stop_signal_called) {
//         Thread.sleep(100.msecs);
//     }
//     if(stop_signal_called) return real.nan;
//     enforce(txqueue.empty);
//     rxreporter.pop();   // 信号を取り出しておく

//     writeln("RECEIVING END");
//     writeln("START OFFSET ESTIMATING");

//     auto fftw = makeFFTWObject!Complex(rxbuffer.length);
//     fftw.inputs!float[] = rxbuffer[];
//     fftw.fft!float();
//     rxbuffer[] = fftw.outputs!float[];

//     real maxValue = -real.infinity;
//     size_t maxPos;
//     foreach(i, e; rxbuffer){
//         auto p = e.sqAbs;
//         if(maxValue < p){
//             maxValue = p;
//             maxPos = i;
//         }
//     }

//     if(maxPos < rxbuffer.length / 2){
//         return (maxPos*1.0L / rxbuffer.length)*2*PI - inputDeltaTheta;
//     }else{
//         return (maxPos*1.0L / rxbuffer.length)*2*PI - 2*PI - inputDeltaTheta;
//     }
// }