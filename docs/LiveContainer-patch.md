# LiveContainer で QSProbe を動かす

QSProbe を LiveContainer 上で動かすには、**LiveContainer 側の
`NSBonjourServices` 許可リストに Quick Share のサービスタイプを追加**して
自前ビルドする必要があります。追加するのは 2 行だけです。

SideStore で直接インストールする場合、この手順は不要です。

---

## なぜ必要なのか

LiveContainer はゲストアプリを**ホストのプロセス内で**動かします。
そのため iOS から見える Info.plist はホスト (LiveContainer) のものになります。

LiveContainer の `Resources/Info.plist` には汎用のプライバシー説明文が
一通り用意されているので、**Local Network の許可も写真ライブラリの許可も
ゲストで取得できます**。素の TCP / UDP 通信は問題なく通ります。

問題は `NSBonjourServices` だけです。これは説明文ではなく
**サービスタイプの固定リスト**で、47 種類が列挙されています。
そして**ゲスト側の `NSBonjourServices` はマージされません**。

Quick Share が使う `_FC9F5ED42C8A._tcp` はこのリストに無いため、
「許可されていないタイプ」として拒否されます。

| 症状 | 意味 |
|---|---|
| `NSNetServicesMissingRequiredConfigurationError (-72008)` | publish しようとしたタイプが許可リストに無い |
| `kDNSServiceErr_NoAuth (-65555)` | browse しようとしたタイプが許可リストに無い |
| 権限プロンプトが出ない | タイプの照合は TCC の手前の構成チェックなので、許可を問う段階に到達しない |

LocalSend が LiveContainer 上で動くのは、宣言している `_http._tcp` が
許可リストに含まれているうえ、Bonjour に依存しない HTTP サブネットスキャン
経路も持っているからです。

---

## 手順

### 1. LiveContainer をフォークして clone する

<https://github.com/LiveContainer/LiveContainer> をフォークし、
Termux などから clone します。

```bash
git clone https://github.com/<あなたのアカウント>/LiveContainer.git
cd LiveContainer
```

### 2. `Resources/Info.plist` を編集する

`NSBonjourServices` の配列を探します。現状は次のような並びです。

```xml
<key>NSBonjourServices</key>
<array>
    <string>_airplay._tcp</string>
    <string>_raop._tcp</string>
    ...
    <string>_remotepairing-pairable-host._tcp</string>
    <string>_stikpairprobe._tcp</string>
</array>
```

末尾の `</array>` の直前に 2 行追加します。

```xml
    <string>_remotepairing-pairable-host._tcp</string>
    <string>_stikpairprobe._tcp</string>
    <!-- Quick Share / Nearby Share (Google の固定タイプ) -->
    <string>_FC9F5ED42C8A._tcp</string>
    <string>_FC9F5ED42C8A._tcp.</string>
</array>
```

末尾ドットの有無はどちらでも動くことを実測で確認済みですが、
**両方書いておくのが安全**です。照合の実装がどちらの正規化を使うかに
依存しなくなります。

### 3. ビルドしてインストールする

LiveContainer 本家の README にあるビルド手順に従ってください。
GitHub Actions を使う場合はフォーク先で Actions を有効にし、
リリースワークフローを実行すると IPA が生成されます。

出来上がった IPA を SideStore でインストールし直します
(既存の LiveContainer は置き換えになります)。

### 4. 確認する

1. パッチ版 LiveContainer で QSProbe を起動する
2. 「広告を開始」→ ログに `★ mDNS publish 成功` が出ること
3. 「探索を開始」→ `-65555 NoAuth` が出ないこと

初回は LiveContainer 本体に対して Local Network の許可ダイアログが出ます。
一度許可すれば、以後どのゲストアプリでも通ります。

---

## 上流に PR を出す場合

許可リストの末尾に `_stikpairprobe._tcp` という明らかに特定ツール向けの
カスタムタイプが既に入っているため、**タイプ追加を受け入れる前例があります**。

PR を出すなら、次の点を書くと通りやすいはずです。

- `_FC9F5ED42C8A._tcp` は **Google が固定した Quick Share / Nearby Share の
  サービスタイプ**であり、アプリごとに任意に決められる値ではないこと
- 対象は QSProbe に限らず、**NearDrop 系のすべての実装**
  (QuickDrop、CrossDrop など) が同じタイプを使うこと
- サービスタイプの追加は**探索の許可範囲を広げるだけで、権限昇格を伴わない**こと

参考リンクとして
<https://github.com/grishka/NearDrop/blob/master/PROTOCOL.md> を挙げると、
タイプが仕様上固定であることの裏づけになります。

---

## 代替案として成立しないもの

**Bonjour を避けて生の mDNS を UDP マルチキャストで自前実装する**方法は
成立しません。`com.apple.developer.networking.multicast` entitlement が
必要ですが、これは Apple の個別審査が要り、無料 Apple ID では取得できません。
LiveContainer 自身もこの entitlement を持っていません
(`.entitlements` を全て確認済み)。

したがって選択肢は次の 2 つです。

1. **SideStore で直接インストールする** (推奨・追加作業なし)
2. **LiveContainer にタイプを追加して自前ビルドする** (この文書の手順)
