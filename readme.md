# EzSDR(v3)

誰でも簡単にソフトウェア無線機でそれなりの実機実験ができるシステムを目指しています．
現在のメジャーバージョンv3はまだ開発を開始誌た段階で送信機能しか実装されていませんので，今すぐにでも利用したい方は安定版のメジャーバージョンv2(multiusrp)をご利用ください．

~~~sh
# v2.11のクローン
$ git clone https://github.com/k3kaimu/Ez-SDR.git ./multiusrp -b v2.11
~~~


## EzSDRのアーキテクチャ

EzSDRでは，ソフトウェア無線機である「デバイス」と，デバイスを管理・制御する「コントローラ」が登場します．
ユーザはコントローラに命令を送ると，その命令をコントローラが実行し，適切にデバイスを制御します．

## コマンドラインオプション

* `-c jsonfile.json`

USRPの構成情報をjsonファイルから読み込みます．
`config_examples`の中を参考にしてください．

なお，次のように`-c`とは別に`--port`のみはコマンドライン引数でパラメータを指定することで構成情報を上書きして使用することもできます．
例では，`config_examples/n210_TX1_RX1_sync.json`に記載されている`port`がどのような値だとしても，実際に使用する値は8889になります．

```sh
$ ./multiusrp -c config_examples/n210_TX1_RX1_sync.json --port=8889
```


## ビルド環境構築とビルド

開発環境用のコンテナのビルドと，開発環境コンテナの起動からビルドまでは次のようにします．

```
$ git clone https://github.com/k3kaimu/Ez-SDR ezsdr
$ cd ezsdr/docker/devenv_uhd4.7
$ docker build -t ezsdr_dev:3.0.0 .
$ cd ../..
$ docker run -it --rm --net=host -v $(pwd):/work ezsdr_dev:3.0.0 /bin/bash
# cd /work
# dub build --build=release
```

## 実行用コンテナ

Ez-SDRの開発目的ではなく，単にEz-SDRを実行するだけであれば，以下のように実行用のコンテナをビルドして，それを使うことができます．

```
$ ...開発環境用のコンテナをビルドしてください...
$ cd ezsdr/docker/v3_prebuild
$ docker build -t ezsdr:3.0.0 .
$ docker run -it --rm --net=host -v $(pwd)/work ezsdr:3.0.0 /bundle/usr/bin/ezsdr -c /work/config_examples/x310_UBX_DRAM_TX_v3.json
```

## TCP/IPによるAPI

次のようなバイナリ列を送ることで制御します．

```
[対象のコントローラー名の長さ（固定長2バイト）][対象のコントローラー名（可変長）][メッセージ長（固定長8バイト）][メッセージ（可変長）]
```

簡単な例として[client/examples/rawcommand_from_d.d](https://github.com/k3kaimu/multiusrp/blob/master/client/examples/rawcommand_from_d.d)を参照してください．
