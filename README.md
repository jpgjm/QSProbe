# QSProbe — M5.3

Quick Share (Nearby Share) の iOS 移植プロジェクト。

| マイルストーン | 状態 |
|---|---|
| M0: mDNS 広告・探索・TCP 着信 | ✅ 完了 |
| M1: 平文フレームのデコード | ✅ 完了 |
| M2: UKEY2 + PIN + 暗号化チャネル | ✅ 完了 |
| M3: ユーザー同意 + 実ファイル受信 | ✅ 完了 |
| M4: 送信 (iPad → Android) | ✅ 完了 |
| M5.1: フォルダ送信 + 写真・動画送信 | ✅ 完了 |
| M5.2: 記録の訂正 | ✅ 完了 |
| **M5.3: LiveContainer 制約の正確な特定 (コード変更なし)** | ← いまここ |

## ⚠️ LiveContainer では動きません (回避策あり)

**原因は `NSBonjourServices` の許可リストだけです。** 権限一般の問題ではありません。

LiveContainer はゲストアプリをホストのプロセス内で動かすため、iOS から見える
Info.plist は**ホスト (LiveContainer) のもの**です。LiveContainer の
`Resources/Info.plist` には汎用のプライバシー説明文が一通り用意されています。

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>The guest app is requesting for this permission.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>The guest app is requesting for this permission.</string>
```

つまり **Local Network の許可も写真ライブラリの許可もゲストで取得できます。**
素の TCP / UDP 通信は問題なく通ります。

問題は `NSBonjourServices` だけです。これは説明文ではなく**サービスタイプの
固定リスト**で、LiveContainer には 47 種類が列挙されています。
**ゲスト側の `NSBonjourServices` はマージされません。**

```xml
<key>NSBonjourServices</key>
<array>
    <string>_airplay._tcp</string>
    <string>_http._tcp</string>
    ...
    <string>_stikpairprobe._tcp</string>
</array>
```

`_FC9F5ED42C8A._tcp` はこのリストに無いため、Quick Share のサービスタイプは
「許可されていないタイプ」として拒否されます。これが次の症状の正体です。

| 症状 | 意味 |
|---|---|
| `NSNetServicesMissingRequiredConfigurationError (-72008)` | publish しようとしたタイプが許可リストに無い |
| `kDNSServiceErr_NoAuth (-65555)` | browse しようとしたタイプが許可リストに無い |
| **権限プロンプトが出ない** | タイプの照合は TCC の手前の構成チェックなので、許可を問う段階に到達しない |

### なぜ LocalSend は LiveContainer で動くのか

LocalSend が宣言する Bonjour タイプは `_http._tcp` / `_bonjour._tcp` /
`_lnp._tcp.` で、**`_http._tcp` が LiveContainer の許可リストに含まれています**。

さらに LocalSend の探索は Bonjour だけに依存していません。
`app/lib/isolate/src/task/discovery/http_scan_discovery.dart` に
**サブネットを HTTP で総当たりする経路**があり、転送自体も素の HTTP over TCP です。
LiveContainer には multicast entitlement が無いので UDP マルチキャスト探索は
効きませんが、この HTTP スキャン経路が代わりに働きます。

**QSProbe は「カスタム Bonjour サービスタイプを使う」という、LiveContainer が
構造的に転送できない唯一の項目に当たっているだけ**で、実装の不備ではありません。

### 回避策: LiveContainer にタイプを追加する

LiveContainer は OSS なので、許可リストに 2 行足して自前ビルドすれば動きます。
手順は [`docs/LiveContainer-patch.md`](docs/LiveContainer-patch.md) にまとめました。

許可リストの末尾に `_stikpairprobe._tcp` という特定ツール向けのカスタムタイプが
既に入っているため、上流に PR を出す前例もあります。

### ⓪ 診断セクションの限界

「⓪ 埋め込み設定の実測値」は `Bundle.main.object(forInfoDictionaryKey:)` で
plist を読みますが、LiveContainer 環境では**ゲストのバンドルを読むため緑になります**。
一方システムはホスト側の許可リストを見て拒否するので、
**⓪ が全部緑でも `-72008` / `-65555` が出ることがあります**。
その場合はコンテナ環境を疑ってください。

## M0 の結論 (訂正版)

初版の検証で「`NSNetService` のサービスタイプには末尾ピリオドが必須」と
結論づけましたが、**これは誤りでした**。

初版のコード (末尾ドット無し、`NSBonjourServices` も 1 件のみ) を
そのまま SideStore でインストールしたところ、エラーなく publish・browse とも
成功しています。

```
22:06:10.024  NetService.publish() を呼びました (type=_FC9F5ED42C8A._tcp)
22:06:12.304  ★ mDNS publish 成功
22:06:13.903  ★ 探索を開始しました (ready)
```

正しい結論は次のとおりです。

| 項目 | 結論 |
|---|---|
| サービスタイプの末尾ドット | **どちらでも動く。** 無関係だった |
| `NSBonjourServices` の記載形式 | ドット無し 1 件で足りる (両方書くのは無害な保険) |
| publish のバックエンド | `NetService` / `NWListener` どちらでも動く |
| `com.apple.developer.networking.multicast` | **不要**。`NSBonjourServices` + `NSLocalNetworkUsageDescription` で足りる |
| 初版が失敗した真因 | **LiveContainer の `NSBonjourServices` 許可リストにタイプが無かったこと** |

multicast entitlement が不要という結論は正しく、
無料 Apple ID + SideStore で Quick Share の LAN 経路が成立することに変わりはありません。

## M5 で見つかった 3 件の問題と対処

### 1. 「ファイルを選ぶ」が無反応になった (退行バグ)

**原因は SwiftUI の仕様です。** 同じビューに `.fileImporter` を 2 つ付けると、
片方しか機能しません。M5 でフォルダ用を追加したことで、ファイル用が
上書きされて死んでいました。

モディファイアを 1 つに統合し、対象の種類を `State` で切り替えるようにしました。
`.sheet` を複数付けたときと同じ既知の落とし穴です。

### 2. 写真が送れない (`IMG_0044.pvt` 160 バイト)

`loadFileRepresentation` は **Live Photo を `.pvt` パッケージ (ディレクトリ) として
渡してきます**。ディレクトリなので `FileHandle` で開けず、
`The file "IMG_0044.pvt" doesn't exist` になっていました。
`attributesOfItem` はディレクトリにもサイズを返すため、
実体のない 160 バイトの項目がキューに入っていたわけです。

対処は 2 段構えです。

- **`PHAssetResource` 経由に切り替え**、構成ファイルを 1 本ずつ書き出す (下記)
- `OutgoingFile` の初期化時にディレクトリを明示的に弾く (再発防止)

なお動画 (`IMG_0045.mov` 9.4 MB) は正常に送れていました。`.pvt` は
Live Photo 固有の問題です。

### 3. Live Photo のペア動画

ご要望どおり**写真ライブラリ権限を要求する方式に変更**しました。

`PHAssetResource.assetResources(for:)` で構成リソースを列挙し、

| 種類 | 選ぶリソース |
|---|---|
| 静止画 | `.fullSizePhoto` → 無ければ `.photo` |
| 動画 | `.fullSizeVideo` → 無ければ `.video` |
| Live Photo のペア動画 | `.fullSizePairedVideo` → 無ければ `.pairedVideo` |

編集済みなら編集後 (`.fullSize*`) を優先します。Live Photo は
**静止画 + ペア動画の 2 ファイル**として送られます。

**`PHAssetResourceManager.writeData(for:toFile:)` を使っています。**
FlyingCarpet は `requestData` で `NSMutableData` に貯めていますが、
12 GB 級の動画で jetsam に殺されるため、ディスクへ直接書く API を選びました。
受信側で確立した「メモリに載せない」方針と揃えています。

権限が得られなかった場合は従来の経路に落ち、`.pvt` はスキップして
その旨をログに出します。

## M4 の結論

**双方向の転送が成立しました。**

| 検証 | 結果 |
|---|---|
| テキストのみ | ✅ |
| JPEG 12 KB | ✅ |
| 複数ファイル同時 (IPA 1.5 MB + ZIP 1.5 MB) | ✅ |
| **Windows PC (`名's PC`) への送信** | ✅ |

Android だけでなく **Windows の Quick Share にも送れた**のは大きな収穫です。
NearDrop 系の実装が Windows と相互運用できることは知られていましたが、
今回の実装でも同じ土俵に乗っていることが確認できました。

なお `POSIXErrorCode(96): No message available on STREAM` は、
送信完了後に相手が接続を閉じたときの正常な終了です。
M5 では送信完了後の切断を WARN ではなく INFO で記録するようにしました。

## M5 でやること

### 1. フォルダ送信

Quick Share は `FileMetadata.parent_folder` (proto フィールド 7) と
`PayloadHeader.parent_folder` でディレクトリ構造を運べます。
選んだフォルダを再帰列挙し、相対パスをこの 2 つに載せます。

**`parent_folder` に選んだフォルダ自身の名前を含めるかはトグルにしました。**
Bada は「含めない」方針で、`Trip/photos/sunset.jpg` を
`name = "sunset.jpg"` / `parent_folder = "photos"` として送ります
(受信側が選んだ保存先の直下に展開される前提)。
一方 FlyingCarpet は含める方針です。どちらが stock 実装と噛み合うかは
実機で確かめる価値があるので、**1 回のインストールで両方試せる**ように
してあります。(検証済み: Android 側の保存構造はトグルに追従する。既定値は ON)

**受信側も `parent_folder` に対応しました。** `Received/<parent_folder>/` の下に
展開します。相手から来たパスなので、要素ごとに検証して `..` を弾き、
必ず `Received/` の内側に収まるようにしています。

### 2. 写真・動画の送信

`PHPickerViewController` を使います。理由は 2 つあります。

- **写真ライブラリの権限が要りません。** ユーザーが選んだ項目だけがアプリに渡ります。
- **元ファイルのバイト列がそのまま得られます。** 再エンコードされないので
  EXIF / GPS / 動画のコーデックが保たれます
  (`preferredAssetRepresentationMode = .current`)。

`loadFileRepresentation` が渡す URL はコールバックを抜けると消えるため、
その場で `tmp/QSProbeOutbox/` へコピーします。FlyingCarpet の iOS 実装と同じ扱いです。
コピーした一時ファイルは送信完了・中止・選択解除のいずれでも削除します。

### 追加・変更されたファイル

| ファイル | 内容 |
|---|---|
| `PhotoPicker.swift` | `PHPickerViewController` のラッパー |
| `Protocol/OutgoingItems.swift` | `PendingItem` / `SecurityScope` / `FolderScanner` / `Outbox` |
| `Protocol/OutboundSession.swift` | `parent_folder` の送出 |
| `Protocol/ReceivedItems.swift` | `parent_folder` の安全な解決 |
| `Protocol/InboundSession.swift` | 受信時のディレクトリ復元 |

### 設計上の判断

**フォルダのセキュリティスコープは 1 個だけ開いて共有します。** 子ファイルごとに
`startAccessingSecurityScopedResource()` を呼ぶのではなく、フォルダ自身のスコープを
`SecurityScope` クラスで保持し、送信完了まで ARC で生かします。
子ファイルは親のスコープが開いている間だけ読めるためです。

**フォルダの列挙はバックグラウンドで行います。** 数千ファイルのフォルダを
メインスレッドで走査すると UI が固まります。

**`NSFileCoordinator` 経由で列挙します。** iCloud Drive 上のフォルダなど、
他プロセスが触っている可能性のある場所を安全に読むためです。

## 検証手順

> **前提**: SideStore でインストールすること。LiveContainer では
> Bonjour のサービスタイプが許可リストに無いため探索・広告が失敗します
> (`docs/LiveContainer-patch.md` の手順を当てれば動きます)。

### フォルダ送信 (M5 で検証済み)

ON / OFF のどちらでも Android 側の保存構造がトグルに追従することを確認済みです。
既定値は ON (フォルダ名を含める) のままにしてあります。

### 写真・動画送信 (M5.1 の本題)

1. 「写真・動画を選ぶ」→ 初回は**写真ライブラリの許可ダイアログが出る**ので許可
2. **Live Photo を選ぶ** → 複数選択も可
3. 相手をタップして送信

期待される挙動:

- Live Photo 1 件 → **2 ファイル** (`IMG_xxxx.HEIC` と `IMG_xxxx.MOV`) が送られる
- 通常の写真 → 1 ファイル
- 動画 → 1 ファイル、元のコーデックのまま
- Android 側でファイル名・撮影日時・位置情報が保たれているか確認

「Live Photo のペア動画も送る」トグルを OFF にすると静止画だけになります。

権限を拒否した場合は、`.pvt` をスキップした旨がログに出ます。
その場合でも通常の写真・動画は送れます。

### 受信側のフォルダ復元

Android からフォルダを送り返して、`Received/` の下に階層が復元されるか確認してください。
Bada は「Send folder」ボタンでフォルダ送信に対応しています。

## 既知の制約

- **LiveContainer では素のままでは動きません。** ホストの `NSBonjourServices`
  許可リストに `_FC9F5ED42C8A._tcp` が無いためです。SideStore を使うか、
  `docs/LiveContainer-patch.md` の手順で LiveContainer 側にタイプを追加してください。
  (Local Network / 写真ライブラリの**権限そのものは LiveContainer でも取得できます**)
- **BLE アドバタイズができない**ため、Android 側が受信画面を開いていないと
  こちらから見つけられません。
- Wi-Fi Direct / ホットスポット経路は未対応です。同一 LAN 必須です。
- バックグラウンドでは動きません。転送中は画面を点けたままにしてください。

## ログの取り出し方

- 画面下部にリアルタイム表示
- 右上メニュー →「ログを共有」
- `Documents/Log/qsprobe-<日時>.log`

## 由来

| ファイル | 由来 |
|---|---|
| `Base64Url.swift` / `QuickShareMdns.swift` / `EndpointInfo.swift` | Bada `core-protocol` |
| `FramedConnection.swift` | Bada `transport/FramedConnection.kt` |
| `D2DKeys.swift` | Bada `crypto/D2DKeyDerivation.kt` + `crypto/pin/PinDerivation.kt` |
| `SecureChannel.swift` | Bada `crypto/securemessage/` |
| `Ukey2Server.swift` / `Ukey2Client.swift` | Bada `ukey2/` |
| `OutgoingItems.swift` (フォルダ規約) | Bada `send/DocumentTreeFileSourceFactory.kt` |
| `OutgoingItems.swift` (列挙) / `PhotoPicker.swift` | FlyingCarpet `Apple/shared/Transfer.swift` + `Apple/iOS/FlyingCarpet/ViewController.swift` |
| `Sources/Protobuf/*.pb.swift` | QuickDrop からそのまま (UNLICENSE) |
