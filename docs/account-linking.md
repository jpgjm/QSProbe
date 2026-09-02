# アカウント連携 — 第1段 (OAuth のみ)

Google アカウントに紐づく `PublicCertificate` を取得して、相手が誰かを
照合できるようにするための下準備。**第1段では OAuth だけ**を通します。

この段で確かめたいことは 1 つです。

> `nearbysharing-pa` という 1P スコープの同意画面が、外部のクライアントから
> 出るのか。出ないなら、以降の段は成立しません。

## 実装したもの

```
Sources/Account/
  AccountConfig.swift            接続先の定数 (UserDefaults で上書き可)
  AccountTokens.swift            トークンの型と Keychain 保存
  AccountSupport.swift           PKCE と、継続を 1 回だけ再開する小箱
  LoopbackRedirectServer.swift   127.0.0.1 で認可コードを受ける短命サーバ
  AccountOAuth.swift             認可フロー本体 (PKCE / 交換 / 更新 / 解除)
  AccountStore.swift             画面から見える状態
  AccountSectionView.swift       「実験機能」セクション
```

既存コードへの変更は `ContentView` に `AccountSectionView()` を 1 行足しただけです。
送受信の経路には触れていません。

## 使い方

1. 診断セクションの下、**実験機能 → アカウント連携 (第1段: OAuth)** を開く
2. 「この実験機能を使う」をオンにする → 警告に同意する
3. リダイレクトの受け口を選ぶ (既定は **ループバック**)
4. 「Google でサインイン」

結果はログに全部残ります。共有した zip を見れば判定できます。

## リダイレクト方式が 2 つある理由

`redirect_uri` に何を使えるかは、この `client_id` が Google のコンソール上で
**どの種別として登録されているか**で決まります。バイナリからは種別まで
読み取れないため、両方を用意しました。

| 種別 | 使える redirect_uri | この実装の呼び名 |
|---|---|---|
| iOS / Android | `com.googleusercontent.apps.<client>:/oauth2redirect` | カスタムスキーム |
| デスクトップ | `http://127.0.0.1:<port>/oauth2redirect` | ループバック |

`nearby_share.exe` は Windows のアプリなので、**ループバックが本命**と見て
既定にしてあります。`redirect_uri_mismatch` が返ったら、もう一方に切り替えて
やり直してください。

### ループバックはどう成立しているか

認可画面を出すのは `ASWebAuthenticationSession` (別プロセス) ですが、
`127.0.0.1` は端末に閉じたアドレスなので、そこからアプリ内の `NWListener` に
届きます。外部 Safari で開くと QSProbe が背面に回り、iOS が listener ごと
止めてしまうため、**必ず `ASWebAuthenticationSession` から開きます**。

待ち受けは `requiredLocalEndpoint` で 127.0.0.1 だけに束縛しています。
全インタフェースで待つと、同じ Wi-Fi の他人が認可コードを取りに来られる
余地が生まれるためです。ループバックなのでローカルネットワーク権限とも
無関係で、追加の許可ダイアログは出ません。

## 返ってきたものの読み方

| ログに出る文字列 | 意味 | 次の一手 |
|---|---|---|
| `redirect_uri_mismatch` | 受け口の形が登録と違う | リダイレクト方式を切り替える |
| `invalid_client` | client_id か client_secret の問題 | 設定欄に client_secret を入れる |
| `invalid_scope` | そのスコープを外部に出さない | **第1段はここで終わり** |
| `access_denied` | 同意画面で拒否 / 1P 専用 | 自分で拒否したのでなければ、実質 1P 専用 |
| `admin_policy_enforced` | 組織アカウントの制限 | 個人アカウントで試す |
| HTTP 200 + `access_token` | 通った | 第2段へ |

同意画面が出たのに**要求したスコープが降りてこない**こともあります。
その場合は「要求したのに降りなかったスコープ」という警告がログに出ます。
`access_token` があっても、そのスコープが無ければ第2段は通りません。

### ログに残らないもの

Google が**認可画面の中でエラーページを返した**場合 (`Error 400: redirect_uri_mismatch`
など)、リダイレクトが起きないためアプリには何も届きません。ログには
「認可を取り消しました」としか残らないので、**画面に出た文言を控えてください**。
`redirect_uri_mismatch` は詳細欄に実際に送った `redirect_uri` が表示されます。

## client_secret について

デスクトップ型のクライアントは、トークン交換で `client_secret` を要求します
(「秘密」とは名ばかりで、配布物に埋まっている類のものです)。
`nearby_share.exe` からは取れていないので、既定では送りません。
`invalid_client` が返るようなら、バイナリから探して設定欄に入れてください。

## 塞がれたときの差し替え

iOS では `defaults write` が使えないため、**画面から上書きできる**ように
してあります (実験機能 → 接続先の設定)。

- `client_id`
- `client_secret`
- `scope` (空白区切り)
- `redirect` のパス

空欄なら既定値に戻ります。「アカウント設定を初期化」で全部消せます。

`ASWebAuthenticationSession` は `Info.plist` の登録が無くてもコールバックを
拾えるので、`client_id` を画面から差し替えてもカスタムスキーム方式は
そのまま動きます。`Info.plist` に書いてあるスキームは Google の作法に
合わせただけのものです。

## 保存先

トークンは Keychain の、この実験専用のサービス名に入れます。

```
サービス名: com.anony.qsprobe.account.experimental
```

実験機能をオフにすると、その時点で消えます。

SideStore で**アンインストール → 再インストール**すると、Keychain の項目が
読めなくなることがあります。その場合は「未サインイン」に戻るだけなので、
もう一度サインインしてください。

## 第2段へ向けた課題

設計メモでは「iOS 18 で `HTTPURLResponse` に trailer が追加されている」と
していましたが、**公開 API にそれらしいものは見当たりません**。
`URLSession` は HTTP/2 の trailer を素直には出しません。unary gRPC の
`grpc-status` は trailer に載るので、ここが第2段の要になります。

現実的な選択肢は 2 つです。

1. **gRPC-Web (`application/grpc-web+proto`) を試す**
   trailer が**本文の末尾のフレーム** (フラグバイト `0x80`) として届くため、
   `URLSession` だけで完結します。`*-pa.googleapis.com` が受けるかは未確認で、
   まずここを試す価値があります。
2. **本文の有無だけで判定する**
   `grpc-status` が読めなくても、HTTP ステータスと本文の有無で 401/403 は
   切り分けられます。細かい理由は取れません。

なお本体の deployment target は 16.6 です。第2段で iOS 18 以降の API に
頼る形になるなら、この実験セクションだけ `@available` で切る必要があります。

## 第2段以降 (未着手)

- `GetAccountInfo` を叩いて `current_dusi` を得る
- `PublishDevice` + `QuerySharedCredentials`
- `SharedCredential.data` が `PublicCertificate` かを実測する
- `InboundSession` の照合ロジックへ組み込む


---

# 実測でわかったこと (stage2d 時点)

## 運び方は確定した

```
Content-Type: application/grpc+proto  → HTTP 404 / text/html         gRPC と認識されない
Content-Type: application/grpc        → HTTP 200 / application/grpc   ★
Content-Type: application/x-protobuf  → HTTP 404 / text/html         この host には無い
  (パスは /$rpc/…)
```

**違いは Content-Type だけ**だった。仕様上はどちらも有効なはずだが、Google の
フロントエンドは `application/grpc+proto` を gRPC として扱わない。
設計メモに書いてあった `application/grpc+proto` がそのまま原因だった。

`grpc-status` は **応答ヘッダ**に載って返ってくる (trailers-only 応答)。
設計メモが懸念していた「`URLSession` が HTTP/2 の trailer を出せない」問題は、
少なくともエラー時には起きない。

## いま返ってくるもの

```
grpc-status: 12 (UNIMPLEMENTED)
grpc-message: The GRPC target is not implemented on the server,
              host: nearbysharing-pa.googleapis.com,
              method: /google.nearby.identity.v1.NearbyService/GetAccountInfo.
```

- **ホストは正しい** — gRPC を喋るサーバに到達している
- **経路名が違う** — そのサービス/メソッドがそこに登録されていない

バイナリから復元した `google.nearby.identity.v1` が、GFE に登録されている
名前と一致していない。Google の内部サービスは `google.internal.…` 配下に
置かれていることがある。

## 経路の総当たり

`UNIMPLEMENTED` はハンドラの手前で返るので、1 本あたり 50ms 程度しかかからない。
数十件を総当たりしても一瞬で終わる。

「経路の総当たり (第2段)」の欄に候補を 1 行 1 件で書く。

- `/` で始まる行 → フルパスとしてそのまま叩く
- サービス名だけの行 → 読み取り専用メソッドを総当たり
- `#` で始まる行 → 無視

判定は `grpc-status` を見るだけ。

| 応答 | 意味 |
|---|---|
| `UNIMPLEMENTED` (12) | そこには無い |
| HTML の 404 | gRPC ですらない |
| それ以外 (0 / 7 / 16 / 3 …) | **ハンドラまで届いた** = 経路が当たっている |

`PERMISSION_DENIED` でも `INVALID_ARGUMENT` でも当たりである点が重要。
空のリクエストを送っているので、当たれば引数エラーが返るのが自然。

### 書き込み系は入れていない

`PublishDevice` / `MintTalismans` / `UpdateTalismanKey` は総当たりの対象から
外してある。`UNIMPLEMENTED` はハンドラの手前で返るので外れているうちは
無害だが、**当たったときは実際に走ってしまう**。空の `Device` が登録される
可能性があるため、経路が確定してから明示的に叩く。

## いちばん確実なのはバイナリから取ること

gRPC の C++ スタブは、メソッドのフルパスを**文字列リテラルとして
バイナリに埋め込む**。正解は `nearby_share.exe` の中にある。

```bash
strings -n 20 nearby_share.exe | grep -E '^/[A-Za-z0-9_.]+/[A-Za-z]+$'
strings nearby_share.exe | grep -i 'nearby.*identity'
strings nearby_share.exe | grep '/PublishDevice\|/QuerySharedCredentials'
```

出てきたパスをそのまま候補欄に貼れば、その場で確かめられる。

## 設定の持ち出し

アンインストール → 再インストールで `UserDefaults` ごと消えるため、
`client_secret` や scope の上書きが毎回失われていた。

「設定をコピー (JSON)」と「クリップボードから読み込む」を追加した。
**書き出した JSON には client_secret が入る**ので、貼り付け先に注意すること。


---

# バイナリから確定した値 (stage2e)

`NearbyShare` の配布物を解析し、推測で埋めていた箇所を実測値に置き換えた。

## gRPC のメソッドは全部そのまま入っていた

`nearby_share.exe` の `nearby_identity_grpc_async_client.cc` の周辺に、
フルパスの文字列リテラルとして 10 本並んでいる。

```
/google.nearby.identity.v1.NearbyService/PublishDevice
/google.nearby.identity.v1.NearbyService/QuerySharedCredentials
/google.nearby.identity.v1.NearbyService/GetAccountInfo
/google.nearby.identity.v1.NearbyService/MintTalismans
/google.nearby.identity.v1.NearbyService/GetIdentityBrokerConfig
/google.nearby.identity.v1.NearbyService/UpdateTalismanKey
/google.nearby.identity.v1.NearbyService/QuerySharedCredentialsWithBindingIds
/google.nearby.identity.v1.NearbyService/InitiateBinding
/google.nearby.identity.v1.NearbyService/JoinBinding
/google.nearby.identity.v1.NearbyService/DeleteBinding
```

**設計メモのサービス名は正しかった。** `google.internal.…` ではない。
`InitiateBinding` / `JoinBinding` / `DeleteBinding` が `binding.proto` ではなく
同じ `NearbyService` に生えている点だけ、設計メモと違う。

## 宛先が 2 つある

`grpc_async_client_factory.cc` の周辺に、この 2 つが隣り合って埋まっている。

```
nearbysharing-pa.googleapis.com
nearby.googleapis.com
```

そして gRPC クライアントも 2 つある。

```
nearby_identity_grpc_async_client.cc   → NearbyService (identity)
nearby_share_grpc_async_client.cc      → NearbySharingService.ListContactPeople
```

identity 側が `nearby.googleapis.com` だと判断した根拠は、proto の
`google.api.resource` 註釈が資源名をこう宣言していること。

```
nearby.googleapis.com/Device
devices/{device}
nearby.googleapis.com/IdentityBrokerConfig
```

資源名の前半はその資源を持つ API のホストを指す。`Device` も
`IdentityBrokerConfig` も identity の proto (`resources.proto`) の型なので、
**identity API のホストは `nearby.googleapis.com`**。

`nearbysharing-pa.googleapis.com` に identity のパスを投げて
`UNIMPLEMENTED` が返っていたのは、これで説明がつく。**経路名ではなく
宛先が違った**。

## その他の確定値

```
client_id     (nearby_share.exe から取得)
client_secret (nearby_share.exe から取得)
scope         https://www.googleapis.com/auth/nearbysharing-pa
```

**値そのものはこのリポジトリに置かない。** GitHub の push protection が
Google の OAuth 資格情報として検出し、push を拒否する。取り出し方はこう。

```bash
strings -n 10 nearby_share.exe | grep -oE '[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com'
strings -n 10 nearby_share.exe | grep -oE 'GOCSPX-[A-Za-z0-9_-]+'
```

取れた値は設定テキスト (`AccountSettings.txt`) に書いて、アプリの
「接続先の設定 → 設定ファイルから読み込む」で取り込む。

バイナリに `AIza…` 形式の API キーは無い。`x-goog-api-key` も送っていない。
`x-goog-api-client` は入っているが、認可には使われない類のもの。

`client_secret` は既定値として持たせた。Google 自身が「インストール型アプリの
client_secret は秘密として扱わない」としている類の値で、アンインストールの
たびに入れ直す手間のほうが実害が大きい。

## 別系統の存在

同じバイナリに、まったく別のサービスも入っている。

```
/google.quick_share_sdk.v1.QuickShare/…            ローカルの IPC (SDK)
/google.quick_share_sdk_internal.v1.QuickShareInternal/…
/location.nearby.sharing.v1.NearbySharingService/ListContactPeople
```

`quick_share_sdk` は Windows アプリ内部のプロセス間通信で、ネットワーク越しの
API ではない。今回の目的には関係しない。


---

# 資格情報の与え方 (stage2f)

## コードには入れない

`client_id` と `client_secret` をソースに書いたところ、GitHub の
push protection が両方を検出して push を拒否した。

```
- Push cannot contain secrets
  —— Google OAuth Client ID ——
  —— Google OAuth Client Secret ——
```

検出器から見れば Google の OAuth 資格情報そのもので、実際
`nearby_share.exe` から抜いた値なので、公開リポジトリに置く筋合いも無い。
`Info.plist` の `CFBundleURLTypes` に書いていた逆順クライアント ID も
同じ理由で外した (カスタムスキーム方式はそもそも使えないので実害も無い)。

## 代わりに設定テキストで渡す

`AccountSettings.txt` のような書式のテキストを、端末側で取り込む。

```
# QSProbe アカウント連携の設定
client_id = ....apps.googleusercontent.com
client_secret = GOCSPX-....
scope = https://www.googleapis.com/auth/nearbysharing-pa
grpc_host = nearby.googleapis.com
grpc_service = google.nearby.identity.v1.NearbyService
```

- 1 行 1 件の `キー = 値`
- `#` で始まる行と空行は読み飛ばす
- 書けるキー: `client_id` `client_secret` `scope` `auth_endpoint`
  `token_endpoint` `revoke_endpoint` `redirect_path` `grpc_host` `grpc_service`

取り込み口は 3 つ。

| 方法 | 場所 |
|---|---|
| ファイルを選ぶ | 接続先の設定 → 設定ファイルから読み込む (.txt) |
| クリップボードから | 接続先の設定 → クリップボードから読み込む |
| 直接入力 | 接続先の設定の各欄 |

「いまの設定をコピー」で同じ書式に書き出せる。アンインストールで
`UserDefaults` ごと消えるので、入れ直し用に控えておくと早い。

`.gitignore` に `AccountSettings.txt` と `*.secrets.txt` を足してある。


---

# 第2段クリア (stage3a)

```
nearby.googleapis.com/google.nearby.identity.v1.NearbyService/GetAccountInfo
  → HTTP 200 / application/grpc / 24 バイト
  → current_dusi = (取得できた)
```

`nearbysharing-pa.googleapis.com` 側は 3 メソッドとも `UNIMPLEMENTED`。
**宛先の読みが当たっていた。**

## 残っている見えない部分

総当たりで `GetIdentityBrokerConfig` と `QuerySharedCredentials` は
**HTTP 200 だが 0 バイト**だった。`grpc-status` ヘッダも無い。

これは 2 つの可能性を区別できていない。

1. 本当に空の応答が返った (成功。空のリクエストを送ったので中身が無い)
2. 失敗したが、`grpc-status` が HTTP/2 の trailer に載っていて `URLSession`
   が取り零した

素の gRPC は、**失敗時は trailers-only 応答**になるので `grpc-status` が
ヘッダに現れる (`UNIMPLEMENTED` がそうだった)。しかし本体を返したあとに
失敗した場合や、本体が空の成功の場合は、trailer が HTTP/2 側に載って見えない。

## gRPC-Web を追加した

`application/grpc-web+proto` は **trailer を本体末尾のフレームで運ぶ**。

```
[0x00][長さ][protobuf 本体]
[0x80][長さ]grpc-status:0\r\ngrpc-message:...\r\n
```

フラグの最上位ビットが立っているフレームを trailer として読むようにした。
これで成功時も含めて `grpc-status` が見える。GFE が `grpc-web` を受けるかは
未確認なので、方式の Picker で切り替えて試す。

## 第3段 (読み取りのみ)

```
GetIdentityBrokerConfig(name: "identityBrokerConfig")
  → root_authority_public_keys / intermediate_authority_certificates

QuerySharedCredentials(name: "devices/{device_id}")
  → SharedCredential[] { id, data_type, data, expiration_time }
```

`device_id` の出どころは未確定。欄が空なら `devices/{current_dusi}` を
組み立てて試す。外れたら欄に直接入れて試せる。

`SharedCredential.data` が `DATA_TYPE_PUBLIC_CERTIFICATE` のとき、中身が
Bada の `wire_format.proto` の `PublicCertificate` かどうかが第 4 段の前提。
取得できたらバイト列の先頭をログに出すので、そこで判定する。

## PublishDevice はまだ入れていない

**アカウントに端末を登録する書き込み**なので、読み取りだけで分かることを
出し切ってから入れる。`device_id` をサーバが発行するのか、こちらが決めるのかも
まだ確定していない。


---

# 運び方の実測 (stage3b)

`nearby.googleapis.com` に対して 4 通りを実際に投げた結果。

| Content-Type | パス | 結果 |
|---|---|---|
| `application/grpc` | `/pkg.Svc/Method` | **成功** |
| `application/x-protobuf` | `/$rpc/pkg.Svc/Method` | **成功** |
| `application/grpc+proto` | `/pkg.Svc/Method` | HTTP 404 / text/html |
| `application/grpc-web+proto` | `/pkg.Svc/Method` | HTTP 404 / text/html |

gRPC-Web は受けてもらえなかった。trailer を本体末尾で受け取る作戦は使えない。

代わりに **`$rpc` 方式が通った**。こちらは gRPC の枠が無いので、
**失敗が素の HTTP ステータスで返る**。trailer を読む必要が無く、
`URLSession` との相性はむしろこちらが良い。

## 選択肢から落とした

`grpc+proto` と `grpc-web` は選べないようにした。うっかり選ぶと全部 404 に
なるだけで、切り分けの役に立たない。保存済みの設定が消した値を指していても、
`init?(rawValue:)` が nil を返して `.grpc` に落ちる。

## 第3段は両方式を順に試す

`GetIdentityBrokerConfig` と `QuerySharedCredentials` は、選択中の方式を
先に試し、落ちたらもう一方を試す。1 回のタップで分かることを増やすため。

`$rpc` で 0 バイトが返った場合は「全フィールドが既定値の応答」として扱う。
失敗なら HTTP が 200 以外になるので、この判断で問題ない。
素の `grpc` で 0 バイトのときは、trailer が見えないので従来どおりエラー扱い。


---

# 第3段クリア (stage3c)

## 証明書が 36 件取れた

```
QuerySharedCredentials(name: "devices/{current_dusi}")
  方式 grpc → HTTP 200, 34265 バイト
  → SharedCredential 36 件、すべて DATA_TYPE_PUBLIC_CERTIFICATE
```

**`current_dusi` がそのまま `device_id` として使える。** 推測が当たった。

`data` の先頭は一貫して `0a20` = フィールド 1、長さ 32 バイト。
Bada の `wire_format.proto` の `PublicCertificate` はフィールド 1 が
`bytes secret_id` なので、**中身は `PublicCertificate` で間違いない**。
設計メモが「決定的な仮定」としていた部分が、実測で裏付けられた。

`data` の長さは 394 / 1026 / 1037 バイトの 3 種類。証明書の世代か、
可視性 (自分の端末 / 連絡先) の違いだと思われる。

## $rpc の失敗は google.rpc.Status で返る

```
HTTP 400, application/x-protobuf
\b\x03\x12%Request contains an invalid argument.
```

これは `google.rpc.Status` の protobuf。field 1 = code (3 = INVALID_ARGUMENT)、
field 2 = message。手で解いてログに出すようにした。

`grpc` 方式では同じ失敗が「HTTP 200 / 0 バイト」にしか見えない。
**$rpc のほうが失敗の理由が分かる**ので、両方式を順に試す価値がある。

## GetIdentityBrokerConfig は名前が違う

```
name = "identityBrokerConfig" → INVALID_ARGUMENT
```

バイナリの descriptor には `nearby.googleapis.com/IdentityBrokerConfig` という
資源型の宣言はあるが、**資源名のパターン文字列が入っていない**
(`Device` には `devices/{device}` があるのに)。名前の形が読み取れない。

ただしこの RPC は証明書の検証に使う根の公開鍵を取るためのもので、
**照合そのものには要らない**。優先度を下げる。

## secret_id_hash の作り方はこれから

相手が `PAIRED_KEY_ENCRYPTION` に載せてくるのは 6 バイト。
`secret_id` は 32 バイト。間の変換は実測で当てる。

候補を 3 つ計算して全部持っておく。

| 名前 | 作り方 |
|---|---|
| `sha256` | SHA-256(secret_id) の先頭 6 バイト |
| `prefix` | secret_id の先頭 6 バイト |
| `suffix` | secret_id の末尾 6 バイト |

受信時に突き合わせ、**どれで一致したか**をログに出す。
自分の Android 端末は同じアカウントなので、その証明書は 36 件の中にあるはず。
一度受信すれば作り方が確定する。

## いまは記録するだけ

一致しても `PAIRED_KEY_RESULT` の返し方は変えていない。
署名の検証 (`signed_data` を `public_key` で検証) はそのあと。
順番を守らないと、何が効いたのか分からなくなる。

証明書は `Documents/AccountCertificates/` に生の protobuf のまま置く。
JSON に詰め直すと、あとで別の解釈をしたくなったときに情報が落ちる。


## メインアクターの境界 (stage3d)

`StoredCertificate` は素の struct で、どのアクターにも属さない。そこから
`@MainActor final class CertificateStore` の `static func hex` を呼ぶと、
非隔離の同期文脈からメインアクター隔離のメソッドを呼ぶことになりビルドが落ちる。

```
error: call to main actor-isolated static method 'hex(_:limit:)'
       in a synchronous nonisolated context
```

`hex` は純粋な変換で共有状態に触れないので、`nonisolated static func` にした。

**型を跨ぐときはこの境界を毎回確認する。** 同じ型の中に閉じている
`ProbeOutcome` や `ClientError` は、囲っている型と同じ扱いになるので問題ない。


---

# secret_id_hash の正体 (stage3e)

## 一致しなかった

36 件の証明書を持った状態で受信したが、`secret_id_hash` はどれとも
一致しなかった。観測値は接続ごとに違う。

```
fa6e60baf958
c45634babce1
f64342dbc11c
110b53260cf7
fc94dc4a68d1
```

証明書の識別子なら、証明書の有効期間 (数時間〜数日) のあいだは
同じ値が出るはずで、**数分のあいだに毎回変わるのはおかしい**。

## バイナリに答えがあった

`third_party/nearby/sharing/paired_key_verification_runner.cc` の周辺に
こういう関数名が埋まっている。

```
VerifyAuthTokenHashWithPrivateCertificate
Attempts to sign authentication token with a previous private key.
```

つまりこの値は**証明書の識別子ではなく、UKEY2 の認証トークンを
証明書の鍵で潰したもの**。名前が `secret_id_hash` なので紛らわしいが、
中身は認証トークンのハッシュ。接続ごとに変わるのはそのためで、
実測と辻褄が合う。

## 潰し方は総当たりで当てる

HKDF なのか HMAC なのか、引数の順序がどちらかまでは、文字列からは読めない。
証明書 1 件につき次を計算して、一致したものを採用する。

鍵になりうるもの: `authenticity_key` (フィールド 2) と `secret_id` (フィールド 1)。
RPC 側の proto では フィールド 2 が `secret_key` と呼ばれている。名前が違うだけ。

| 名前 | 作り方 |
|---|---|
| `hkdf(key,salt=token)` | HKDF-SHA256(ikm=鍵, salt=トークン, info=空, 6 バイト) |
| `hkdf(token,salt=key)` | 引数を入れ替えたもの |
| `hmac(key,token)` | HMAC-SHA256(鍵, トークン) の先頭 6 バイト |
| `hmac(token,key)` | 引数を入れ替えたもの |
| `sha256(key\|token)` | 連結して SHA-256、先頭 6 バイト |
| `sha256(token\|key)` | 連結の順を入れ替えたもの |

Chromium 系の実装は `HkdfSha256(ikm: secret_key, salt: auth_token,
info: 空, 6 バイト)` の形なので、`hkdf(key,salt=token)` が本命。

`authString` は `InboundSession` が UKEY2 完了時に握っている値
(`ukey2AuthKey`) をそのまま使う。

## 外れたときに何を足すか分かるようにした

一致しなかった場合、証明書 1 件ぶんの候補を**全部ログに出す**。
`authString` の長さと先頭も出す。当たらなかったときに、次に何を試せばよいかを
その場で決められる。


---

# まだ一致しない (stage3f)

12 通り × 36 件で外れた。観測値と材料は次のとおり。

```
secret_id_hash = e52efe11fe99   (接続ごとに変わる)
authString     = 32 バイト / da13b53a22e73fe7…
証明書         = 36 件、いずれも復元できている
```

## 増やした軸

### 認証トークンの長さ

UKEY2 の authString は 32 バイトだが、Nearby Connections が
**認証トークンとして使う長さ**は確定できていない。実装によっては 5 バイト。

HKDF-Expand の出力は前方一致するので、`GetVerificationString(5)` は
`GetVerificationString(32)` の先頭 5 バイトと同じ値になる。
つまり長さ違いは「先頭を切る」だけで再現できる。

試す長さ: 32 (全体) / 5 / 4 / 6 / 16。

### 鍵になりうるもの

`authenticity_key` (フィールド 2) に加えて、`secret_id` (フィールド 1) と
`metadata_encryption_key_tag` (フィールド 7) も試す。

### 合計

3 種の鍵 × 5 種の長さ × 6 通りの潰し方 = 90 通り。
これを 36 件ぶん回す。計算量は無視できる。

## 先に確かめること

**証明書に鍵が入っているのか。**

RPC 経由で取れる `PublicCertificate` に `authenticity_key` が入っていなければ、
鍵を使う導出は最初から成立しない。総当たりを増やす前に確かめるべきことなので、
取り込み時にフィールドの中身を数えてログに出すようにした。

```
Account 証明書:   --- フィールドの中身 ---
Account 証明書:     secret_id = 36/36 件 (32 バイト)
Account 証明書:     authenticity_key = ?/36 件
Account 証明書:     public_key = ?/36 件
Account 証明書:     encrypted_metadata = ?/36 件
Account 証明書:     metadata_key_tag = ?/36 件
```

`data` の長さが 394 / 1026 / 1037 の 3 種類あったので、
**入っているフィールドが証明書ごとに違う**可能性が高い。
394 バイトのものは metadata を持っていないはず。

`authenticity_key` が全件で空なら、この経路では照合できないという結論になり、
`PublishDevice` と binding を通す方向に切り替えることになる。


---

# proto の形が違う (stage3g)

## 鍵はある

```
secret_id          36/36 件 (32 バイト)
authenticity_key   36/36 件 (32 バイト)
public_key         36/36 件 (91 バイト)
encrypted_metadata  0/36 件
metadata_key_tag   36/36 件 (14 バイト)
```

鍵が空という最悪の筋は消えた。92 通り × 36 件でも一致しないので、
別の理由がある。

## 数が合っていない

読めているフィールドの合計はこうなる。

```
32 + 32 + 91 + 14 = 169 バイト (+ タグと長さで 180 バイト程度)
```

ところが `data` の実長は **394 / 1026 / 1037 バイト**。
**半分以上が見えていない。**

つまり `SharedCredential.data` は、Bada の `wire_format.proto` の
`PublicCertificate` と**同じ形ではない**。フィールド 1〜3 が偶然
筋の通る値になっただけで、4 番以降の対応はずれている可能性が高い。

`metadata_encryption_key_tag` が 14 バイトというのも不自然で、
HMAC のタグなら 32 バイトのはず。バイナリの descriptor には
`nearby.sharing.proto.PublicCertificate.binding_id` という
**Bada 側に無いフィールド**も見えている。

## 推測を足す前に、構造を出す

定義を当てずっぽうで足していくと、当たったのか偶然かの区別がつかなくなる。
先に「何番のフィールドが何バイトあるか」を機械的に出す。

`ProtoInspector` を追加した。定義を持たないまま、ワイヤ形式だけを頼りに
フィールド番号・ワイヤ型・長さへばらす。

- 長さ付きフィールドは、中身が印字可能なら文字列として出す
- 先頭が妥当なタグに見えれば「入れ子か」と注記する
- varint がミリ秒エポックに見える範囲なら日時も添える
- 読めた中身が全体の半分未満なら、その旨を出す

取り込み時に、**`data` の長さの種類ごとに 1 件**だけ構造を出す。
394 / 1026 / 1037 の 3 種類あるので 3 件ぶん。

ここが出れば、正しい定義を書ける。書き直したうえで、
`secret_id_hash` の照合をやり直す。


---

# proto の正しい形 (stage3h)

`ProtoInspector` の出力から、`SharedCredential.data` の形が確定した。

```
f1  bytes 32          secret_id
f2  bytes 32          secret_key
f3  bytes 91          public_key            (P-256 の SubjectPublicKeyInfo)
f4  message 6         start_time            (google.protobuf.Timestamp)
f5  message 6         end_time
f7  bytes 14          metadata_encryption_key
f8  bytes 162〜215    encrypted_metadata_bytes
f9  bytes 32          metadata_encryption_key_tag
f10 varint = 1        trust_type
f11 bytes 578〜587    (入れ子。長い個体だけに付く)
```

## Bada とは 2 つずれていた

| | Bada `wire_format.proto` | RPC 側 |
|---|---|---|
| metadata 本体 | f6 | **f8** |
| metadata 鍵の tag | f7 | **f9** |
| metadata 鍵 | 無し | **f7** |

このずれのせいで、

- `encrypted_metadata` を 0 件と誤認していた (実際は f8 に 162〜215 バイト)
- 14 バイトの `metadata_encryption_key` を tag だと誤読していた

長さも裏付けになる。Nearby Share の metadata 暗号鍵は 14 バイト、
tag は HMAC-SHA256 の出力なので 32 バイト。どちらも一致する。

**ただし `secret_key` (f2) の位置は Bada と同じ**なので、
`secret_id_hash` の照合に使っていた鍵自体は正しかった。
proto を直しても、その一点だけでは一致しない。

## なぜ一致しないのか — 次に疑うところ

材料は揃っていて、潰し方も 90 通り試して外れている。
残る筋は「**相手が証明書を使っていない**」。

バイナリにこういう文字列がある。

```
Incoming connection with non-everyone visibility cannot verify public certificate.
```

Quick Share の公開範囲が「**全ユーザーに表示**」のとき、送信側は
アカウントの秘密証明書で署名せず、`secret_id_hash` に**乱数**を入れる。
QSProbe 自身も同じことをしている (`randomData(6)`)。

これなら実測と完全に辻褄が合う。

- 接続のたびに値が変わる ✅
- どの証明書とも一致しない ✅
- `signed_data` は 71 バイト付いている (乱数でも長さは揃う) ✅

**確かめ方はアプリの変更ではなく端末の設定。**
F-51F の Quick Share の公開範囲を「連絡先」か「自分のデバイス」に変えて、
もう一度送る。それで一致すれば、この読みで確定する。

## 併せて増やしたもの

- 鍵の候補に `metadata_encryption_key` (f7) と
  `metadata_encryption_key_tag` (f9) を追加。4 種 × 5 長さ × 6 通り = 120 通り
- `trust_type` を表示に出す。自分の端末と連絡先の区別が付く
- `f11` の中身も一段だけ掘って構造を出す


---

# 誰の証明書かを出す (stage3i)

## 直した proto は当たっていた

```
secret_id          36/36 (32 バイト)
secret_key         36/36 (32 バイト)
public_key         36/36 (91 バイト)
metadata_key       36/36 (14 バイト)
encrypted_metadata 36/36 (162/213/215 バイト)   ← 0 件ではなかった
metadata_key_tag   36/36 (32 バイト)
extra_blob         30/36 (578/587 バイト)
```

`f11` の中身も出た。証明書の有効期間は 3 日、末尾に `"Ed25519"` の
文字列と 32 バイトの鍵が並ぶ。`MintTalismans` が返す identity talisman の
類と思われる。今回の照合には要らない。

## それでも一致しない

122 通り × 36 件で外れた。原因の候補は 2 つに絞れる。

1. 相手が証明書を使っていない (公開範囲が「全ユーザー」なら乱数を送る)
2. そもそも持っている 36 件が相手のものではない

**metadata を開ければ 2 を直接確かめられる。** 端末名が出るので、
相手の端末が一覧に居るかどうかが分かる。

## 復号の手順

```
鍵      = HKDF-SHA256(ikm: metadata_encryption_key, salt: 空, info: 空, 32)
カウンタ = 上の先頭 16 バイト
平文    = AES-256-CTR(鍵, カウンタ)
```

CryptoKit に CTR が無いので `CCCryptorCreateWithMode` を使う。
導出のしかたに確信が持てないので 3 通り試し、`EncryptedMetadata` として
読めて**文字列が壊れていないもの**を採用する。

## 手前で効く自己検査

`metadata_encryption_key_tag` は `SHA-256(metadata_encryption_key)` のはず。
これが 36/36 で合えば、フィールドの対応が正しいことの裏付けになる。
復号を試すより先にこちらで当たりを付ける。

## 読み方

| ログ | 意味 | 次の一手 |
|---|---|---|
| tag が 36/36 一致 | proto の対応は正しい | 復号結果を見る |
| 復号できて相手の端末名がある | 証明書は合っている | 「相手が証明書を使っていない」に絞れる |
| 復号できて相手の端末名が無い | 証明書の集合が違う | 資源名や取得経路を見直す |
| 1 件も復号できない | 鍵の導出が違う | 復号の候補を増やす |


## 排他アクセス (stage3j)

```
error: overlapping accesses to 'output', but modification requires
       exclusive access; consider copying to a local variable
```

`output.withUnsafeMutableBytes { ... output.count ... }` と書いていた。
可変借用の最中に同じ変数を読むと弾かれる。長さは借用の外で控えるか、
閉包が受け取るバッファ側 (`outputBytes.count`) を使う。

`withUnsafeBytes` (読み取り) の中で `key.count` を読むのは、
読み取り同士なので問題ない。**可変借用のときだけ**気を付ける。

置換のあとに走らせる照合項目に加えた。


---

# 決め打ちをやめる (stage3k)

## tag の検算が 0/34 で外れた

`metadata_encryption_key_tag = SHA-256(metadata_encryption_key)` という読みは
外れ。metadata の復号も 1 件も開けなかった。

決め打ちを重ねても当たらないので、**作り方そのものを探す**方式に変える。

## tag の作り方を探す

証明書の各フィールドを 5 通りで潰し、f9 と一致するものを探す。

対象: `metadata_key` / `secret_id` / `secret_key` / `public_key`
潰し方: `sha256` / `sha512` の先頭 32 / `hkdf32` /
`hmac(x, 空)` / `hmac(空鍵, x)` / `hmac(secret_key, x)`

一致するものが出れば、フィールドの対応が正しいことの裏付けになる。
1 つも出なければ、**f9 は tag ではない**ということになり、
フィールドの意味づけから見直す。

## 復号は総当たりでよい

復号は**自己検証できる**。鍵を間違えれば平文はランダムなバイト列になり、
protobuf として読めても文字列が壊れる。だから総当たりしても
「たまたま当たったように見える」ことが起きにくい。

鍵の候補 6 通り × カウンタの候補 4 通り = 24 通りを順に試し、
`EncryptedMetadata` として読めて文字列が壊れていないものを採用する。

- 鍵: `hkdf32(mkey)` / `sha256(mkey)` / `hkdf16(mkey)` /
  `sha256(mkey)` の先頭 16 / `secret_key` / `hkdf32(secret_key)`
- カウンタ: ゼロ / `hkdf16(mkey)` / 鍵の先頭 16 / `sha256(mkey)` の後ろ 16

AES の鍵長も 16 / 24 / 32 を通す。

## 当たったら手順を記録する

どの組み合わせで開いたかをログに出す。次からは一本に絞れる。


---

# tag の作り方が判明 (stage3l)

```
metadata_encryption_key_tag = HMAC-SHA256(鍵: 空, メッセージ: metadata_encryption_key)
                              34/34 件で一致
```

HMAC は鍵をブロック長までゼロ詰めするので、「鍵が空」と
「鍵が 32 バイトのゼロ」は同じ結果になる。実装側は前者だろう。

**これでフィールドの対応が確定した。**

```
f7 = metadata_encryption_key   (14 バイト)
f9 = metadata_encryption_key_tag (32 バイト)
```

`SHA-256(metadata_key)` という最初の読みが外れていただけで、
proto の読み方そのものは正しかった。

## 復号はまだ開かない

24 通りで外れた。ただし**判定の作り方に穴があった**。

以前は「`EncryptedMetadata` として読めて、文字列が壊れていないこと」を
条件にしていた。この定義のフィールド番号は推測なので、
**正しく復号できていても捨ててしまう**可能性がある。

判定を proto の定義から切り離す。

1. protobuf として最後まで読み切れること
2. 印字可能な文字列が 1 つ以上入っていること

metadata は 213 バイトあり、端末名のほかにアイコンの URL あたりが
入っているはずなので、2 は満たされる。鍵を間違えた平文はランダムな
バイト列なので、この条件はまず通らない。

## 候補も足した

tag が `hmac(空鍵, mkey)` だったので、同じ流儀の鍵を候補に加えた。
カウンタには 12 バイトの IV を右詰めした形も足した。

鍵 7 通り × カウンタ 5 通り = 35 通り。

## 開いたら構造を出す

復号後の生バイト列も持っておき、`ProtoInspector` で構造を出す。
こちらの `EncryptedMetadata` の定義が外れていても、そこから
正しい定義を書ける。


---

# 判定材料の強いほうへ移る (stage3m)

## metadata の復号は当たり判定が弱い

35 通り試して開かない。しかも判定が「protobuf として読めて、
印字可能な文字列が入っていること」という状況証拠なので、
候補を増やすほど誤判定の余地も増える。

広げ方は変えた (鍵 10 通り × カウンタ 8 通り × 暗号文の読み飛ばし 3 通り)
が、**探索は 1 件だけで行い、当たった手順を全件に使い回す**形にした。
34 件ぶん全通りを回すのは無駄でしかない。

## 広告からの特定なら正誤がはっきりする

tag の作り方が
`HMAC-SHA256(鍵: 空, メッセージ: metadata_encryption_key)` だと
34/34 件で確定した。これは**復号した鍵が正しいかをその場で検算できる**
ということ。

Nearby Share の本来の仕組みもこれで、相手を特定する手順はこうなる。

```
広告の EndpointInfo に 16 バイト = salt(2) + 暗号化された metadata 鍵(14)
  ↓ 証明書の secret_key と salt から鍵を作る
  ↓ AES-CTR で 14 バイトを復号
  ↓ HMAC-SHA256(空, 復号結果) を計算
  ↓ 証明書の metadata_encryption_key_tag と一致したら、その証明書の持ち主
```

当たり判定が厳密なので、鍵の作り方を総当たりしても誤判定しない。

`CONNECTION_REQUEST` で相手の `EndpointInfo` は既に読んでいるので、
そこに差し込んだ。受信が 1 回起きれば結果が出る。

## これで何が分かるか

| 結果 | 意味 |
|---|---|
| 特定できた | 相手の証明書を手元に持っている。`secret_id_hash` が一致しないのは別の理由 (乱数を送っている等) |
| 特定できない | 持っている証明書が相手のものではない。取得の資源名から見直す |

`secret_id_hash` の照合と違い、こちらは**言い訳の余地が無い**。
第 3 段の決着はここで付く。


---

# 第3段クリア。第4段へ (stage4a)

## 相手の証明書は手元にあった

```
★★★ 相手の証明書を特定しました (key/hkdf16(salt))
secret_id  = 0d9d4d043b079282…
metadata 鍵 = 29f2dd877201894ce2f3c1debe77
```

広告に載る 16 バイトから、正しい証明書を引き当てられた。
判定は `HMAC-SHA256(空, 復号した鍵) == metadata_encryption_key_tag`
なので、**当たりに疑いの余地が無い**。

手順も確定した。

```
鍵     = 証明書の secret_key (32 バイト) をそのまま
カウンタ = HKDF-SHA256(ikm: salt(2 バイト), salt: 空, info: 空, 16 バイト)
復号   = AES-256-CTR
```

Google は secret_key を HKDF に通さず**生のまま AES 鍵に使っている**。
metadata 本体の復号がどれだけ試しても開かなかったのは、
「鍵は必ず導出されている」と思い込んでいたせいかもしれない。

これで第 3 段の問いには答えが出た。**証明書の集合は正しい。**

## secret_id_hash は追わない

証明書が手元にあるのに、`secret_id_hash` は 122 通り × 43 件のどれとも
一致しない。ここを詰めるより、本筋に移る。

`signed_data` は 71 バイトで、先頭が `3045…` / `3044…`。
これは **DER 形式の ECDSA 署名**。証明書には `public_key`
(91 バイトの SubjectPublicKeyInfo) が入っている。

**署名を検証できれば、相手が本人であることが直接証明できる。**
ハッシュの一致は「同じ鍵を持っている」という弱い証拠でしかないので、
こちらのほうが本筋であり、Windows 版のログ文字列とも合う。

```
Successfully verified remote paired key encryption frame.
Unable to verify remote paired key encryption frame.
```

## 署名対象は総当たりでよい

何に署名しているかは文字列から読めない。UKEY2 の authString そのものか、
先頭を切ったものか、ハッシュ済みか。

**検証は正誤がはっきりする**ので、候補を並べて構わない。
署名の形式 2 通り × トークンの長さ 5 通り × ハッシュ済みか否か 2 通り。

## いまは記録だけ

署名が通っても `PAIRED_KEY_RESULT` の返し方は変えない。
何に署名しているかが確定してから切り替える。順番を守らないと、
何が効いたのか分からなくなる。

## 併せて直した

`secret_id_hash` が外れたときに並べる候補は、**広告から割り出した証明書**
に対して計算するようにした。無関係な証明書[0] の候補を並べても意味がない。


---

# 署名対象の前置き (stage4b)

## 素のトークンでは通らない

```
公開鍵 = 91 バイト / 署名 = 71〜72 バイト / authString = 32 バイト
→ 20 通りすべて外れ
```

署名は DER の ECDSA、公開鍵は P-256 の SPKI。形は合っている。
**署名の対象が違う。**

## 反射攻撃対策の印を疑う

送信側と受信側が同じ値に署名すると、片方の署名をそのまま返せてしまう
(反射攻撃)。これを避けるため、署名の前に役割を表す 1 バイトを
足すのが定石で、Nearby もその作りになっているはず。

印が 1 バイトなら 256 通りしかない。**検証は正誤がはっきりする**ので、
総当たりで特定できる。誤判定の余地も無い。

前置きと後置きの両方、トークンは全体と先頭 5 バイトの両方を見る。
署名 2 形式 × トークン 2 通り × 位置 2 通り × 256 = 2048 回の検証で、
0.2 秒程度。

## 併せて確かめてほしいこと

外れた場合、**authString 自体が Google と食い違っている**可能性が残る。
これは端末の画面で確かめられる。

受信時に QSProbe が出す確認番号と、Android 側に出る番号が一致するか。
食い違うなら、UKEY2 の authString か、そこから PIN を導く手順のどちらかが
ずれている。ログにその旨を出すようにした。


---

# 第4段クリア (stage4c)

```
★★★★ 署名を検証できました (der/t32/前置き 0x01)
相手は証明書の持ち主本人です
```

## 署名の形

```
payload   = 0x01 || authString(32 バイト)
signature = DER の ECDSA (P-256, SHA-256)
検証鍵    = 証明書の public_key (91 バイトの SubjectPublicKeyInfo)
```

先頭の `0x01` は役割を表す印。送信側と受信側が同じ値に署名すると、
片方の署名をそのまま返せてしまう (反射攻撃) ため、それを避けるためのもの。
1 バイトなので 256 通りの総当たりで特定できた。

## PIN の一致も確認できた

端末の画面で突き合わせた結果、QSProbe の確認コードと Android 側の
`PIN:` が一致した (8876 / 4795)。

つまり **UKEY2 の authString も、そこから PIN を導く手順も正しい**。
署名が通らなかった原因は前置きの印だけだった。

## PAIRED_KEY_RESULT を success で返す

検証できた場合に限り `success` を返すようにした。

`success` は「相手が名乗ったとおりの人物だと確認できた」という意味なので、
検証を通していないのに返してはいけない。逆に、検証できたのに `unable` を
返し続けるのは、この段の成果を捨てているのと同じ。

画面の「送信元」にも、検証できた相手だけ ✓ を付ける。
名前は相手が名乗っているだけの値なので、検証の有無は区別して見せる。

## ここまでで通った道筋

```
OAuth (ループバック / nearbysharing-pa スコープ)
  ↓ アクセストークン
gRPC (nearby.googleapis.com / application/grpc)
  ↓ GetAccountInfo → current_dusi
QuerySharedCredentials(devices/{current_dusi})
  ↓ PublicCertificate 30〜43 件
広告の salt(2) + 暗号化 metadata 鍵(14)
  ↓ AES-CTR (鍵: secret_key 生, カウンタ: HKDF16(salt))
  ↓ HMAC-SHA256(空, 復号鍵) == metadata_encryption_key_tag で検算
相手の証明書を特定
  ↓ public_key で signed_data を検証 (payload = 0x01 || authString)
相手が本人だと確認 → PAIRED_KEY_RESULT = success
```

## まだ残っていること

- **自分の証明書を持っていない。** `signed_data` は乱数を送っている。
  相手から見ると QSProbe は「検証できない相手」のまま。
  こちらも名乗るには `PublishDevice` で自分の証明書を登録する必要がある
  (第 3 段の書き込み側、未着手)
- `secret_id_hash` の作り方は未解明。ただし署名の検証が通る以上、
  照合には要らない
- `encrypted_metadata` の復号は未達。端末名は広告から取れているので、
  実用上の不足は無い


---

# 検証を何に使うか (stage4d)

## 表示だけでは意味が無い

受信画面に「本人確認済み」と出しても、実用上の価値はほとんど無い。
確認コードを見るには**番号を読める距離に居る**必要があり、
そこまで来ている相手なら、印が 1 つ増えても判断は変わらない。

**価値があるのは、自動承認の条件にすること。**

```
確認せずに受け取る = オン
  ↓
署名を検証できた相手  → 確認なしで受け取る
検証できない相手      → これまでどおり確認コードを出す
```

これなら「同じ Wi-Fi 上のどの端末からでも確認なしで受け取る」という
危険な状態が解消される。設定は実験機能の「受信の絞り込み」に置いた。
既定はオン。

## 2 種類の確からしさを区別する

| 場面 | 何が言えるか | 偽装できるか |
|---|---|---|
| 探索一覧 (広告が証明書と一致) | 登録済みの端末と同じ広告を出している | **できる**。広告はコピーして流せる |
| 受信時 (署名を検証) | 相手が証明書の持ち主本人 | できない。接続ごとの authString に署名するため |

探索一覧の印は「登録済みの端末」までしか言えない。同じ言葉を使うと
弱いほうに引きずられるので、文言を分けた。

- 探索一覧 … `登録済みの端末`
- 受信時 … `署名を検証済み`
- 自動承認の条件 … **署名の検証のみ**

## 探索一覧にも印を出す

広告の 16 バイトを手元の証明書と突き合わせ、当たった端末に印を付ける。
接続する前に「これは自分の端末だ」と分かるので、送信先を選ぶときの
手掛かりになる。ただし上のとおり、これは本人確認ではない。

## 証明書が無いときの扱い

証明書を 1 件も持っていなければ誰も検証できないので、
絞り込みがオンなら**自動受信は一切行われない**。
その旨を設定画面に出している。


---

# 送信側でも検証する (stage4e)

## 何を確かめたいのか

受信側として検証できた署名の対象は `0x01 || authString` だった。
この `0x01` は役割を表す印なので、**受信側が署名するときは別の値**のはず。
同じ値だと片方の署名をそのまま返せてしまう。

その対の値は、**こちらが送信側に回れば分かる**。相手が受信側になり、
`PAIRED_KEY_ENCRYPTION` を送ってくるので、その `signed_data` を
同じ仕組みで検証すればよい。

**書き込みを一切せずに確かめられる。** 自分の証明書を作る前に、
必要な材料をここで揃えておく。

## 実装

- `OutboundSession.send(...)` に相手の広告 (`EndpointInfo.metadata`) を渡す
- 送信開始時に証明書を特定する
- 相手の `signed_data` を、その証明書の公開鍵で検証する
- 検証できたら `PAIRED_KEY_RESULT` を `success` で返す

探索一覧から送るときは広告を見ているので渡せる。QR 経由など広告を
見ていない場合は nil で、そのときは特定できない。

## 当たった印は覚える

総当たりは残すが、一度当たった印は先頭で試すようにした。
毎回 256 通り回すのは無駄でしかない。

既定は `0x01` (受信側として実測済み) と `0x02` (対の値の第一候補)。
別の値が当たったら、その場で覚えてログに出す。

## この先

印が判明すれば、自分の証明書を作るのに必要なものが揃う。
残っているのは `encrypted_metadata` の暗号化手順だけになる。


---

# 上流の実装を読んだ (stage4f)

## 総当たりは不要だった

`nearby_share.exe` に埋まっていたソースパスが
`third_party/nearby/sharing/certificates/…` である以上、実装は
**github.com/google/nearby** にある。オープンソースだった。

推測を重ねて総当たりを広げるより先に、ここを読むべきだった。
以下はすべてそこから読み取ったもので、推測は含まない。

## 土台

```
DeriveNearbyShareKey(key, n) = HKDF-SHA256(ikm: key, salt: 空, info: 空, n)
```

## ① metadata 本体 — AES-256-GCM だった

```
鍵    = DeriveNearbyShareKey(metadata_encryption_key, 32)
nonce = DeriveNearbyShareKey(secret_key, 12)      ← secret_key から
AAD   = 空
```

**CTR ではなく GCM。** しかも nonce は `secret_key` 由来。
「mkey から nonce を作るはず」と思い込んでいたので、GCM を試していても
外していた。認証タグが付くので、開けたこと自体が正しさの証明になる。

## ② 広告の metadata 鍵 — AES-256-CTR

```
鍵     = secret_key をそのまま (導出しない)
カウンタ = DeriveNearbyShareKey(salt, 16)
```

これは実測で当てた `key/hkdf16(salt)` と完全に一致した。

## ③ metadata 鍵の検算

```
tag = HMAC-SHA256(鍵: 32 バイトのゼロ, メッセージ: metadata_encryption_key)
```

実測どおり。上流のコメントには
`This array of 0x00 is used to conform with the GmsCore implementation.`
とある。

## ④ secret_id_hash

```
ComputeAuthenticationTokenHash(token, secret_key)
  = HKDF-SHA256(ikm: token, salt: secret_key, info: 空, 6)
```

名前に反して証明書の識別子ではない。**接続ごとの認証トークンを
証明書の鍵で潰したもの**で、毎回変わるのはそのため。

`raw_authentication_token` は UKEY2 の
`GetVerificationString(32)` そのもの (`encryption_runner.cc`)。
4 桁 PIN はそれを base64 して先頭 5 文字を大文字にしたもの。

## ⑤ 署名の前置き

```
kNearbyShareSenderVerificationPrefix   = 0x01
kNearbyShareReceiverVerificationPrefix = 0x02
```

実測どおり。署名する側は自分の役割の印を付け、検証する側は相手の役割の
印を付ける。

## ⑥ EncryptedMetadata の定義

```
1 device_name / 2 full_name / 3 icon_url / 4 bluetooth_mac_address
5 obfuscated_gaia_id / 6 account_name / 7 model_name
```

5 と 6 を取り違えていた。

## この版でやったこと

総当たりのコードを全部捨て、確定式に置き換えた。

- metadata を GCM で開く。開けたら端末名を出す
- `secret_id_hash` は式で計算して照合する
- 署名の前置きは定数にする (総当たりは仕様変更の検知用に残す)
- `EncryptedMetadata` の定義を直す

## 教訓

バイナリに `third_party/…` のソースパスが出たら、まずそれが
オープンソースかどうかを調べる。文字列や定数の名前が読めるということは、
**元のコードが読める可能性がある**ということ。


---

# 自分の証明書を作る (stage5a)

**この段では Google に何も送らない。** 作るだけ。

## 上流から読み取った仕様

```
secret_key              32 バイト乱数
secret_id               SHA-256(secret_key)      ← 乱数ではない
metadata_encryption_key 14 バイト乱数
鍵ペア                   P-256
有効期間                 72 時間
境界のぼかし             開始・終了をそれぞれ最大 2 時間ずらす
```

境界をずらすのは、いつ作ったかを隠すため。

`device_id` は**クライアントが決める** 10 文字の `A-Z0-9`。
`current_dusi` とは無関係だった。`devices/{current_dusi}` で
`QuerySharedCredentials` が通っていたのは、サーバが未知の device_id でも
アカウント全体の credentials を返すため。

## proto の訂正

`f10` は `trust_type` ではなく **`bool for_self_share`** だった。
実測で全件 1 だったのは、**降りてきたのが自分の端末向けの証明書だけ**
だったということ。連絡先向けは含まれていない。

`f11` は上流で `reserved 11;`、`f12` が `binding_id`。

## 自己検証

作った証明書を、**既に動いている読み取り側にそのままかける**。
読み取り側は実測で正しさが確認できているので、そこを通れば
組み立ても正しいと言える。Google に何も送らずに検算できる。

1. `tag == HMAC-SHA256(ゼロ, mkey)` か
2. metadata を GCM で開けるか
3. 自分の広告から自分の証明書を特定できるか
4. 自分の署名を自分の公開鍵で検証できるか

4 つとも通れば、`PublishDevice` に載せる形は正しい。

## 広告の切り替え (5b)

広告の 16 バイトを、乱数から証明書由来に変えられる。

```
salt(2 バイト乱数) + AES-CTR(鍵: secret_key, カウンタ: HKDF(salt, 16)) で
metadata 鍵を暗号化した 14 バイト
```

salt は毎回変える。使い回すと同じ 16 バイトが出続けて追跡されるため。

**この段階では相手はこれを復号できない。** こちらの証明書を Google に
登録していないので、相手の手元に無いため。名前を隠すと、相手からは
`(hidden)` としか見えなくなる。

既定はオフ。切り替えたら広告を張り直す必要がある。

## 次の段で要るもの

`PublishDevice` に進むと、1 つだけ未確定が残る。

```
SharedCredential.id = util_hash::HighwayFingerprint64(secret_id)
```

Google 内部のラッパーで、鍵定数が分からない。サーバ側の索引にすぎない
可能性が高いので、まず `secret_id` の先頭 8 バイトを送って拒否されるかを
見る、という段取りになる。

証明書の回転 (72 時間ごとの再生成) も、登録と同時に要る。
作りっぱなしだと 3 日後に静かに壊れる。


---

# 端末を登録する (stage5c)

**ここから先は Google アカウントへの書き込み。**

## 何枚作るか

上流は可視性 2 種 × 3 枚 = **6 枚**を持つ。

```
DEVICE_VISIBILITY_ALL_CONTACTS  → for_self_share = false
DEVICE_VISIBILITY_SELF_SHARE    → for_self_share = true
```

各可視性で、証明書の期間は**連鎖させる**。1 枚目が今から 72 時間、
2 枚目はその終わりから 72 時間、3 枚目はさらにその先。
こうすると 9 日ぶんの有効期間が先に埋まり、期限切れで名乗れなくなる
瞬間が生まれない。

## device_id

端末側で決める **10 文字の `A-Z0-9`**。アカウント内で区別できればよく、
世界で一意である必要は無い。`current_dusi` とは無関係。

一度決めたら変えない。作り直すとサーバから見て別の端末になる。

## リクエストの形

```
device.name         = "devices/{device_id}"
device.display_name = 端末名
device.contact      = 2 (CONTACT_GOOGLE_CONTACT)
device.per_visibility_shared_credentials = [
  { visibility: 1 (SELF),     shared_credentials: [3 枚] },
  { visibility: 2 (CONTACTS), shared_credentials: [3 枚] },
]

各 shared_credential:
  id              = ?
  data_type       = 1 (DATA_TYPE_PUBLIC_CERTIFICATE)
  data            = PublicCertificate のシリアライズ
  expiration_time = end_time
```

## 唯一の未確定 — SharedCredential.id

上流は `util_hash::HighwayFingerprint64(secret_id)`。Google 内部の
ラッパーで鍵定数が読めない。

**総当たりはしない。** サーバ側の索引にすぎない可能性が高いので、
`secret_id` の先頭 8 バイトを `int64` として入れて 1 回投げる。
通ればそれで終わり。`INVALID_ARGUMENT` が返ったら、そのとき考える。

そのときも総当たりではなく、HighwayHash の実装を移植して、
**手元にある 42 組の (secret_id, id) で検算する**という手が使える。
未知なのは鍵となる 4 つの定数だけで、候補は数個しかない。

## 応答

`contact_updates` に `CONTACT_UPDATE_REMOVED` (2) が入っていたら、
上流は証明書を作り直してもう一度呼ぶ。まずは 1 回で通るかを見る。

## 取り消し

Google アカウントの設定から端末を削除する。画面に `device_id` を
出しているので、控えてから実行すること。


---

# 登録したら名乗る義務が生まれる (stage5d)

## PublishDevice は通った

```
PublishDevice (body 1711 バイト) → 成功
```

`SharedCredential.id` は `secret_id` の先頭 8 バイトで通った。
`HighwayFingerprint64` を当てる必要は無かった。サーバ側の索引で、
検算はされていない。

相手の Quick Share で、iPad が**「お使いのデバイス」欄に移った**。

## それでもファイルが受け取れない

ログを追うと、こうなっていた。

```
相手の証明書を特定しました
署名を検証できました
PAIRED_KEY_RESULT (success) を送信しました
相手から DISCONNECTION を受信しました      ← 切られる
```

**こちらが success を返しても切られる。** 相手が切っている。

理由は単純で、こちらが送る `PAIRED_KEY_ENCRYPTION` が乱数のままだった。
登録前は「知らない端末」なので検証を求められず、PIN 確認で通っていた。
登録したことで相手は iPad の証明書を持つようになり、**検証できて当然**と
みなすようになった。そこで乱数を返すと「登録済みなのに名乗れない端末」に
なり、接続を切られる。

**登録と名乗りは対になっている。** 片方だけでは動かない。

## 直したこと

自分の証明書があれば、乱数ではなく本物を載せる。

```
signed_data    = ECDSA(印 || authString)
secret_id_hash = HKDF-SHA256(ikm: authString, salt: secret_key, 6)
```

印は役割で変わる。受信側は `0x02`、送信側は `0x01`。

## 「画面 OFF」の表示

相手の一覧に「iPad / 画面 OFF」と出ていた。登録済みの端末として
知ってはいるが、いまその端末の広告と結び付いていない、という状態。

広告の 16 バイトを証明書由来に切り替えると結び付くはず。
「広告に自分の証明書を使う」をオンにして試す。

## 証明書を作り直したら

**登録もやり直す。** 作り直すと secret_id が変わるので、
サーバに載っている証明書と手元のものが食い違い、名乗れなくなる。


---

# 名乗る口が 2 つあった (stage5e)

## 受信は通り、送信が切られる

```
Outbound: 自分の証明書で署名しました (送信側の印)
Outbound: ★★★★ 署名を検証できました (der/前置き 0x02)
Outbound: ★ PAIRED_KEY_RESULT (success) を送信しました
Outbound: ★ INTRODUCTION を送信しました
Outbound: 相手から DISCONNECTION を受信しました    ← 26 ms 後
```

こちらは相手を検証でき、署名も本物を送っている。それでも切られる。

## 原因

**相手がこちらを特定する材料が、送信時だけ乱数のままだった。**

こちらの証明書を相手に伝える口は 2 つある。

| 場面 | どこに載るか |
|---|---|
| 受信 (相手が接続してくる) | mDNS の広告 (`EndpointInfo`) |
| 送信 (こちらが接続する) | `CONNECTION_REQUEST` の `endpoint_info` |

広告側だけ証明書由来に直していて、送信側の `CONNECTION_REQUEST` は
`randomMetadata()` のままだった。

相手から見ると「署名は本物なのに、どの証明書のものか分からない」相手に
なる。**中途半端に名乗るのは、名乗らないより悪い。**

## 直したこと

`OutboundSession.startHandshake` の `endpoint_info` も、
広告と同じ条件で証明書由来にした。

## 相手の判定をログに出す

`PAIRED_KEY_RESULT` を受け取ったとき、相手がこちらをどう判定したかを
残すようにした。

```
success → 相手がこちらを検証できた
fail    → こちらの名乗りが噛み合っていない
unable  → 相手は検証できなかった (証明書を持っていない等)
```

転送が始まらないとき、原因がこちら側の名乗りにあるのか、相手の同意待ちなのかを
これで切り分けられる。今回もこのログがあれば一度で分かった。


---

# 特定の経路をもう 1 本 (stage5f)

## 相手はこちらを認めた

```
Outbound: ★ 相手がこちらを検証しました (success)
```

前回入れたログが効いた。**こちら側の名乗りは通っている。**
`CONNECTION_REQUEST` に証明書を載せる修正で、そこは解決した。

## 今度はこちらが相手を特定できない

```
Outbound: 証明書を特定できていないので、署名は検証できません
Outbound: ★ PAIRED_KEY_RESULT (unable) を送信しました
→ 相手から DISCONNECTION
```

相手は success を返したのに、こちらが unable を返した。
登録済みの端末同士で片方だけ認められない状態になり、相手が切る。

証明書は 60 件持っている。それでも当たらない。
`PublishDevice` の直前までは当たっていたので、**登録を機に相手が
証明書を切り替えた**と読める。手元の 60 件はその前に取ったもの。

## 広告に頼るのをやめる

こちらの手元にある証明書から相手を割り出す経路は、これまで 1 本だけだった。

| 経路 | 材料 | 弱点 |
|---|---|---|
| 広告からの特定 | `EndpointInfo` の 16 バイト | 接続の入口でしか見られない。相手が切り替えた直後は噛み合わない |
| **secret_id_hash からの特定** | 接続ごとの認証トークン | 証明書さえ持っていれば必ず当たる |

2 本目を足した。広告で外しても、`PAIRED_KEY_ENCRYPTION` に載っている
`secret_id_hash` を全証明書と突き合わせれば拾える。計算式は確定済み。

送信・受信の両方に入れた。

## 登録したら取り直す

`PublishDevice` に成功したら、その場で `QuerySharedCredentials` を
呼び直すようにした。登録すると相手はこちらを「自分のデバイス」として
扱い始め、そのとき証明書を切り替えることがある。手元を更新しないと、
相手を特定できずに接続を切ることになる。


---

# 名乗る形を揃える (stage5g)

## 送信は通ったが、番号確認が残る

```
Outbound: ★ secret_id_hash が一致しました       ← 2 本目の経路が効いた
Outbound: ★ PAIRED_KEY_RESULT (success) を送信   ← こちらは相手を検証できた
Outbound: 相手は検証できませんでした (unable)     ← 相手はこちらを検証できない
Outbound: 相手の応答 = accept                    ← 番号確認を経て受理
```

転送そのものは成功する。ただし相手がこちらを検証できていないので、
番号の確認を求められる。

同じ Android が、**受信のときはこちらを検証できている**。

```
Session: ★ 相手がこちらを検証しました (success)
Session: ★ 自動承認。ファイル 1 件の受信を開始します
```

証明書を持っているかどうかの差ではない。役割による差。

## 名乗る場所が役割で違う

| 役割 | 相手が見る場所 | `hidden` |
|---|---|---|
| 受信 (相手が接続) | mDNS 広告 | 設定に従う |
| 送信 (こちらが接続) | `CONNECTION_REQUEST` | **`false` 固定だった** |

送信時は名前を平文で載せていた。これは「全ユーザーに表示」の形で、
証明書で名乗ることと噛み合わない。バイナリにこの文字列がある。

```
Incoming connection with non-everyone visibility cannot verify public certificate.
```

公開範囲の申告と証明書の検証が結び付いている、と読める。
`hidden` を広告と揃えた。

## 同じファイルを 2 回送っていた

```
送信候補にファイル 1 件を追加しました
  README.txt — 602 バイト
...
README.txt (602 バイト)
README.txt (602 バイト)     ← INTRODUCTION に 2 件
★★★ 送信完了 — README.txt
★★★ 送信完了 — README.txt  ← 2 回送っている
```

証明書とは無関係の既存の穴。選び直したつもりで二重に積むと、
そのまま 2 回送られていた。一覧に件数は出ているが、気付きにくい。

同じ URL は足さないようにした。弾いた件数もログに出す。
同じファイルを重ねて送りたい場面は考えにくいので、ここで止めるのが妥当。


---

# secret_id_hash の意味を取り違えていた (stage5h)

## おかしなログ

送信中に、相手の `secret_id_hash` が**こちらの証明書**と一致した。

```
Outbound: 名's PC へ接続します
Outbound: ★ secret_id_hash が一致しました
Outbound: iPad / secret_id=f9db7ce5ebd2282f… / 自分の端末
```

相手は名's PC なのに、当たったのは iPad の証明書。6 バイトの衝突は
確率的にありえない。読み方が間違っている。

## 上流を読み直した

```cpp
std::vector<uint8_t> certificate_id_hash;
if (certificate_.has_value()) {
  certificate_id_hash = certificate_->HashAuthenticationToken(raw_token_);
}
if (certificate_id_hash.empty()) {
  certificate_id_hash = GenerateRandomBytes(6);
}
```

`certificate_` は `PairedKeyVerificationRunner` のメンバで、
**相手の証明書** (`NearbyShareDecryptedPublicCertificate`)。

つまり送り手は、**受け手の証明書の secret_key** で認証トークンを潰して送る。
相手の証明書を持っていなければ乱数になる。

**この値は「あなたを認識しています」という意味。**
「私は誰それです」ではない。名前に引きずられて逆に読んでいた。

## 直したこと

- 一致した証明書を署名の検証に回すのをやめた。あれは**こちらの**証明書で、
  相手の公開鍵ではない。幸い広告からの特定が先に効いていたので、
  検証自体は正しい証明書で行われていた
- 送るときも、相手の証明書の `secret_key` で作るようにした。
  相手が分からないときは、上流と同じく乱数のままにする
- ログの文言を「相手はこちらを認識しています」に変えた

## うまくいくときといかないときがある理由

これで説明がつく。

```
01:12:00  相手はこちらを認識していない → unable → 番号確認
01:12:22  相手はこちらを認識している   → success → 自動
```

どちらも `hidden=false` で、こちらの設定は同じ。差は**相手が
こちらの証明書を取得済みかどうか**だけ。

証明書は Google のサーバ経由で配られるので、`PublishDevice` の直後は
相手に届いていない。相手が取りに行くまでの時間差が、そのまま
「うまくいったりいかなかったり」に見えていた。

こちらから早める手立ては無い。相手が取得すれば安定する。

## hidden を揃えた件

stage5g で「送信時の `hidden` が違うせいでは」と見立てたが、
**外れ**だった。両方 `hidden=false` のまま success になっている。
揃えること自体は筋が通るので残すが、原因ではなかった。


---

# 画面を整理した (ui1)

## 段階ではなく目的で分ける

開発の段階 (第1段〜第5段) をそのまま画面の見出しにしていた。作る側の
都合であって、使う側には意味がない。しかも `DisclosureGroup` が 4 階層に
入れ子になっていて、**開くまで中身が分からない**状態だった。

目的で分け直し、別画面に移した。

```
メイン画面
└ 実験機能
  └ アカウント連携  連携済み / 証明書 42 件 / 登録の期限 あと 8 日  →

アカウント連携 (別画面)
├ この実験機能を使う
├ 連携        状態・トークン・サインイン/アウト・解除・更新
├ 受信の設定  本人確認できた相手だけ自動受信・証明書の取得
├ この端末    証明書・自己検証・登録・端末名を隠す
└ 接続先      client_id / client_secret / scope
```

メイン画面には **1 行だけ**。開かなくても状態が分かる。

## 診断も別画面へ

受信したフレーム・埋め込み設定・ログは、どれも「普段は見ないが困ったときに
必要なもの」。受信や送信の操作の間に挟まって邪魔だった。

`診断 →` の 1 行にまとめ、ログの共有と消去もその画面に置いた。
これまで右上のメニューに隠れていて見つけにくかった。

## 調査用の道具を外した

役目を終えたので画面から外し、実装も消した。

- 経路の総当たり (ホスト × 経路)、現在のサービス名で全メソッド
- 運び方の切り替え → `application/grpc` 固定
- リダイレクトの受け口 → ループバック固定 (カスタムスキームは使用不可が確定)
- tokeninfo によるトークン検証
- `GetIdentityBrokerConfig` (名前が不明のまま。照合には不要)
- gRPC ホスト / サービス名 / 資源名の入力欄 (すべて確定済み)
- 設定テキストの書き出しと読み込み

`ProtoInspector` はコードに残してある。呼び出しを 1 行足せば、
証明書の構造を再び出せる。Google が proto を変えたときのため。

**捨てたのは画面であって知見ではない。** 手順と結論はこの文書に、
コードは git に残っている。

## 期限を見せる

証明書は 72 時間 × 3 枚で 9 日ぶんあるが、切れると**静かに名乗れなくなる**。
相手からは「登録済みなのに検証できない端末」に見えて接続を切られる。

残り時間を出し、24 時間を切ったら色を変えて促すようにした。
メイン画面の 1 行にも出るので、開かなくても気付ける。

## 広告のトグルを 1 つに

「広告に自分の証明書を使う」は、登録が済んでいれば常にオンでよい。
オフだと相手が特定できず、中途半端に名乗る状態になる。

画面から外し、**登録に成功した時点で自動でオンにする**ようにした。
残したのは「端末名を隠す」だけ。

## 失敗に次の一手を添える

エラーの文字列をそのまま出しても、次に何をすればよいか分からない。
`invalid_client` なら「client_secret を確認」、`UNAUTHENTICATED` なら
「トークンを更新」といった手当てを 1 行添える。


## 削るときに巻き込んだもの (ui2)

```
error: type 'AccountConfig.Key' has no member 'redirectPath'
error: type 'AccountConfig.Key' has no member 'grpcHost'
error: type 'AccountConfig.Key' has no member 'grpcService'
```

上書きの口を消したのに、アクセサ側が `Key.xxx` を参照したままだった。
これらは実測で確定した値なので、**定数に変えた**。入力欄を残しても
迷わせるだけで、変えて通る値が他に無い。

```swift
static var redirectPath: String { defaultRedirectPath }
static var grpcHost: String { defaultGrpcHost }
static var grpcService: String { defaultGrpcService }
```

あわせて、リダイレクト URI の組み立て
(`reversedClientId` / `customSchemeRedirectURI` / `loopbackRedirectURI`)
まで巻き込んで消していたので戻した。`AccountOAuth` が使う。

カスタムスキームは使えないと確定しているが、切り分けの記録としてコードは残す。
