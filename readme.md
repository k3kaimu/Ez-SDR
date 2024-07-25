# EzSDR

誰でも簡単にソフトウェア無線機でそれなりの実機実験ができるシステムを目指しています．


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

コンテナの起動からビルドまでは次のようにします．

```
$ docker compose up -d
$ ...少し待つ...
$ docker exec -it container_name bash
$ dub build --build=release --compiler=ldc2
```

なおlibuhdのバージョンの変更等はリポジトリの中の`docker-compose.yml`や`entrypoint.sh`を参考にしてください．


## TCP/IPによるAPI

次のようなバイナリ列を送ることで制御します．

```
[対象のコントローラー名の長さ（固定長2バイト）][対象のコントローラー名（可変長）][メッセージ長（固定長8バイト）][メッセージ（可変長）]
```

簡単な例として[client/examples/rawcommand_from_d.d](https://github.com/k3kaimu/multiusrp/blob/master/client/examples/rawcommand_from_d.d)を参照してください．
