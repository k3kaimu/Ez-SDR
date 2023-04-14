# multiusrp


## TCP/IPによるAPI

次のようなバイナリ列を送ることで制御します．

```
[コマンドid（固定長1byte）][コマンドメッセージ（可変長）]
```

### Transmitコマンド（id:0x74）

```
[0x74][サンプル数N（4byte）][送信機1のデータIQIQIQ...（short）][送信機2のデータIQIQIQ...（short）]...
```

レスポンスなし

### Receiveコマンド（id:0x72）

```
[0x74][サンプル数N（4byte）]
```

レスポンス

```
[送信機1のデータIQIQIQ...（short）][送信機2のデータIQIQIQ...（short）]...
```
