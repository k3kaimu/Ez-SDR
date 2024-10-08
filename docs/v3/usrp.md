# Ez-SDRにおけるUSRPについて

現在のEz-SDRでは，USRPを制御するために以下の`MultiUSRP`と`USRP_TX_LoopDRAM`という二つのデバイスインターフェイスを定義しています．
`MultiUSRP`は一般的な送受信用途であり，`USRP_TX_LoopDRAM`は高速に同じ信号をループして送信する用途に利用できます．

## MultiUSRP

USRPを制御する最も一般的な方法は，`MultiUSRP`デバイスインターフェイスを利用することです．
このデバイスは，`libuhd`の`uhd::multiusrp`を用いてUSRPデバイスを制御します．
例として，このデバイスの設定用JSONは以下のような記述になります．

```json
{
    "type": "MultiUSRP",
    "mode": "TRX",
    "args": "addr0=192.168.44.34,addr1=192.168.43.33,send_frame_size=9000",
    "timeref": ["internal", "internal"],
    "clockref": ["internal", "internal"],
    "tx-subdev": ["A:0 B:0", "A:0 B:0"],
    "rx-subdev": ["A:0 B:0", "A:0 B:0"],
    "tx-channels": [
        {
            "for-channels": [0, 1],
            "rate": 100e6,
            "freq": 2.4e9,
            "gain": 30,
            "ant": "TX/RX"
        },
        {
            "for-channels": [2, 3],
            "rate": 100e6,
            "freq": 2.5e9,
            "gain": 30,
            "ant": "TX/RX"
        }
    ],
    "rx-channels": [
        {
            "for-channels": [0, 1],
            "rate": 100e6,
            "freq": 2.4e9,
            "gain": 30,
            "ant": "RX2"
        },
        {
            "for-channels": [2, 3],
            "rate": 100e6,
            "freq": 2.4e9,
            "gain": 30,
            "ant": "RX2"
        }
    ],
    "tx-streamers": [ { "channels": [0] }, { "channels": [1] }, { "channels": [2] }, { "channels": [3] } ],
    "rx-streamers": [ { "channels": [0] }, { "channels": [1] }, { "channels": [2] }, { "channels": [3] } ]
}
```

各フィールドの意味は次の通りです．

* `"type": "MultiUSRP"`：このデバイスインターフェイスが`MultiUSRP`であることを表します．
* `"mode": "..."`：このデバイスインターフェイスが送受信両方可能か，送信のみ可能か，受信のみ可能かを設定します．上記設定における`"TRX"`とは送信と受信の両方を扱うことを表します．もし，送信のみの場合は`"mode": "TX"`とし，受信のみの場合は`"mode": "RX"`としてください．
* `"args": "..."`：今回は2台のUSRPを制御し，`send_frame_size=9000`というパラメータも指定しています．これらの記述方法は`uhd::usrp::multi_usrp::make`に従いますので，詳細は[https://files.ettus.com/manual/page_multiple.html#multiple_setup](https://files.ettus.com/manual/page_multiple.html#multiple_setup)や[https://files.ettus.com/manual/page_configuration.html#config_devaddr](https://files.ettus.com/manual/page_configuration.html#config_devaddr)を参照してください．
* `"timeref": [...]`：PPS信号をUSRPの内部`"internal"`から取得するのか，外部`"external"`から取得するのか指定します．今回は2台のUSRPがあるので，それぞれで指定しています．この設定項目は省略可能です．また，複数のUSRPデバイスのなかで指定しないものがあれば空文字列`""`を与えてください．
* `"clockref": [...]`：10MHzの参照信号をUSRPの内部`"internal"`から取得するのか，外部`"external"`から取得するのか指定します．今回は2台のUSRPがあるので，それぞれで指定しています．この設定項目は省略可能です．また，複数のUSRPデバイスのなかで指定しないものがあれば空文字列`""`を与えてください．
* `"tx-subdev": [...]`：USRPの送信側のsubdevice設定をします．今回はUSRPが2台ありますので，それぞれに対して`A:0 B:0`と記述しています．記述方法は`uhd::multi_usrp::set_tx_subdev_spec`や`uhd::multi_usrp::set_rx_subdev_spec`に従いますので，記述方法の詳細は[https://files.ettus.com/manual/page_configuration.html#config_subdev](https://files.ettus.com/manual/page_configuration.html#config_subdev)や[https://files.ettus.com/manual/classuhd_1_1usrp_1_1multi__usrp.html#a3b8d9d9fb9a1ec51e81a207cd299e517](https://files.ettus.com/manual/classuhd_1_1usrp_1_1multi__usrp.html#a3b8d9d9fb9a1ec51e81a207cd299e517)及び[https://files.ettus.com/manual/classuhd_1_1usrp_1_1multi__usrp.html#a7f94ed00059cc7dd30567d031b3f9679](https://files.ettus.com/manual/classuhd_1_1usrp_1_1multi__usrp.html#a7f94ed00059cc7dd30567d031b3f9679)を参照してください．USRP X300系など，内部にドーターボードが2枚挿入可能なUSRPでは設定必須ですが，USRP N200系などでは設定不要です．複数のUSRPデバイスのなかで指定しないものがあれば空文字列`""`を与えてください．
* `"rx-subdev": [...]`：USRPの受信側のsubdevice設定をします．記述方法は`"tx-subdev"`と同じです．
* `"tx-channels": [...]`：USRPの送信channelの設定をします上記の例では，channelについては[`uhd::stream_args_t::channels`](https://files.ettus.com/manual/structuhd_1_1stream__args__t.html#aebfb903c0cb6c040d78ef90917e55a61)を参照してください．各channelには`rate`, `freq`, `gain`, `ant`が設定可能です．今回はchannel番号`0`と`1`に対して，サンプリングレートを100Msps，周波数を2.4GHz，利得を30dB，使用するポートを`TX/RX`とすることを設定し，channel番号`2`と`3`には周波数を2.5GHzに設定するようにしています．
* `"rx-channels": [...]`：`"tx-channels"`と同様の記述方法です．
* `"tx-streamers": [...]`：コントローラインターフェイスが利用する送信ストリームをchannel番号で定義します．このchannel番号のリストは[`uhd::stream_args_t::channels`]([https://files.ettus.com/manual/structuhd_1_1stream__args__t.html](https://files.ettus.com/manual/structuhd_1_1stream__args__t.html#aebfb903c0cb6c040d78ef90917e55a61))に設定され，これを用いて[`uhd::tx_streamer`](https://files.ettus.com/manual/classuhd_1_1tx__streamer.html)が作成されます．たとえば`{ "channels": [0, 3] }`とすればchannel番号`0`と`3`を利用するストリームも定義可能です．
* `"rx-streamers": [...]`：基本的には`"tx-streamers"`と同じで，受信用になります．

`"MultiUSRP"`デバイスインターフェイスで作成されるストリームは複数ありますので，これをコントローラに紐づける際には`"<DeviceName>:<TX or RX>:<Streamer Index>"`というように指定します．
たとえば，デバイスインターフェイス名が`USRP0`であり，`"tx-streamers"`で設定した先頭のストリームをコントローラに紐づけたい場合は`"USRP0:TX:0"`とします．

## USRP_TX_LoopDRAM

USRP X系では，内部のFPGAに実装されているRFNoCのReplayBlockを用いて高速に信号を送受信できます．
`"USRP_TX_LoopDRAM"`デバイスインターフェイスでは，このReplayBlockを利用して信号を繰り返し送信します．

設定用JSONの記述は以下の通りです．

```json
{
    "type": "USRP_TX_LoopDRAM",
    "args": "addr0=192.168.44.34",
    "rate": 200e6,
    "freq": 2.4e9,
    "gain": 30,
    "ant": "TX/RX"
}
```

* `"type": "..."`：このデバイスインターフェイスが`USRP_TX_LoopDRAM`であることを表します．
* `"args": "..."`：記述方法は`uhd::multi_usrp::make`に従いますので，詳細は[https://files.ettus.com/manual/page_multiple.html#multiple_setup](https://files.ettus.com/manual/page_multiple.html#multiple_setup)や[https://files.ettus.com/manual/page_configuration.html#config_devaddr](https://files.ettus.com/manual/page_configuration.html#config_devaddr)を参照してください．
* `"rate"`, `"freq"`, `"gain"`, `"ant"`：それぞれサンプリングレート，周波数，利得，ポートを表します．

`"USRP_TX_LoopDRAM"`デバイスインターフェイスで作成されるストリームは一つであり，これをコントローラに紐づける際にはデバイスインターフェイス名と同じ名前で指定できます．
