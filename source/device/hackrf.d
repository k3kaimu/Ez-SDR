module device.hackrf;

import std.json;
import std.stdio;
import std.string;

import libhackrf;
import device;
import types;
import utils : UniqueArray;
import multithread;


shared bool HACKRF_IS_INITIALIZED = false;


shared static ~this()
{
    if(HACKRF_IS_INITIALIZED) {
        hackrf_exit();
    }
}


void initHackRF()
{
    synchronized {
        if(!HACKRF_IS_INITIALIZED) {
            auto ret = hackrf_init();
            enforceHackRFError(ret, "hackrf_init failed.");
            HACKRF_IS_INITIALIZED = true;
        }
    }
}


private
void enforceHackRFError(int flag, string msg, string file = __FILE__, int line = __LINE__)
{
    if(flag != hackrf_error.HACKRF_SUCCESS) {
        import std.conv : to;
        auto errorName = hackrf_error_name(cast(hackrf_error) flag).fromStringz().to!string;
        throw new Exception(msg ~ "\n HackRF error name: " ~ errorName, file, line);
    }
}


class HackRF : IDevice
{
    this(){}


    void construct()
    {
        initHackRF();
    }


    void destruct(){}


    string nameImpl() shared @nogc const { return _name; }


    void setup(string name, JSONValue[string] configJSON)
    {
        _name = name;
        _mode = configJSON["mode"].get!string == "TX" ? HackRFMode.TX : HackRFMode.RX;

        writefln("HackRF device setup: %s", _name);

        // デバイスのオープン
        writefln("Try to open HackRF device by serial: %s ...", configJSON["serial"].get!string);
        hackrf_open_by_serial(configJSON["serial"].get!string.toStringz(), &_device)
            .enforceHackRFError("hackrf_open_by_serial failed.");
        writefln("HackRF device %s is opened as %s mode...", configJSON["serial"].get!string, _mode == HackRFMode.TX ? "TX" : "RX");
        
        // デバイスのサンプリングレートの設定
        hackrf_set_sample_rate(_device, configJSON["rate"].get!double)
            .enforceHackRFError("hackrf_set_sample_rate failed.");
        writefln("\tsample rate set: %s", configJSON["rate"].get!double);

        // baseband_filter_bandwidthの設定
        if(auto p = "bw" in configJSON) {
            hackrf_set_baseband_filter_bandwidth(_device, cast(uint) p.get!double)
                .enforceHackRFError("hackrf_set_baseband_filter_bandwidth failed.");
            writefln("\tbaseband filter bandwidth set: %s", p.get!double);
        }

        // ハードウェア同期モードの設定
        if(auto p = "HW_sync" in configJSON) {
            hackrf_set_hw_sync_mode(_device, p.get!bool ? 1 : 0)
                .enforceHackRFError("hackrf_set_hw_sync_mode failed.");
            writefln("\thardware sync mode set: %s", p.get!bool);
        }

        // 周波数の設定
        hackrf_set_freq(_device, cast(ulong) configJSON["freq"].get!double)
            .enforceHackRFError("hackrf_set_freq failed.");
        writefln("\tfrequency set: %s", cast(ulong) configJSON["freq"].get!double);

        // RF段のアンプを使うかどうかの設定(bool)
        if(auto p = "useRFAmp" in configJSON) {
            hackrf_set_amp_enable(_device, p.get!bool)
                .enforceHackRFError("hackrf_set_amp_enable failed.");
            writefln("\tRF amplifier set: %s", p.get!bool);
        }

        if(auto p = "useANTPwr" in configJSON) {
            hackrf_set_antenna_enable(_device, p.get!bool)
                .enforceHackRFError("hackrf_set_antenna_enable failed.");
            writefln("\tantenna power set: %s", p.get!bool);
        }

        if(auto p = "gain" in configJSON) {
            if(_mode == HackRFMode.TX) {
                hackrf_set_txvga_gain(_device, p.get!uint)
                    .enforceHackRFError("hackrf_set_txvga_gain failed.");
                writefln("\tTX VGA gain set: %s", p.get!uint);
            } else {
                hackrf_set_lna_gain(_device, p.get!uint)
                    .enforceHackRFError("hackrf_set_lna_gain failed.");
                writefln("\tRX LNA gain set: %s", p.get!uint);
            }
        }

        // clkoutの設定
        if(auto p = "clkout" in configJSON) {
            hackrf_set_clkout_enable(_device, p.get!bool ? 1 : 0)
                .enforceHackRFError("hackrf_set_clkout_enable failed.");
            writefln("\tclkout set: %s", p.get!bool);
        }

        if(auto p = "bufferSize" in configJSON) {
            _bufferSize = cast(size_t) p.get!ulong;
            writefln("\tbuffer size set: %s", _bufferSize);
        } else {
            writefln("\tdefault buffer size: %s", _bufferSize);
        }
    }


    IStreamer makeStreamer(string[] args) shared
    {
        if(_mode == HackRFMode.TX) {
            return new HackRFTxStreamerImpl!(ComplexInt!byte)(_name, this, _bufferSize);
        } else {
            return new HackRFRxStreamerImpl!(ComplexInt!byte)(_name, this, _bufferSize);
        }
    }


    void setParam(const(char)[] key, const(char)[] value, scope const(ubyte)[] optArgs) shared @nogc {}
    UniqueArray!char getParam(const(char)[] key, scope const(ubyte)[] optArgs) shared @nogc { return typeof(return).init; }
    void query(scope const(ubyte)[] optArgs, scope void delegate(scope const(ubyte)[]) writer) shared @nogc {}


    private hackrf_device* _handler() @nogc
    {
        return _device;
    }


  private:
    hackrf_device* _device;
    string _name;
    HackRFMode _mode;
    size_t _bufferSize = 128*1024;

    enum HackRFMode
    {
        TX, RX
    }



    static class HackRFTxStreamerImpl(C) : IStreamer, IBurstTransmitter!C, ILoopTransmitter!C
    {
        this(string name, shared(HackRF) dev, size_t bufferSize = 32*1024)
        {
            _name = name;
            _dev = dev;
            _queue = new LockFreeSPSCQueue!C();
        }


        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared const @nogc { return 1; }
        string nameImpl() shared @nogc const { return _name; }


        StreamerElementType elementTypeImpl() shared @nogc { return StreamerElementType.ComplexInt8; }


        void beginBurstTransmit(scope const(ubyte)[] q) @nogc
        {
            assert(q.length == 0, "additional arguments is not supported");
            _firstTransmit = true;

            // キューに溜まっているすべてのデータを消す
            // まだ送信していない状態なので，cast()で型を変換してunsharedな関数を呼び出しても良い
            (cast() _queue).clear();
        }


        void endBurstTransmit(scope const(ubyte)[] q) @nogc
        {
            synchronized(_dev) {
                auto ret  = hackrf_stop_tx((cast() _dev)._handler());
                if(ret != hackrf_error.HACKRF_SUCCESS) {
                    printf("hackrf_stop_tx failed\n");
                }
            }

            // enforceHackRFError(ret, "hackrf_stop_tx failed.");
            _firstTransmit = false;
        }


        void burstTransmit(scope const C[][] signal, scope const(ubyte)[] q, scope size_t[] txsamples) @nogc
        in(signal.length == 1, "signal must be a single channel signal")
        in(q.length == 0, "additional arguments is not supported")
        in(txsamples.length == 1, "txsamples must be a single element array")
        {
            txsamples[] = _queue.push(signal[0]);
            if(txsamples[0] == 0) {
                import core.thread;
                Thread.yield();
            }

            // {
            //     foreach(i; 0 .. txsamples[0]) {
            //         printf("HackRF-TX: Sample %d, Re: %d, Im: %d\n", 
            //             cast(int) i, cast(int) signal[0][i].re, cast(int) signal[0][i].im);
            //     }
            // }

            // 最初の送信時にコールバックを登録
            if(_firstTransmit) {
                synchronized(_dev) {
                    auto ret = hackrf_start_tx((cast() _dev)._handler(), &HackRFTxStreamerImpl.burstTransmitCallback, cast(void*) this);
                    printf("HackRF-TX: Start burst transmit...\n");
                    // enforceHackRFError(ret, "hackrf_start_tx failed.");
                    if(ret != hackrf_error.HACKRF_SUCCESS) {
                        printf("hackrf_start_tx failed\n");
                    } else {
                        _firstTransmit = false;
                    }
                }
            }


            import core.stdc.stdio : fflush, stdout;
            fflush(stdout);
        }


        mixin LoopByBurst!C;


      private:
        string _name;
        shared(HackRF) _dev;
        shared(LockFreeSPSCQueue!C) _queue;
        bool _isRunning = false;
        bool _firstTransmit = false;


        extern(C) static int burstTransmitCallback(hackrf_transfer* transfer)
        {
            shared(HackRFTxStreamerImpl) self = cast(shared(HackRFTxStreamerImpl)) transfer.tx_ctx;


            size_t tryCount = 0;
            size_t numSamples = 0;
            while(numSamples == 0 && tryCount < 1000) {
                size_t readsamples = self._queue.pop(cast(C[])transfer.buffer[numSamples .. transfer.buffer_length]);
                numSamples += readsamples;
                transfer.valid_length = cast(int) (numSamples * C.sizeof);

                if(readsamples == 0) {
                    import core.thread;
                    Thread.yield();
                }

                ++tryCount;
            }

            // printf("HackRF-TX: Transmitting %d samples...\n", cast(int) numSamples);
            // printf("HackRF-TX: %d buffer is valid.\n", cast(int) transfer.valid_length);
            if(numSamples == 0) {
                printf("HackRF-TX: No samples to transmit...\n");
                printf("HackRF-TX: Fill zeros to the buffer.\n");
                // 送信するサンプルがない場合は，バッファをゼロで埋める
                // これをしないと，HackRFが今後一切callbackを呼ばなくなるみたい
                transfer.buffer[0 .. transfer.buffer_length] = 0;
                transfer.valid_length = transfer.buffer_length;
            }

            // if(numSamples > 8) {
            //     foreach(i; 0 .. 8) {
            //         printf("Re: %d, Im: %d\n", 
            //             cast(int) transfer.buffer[i * 2], cast(int) transfer.buffer[i * 2 + 1]);
            //     }
            // }

            import core.stdc.stdio : fflush, stdout;
            fflush(stdout);
            return 0;
        }
    }


    static class HackRFRxStreamerImpl(C) : IStreamer, IContinuousReceiver!C
    {
        this(string name, shared(HackRF) dev, size_t bufferSize)
        {
            _name = name;
            _dev = dev;
            _queue = new LockFreeSPSCQueue!C(bufferSize);
        }


        shared(IDevice) device() shared @nogc { return _dev; }
        size_t numChannelImpl() shared const @nogc { return 1; }
        string nameImpl() shared @nogc const { return _name; }


        StreamerElementType elementTypeImpl() shared @nogc { return StreamerElementType.ComplexInt8; }


        void startContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            // バッファに溜まっているすべてのデータを消す
            // まだ受信していない状態なので，cast()で型を変換してunsharedな関数を呼び出しても良い
            (cast() _queue).clear();

            printf("HackRF-RX: Start continuous receive...\n");

            // 受信開始
            synchronized(_dev) {
                auto ret = hackrf_start_rx((cast() _dev)._handler(), &HackRFRxStreamerImpl.continuousReceiveCallback, cast(void*) this);
                // enforceHackRFError(ret, "hackrf_start_rx failed.");
                if(ret != hackrf_error.HACKRF_SUCCESS) {
                    printf("hackrf_start_rx failed\n");
                }
            }
        }


        void stopContinuousReceive(scope const(ubyte)[] optArgs) @nogc
        {
            synchronized(_dev) {
                auto ret = hackrf_stop_rx((cast() _dev)._handler());
                // enforceHackRFError(ret, "hackrf_stop_rx failed.");
                if(ret != hackrf_error.HACKRF_SUCCESS) {
                    printf("hackrf_stop_rx failed\n");
                }
            }
        }


        void singleReceive(scope C[][] buffers, scope const(ubyte)[] optArgs, scope size_t[] rxsamples) @nogc
        in(buffers.length == 1, "buffers must be a single channel buffer")
        in(buffers.length == 1, "rxsamples must be a single element array")
        {
            rxsamples[] = _queue.pop(buffers[0]);
        }


      private:
        string _name;
        shared(HackRF) _dev;
        shared(LockFreeSPSCQueue!C) _queue;

        extern(C) static int continuousReceiveCallback(hackrf_transfer* transfer)
        {
            shared(HackRFRxStreamerImpl) self = cast(shared(HackRFRxStreamerImpl)) transfer.rx_ctx;
            
            C[] samplebuffer;
            samplebuffer = cast(C[]) transfer.buffer[0 .. transfer.valid_length];
            
            size_t numRx = 0;
            size_t tryCount = 0;
            while(samplebuffer.length && tryCount < 1000) {
                size_t num = self._queue.push(samplebuffer);
                samplebuffer = samplebuffer[num .. $];
                numRx += num;

                if(samplebuffer.length > 0) {
                    import core.thread;
                    Thread.yield();
                    ++tryCount;
                }
            }

            if(samplebuffer.length != 0) {
                printf("HackRF-RX: Received %d samples, but only %d samples are stored in the queue.\n", 
                    cast(int) (transfer.valid_length / C.sizeof), cast(int) numRx);
            }

            return 0;
        }
    }
}
