# 白内障執刀ノート

白内障手術の動画を見返しながら、工程ごとの時間、自己評価、反省点、症例メモを端末内に記録するFlutterアプリです。記録した時間は症例単位で振り返り、分析画面で推移を確認できます。

## 主な機能

- 手術日、左右眼、動画を指定した症例登録
- 月別の症例一覧と工程進捗の確認
- 動画の再生、一時停止、シーク、5秒／15秒移動、再生速度変更
- 総手術時間と次の10工程の開始・終了時刻の記録
  1. サイドポート作成
  2. 粘弾性物質注入
  3. CCC
  4. メインポート作成
  5. ハイドロダイセクション
  6. 核処理
  7. I/A
  8. IOL挿入
  9. I/A（粘弾性物質除去）
  10. 創口閉鎖・圧調整
- 工程ごとの自己評価と反省点、症例全体のメモ
- 工程時間の推移、平均、前回比の分析
- システム設定に追従するLight／Darkテーマ
- 日本語UI（日本語以外の端末でもFlutter UIは日本語へフォールバック）

総手術時間は工程進捗の10件には含めず、個別工程と並行して計測できます。旧版で保存された工程は閲覧互換性のため保持しますが、現在の進捗や分析には含めません。

## データ保存とプライバシー

記録はDrift（SQLite）を使用して端末内だけに保存します。患者氏名、患者ID、生年月日の入力欄、クラウド同期、外部送信機能はありません。

選択した動画は元ファイルを変更せず、Application Supportディレクトリ内の症例専用フォルダへコピーします。DBには管理コピーの相対パスと表示用ファイル名を保存します。

```text
<ApplicationSupportDirectory>/
  videos/
    <surgeryRecordId>/
      <uuid>.<mp4|mov|m4v>
```

旧版の外部絶対パスは、詳細画面の明示操作、またはレビューで再生が必要になった時に、安全性を確認してアプリ管理領域へ移行します。移行に失敗した場合は外部原本をそのまま利用し、削除しません。実体がない場合も症例記録は閲覧でき、同じ動画の再リンクまたは別動画への差し替えを選べます。

端末内保存であっても、医療情報として端末のパスコード、OS更新、紛失対策を含む施設の運用規程に従って扱ってください。

## 開発

開発・ReleaseビルドにはFlutter 3.47.1 stable（Dart 3.13.1）以降を使用します。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

最低対応OSはiOS／iPadOS 15.0です。iPhoneとiPadの縦横表示、およびiPadのウインドウリサイズを対象とします。

## iOS Archive

アプリのversionとbuild番号は`pubspec.yaml`の`version`を正とし、iOS向けのversion名は`N.N.N`形式にします。Runner targetの`Verify Flutter Version` Build Phaseが、Xcodeで実際に使われる値との一致をArchive時に確認します。

番号が一致しない場合、最初のArchiveは生成設定を同期して安全に停止します。XcodeはArchive開始時の設定を保持するため、表示された案内に従ってもう一度Archiveしてください。古い番号のままArchiveを成功させることはありません。最初から1回でArchiveする場合は、事前に`tool/sync_ios_xcode_config.sh`を実行します。

同期後も一致エラーが続く場合は、Xcodeを閉じて`ios/Runner.xcworkspace`を開き直します。それでも再発する場合は、SchemeやBuild Settingsで`FLUTTER_BUILD_NAME`／`FLUTTER_BUILD_NUMBER`を上書きしていないか確認します。

初回clone後など`ios/Flutter/Generated.xcconfig`がない場合は、先に`flutter pub get`を実行してください。`Generated.xcconfig`と`flutter_export_environment.sh`は端末固有情報を含む生成物なので、直接編集またはGit管理しません。

## デザイン基盤

共有するブランド色、Light／Dark配色、余白、角丸、モーション、意味色は`lib/src/theme`に集約します。新しいトークンは複数機能で同じ意味を持つ場合に追加し、動画比率やグラフ寸法など機能固有の値は利用箇所に置きます。

動画surfaceと前景色、およびiOS起動画面と一致させるlaunch色は、テーマに依存させない固定色です。その他のUI色は原則として`ColorScheme`または意味色トークンを使用します。

## 配布アセット

LaunchScreenはLight `#006D77`、Dark `#003F45`の背景のみで構成します。AppIconのフルブリード原画は`assets/branding/app_icon_master.png`で管理し、iOS／iPadOSの全slotとAndroidの各mipmapへ反映します。

テスト、スクリーンショット、Golden、fixtureには、実患者情報、実手術動画、実ファイル名を使用しません。
