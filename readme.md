# Ez-SDR(v3)

## まずは試してみる

Ez-SDRではビルド済みDockerイメージを配布していますので，Dockerがインストール済みの環境で簡単に試すことができます．
以下のコマンドは，ビルド済みDockerイメージを利用して，`setting.json`にとして保存した設定ファイルに従ってEz-SDRを起動する例です．
設定ファイルの書き方の例は`config_examples`ディレクトリを参照してください．

```sh
$ docker pull ghcr.io/k3kaimu/ezsdr:latest
$ cat setting.json | docker run -i --rm --init --net=host ghcr.io/k3kaimu/ezsdr:latest
```

## 対応ソフトウェア無線機

現在のところはUSRP（UHD）にのみ対応していますが，今後はHackRF及びBladeRFへの対応を予定しております（現在実装中）．


## Ez-SDRのアーキテクチャ

Ez-SDRでは，ソフトウェア無線機である「デバイス」と，デバイスを管理・制御する「コントローラ」が登場します．
ユーザはコントローラに命令を送ると，その命令をコントローラが実行し，適切にデバイスを制御します．


## コマンドラインオプション


`-c {config file}.json`で，USRPの構成情報をjsonファイルから読み込みます．
なお，次のように`-c`とは別に`--port`のみはコマンドライン引数でパラメータを指定することで構成情報を上書きして使用することもできます．
例では，`config_examples/n210_TX1_RX1_sync.json`に記載されている`port`がどのような値だとしても，実際に使用する値は8889になります．

```sh
$ ./ezsdr -c config_examples/n210_TX1_RX1_sync.json --port=8889
```

Dockerイメージを使う場合は以下の通りです．

```sh
$ cat config_examples/n210_TX1_RX1_sync.json | docker run -i --rm --init --net=host ghcr.io/k3kaimu/ezsdr:latest --port=8889
```
