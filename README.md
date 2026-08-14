# QSProbe

iOS / iPadOS 向けの Quick Share (Nearby Share) クライアント。
無料 Apple ID + SideStore で動きます。

| 機能 | 状態 |
|---|---|
| Android / Windows からの受信 | ✅ |
| Android / Windows への送信 | ✅ |
| フォルダ送信 (階層を保つ) | ✅ |
| 写真・動画の送信 (Live Photo はペア動画も) | ✅ |
| テキスト送受信 | ✅ |
| QR ペアリング (送信側) | ✅ |
| QR ペアリング (受信側) | ❌ 削除。理由は下記 |

## ⚠️ SideStore でインストールしてください

**LiveContainer では動きません。** ホスト側の `NSBonjourServices` 許可リストに
`_FC9F5ED42C8A._tcp` が無いためです。Local Network や写真ライブラリの
**権限そのものは LiveContainer でも取得できます**が、Bonjour の
サービスタイプ許可リストだけはゲスト側の宣言がマージされません。

LiveContainer 上で動かしたい場合は
[`docs/LiveContainer-patch.md`](docs/LiveContainer-patch.md) の手順で
2 行追加して自前ビルドしてください。

## 画面構成

```
受信          このデバイスを見えるようにする (トグル)
              確認せずに受け取る (トグル)
              確認コード / 受信の進捗 / 受け取る・拒否

送信          ファイル / フォルダ / 写真 の 3 ボタン
              テキスト欄 (空なら貼り付け、入力済みなら消去)
              送るもの一覧 / 送信のオプション
              送信の進捗
              QR を表示して送る

近くのデバイス 近くのデバイスを探す (トグル)
              見つかった相手 (タップで送信)

実験機能      アカウント連携 (既定でオフ)  → 別画面
診断          → 別画面 (受信したフレーム / 埋め込み設定 / ログ / 共有 / 消去)
```

受信の同意はシートで出ます。転送中は画面の上に帯が出るので、
スクロールしても進捗を見失いません。

## 使い方

### 受け取る

1. 「このデバイスを見えるようにする」をオン
2. 相手の Quick Share にこの端末が出るので選んでもらう
3. **確認コードが相手の画面と一致することを確かめて**「受け取る」

受け取ったテキストは画面に出ます。「コピー」ボタン、長押しのメニュー、
文字の直接選択のいずれでもコピーできます。

**URL の場合は「開く」ボタンも並びます。** 判定は `TextMetadata.type` が
`.url` かどうかを見ますが、相手が種別を立ててこないこともあるため、
`http://` / `https://` で始まる本文も開けるものとして扱います。

**写真とビデオは「写真」App に入ります** (既定)。
「写真とビデオを「写真」に保存」をオフにすると、他のファイルと同じく
`Documents/Received/` に残ります。

それ以外のファイルは `Documents/Received/` です。
「ファイル」App の QSProbe → Received から取り出せます。
フォルダで送られた場合は階層が復元されます。

判定は拡張子で行います (`jpg` `png` `heic` `mov` `mp4` など)。
取り込めなかった場合 (権限が無い、写真として解釈できない等) は
**元の場所に残します**。受け取ったのに何処にも無い、という状態を作らないためです。

### 送る

1. ファイル / フォルダ / 写真 を選ぶ (テキストだけでも可)
2. 「近くのデバイスを探す」をオン
3. 一覧に出た相手をタップ

**相手側で Quick Share の受信画面を開いておく必要があります。**
iOS は BLE アドバタイズに service data を載せられないため、
こちらから相手を起こすことができません。

### 相手が見つからないとき: QR

1. 送るものを選ぶ
2. 「QR を表示して送る」
3. 相手のカメラで読み取ってもらう
4. 「見つかりました」と出たら「この相手に送信」

**BLE を経由しないので、mDNS だけでは見つけてもらえない端末にも届きます。**
実測では QR 経由だと相手側の確認が出ず、約 90 ミリ秒で受理されます。

「読み取られたら自動で送信」をオンにすると、相手が読み取った時点で
承認を待たずに送信を始めます。QR を見ていない端末は TLV を作れないため、
対象は構造的に限定されます。

## 削除した機能とその理由

### 受信側の QR ペアリング

Android が出す QR を読み取って受け取る経路を実装しましたが、**削除しました。**

読み取り・鍵導出・TLV 広告・相手からの接続・署名検証まではすべて成功します。
しかし `PAIRED_KEY_RESULT` を返した 20〜40 ミリ秒後に、相手から必ず
DISCONNECTION が来て 7 フレームで終わります。

`wire_format.proto` によれば、こちら側も `qr_code_handshake_data` に
**「HKDF of the connection token and of the UKEY2 token」**を返す必要がありますが、
この導出はどの第三者実装も到達していません。

- NearDrop の PROTOCOL.md は送信側の署名しか記載しておらず、
  `TODO: figure out why this sometimes fails` とある
- Bada の `QrHandshakeSigner` も送信側のみ
- CrossDrop は NearDrop 由来

「connection token」の解釈を 7 通り用意し、出力長 2 種 × status 2 種の
**30 通りを自動で総当たり**しましたが、到達したものはありませんでした。

**実用上の影響はありません。** Android → iPad は通常の mDNS 探索で動きます。
また Android の QR は「ローカル経路」と「Google サーバー中継」の 2 つの入口を
兼ねており、後者は URL を Safari で開けば動きます (ファイルは 24 時間保存)。

### 末尾ドットの切り替え / publish バックエンドの切り替え

どちらも実測で「どちらでも動く」ことが確定したため削除しました。
サービスタイプは **`_FC9F5ED42C8A._tcp` (末尾ドット無し)**、
publish は `NetService` に固定です。

`NSNetService` のドキュメントは末尾ピリオド付きの絶対名を要求していますが、
実測ではドット無しでも publish も browse も成功します。
`Info.plist` の `NSBonjourServices` も 1 件に絞ってあり、
**コード側とドットの有無を揃えてある**のが要点です。片方だけドット付きにする
組み合わせは検証していないので、変えるなら両方まとめて変えてください。

## 既知の制約

- **相手を起こせません。** iOS は BLE アドバタイズに service data を載せられないため、
  相手側で受信画面を開いてもらうか、QR を使う必要があります。
- **バックグラウンドでは動きません。** 転送中は画面を点けたままにしてください。
  ただしトグルをオンにしたままアプリを離れて戻った場合は**自動で張り直し**、
  アプリを終了して開き直した場合も**前回の状態を復元**します。
- Wi-Fi Direct / ホットスポット経路は未対応です。同一 LAN が必要です。
- 同一 LAN 上の相手を識別する安定した手段がありません
  (デバイス名は詐称でき、`secret_id_hash` は接続ごとにローテーションします)。
  「確認せずに受け取る」を有効にすると、誰からでも受け取ります。

## 実装メモ

### 由来

| ファイル | 由来 |
|---|---|
| `Base64Url.swift` / `QuickShareMdns.swift` / `EndpointInfo.swift` | Bada `core-protocol` |
| `FramedConnection.swift` | Bada `transport/FramedConnection.kt` |
| `D2DKeys.swift` | Bada `crypto/D2DKeyDerivation.kt` + `crypto/pin/PinDerivation.kt` |
| `SecureChannel.swift` | Bada `crypto/securemessage/` |
| `Ukey2Server.swift` / `Ukey2Client.swift` | Bada `ukey2/` |
| `QrPairing.swift` | Bada `qr/` (送信側のみ) |
| `OutgoingItems.swift` | Bada `send/DocumentTreeFileSourceFactory.kt` + FlyingCarpet |
| `PhotoLibrarySaver.swift` | AlterSend `apps/mobile/src/transfer/receive/utils/downloadHandlers.ts` |
| `Sources/Protobuf/*.pb.swift` | QuickDrop からそのまま (UNLICENSE) |

### 外部依存

`SwiftProtobuf` のみ。ECDH と署名は CryptoKit の P256、AES-256-CBC は
CommonCrypto、QR 生成は CoreImage で足ります。

### 押さえてある落とし穴

- **「写真」への取り込みはコピーではなく移動。** `PHAssetResourceCreationOptions`
  の `shouldMoveFile = true` を使います。コピーしてから元を消す方式だと、
  取り込みの瞬間だけディスクを二重に使います。12 GB の動画を受け取れる実装なので
  無視できない差です。
- **メモリに載せない。** 送受信ともディスクへストリーミングします。
  iPad 9 の jetsam 上限 (約 1850 MiB) を超えると殺されます。12.13 GB の
  動画を約 4 分 15 秒で受信できることを確認済みです。
- **`LAST_CHUNK` は必ず別フレームで送る。** Samsung One UI 7+ は
  データチャンクに融合させると無言で破棄します。
- **HMAC は復号より先に、定数時間で比較する。** 逆順にすると padding oracle になります。
- **デバイス名は UTF-8 で 19 バイトにクランプする。** stock 互換のため。
- **`keepAlive` は返すだけでなく、こちらからも 5 秒間隔で送る。** ACK を返す
  だけだと、INTRODUCTION を送ってから相手が承認するまでの沈黙で切られることが
  あります。stock も 5 秒間隔で能動的に送ってきます。
- **進捗通知は 100ms に間引く。** 毎チャンク更新するとメインスレッドが詰まります。
- **ファイルサイズが読めなかったことを握り潰さない。** `?? 0` で丸めると
  一覧の合計が `Zero KB` になったときに原因が追えません。読めなければ -1 を
  返してログに残します。
- **「ユーザーの意図」と「実際の状態」を分けて持つ。** バックグラウンドへ回ると
  iOS が listener と publish を落とすため、トグルを実状態に結び付けると
  復帰のたびに勝手にオフに見えます。意図は `isEnabled` に、実状態は `state` に
  持たせ、前面復帰時 (`scenePhase`) に意図がオンなら張り直します。

## 実験機能: アカウント連携

**既定でオフです。オフのあいだは通信も保存も一切しません。**

Google アカウントに紐づく証明書を取れれば、相手が誰かを照合できるように
なります (いまは `PAIRED_KEY_RESULT` に `unable` を返すだけ)。その下準備として、
`nearby_share.exe` から読み取った client_id で OAuth を通せるかを試す段です。

Google の非公開 API が相手なので、**いつ塞がれてもおかしくありません**。
有効にするときに警告が出ます。手順と、返ってきたエラーの読み方は
[`docs/account-linking.md`](docs/account-linking.md) にまとめてあります。

接続先の定数はコードに固定せず、画面から差し替えられるようにしてあります。

## ビルド

GitHub Actions (macOS ランナー) で unsigned IPA を生成し、SideStore で入れます。
Mac も Xcode も不要です。

```
Actions → Build QSProbe (unsigned IPA) → Run workflow
```

失敗時は `build-failure` アーティファクトに `errors.txt` などが入ります。

## ログ

画面では従来どおりのテキストで、ファイルは **JSON Lines (NDJSON)** で書き出します。

```
Documents/Log/2026-08-13T04-27-50+09-00_log.jsonl
```

```json
{"ts":"2026-08-13T04:27:50.123+09:00","level":"OK","category":"Advertiser","message":"★ mDNS publish 成功"}
```

右上のメニューは 2 つだけです。

| メニュー | 動作 |
|---|---|
| ログを共有 | テキストと JSON Lines をまとめた zip を書き出す |
| ログを消去 | 画面と書き出しファイルの両方を空にする |

共有すると、**同じ内容の 2 形式**が 1 個の zip に入ります。

```
2026-08-13T04-27-50+09-00_log.zip
  ├─ 2026-08-13T04-27-50+09-00_log.txt     人が読む用
  └─ 2026-08-13T04-27-50+09-00_log.jsonl   機械が読む用
```

`.txt` は `.jsonl` から生成しているので、**どちらも全期間ぶん**です
(画面のバッファは 500 件で頭が落ちますが、こちらは落ちません)。

zip 化は `NSFileCoordinator` の `.forUploading` を使っています。
ディレクトリを渡すと zip にまとめた一時ファイルを作ってくれるので、
外部ライブラリを足さずに済みます。

### なぜ JSON Lines なのか

- **途中で切れても壊れない。** 配列で包む JSON だと、クラッシュや強制終了で
  末尾の `]` が書かれずファイル全体が読めなくなります。NDJSON なら
  最後の 1 行を捨てるだけで残りが使えます。追記も 1 行足すだけです。
- **grep がそのまま効く。** 1 行に必要な情報が揃っているので、
  `grep Outbound` のような素朴な絞り込みが従来どおり使えます。
- **集計しやすい。** `category` と `level` が独立した項目になるので、
  「Session の WARN だけ」「keepAlive の間隔」といった抽出が
  正規表現に頼らず書けます。

`category` は `"Advertiser: ..."` のような接頭辞から機械的に切り出しています。
接頭辞が無い行は `App` になります。

### ファイル名について

**共有時は文字列ではなくファイル URL を渡しています。** 文字列のまま
共有シートに載せると、iOS が中身を見て勝手に「テキスト.txt」と名付けます。
ISO 8601 のコロンはファイル名に使えないのでハイフンにしてあります。
