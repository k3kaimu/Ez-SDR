# multiusrp

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
[コマンドid（固定長1byte）][コマンドメッセージ（可変長）]
```

簡単な例として[client/examples/rawcommand_from_d.d](https://github.com/k3kaimu/multiusrp/blob/master/client/examples/rawcommand_from_d.d)を参照してください．

### Transmitコマンド（id:0x54）

送信信号を送信用USRPに設定します

```
[0x54][サンプル数N（4byte）][送信機1のデータIQIQIQ...（32bit float）][送信機2のデータIQIQIQ...（32bit float）]...
```

* レスポンスなし

複数のUSRPに設定される信号の長さは同一である必要があります．
また，この命令で設定された信号の送信が終了した場合，先頭から続けて（ループして）再度送信を再開します．

### Receiveコマンド（id:0x52）

送信用USRPから受信した信号を取得します

```
[0x52][サンプル数N（4byte）]
```

* レスポンス

```
[受信機1のデータIQIQIQ...（32bit float）][受信機2のデータIQIQIQ...（32bit float）]...
```

この命令は，かならず受信アライメントに同期して受信信号を取得します．
受信アライメントが`N`，サンプリング周波数が`Fs`であれば，1回目の受信命令と2回目の受信命令で取得される先頭サンプルの時間差は`NFs`の整数倍になります．

### Shutdownコマンド

```
[0x51]
```

* レスポンスなし

この命令は制御用のプログラムをシャットダウンします．


### changeRxAlignSizeコマンド

```
[0x41][アライメントサイズN(4byte整数)]
```

* レスポンスなし

この命令は，受信処理におけるアライメントのサイズを変更します．


### skipRxコマンド

```
[0x44][スキップサンプル数N(4byte整数)]
```

* レスポンスなし

この命令は，`N`サンプルの受信信号を破棄してアライメントを`N`サンプルずらします．
たとえば，既知の遅延サンプル数`D`が分かっている場合には`D`サンプルだけスキップすれば，受信アライメントと信号の先頭が揃います．


### syncToPPSコマンド

```
[0x53]
```

* レスポンスなし

制御ソフトに接続されたすべてのUSRPをPPSに同期します．
