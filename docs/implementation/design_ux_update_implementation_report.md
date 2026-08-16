# 白内障執刀ノート — デザイン / UX 改善アップデート実装報告

- 対象要件：`docs/requirements/design_ux_update_requirements.md` v3.0
- 実装ブランチ：`feature/design-ux-update-v3`
- 基準コミット：`68e0e1a`
- 最終自動検証日：2026年8月15日
- 状態：ユーザー提供のAppIcon原画を含む静的実装と署名済みarchive／App Store IPA生成を確認済み。厳密なリリースゲートには実機・iOS 15・cold launch計測・App Store Connect validation等の未確認項目あり

## 1. 実装範囲

### Phase 0：データ・動画安全性

- `videoPath` を未登録、管理相対パス、旧絶対パス、不正参照へ厳密に分類するclassifierを追加
- 同一症例の全mutationを共有coordinatorで直列化し、動画storage操作を全症例共通lockで直列化
- 新規登録、初回添付、同一動画再リンク、別動画差し替え、旧パス移行、動画削除、症例削除を別Service APIへ分離
- 動画参照の期待値をDB transaction内で比較するCAS更新を追加
- sourceとstaged fileのサイズ・SHA-256を照合し、衝突しないfinal名へrename後、実際のfinal fileを再生probe
- `videos` root、症例directory、final fileのsymlink・root逸脱を拒否
- backup除外属性を動画byte書き込み前のrootとfinal fileへ設定し、iOS側でread-back
- DB参照snapshotが完全と証明できた場合だけ、未参照finalと24時間超のtmpをreconciliation
- DB commit後のcleanup失敗を論理操作失敗と混同せず、「後処理保留」として保持・表示
- 時刻列だけを保存するAPIと、評価・反省点・症例メモだけを一括保存するAPIへ分離
- 旧DBの不足工程行をレビュー進入時だけ原子的・idempotentに補完
- schema version、table、column、storage ID、動画rootは変更していない

### Phase 1：コアUX

- 一覧・詳細・レビューで、動画の未登録、確認中、管理動画、旧形式、実体なし、不正参照、確認失敗を分離
- 初回添付・同一動画再リンクでは工程時刻を保持し、別動画差し替え・動画削除だけ確認後に全工程時刻を消去
- レビューの通常保存と「保存して閉じる」を原子的にし、失敗時は画面、入力、dirty状態を保持
- Provider再読込失敗や古い非同期応答で、commit済み値や編集ドラフトを巻き戻さない状態管理を追加
- 症例削除検知後は入力をread-onlyで保持し、ドラフトのコピー／破棄導線を提供
- 5秒／15秒のシーク、再生速度、工程位置ジャンプ、開始・終了・再設定を整理
- 生例外を利用者向けメッセージへ変換し、成功・警告・失敗のfeedback toneを分離

### Phase 2・3：テーマ、画面、アクセシビリティ

- 共通のLight／Dark ThemeData、色、余白、角丸、motion、意味色tokenを追加
- Flutter UIを日本語固定fallbackとし、Material／Cupertino localizationを追加
- 一覧、新規登録、詳細、レビュー、分析を新しい画面構成へ更新
- 10工程の進捗と独立した総手術時間を表示し、`reviewStatus` を完成判定に使用しない
- 空、loading、error、確認dialog、SnackBar、動画surfaceを共通化
- 分析グラフへ前後操作、adjustable Semantics、選択点、平均、前回比、全件表示を追加
- actionを持つSemantics nodeの44×44、Safe Area内到達性、label、text contrast、CustomPainter配色を自動検証
- Light／Dark、文字倍率1.0／2.0、phone／iPad／compact、pixel ratio 1.0／3.0の8つのデザイン基盤Goldenを追加

### Phase 4：iOS、起動画面、文書

- 空の`LaunchImage`参照とassetを削除
- `LaunchBackground` named colorを追加し、Light `#006D77`、Dark `#003F45`をLaunchScreen、Main storyboard、Flutter pre-contentで共有
- `ja.lproj/InfoPlist.strings`とbundle localizationを追加
- iOS側のbackup除外設定・read-back helperとXCTestを追加
- RunnerのPrivacy Manifestへアプリコンテナ／ユーザー選択ファイルのFile Timestamp理由を宣言し、依存SDKを含む全manifestを配布IPA内で検証
- 非免除暗号を使用しないexport compliance宣言とAutomatic signingを明示
- README、アプリdescription、要件定義、実装報告を更新
- ユーザー提供原画の黒い四隅を既存グラデーションで補完し、OS側のマスクを前提とするフルブリード・sRGB・alphaなしのAppIconマスターを追加
- AppIconマスターからiPhone／iPad／App Storeの全slotとAndroidの各mipmapを生成し、Flutter標準アイコンを置換

## 2. 主な変更ファイル

- Data／Service：`lib/src/data/providers.dart`、`record_video_service.dart`、`surgery_repository.dart`、`video_storage_repository.dart`
- 新規安全性部品：`file_sha256.dart`、`record_mutation_coordinator.dart`、`video_path_classifier.dart`
- 画面：`new_record_screen.dart`、`record_list_screen.dart`、`record_detail_screen.dart`、`step_review_screen.dart`、`analysis_screen.dart`、`surgery_trend_chart.dart`
- テーマ／共通UI：`lib/src/theme/*`、`lib/src/widgets/*`、`lib/main.dart`
- iOS：`AppDelegate.swift`、`Info.plist`、`PrivacyInfo.xcprivacy`、両storyboard、`LaunchBackground.colorset`、`ja.lproj`、`RunnerTests.swift`、Xcode project設定
- AppIcon：`assets/branding/app_icon_master.png`、`ios/Runner/Assets.xcassets/AppIcon.appiconset/*`、`android/app/src/main/res/mipmap-*/ic_launcher.png`
- 自動試験：既存test群の更新に加え、旧DB fixture、path／storage／service／repository／crash boundary／theme／Golden testを追加
- 文書：`README.md`、`docs/requirements/design_ux_update_requirements.md`

`pubspec.yaml`の開始前差分である`version: 1.0.0+15`はユーザー所有の変更として保持した。

## 3. 自動検証結果

| 検証 | 結果 |
|---|---|
| `dart format`（変更Dart 39ファイル） | 成功 |
| `flutter analyze` | 成功、`No issues found` |
| `flutter test` | 成功、221件 |
| `flutter test test/step_review_screen_test.dart` | 成功、23件 |
| 重点回帰（詳細・storage・video service・theme・分析） | 成功、77件 |
| `git diff --check` | 成功 |
| AppIcon静的検証 | 全slotの寸法、sRGB、alphaなし、フルブリード、不要メタデータ除去を確認 |
| Asset Catalog compile | 成功、AppIconに関するerror／warningなし |
| Debug iOS Simulator build | 成功、`Runner.app`生成 |
| 署名なしRelease iOS build | 成功、`Runner.app` 21.7 MB |
| 署名済みApp Store archive／IPA | 成功、version 1.0.0、build 16、archive 177.7 MB、IPA 23.6 MB |
| 配布成果物検証 | archive／IPAの厳密codesign、Distribution証明書、App Store profile、全9 Privacy Manifest、arm64、dSYM UUID一致を確認 |
| Release bundle | `ja.lproj`あり、最低OS 15.0、iPhone／iPad、宣言方向を確認 |
| iOS XCTest | iPhone 17／iOS 26.0で3件成功 |

iOS XCTestで確認した内容は、Launch色のLight／Dark値、日本語bundle、実directoryと実fileに対する`isExcludedFromBackup == true`のread-backである。

旧DB互換試験では、`1.0.0+1`相当と`1.0.0+14`相当のfile-backed SQLite fixtureを使用し、`integrity_check`、既存値、旧／未知工程、管理動画SHA-256、読取時の非破壊性を確認した。動画系ではcopy／DB／cleanup fault、CAS競合、commit前後の再open、incomplete snapshot、symlink、同サイズ内容差し替え、再生probe失敗を検証した。

なお、一部のfault testは同じSQLite executorを複数の`AppDatabase` wrapperから意図的に開くため、Driftのtest-only warningを出す。テスト結果は成功で、productionで複数DB instanceを生成する変更ではない。

## 4. リリースゲート判定

| Gate | 現在の判定 | 根拠／未確認 |
|---|---|---|
| RG-1 コード品質 | 配布前項目まで成功 | analyze、221 tests、Debug、unsigned Release、署名済みarchive／App Store IPAとローカル配布成果物検証は成功。App Store Connect validationは未実施 |
| RG-2 データと動画 | 自動試験成功、正式合格は保留 | 旧DB／SHA-256／fault／喪失状態／native read-backは確認。実機上の新旧fixture内「全管理動画」のread-backは未確認 |
| RG-3 iOS | 保留 | 日本語bundleと日本語DatePicker自動試験は成功。iOS 15、iPad、実機、native picker、編集メニュー、全方向、連続resizeの手動matrixは未実施 |
| RG-4 UX／A11y | 保留 | デザイン基盤Golden、guideline、custom semantics、contrast、theme切替試験は成功。全実画面・全状態のmatrix、実VoiceOver、実機文字倍率、レビュー位置通知100回のbuild-count、実動画での速度維持、旧Controller遅延完了の専用試験は未完了 |
| RG-5 起動画面 | 実装成功、正式合格は保留 | asset／storyboard／bundle色とXCTestは成功。clean-install動画のframe samplingを指定全端末・全方向・Light／Dark・iOS 15で未実施 |
| RG-6 AppIcon | 静的実装・archive格納成功、正式合格は保留 | ユーザー提供原画から全slotを生成し、Flutter標準アイコン、alpha、焼き付け角丸、不要メタデータがないこと、Asset Catalog compile、署名済みarchive／IPAへの格納を確認。実機ホーム、App Switcher、Spotlight、設定、App Store Connect validationは未確認 |

要件定義の厳密な定義では、未確認を合格扱いにできないため、現時点を「配布可能」または「RG-1〜RG-6通過」とは判定しない。

## 5. 配布前に必要な作業

1. AppIconをclean installした実機のホーム、App Switcher、Spotlight、設定、およびApp Store Connect validationで確認する。
2. iOS／iPadOS 15.xと現行OSのiPhone／iPadで、主要フロー、全宣言方向、Light／Dark、文字倍率2.0、VoiceOver、native picker、編集メニューを確認する。
3. iPadで幅320ptまでの連続resize、Stage Manager／Split View、実行中回転を確認する。
4. clean installごとにcold launchを録画し、要件のRGB許容値と白／黒全面frame数をframe samplingする。
5. 実機のfixture内全管理動画でbackup除外属性をread-backする。
6. 生成済みIPAをTestFlight／App Store Connectでvalidationし、アップロードする。
7. §11-2の性能／lifecycle専用試験（位置通知100回、実動画での速度維持、dispose済みController遅延完了）と、全実画面・全状態のGolden matrixを追加する。

## 6. 今回のProblems修正

`test/step_review_screen_test.dart`で参照されていたテスト用`_PendingCleanupVideoService`を定義した。logical commit後にcleanup保留を返すfixtureとして、レビュー画面が成功表示ではなく警告を出す経路を検証する。

- 対象ファイル単体の`flutter analyze`：成功
- レビュー画面テスト：23件すべて成功
- 全体の`flutter analyze`／`flutter test`／iOS Debug／Release：再実行して成功
