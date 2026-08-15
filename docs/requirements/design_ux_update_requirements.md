# 白内障執刀ノート — デザイン / UX 改善アップデート要件定義

- 対象プロジェクト：`cataract_surgery_note`
- 対象リリース：iOS / iPadOS 向け次期リリース
- 文書版：3.0（前回改訂版を全面的に置換）
- 基準コード：`68e0e1a`（`main`）
- 検証日：2026年8月13日
- ステータス：実装着手可能。配布用AppIconのみ正式原画待ち

---

## 0. 本書の効力と読み方

本書は、デザイン / UX 改善の実装、テスト、完了判定に使用する唯一の要件定義とする。旧版と矛盾する場合は本書を優先する。

本書の「必須」「してはならない」は受け入れ条件である。「推奨」は、採用しない場合に理由と代替策を実装完了報告へ記載する。

実装時は実コードを再確認する。基準コード以後に差異がある場合、データ消失、動画喪失、プライバシー、画面遷移、または受け入れ条件へ影響する差異は、推測で処理せず実装前に報告する。

本書では、次の2種類の完了を区別する。

1. **UX 実装完了**：外部原画に依存しないRG-1〜RG-5をすべて通過した状態
2. **配布可能**：RG-1〜RG-6をすべて通過し、未確認事項がない状態

正式な15度ナイフ原画が未提供でも、アイコン以外の実装は進めてよい。ただし Flutter 標準アイコンのまま配布可能とは判定しない。

---

## 1. 目的と成功条件

本アプリは、術者本人が手術動画を見返し、総手術時間、各工程の所要時間、自己評価、反省点を症例ごとに記録・分析するローカル専用アプリである。

本アップデートの目的は、次のレビューサイクルを壊さず、短時間で迷わず、安全に完了できるようにすることである。

1. 症例と動画を登録する
2. 動画を見ながら工程時間を記録する
3. 時間の推移を確認する
4. 動画、自己評価、反省点から原因を振り返る
5. 次の症例で意識する

成功条件は以下とする。

- 閲覧、移行、失敗した操作によって既存記録や既存動画を失わない
- 操作結果、未保存状態、エラーと回復方法が理解できる
- ライト / ダーク、文字倍率1.0 / 2.0、iPhone / iPad、宣言済みの全画面方向で主要フローを完了できる
- VoiceOverだけでも主要フローを完了できる
- 動画再生中の位置通知がレビュー画面全体を再ビルドしない
- 既存のDB、動画保存方式、オフライン動作、プライバシー設計を維持する

手術時間短縮などの臨床的効果は本リポジトリから検証できないため、本リリースの合否指標には使用しない。

---

## 2. 検証済みの現状

### 2-1. コード品質とビルド

基準コードと既存の未コミット版数差分がある状態で、次を確認した。

| 項目 | 結果 |
|---|---|
| `flutter analyze` | 成功、問題なし |
| `flutter test` | 既存テストすべて成功（基準時点では104件） |
| Debug iOS Simulator build | 成功 |
| 署名なし Release iOS build | 成功、`Runner.app` 20.7 MB |
| Flutter | 3.38.3 stable |
| Dart | 3.10.1 系 |
| Xcode | 26.5（17F42） |

テスト件数は履歴情報であり、将来の合否条件へ固定しない。

### 2-2. 作業ツリー

開始時点の既存差分は `pubspec.yaml` の `version: 1.0.0+14` から `+15` への変更のみである。この差分はユーザー所有として保持し、本作業の都合で戻したり上書きしたりしない。

### 2-3. 対応環境

- 最低OS：iOS / iPadOS 15.0
- 端末：iPhone、iPad
- iPhone：縦、横左、横右
- iPad：縦、上下逆、横左、横右
- iPadのSplit View、Stage Manager、ウインドウ表示と実行中の動的リサイズ：`UIRequiresFullScreen` がないため対象

iPhone専用化、iPad除外、横向き廃止、最低OS引き上げは本実装だけの判断で行わない。

### 2-4. ローカライズ

- Flutterの日本語localization delegateは未設定
- Xcode `developmentRegion` は `en`
- Xcode `knownRegions` は `en` と `Base` のみ
- 現行Release bundleには `Base.lproj` しかなく、日本語bundle localizationはない

### 2-5. ブランドと起動画面

- AppIconの1024px画像はFlutter標準ロゴであり、15度ナイフの正式アイコンではない
- AppIconの1024px画像は1024×1024、alphaなし
- `LaunchImage` 3枚はいずれも1×1の透明PNG
- `LaunchScreen.storyboard` は透明な `LaunchImage` を中央に置き、背景を白へ固定している
- リポジトリおよび到達可能なGit履歴に15度ナイフの正式原画はない

### 2-6. 現在確認されている安全上の欠陥

以下は本アップデートで先に解消するブロッカーである。

1. 旧絶対パスの動画を詳細 / レビュー画面で解決すると、通常の差し替え処理を経由して全工程時刻を消去し得る
2. 動画差し替え、動画削除、症例削除がDBとファイルを非原子的な順序で変更し、途中失敗時に動画または記録を失い得る
3. 「保存して閉じる」はレビュー保存失敗後も画面を閉じ、入力を失い得る
4. 時刻保存とレビュー保存が同じ行の全列を更新し、競合時に新しい値を古い値で巻き戻し得る
5. バックアップ除外のプラットフォームエラーが握り潰され、UIの「バックアップされません」という断定を保証できない

既存テストが成功していても、これらの経路は現在テストされていない。

---

## 3. 正式なデータ定義

### 3-1. 表示対象

表示対象は以下の10工程である。

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

`SurgicalStep.totalSurgeryTime` は10工程とは別の独立項目である。10工程の合計から総手術時間を生成してはならない。

レビュー画面の構成は「総手術時間1項目＋10工程＋症例メモ」と表現する。「11工程」「12タブ」を正式表現として使用しない。

### 3-2. 並行計測

- 総手術時間は個別工程と並行計測できる
- 個別工程同士は並行計測できない
- 同じ項目の重複開始はできない

### 3-3. 旧工程

`subTenonAnesthesia` と `dexartSubconjunctivalInjection` は読み込み互換のためenumとDB行を保持する。

- 通常のレビュー項目、工程進捗、分析指標には含めない
- アップデート、動画移行、閲覧だけを理由に削除・変更しない
- 真の動画差し替えまたは動画削除では、動画位置との整合性を保つため開始・終了時刻だけは他工程と同様に消去する
- 自己評価と反省点は保持する

### 3-4. 工程進捗

工程進捗は、表示対象10工程のうち `duration != null` である件数とする。

- 0件：`未記録`
- 1〜10件：`工程 n/10`
- 開始のみ：完了数へ含めず、別途 `計測中` とする
- 総手術時間：分母・分子へ含めず、完了値がある場合だけ別表示する
- 不正な範囲、未知工程、旧工程：進捗へ含めない

### 3-5. `reviewStatus`

`reviewStatus` は互換フィールドとしてDBとモデルに残し、既存の更新挙動を今回変更しない。ただし完成状態の正しい情報源ではないため、一覧・詳細・進捗・分析のUI判断に使用しない。

- UI上の `下書き` / `レビュー済み` 表示は除去する
- DBカラム、enum、読み込み、既存更新処理は残す
- 時刻の開始・終了・再設定が成功した場合は、従来どおり同じtransactionで `reviewStatus = reviewed` と症例 `updated_at` を更新する
- 明示保存で評価または反省点が1件以上変わった場合も、従来どおり同じtransactionで `reviewStatus = reviewed` と症例 `updated_at` を更新する
- 症例メモだけを保存した場合は、従来どおり `reviewStatus` を変更しない
- DBスキーマ変更や既存値の一括変換は行わない

---

## 4. データ保全と変更可能範囲

### 4-1. 最優先の不変条件

アップデート、閲覧、読取専用集計、および論理コミット前に失敗した操作では、以下を操作前と同一に保つ。

- 症例ID、手術日、左右眼
- 総手術時間と全工程の開始・終了時刻
- 自己評価、反省点、症例メモ
- 旧工程と未知工程のDB行
- `reviewStatus`
- 既存動画参照と既存動画ファイル

工程時刻を消去してよいのは、ユーザーが確認した個別工程の「再設定」、影響を確認した「別動画への差し替え」「動画のみ削除」、または症例自体を削除する場合だけである。

成功した旧パス移行と同一動画再リンクでは、`video_path`、`video_display_name`、必要な症例更新日時だけを変更してよい。その他の記録と外部原本は不変とする。

### 4-2. 許可するデータ / サービス層変更

次の変更は本要件の達成に必要なため許可する。

- 一覧・詳細用の読み取り専用集約query、ViewData、Provider
- 副作用のない動画パス分類・動画状態resolver
- 旧パス移行、同一動画再リンク、別動画差し替え、動画削除、症例削除を分離したService API
- 症例IDを事前採番し、動画参照を含む症例作成と必要な初期工程行を1 transactionで作成するRepository API
- 動画参照更新と工程時刻消去を1 transactionで実行するRepository API
- 時刻列だけを更新するAPI
- 評価・反省点・症例メモだけを一括保存するtransaction API
- 旧DBの不足工程行をレビュー進入時に原子的・idempotentに補完するAPI
- 同一症例の動画操作の直列化、競合検出、障害注入用seam
- app管理領域内の未参照動画を安全に再試行削除するcleanup処理

### 4-3. 禁止する変更

- DB schema version、テーブル、カラム、storage IDの変更
- 新しいDB migrationの追加
- 動画保存ルート `Application Support/videos/<recordId>/...` の変更
- 外部絶対パスの原本削除
- 既存患者識別情報フィールドの追加
- ネットワーク通信、クラウド同期、分析SDKの追加
- 一覧、詳細の補助表示、分析から `ensureStepReview(s)` を呼ぶこと

既存の `beforeOpen` による過去DB向けカラム補完は維持してよい。

旧DBの不足工程行は、レビュー画面へ進入した時だけ、表示対象全項目を1つのtransactionで原子的かつidempotentに補完できる。既存工程行、旧工程、時刻、評価、反省点、症例、動画参照、`reviewStatus` を変更しない。失敗時は新規行を1件も残さず、同時進入でも重複を作らない。一覧、詳細の補助表示、分析、動画状態確認からは実行しない。

---

## 5. 動画状態と安全な操作契約

### 5-1. パス分類

動画パスは必ず `recordId` と組み合わせて以下へ分類する。

以下を上から順に判定し、複数分類へ一致させない。

| 優先 | 条件 | 内部分類 | 動作 |
|---:|---|---|---|
| 1 | `videoPath == null` | `unregistered` | ファイルアクセスなし |
| 2 | 空文字、NUL、非canonicalな区切り、root以外の空segment、`.` / `..` segmentを含む | `invalidReference` | ファイル探索・移行・削除をしない |
| 3 | 元文字列が厳密に `videos/<同じrecordId>/<単一ファイル名>` | `managed` | Application Support内だけを確認 |
| 4 | canonicalな絶対パス | `legacyExternal` | 通常ファイルであることの確認だけ可能 |
| 5 | その他、別recordId、余分な階層 | `invalidReference` | ファイル探索・移行・削除をしない |

正規化によって `..` や余分な階層を消して管理パスへ昇格させてはならない。`isManagedVideoPath == false` を旧絶対パスと同義にしてはならない。

UI状態は少なくとも次を区別する。

- 未登録
- 確認中
- 利用可能（管理動画）
- 利用可能（旧形式。詳細 / レビューで安全な移行を試行可能）
- 実体なし
- 不正参照
- 確認失敗（再試行可能）

`確認失敗` を `実体なし` と表示してはならない。

### 5-2. 共通コミット規則

- 同一症例の動画変更、症例情報更新、レビュー明示保存、時刻保存、症例削除は、全route / 画面で共有する同じ症例単位のmutation coordinatorを通して直列化する
- storageへの書き込みとreconciliationは、全症例で共有するstorage lockを通す
- DB更新transaction内で、現在の `video_path` が操作開始時の期待値と一致することを条件付き更新または再読込で確認する
- 動画byteを書き込む前に、canonicalな `videos` rootのバックアップ除外を設定・read-backする。失敗時はcopyを開始しない
- 新動画は一時ファイルへコピーし、sourceとstaged fileのサイズおよびSHA-256一致を確認後にfinal pathへrenameする
- final filenameは衝突しにくい新規名とし、既存ファイルを上書きまたは事前削除しない。衝突時は別名で再試行するか安全に失敗する
- rename後のfinal fileを実際に使用するmedia probe / VideoPlayerControllerで初期化し、映像durationが0より大きく、エラーなくデコード開始できることを確認する。UIで選択元をpreviewできただけでは代替しない
- バックアップ除外の設定と確認に成功してからDBを論理コミットする
- DB論理コミット前に旧管理動画を削除してはならない
- 論理コミット前の失敗ではDB、旧動画、全記録を不変とする
- DB commit後に旧管理動画を削除する
- commit後のcleanup失敗はDB操作の失敗として巻き戻さず、`完了・後処理保留` として安全なcleanupを再試行する
- 外部絶対パスは、どの操作でも削除しない
- commit後の再読込失敗を「保存失敗」と誤表示しない。`保存済み・表示更新失敗` と区別する
- UPDATE / DELETEの対象件数が期待値と異なる場合は競合としてtransactionをrollbackし、成功を返さない

cleanupは、正規化した `<Application Support>/videos` 配下だけを対象とする。DBの全動画参照を1つの一貫したsnapshotとして取得・分類できた場合だけ候補を確定し、削除直前にもlock内で未参照を再確認する。他症例、外部パス、参照中のfinal fileを削除してはならない。

保護集合には管理相対パスだけでなく、DBにある全絶対パスをcanonical / symlink-resolved targetとして含める。旧絶対パスが管理root内の同じ実体を指す場合や、symlink経由で候補と同一になる場合も参照中として保護する。外部絶対パスのtargetをcleanup対象へ加えてはならない。

DB queryの例外、部分結果、未知のpath分類、または参照の完全性を証明できない状態ではfail closedとし、tmpを含むファイルを一切変更しない。

動画書き込みとcleanupは同じstorage同期機構を通し、cleanupがコピー中、一時ファイル、rename後かつDB commit前のfinal fileを削除しないようにする。DB内に不正参照がある場合は、その参照先候補または症例ディレクトリを自動削除せず診断対象として残す。

管理動画に対するresolve、copy destination、rename、個別file / directory cleanup、reconciliation、バックアップ属性設定・読戻しは、すべて共通のsafe-path preconditionを通す。

- canonicalな `videos` rootは通常directoryでありsymlinkではない
- recordId directoryと既存fileを含む各path componentを `lstat` 相当で調べ、symlinkを追跡しない
- 既存targetはcanonical / real pathがroot配下であり、期待する `videos/<recordId>/<filename>` または直下record directoryと一致する
- 新規targetはcanonicalな既存parentがroot直下の正しいrecordId directoryである
- 違反、不明、raceによる差し替わりではI/Oと属性変更を行わず安全に失敗する

### 5-3. 新規症例登録

新規登録もファイルとDBをまたぐ安全契約の対象とする。

1. 永続化前に一意な症例IDを採番する
2. そのIDの管理領域へ動画を一時コピーし、サイズ、SHA-256、final fileの再生可能性、バックアップ除外属性を確認する
3. 1つのDB transactionで、動画参照を含む症例行と既存仕様上必要な初期工程行を作成する
4. DB commit成功後だけ登録成功を返す

- コピー、検証、バックアップ除外、DB transactionの失敗時は症例行を残さず、新規ファイルをcleanupする
- cleanup自体が失敗した場合は未参照ファイルとして後続のreconciliation対象にし、登録成功とは返さない
- DB commit後の再読込、Provider更新、画面遷移の失敗を理由に、commit済み症例や参照中動画を削除しない
- 選択元の外部動画は成功・失敗を問わず削除しない
- 同じ登録操作の多重実行を防ぐ

### 5-4. 旧絶対パス移行

- 一覧・分析では存在確認だけを行い、コピーやDB更新をしない
- 詳細 / レビューで再生が必要になったときだけ移行を試行してよい
- 成功時は同じ動画を管理領域へコピーし、動画参照だけを更新する
- 全工程時刻、評価、反省点、症例メモ、旧工程、`reviewStatus` を変更しない
- 外部原本を残す
- 移行失敗時は外部原本をそのまま再生し、記録閲覧を妨げない
- 通常の「別動画への差し替え」APIを流用しない
- 移行commit後は新しい参照を結果として返して症例 / 動画Providerを更新し、画面が新しい参照を取得するまで時刻操作を有効にしない

### 5-5. 実体なし動画の再リンク

UIは以下を分けて提示する。

1. `同じ動画を再登録`：工程時刻を保持する
2. `別の動画に差し替え`：工程時刻を消去する

同じ動画かどうかをファイル名や長さだけで自動断定しない。ユーザーが同じ動画であることを明示した場合に限り、動画参照だけを更新して全記録を保持する。

### 5-6. 既存症例への初回添付と不正参照の回復

`videoPath == null` の既存症例へ初めて動画を添付する場合は、期待旧参照を `null` として動画参照だけをtransactionで更新し、既存の全工程時刻、評価、反省点、症例メモ、旧工程、`reviewStatus` を保持する。

- 既存工程時刻がある場合は「記録済みの位置を保持するため、対応する同じ手術動画を選ぶ」ことを選択前と確認時に示す
- DB失敗、競合、バックアップ除外失敗では参照と全記録を不変にし、新規コピーだけを安全にcleanupする
- `invalidReference` は自動的に開く、移行する、削除する、または初回添付として上書きしない
- 不正参照からは `同じ動画を再登録` と `別の動画に差し替え` をユーザーが選択でき、それぞれ§5-5と§5-7の契約を適用する

### 5-7. 別動画への差し替え

確認ダイアログには「総手術時間を含む全工程の開始・終了位置が削除される。自己評価、反省点、症例メモは残る」と明記する。

成功時は1つのDB transactionで以下を行う。

1. 新しい `video_path` / `video_display_name` へ更新
2. 当該症例の総手術時間、表示工程、旧工程を含む全行の開始・終了を `NULL` へ更新

評価、反省点、症例メモ、日付、左右眼、工程行そのものは保持する。commit後に旧管理動画をcleanupする。

### 5-8. 動画のみ削除

確認ダイアログには、動画参照と全工程位置が削除され、評価・反省点・症例メモは残ることを明記する。

DB transactionで動画参照を `NULL` にし、全開始・終了時刻を `NULL` にする。commit後に旧管理動画をcleanupする。

### 5-9. 症例削除

- 症例と全工程記録が削除されることを明記した破壊的確認を使う
- recordIdは空文字、`.`、`..`、NUL、path separatorを含まない単一segmentでなければ拒否する
- DBの症例削除とFK `ON DELETE CASCADE`を先にcommitし、DELETE affected rowsが正確に1件の場合だけ、そのID専用のcleanup tokenを発行する
- commit成功後、そのtokenから解決したcanonical targetがcanonicalな`videos` rootの直下で、通常directoryかつsymlinkでないことを確認し、その症例IDの管理動画ディレクトリだけをcleanupする
- 症例が存在しない0件DELETE、複数件DELETE、無効ID、root外target、symlinkではcleanupを開始せず成功表示もしない
- DB削除失敗時は症例、工程行、管理動画をすべて保持する
- 削除成功後の通知は戻り先の一覧で表示する

### 5-10. クラッシュ境界

許容状態を次のように固定する。

- commit前の終了：DB、旧動画、工程記録は旧状態。未参照の一時 / 新規ファイルが残ることは許容
- commit後・cleanup前の終了：DBは新状態、新しく参照された動画は存在。旧管理動画が未参照で残ることは一時的に許容
- 次回の安全なcleanupで未参照ファイルを再試行削除する

データや参照中動画の喪失より、一時的な孤児ファイルを優先して許容する。

再試行をプロセス内メモリだけに保持してはならない。少なくとも次回のアプリ / storage service初期化時と動画操作後に、DB参照と管理領域を照合するreconciliationを実行する。書き込みと排他し、候補検出と削除の両時点で未参照であるfinal file、および処理中でなく最終更新から24時間を超えたtmpだけを削除できる。参照中、処理中、正体不明のファイルは削除しない。

### 5-11. iCloudバックアップ除外

手術動画は機微データとして扱い、バックアップ除外は動画保存成功条件の一部とする。

- `videos` ディレクトリとfinal動画ファイルへ除外属性を設定する
- `videos` directoryの除外属性をread-backしてから、tmpを含む最初の動画byteを書き込む
- final動画ファイルの `isExcludedFromBackup == true` を確認する
- 設定または確認の失敗を握り潰さない
- 失敗時は新規コピーを削除し、既存DB、既存動画、工程時刻を変更しない
- 日本語で再試行可能なエラーを表示する
- UIで「バックアップされません」と表示するのは属性確認に成功した管理動画だけとする
- commit前クラッシュで残り得るtmp / finalも、作成時点から除外済みroot内にあることを保証する

既存の管理動画もアップデート後の非破壊検証対象とする。

- storage初期化時に、完全なDB snapshotが参照する全管理動画と `videos` directoryへ除外属性を再設定し、final fileから読み戻す
- 既存動画で設定または確認に失敗してもDBや動画を変更・削除せず、閲覧と再生は維持する
- 失敗中はバックアップ除外を断定せず、プライバシー警告と再試行を提示する
- 旧外部絶対パスへ属性を設定しない
- 配布判定では旧版fixtureを含む現存する全管理動画でread-back成功を必須とする

---

## 6. デザイン基盤、テーマ、日本語化

### R1. デザイントークン

複数画面で実際に共有する次の値を `lib/src/theme` 等へ集約する。

- ブランド色：`#006D77`
- Light / Dark `ColorScheme`
- 画面余白、カード内余白、主要角丸
- 標準モーション時間
- 動画surfaceの背景 / 前景色
- 成功、警告、失敗の意味色

すべての数値リテラルを定数化しない。動画比率、グラフgeometry、個別調整値は意図が明確ならローカルに残す。

`ThemeData` では少なくとも以下を実利用に合わせて定義する。

`appBarTheme` / `cardTheme` / `filledButtonTheme` / `outlinedButtonTheme` / `textButtonTheme` / `inputDecorationTheme` / `listTileTheme` / `dividerTheme` / `snackBarTheme` / `dialogTheme` / `tabBarTheme` / `segmentedButtonTheme`

### R2. ダークモード

- `theme`、`darkTheme`、`themeMode: ThemeMode.system` を設定する
- 動画領域は両テーマで暗いsurfaceとする
- OS appearanceの実行時切り替えへ再起動なしで追従する
- 切り替え時に入力、dirty、選択タブ、再生速度、分析の選択点を失わない
- ダイアログ、BottomSheet、入力欄、SnackBar、空状態、エラー状態、グラフを両テーマで確認する

### R3. 日本語ローカライズ

- `flutter_localizations` を導入する
- Material / Widgets / Cupertino delegateを設定する
- `supportedLocales` に `Locale('ja')` を設定する
- Flutter UIは、日本語以外の端末でも日本語専用アプリとして `localeResolutionCallback` 等で日本語へフォールバックする
- Xcode Localizationsへ日本語を追加し、Release bundleへ日本語localizationを含める
- `developmentRegion = en` は変更しない
- `DateFormat` は必要な箇所で `ja_JP` を明示する

日本語端末でDatePicker、Flutter編集メニュー、ネイティブファイルピッカー、写真アクセス許可文を確認する。英語端末ではFlutter localeが `ja` となり、アプリ本文、DatePicker、Flutter編集メニューが日本語になることを確認する。ファイルピッカー等、OS所有のUIは端末言語に従うことを許容し、アプリ管理の日本語文言と混同しない。

### R4. 共通UI

共通化は、文言、Semantics、エラー回復方法を揃える価値がある場合に限る。

候補：`AppEmptyState`、`AppErrorState`、`AppConfirmDialog`、SnackBar helper、`VideoSurface`。

レビュー専用の `ProcedureTimingCard`、`VideoTransportControls`、`StepNotesCard` はレビュー機能内へ置く。2箇所に存在するだけで過度に汎用化しない。

### R5. フィードバック

- 画面上で結果が明らかな成功にはSnackBarを重ねない
- 保存、削除、動画操作の失敗は、原因カテゴリと次の行動を日本語で示す
- 生の例外、パス、SQL、スタックトレースを表示しない
- 頻繁な時刻操作はハプティクスとインライン状態で伝える
- SnackBarは原則floatingとし、表示前に既存SnackBarを整理してキュー化を防ぐ
- キーボード、FAB、ホームインジケータ、下部操作を覆わない
- 色だけで成功、警告、失敗を区別しない

---

## 7. 画面別要件

### R6. 症例一覧

月別グループと総手術件数を維持する。空状態では件数0のカードを表示しない。

各症例に以下を表示する。

| 項目 | 表示 |
|---|---|
| 日付 | 月見出しに年があるため `8月13日（水）` |
| 左右眼 | `右眼` / `左眼` を文字付きで表示 |
| 工程進捗 | `未記録` または `工程 n/10` |
| 総手術時間 | 独立値が完了している場合のみ |
| 動画状態 | §5-1の状態を理解可能な文言で表示 |

実装要件：

- 基本症例一覧を先に表示し、補助情報の失敗で一覧全体を失敗させない
- 全症例×全工程の分析snapshotへ依存しない
- 読み取り専用の集約queryまたは同等のViewDataを使う
- 不足工程行を作成しない
- 動画状態確認でコピー、DB更新、旧パス移行を起動しない
- 空状態に用途説明と `最初の症例を登録` CTAを置く
- 読み込み失敗時に再読み込みを提供する

### R7. 新規症例登録

登録順序は「動画を選択 → 手術日 → 左右眼 → 登録」を維持する。

#### バリデーション

- 初期表示では赤い必須エラーを出さない
- 登録操作後に不足 / 不正項目を各フィールド付近へ表示する
- 最初のエラーを1回だけlive regionで通知し、画面外ならスクロールする
- 項目を修正したらそのエラーを再評価する
- 保存失敗後も動画、日付、左右眼を保持する
- 動画確認中は確認中であることを表示する
- 動画確認完了後、保存中でない限り登録操作を利用できる
- 再生不能動画では登録せず、動画エラーと変更CTAを表示する
- ボタン押下が無反応に見える状態を作らない

#### 動画プレビュー

- 共通 `VideoSurface` を使用する
- Sliderドラッグ中はつまみと時間をローカルに追従させる
- 実動画への `seekTo` は `onChangeEnd` で1回だけ行う
- 動画差し替え時に日付と左右眼をリセットする既存仕様を維持する

登録成功後は詳細へ遷移する。遷移で成功が明らかなため成功SnackBarは必須としない。

新規症例画面は動画選択済みの時点から未保存状態とする。AppBarの戻る操作では破棄確認を表示する。

### R8. 症例詳細

次の4セクションへ整理する。

1. 症例情報
2. 動画
3. 工程記録
4. 危険操作

必須事項：

- `reviewStatus` の代わりに工程進捗と独立した総手術時間を表示する
- 手術日 / 左右眼の既存編集機能を維持し、キャンセルでは不変、保存失敗では画面と入力を保持する
- 補助情報の失敗時も症例情報、動画操作、工程レビュー導線を維持する
- 未登録、確認中、利用可能、旧形式、実体なし、不正参照、確認失敗を扱う
- 動画実体がなくても工程記録を閲覧できる
- 同じ動画の再登録と別動画への差し替えを区別する
- 動画差し替え、動画削除、症例削除の確認文は実際の消去範囲と一致させる
- 破壊操作中の多重起動と離脱を防ぐ
- 症例削除を最下部へ置く
- 失敗時は画面を維持し、日本語エラーと再試行を提供する
- 別routeの更新 / 削除と競合した0行UPDATEを成功表示せず、最新状態または症例削除済み状態へ回復する

### R9. 工程レビュー

#### R9-1. 状態分類

状態を次の3種類へ分離する。

1. 即時保存：各項目の開始・終了時刻
2. 明示保存ドラフト：自己評価、反省点、症例メモ
3. 一時再生状態：位置、再生 / 停止、速度、選択タブ

`dirty` は明示保存ドラフトと最後にcommit成功した基準値との差分で判定する。

- 時刻操作、再生、シーク、速度、タブ切り替えはdirtyにしない
- 保存済み値へ戻した場合はcleanへ戻る
- 初期同期やProvider更新でdirtyを発生させない
- build中にController、基準値、dirtyを変更しない
- 保存ボタンは `dirty && !hasPendingWrite && dataReady` の場合だけ有効
- 保存開始後の追加変更を未保存のままclean扱いしない
- 前後空白を除去して保存する場合は、同じ正規化をdirty比較にも使い、commit後のControllerと基準値をDBへ保存した正規値に揃える

#### R9-2. 保存APIと原子性

時刻保存APIは、画面が最新の症例世代から同期したcommit済み動画参照の `expectedVideoPath` を必須入力とする。DB transaction内で症例が存在し、現在の `video_path` と完全一致する場合だけ、開始、終了、工程行の更新日時を変更し、評価と反省点を書き戻さない。互換性維持のため、症例の `reviewStatus = reviewed` と症例更新日時は同じtransactionで更新する。

開始 / 終了では `expectedVideoPath` がVideoPlayerControllerにbindした参照と一致することも必須とする。動画なしでの個別工程再設定はControllerを必要とせず、最新症例世代の `null`、欠損管理参照、または不正参照をexpected値として条件更新する。

症例削除済み、動画参照の差し替え / 削除 / 移行済み、対象工程行なし、またはUPDATE件数が期待値と異なる場合は競合として全体をrollbackする。0行UPDATEを成功として返してはならない。UIは保存成功を表示せず、最新状態を再読込して「動画が変更されたため時刻を保存しませんでした」と回復方法を示す。

明示保存は、変更対象の評価・反省点と症例メモを1つのDB transactionで保存する。

- 開始・終了時刻を変更しない
- 途中失敗時は同じ保存操作をすべてrollbackする
- 症例行と各対象工程行の存在、および期待UPDATE件数を確認し、削除済み / 競合による0行UPDATEを成功にしない
- commit後だけ成功をUIへ返し、Providerをinvalidateする
- 評価または反省点が1件以上変わった場合だけ、同じtransactionで `reviewStatus = reviewed` を更新する
- 症例メモだけの変更では `reviewStatus` を変更しない

#### R9-3. 同時操作

- 同時に実行する永続化処理は1件だけとする
- 時刻保存中は他の時刻操作とレビュー保存を無効化する
- レビュー保存中は時刻操作とドラフト入力を無効化する
- 永続化中は離脱を許可しない
- 再生、一時停止、シーク、速度変更は利用可能としてよい
- UI排他だけに依存せず、フィールド別Repository APIで巻き戻しを防ぐ
- 別routeの動画操作 / 症例削除との競合は、§5-2の症例単位coordinatorと `expectedVideoPath` のDB preconditionの両方で防ぐ

#### R9-4. 保存して閉じる

- キャンセル：入力とdirtyを変更しない
- 変更を破棄：ドラフトを保存せず閉じる。即時保存済み時刻は戻さない
- 保存して閉じる：通常保存と同じtransactionを1回だけ実行する
- 保存成功時だけcleanにして閉じる
- 保存失敗時は画面、入力、dirtyを保持して再試行可能にする
- ただし症例削除済み競合では再試行不能とし、入力を消さずread-onlyの回復状態へ移る。`症例が別画面で削除されたため保存できません` と表示し、各テキストのコピー、ドラフト破棄、一覧へ戻る操作を提供する。症例を復活させない
- ダイアログと保存処理の多重起動を防ぐ

#### R9-5. Provider同期

- 初回データ到着時にControllerと保存済み基準値を初期化する
- buildではなくRiverpod listener等で更新を扱う
- clean時は最新レビュー内容を画面と基準値へ反映する
- dirty時 / 保存中はローカルドラフト、選択範囲、IME composingを上書きしない
- dirty時も時刻の最新値は反映する
- 古い非同期応答が新しい保存結果を巻き戻さないよう世代管理する
- 動画移行 / 再リンク / 差し替え後は、commit済み参照とControllerが同じ世代になるまで位置依存操作を無効化する
- 初回表示後のrefresh失敗では現在画面を残して再試行を提供する
- commit成功後のrefresh失敗では、commit済み値をController、保存済み基準、工程インライン状態へ即時反映したままcleanを維持し、`保存済み・表示更新失敗` と再読込を提示する
- Controller、FocusNode、listener、ValueNotifierを適切にdisposeする

#### R9-6. 計測フィードバック

- 未着手、計測中、完了を文字 / アイコンとSemanticsで区別する
- 開始、終了、再設定のDB保存成功後に軽いハプティクスを1回だけ実行する
- 競合、入力不正、キャンセル、保存失敗ではハプティクスを実行しない
- ハプティクス失敗でcommit済み操作を失敗扱いしない
- 時刻保存ごとの成功SnackBarは表示しない

#### R9-7. 時刻シーク

- 開始 / 終了時刻は最低44×44、Materialでは可能なら48×48の正式なボタンにする
- ボタン、ラベル、操作結果をVoiceOverで理解できるようにする
- Tooltipを用意する

#### R9-8. 動画更新範囲

- 位置通知でルート画面、全タブ、工程フォームを `setState` しない
- 時間表示、Slider、再生アイコンだけを局所更新する
- 最新位置から開始 / 終了時刻を取得する
- 同一パスのProvider refreshやタブ切り替えでVideoPlayerControllerを再生成しない
- 動画パス変更時だけ旧Controllerをdisposeし、画面内再生速度を再適用する
- 古いControllerの遅延完了が新Controllerを上書きしない
- dispose後の通知を無視する
- 再生速度は同じ画面内で維持し、画面を閉じた後は保持しない

#### R9-9. キーボード

- フォーカスされた反省点 / メモと編集中テキストを隠さない
- `viewInsets` とSafe Areaを考慮する
- 必要に応じて `Scrollable.ensureVisible` を使う
- 文字倍率2.0でも動画、入力欄、保存操作へ再到達できる

#### R9-10. iOSの戻る操作

- cleanかつ永続化中でない場合は標準エッジスワイプを維持する
- dirty時はデータ保護を優先し、エッジスワイプを意図的に無効化する
- dirtyかつ永続化中でない場合はAppBarの戻るボタンを利用でき、保存 / 破棄 / キャンセルを選べる
- 保存中はエッジスワイプとAppBar戻るの両方で離脱させない
- cleanへ戻ればエッジスワイプを再度有効化する

`PopScope(canPop: false)` のiOSエッジスワイプではコールバック自体が呼ばれないため、「dirty時のスワイプで確認ダイアログを出す」とは規定しない。

#### R9-11. 動画を利用できない場合

- 動画が未登録、実体なし、不正参照、確認失敗、または再生初期化失敗でも、既存の全工程時刻、評価、反省点、症例メモを表示できる
- 評価、反省点、症例メモは編集・保存できる
- 現在の動画位置を必要とする開始、終了、シークは無効化し、理由と動画の再登録 / 再試行導線を表示する
- 個別工程の再設定は動画位置を必要としないため、既存の確認ダイアログを経て利用できる
- 動画エラー、再試行、再リンクを理由に工程時刻やドラフトを自動消去しない
- 旧外部動画の安全な移行だけが失敗した場合は、§5-4に従って外部原本からの再生を試みる

### R10. 分析

- 既存の指標、全症例俯瞰、前後選択、詳細導線を維持する
- 読み取り専用とし、DB行作成 / 更新、動画アクセスをしない
- Painterへ現在の `TextScaler` を渡し、`shouldRepaint` に含める
- 文字倍率に応じて軸余白と高さを調整し、欠けと重なりを防ぐ
- Light / Darkで線、点、グリッド、ラベル、選択点のコントラストを満たす

全症例を一画面へ描画するため、細い各データ点を独立したSemanticsボタンにしない。

- グラフ全体を1つのadjustable Semanticsコントロールとする
- タップ位置から最寄りの症例を選択する
- 0件では空状態を表示し、adjustable controlを作らない
- 1件以上では、初期選択をその指標で最も新しい症例 `K = N` とする
- VoiceOverのincrementは新しい症例、decrementは古い症例へ1件移動し、端で循環させない
- 1件時は `全1件中1件目` を読み上げ、increment / decrementで状態を変えない
- 先頭 / 末尾では不可能な方向をVoiceOverへ伝え、選択変更を誤って通知しない
- 指標変更時は同じ症例に新指標の有効値があれば選択を保持し、なければ新指標の最新症例を選択する
- `全N件中K件目、日付、左右眼、工程、時間` を読み上げる
- 下部カードに44×44以上の前、次、詳細ボタンを置く
- 1件、2件、50件で利用可能であることを確認する

---

## 8. アクセシビリティとレイアウト

### 8-1. 文字と操作

- 自動テスト上の「200%」は `TextScaler.linear(2.0)` と定義する
- タップ可能なSemanticsノードは44×44 logical pixels以上とする
- 固定 `height` より `minHeight` を使い、文字倍率に応じて拡張できるようにする
- 状態を色だけで表現しない
- 標準コントロールのSemanticsを重複して読み上げさせない
- VoiceOverフォーカス順を視覚順と合わせる
- Slider、SegmentedButton、グラフは現在値と変更結果を読み上げる
- `MediaQuery.disableAnimations` がtrueなら追加した非必須モーションを停止する

コントラスト基準：

- 通常文字：4.5:1以上
- 大きな文字：通常ウェイトで18pt以上、または太字で14pt以上の場合に3:1以上
- 操作部品と意味を持つグラフ要素：隣接色に対して3:1以上

例外は「原則」で済ませず、対象、測定値、理由、代替識別手段、承認を記録する。

### 8-2. 必須レイアウトマトリクス

| 区分 | Logical viewport | 必須条件 |
|---|---:|---|
| 最小phone縦 | 320×568 | 1.0 / 2.0、Light / Dark |
| 最小phone横 | 568×320 | 1.0 / 2.0、Light / Dark、キーボード |
| 大型phone縦 | 430×932 | 1.0 / 2.0、Light / Dark |
| 大型phone横 | 932×430 | 1.0 / 2.0、Light / Dark |
| iPad縦 | 768×1024 | 1.0 / 2.0、Light / Dark |
| iPad横 | 1024×768 | 1.0 / 2.0、Light / Dark |
| iPad compact Split View | 320×1024 | 1.0 / 2.0、Light / Dark、キーボード |

上表の全組み合わせに、次の `MediaQueryData` stress fixtureを割り当てる。値は特定機種の再現ではなく、非対称insetを含むレイアウト耐性の検証値である。可能ならtest viewを設定して `MediaQueryData.fromView` から生成する。直接構築する場合は `padding = max(viewPadding - viewInsets, 0)` を各辺で計算し、`systemGestureInsets` も同じ安全領域値へ明示する。

- insetなし：`viewPadding = EdgeInsets.zero`、`viewInsets = EdgeInsets.zero`
- phone縦：`viewPadding = EdgeInsets.fromLTRB(0, 59, 0, 34)`
- phone横左：`viewPadding = EdgeInsets.fromLTRB(59, 0, 21, 21)`
- phone横右：前項のleft / rightを反転
- iPad：`viewPadding = EdgeInsets.fromLTRB(0, 24, 0, 20)`
- キーボード：phone横は `viewInsets.bottom = 160`、phone縦 / iPadは `viewInsets.bottom = 300`
- pixel ratio：代表Goldenを1.0と3.0で実行する

各fixtureで初期表示だけでなく、全scrollableを先頭から末尾まで操作し、各必須操作を完全に画面内へ出してtap / focusできることを確認する。overflow、到達不能操作、Safe Area / ホームインジケータ / キーボードとの重なりを、期待control一覧とgeometry assertionで自動判定する。

実機 / integration testでは、iPhoneの横左 / 横右、iPadの縦 / 上下逆 / 横左 / 横右を別ケースとし、表示中に回転しても入力、dirty、選択タブ、再生速度、分析選択を保持する。

iPadの現行OSでは、主要画面を表示したままウインドウの四隅と各辺をドラッグし、幅は最大値から320 logical pixelsまで、高さはOSが許可する最小値まで連続的に縮小・拡大する。幅 / 高さの同時変更、横長 / 縦長、動画再生中、dirty入力中、キーボード表示中にも実行し、クラッシュ、overflow、操作喪失、状態初期化がないことを確認する。

### 8-3. 主要フロー

文字倍率1.0 / 2.0およびVoiceOverで以下を完了できること。

1. 一覧から新規症例登録
2. 詳細から工程レビュー
3. 開始、終了、再設定
4. 評価、反省点、メモの保存と未保存離脱
5. 分析指標変更、症例選択、詳細遷移
6. 動画の再リンク、差し替え、削除
7. 症例削除の確認、キャンセル、失敗後の再試行

---

## 9. ブランド、起動画面、ドキュメント

### R11. AppIcon

- 既存の15度ナイフというブランドコンセプトを維持する
- 正式原画が提供されるまで生成作業を開始しない
- iPhone、iPad、App Store用の全slotを生成する
- alpha、不要な透明余白、焼き付けた角丸を含めない
- Flutter標準ロゴを全slotから除去する

正式原画の提供は配布リリースの外部入力かつRG-6ブロッカーである。

### R12. LaunchScreen

- 空の `LaunchImage` 参照を除去する
- Asset Catalogのnamed colorでAny / Darkを定義する
- Light背景：`#006D77`
- Dark背景：`#003F45`
- 原画提供前は背景のみとし、空画像やFlutterロゴを配置しない
- Flutter最初の画面背景を対応するlaunch色と整合させ、全面白 / 黒フラッシュを防ぐ
- 意図的な待機時間を追加しない

### R13. ドキュメント

- `pubspec.yaml` のdescriptionをアプリ内容へ合わせる
- READMEを10工程＋総手術時間、動画レビュー、分析、ダークモード、ローカル保存へ合わせる
- テーマ定義にトークン追加基準と固定色の例外を短く記載する
- テスト件数、ファイル数、行番号を恒久的な要件値として固定しない
- スクリーンショット、Golden、fixtureには実患者情報、実手術動画、実ファイル名を使わない

---

## 10. 対象外

- ボトムナビゲーション導入、画面遷移構造の全面変更
- 工程タブ構成そのものの再設計
- 検索、絞り込み、並び替え
- CSV / JSON出力、クラウド同期、オンボーディング
- 全文言の多言語化
- Android固有のデザイン調整
- 再生速度の画面外 / アプリ再起動後の永続化
- pull-to-refreshの一覧追加
- Heroや装飾目的のカスタム遷移
- DBスキーマ変更、`reviewStatus` 削除
- CCCリング等へのブランド刷新

安全性修正、読み取り専用集約、iOS localization、バックアップ除外の検証は対象外に含めない。

---

## 11. テスト要件

### 11-1. データ / 動画の自動テスト

以下を最低限実装する。fault injectionにはthrowing storage wrapper、SQLite trigger、制御可能なFuture等を使う。

1. 新規登録成功で、動画参照付き症例と必要な初期工程行が同時commitされる
2. 新規登録のコピー / バックアップ除外失敗で症例行が作成されず、選択元動画が残る
3. 新規登録のDB失敗で症例行が作成されず、新規管理動画が削除またはreconciliation対象になる
4. 新規登録のcommit後再読込 / 表示更新失敗で、症例と参照中動画を削除しない
5. final filename衝突時に既存ファイルを上書きも削除もしない
6. 旧絶対パス移行前後で日付、左右眼、全工程時刻、評価、反省点、メモ、表示 / 旧 / 未知工程のrow identity、`reviewStatus` が一致する
7. 旧パス移行のDB失敗でDB不変、外部原本が再生可能、新規コピーが参照されない
8. 一覧の旧パス状態判定前後でDBとsupport directoryが不変
9. 同一動画再リンクで動画参照以外を保持する
10. 同一動画再リンク失敗で欠損参照と全記録を保持する
11. 別動画差し替え成功で参照更新と全時刻消去が同時commitされ、日付、左右眼、表示 / 旧 / 未知工程のrow identity・評価・反省点、メモ、`reviewStatus` は完全一致する
12. 差し替えの時刻更新失敗で参照更新もrollbackされる
13. 旧ファイルcleanup失敗でも新動画とDB新状態が利用可能で、後処理保留になる
14. 動画削除成功で参照と全時刻だけを消去し、日付、左右眼、表示 / 旧 / 未知工程のrow identity・評価・反省点、メモ、`reviewStatus` は完全一致する
15. 動画削除のDB失敗で参照、時刻、管理動画が不変
16. 動画削除のcleanup失敗でDBはcommit済み、後処理が再試行される
17. 動画削除が旧外部原本を削除しない
18. 症例DB削除失敗で症例、工程行、管理動画が残る
19. 症例cleanup失敗でDB削除は成功し、後処理が再試行される
20. 症例削除が旧外部原本を削除しない
21. 同一症例の競合動画操作は期待旧パスが一致する1件だけcommitする
22. path classifierが相対 / 絶対pathの`.` / `..`、重複区切り、NUL、別recordId、不正相対パスを拒否し、filesystemへアクセスしない
23. 動画状態確認失敗でも一覧の基本情報を表示し、`実体なし` と誤表示しない
24. 進捗読み取り前後で工程行数と値が不変
25. commit前クラッシュ相当状態の再openで旧参照、旧動画、時刻が利用可能
26. commit後cleanup前の再openで新参照を利用し、旧孤児を参照しない
27. 次回起動のreconciliationが未参照finalと24時間超の未参照tmpだけを削除し、参照中、不正参照候補、処理中、24時間以内のtmpを保持する
28. 書き込みとcleanupを競合させてもcommit予定または参照中の動画を削除しない
29. バックアップ除外をdirectoryとfinal fileへ設定・確認する
30. バックアップ除外失敗で新規コピー、DB参照、既存時刻が安全にrollbackされる
31. `videoPath == null` の既存症例への初回添付で全工程時刻とレビューを保持する
32. 初回添付のDB失敗 / 競合で参照と記録を保持し、新規コピーだけをcleanupする
33. 不正参照を自動で開かず、同一動画再登録と別動画差し替えの選択どおりに記録を保持 / 消去する
34. barrierで差し替えと旧動画由来の時刻保存を競合させ、差し替え後に旧時刻をcommitしない
35. barrierで動画削除と時刻保存を競合させ、削除後に時刻をcommitしない
36. barrierで症例削除と時刻保存を競合させ、0行UPDATEを成功扱いせず症例を復活させない
37. reconciliationのDB全参照queryが例外、部分結果、未知状態の場合に、全tmp / final fileが不変である
38. 既存管理動画へ除外属性を再設定してread-backし、失敗時もDB / 動画を保持して再試行できる
39. 旧外部動画へ除外属性の設定や削除を行わない
40. 症例情報更新と症例削除を競合させ、削除後の0行UPDATEを成功表示しない
41. 存在しないrecordIdの0件DELETEではcleanup tokenを発行せず、全ファイルを保持する
42. 空、`.`、`..`、NUL、separatorを含むrecordIdを拒否し、全ファイルを保持する
43. symlink化した症例directoryとroot外canonical targetをrecursive deleteせず、リンク先を保持する
44. 管理root内の動画を指す旧絶対パスとsymlink同値参照をreconciliationの保護集合へ含め、削除しない
45. 旧パス移行直後はcommit済みの新参照でControllerと `expectedVideoPath` を同期してから時刻保存できる
46. CCCだけの旧DBでレビュー補完に成功すると全表示項目が1件ずつ存在し、既存CCC / 旧工程 / 症例 / 動画値は不変である
47. 旧DBの工程補完途中失敗で全insertをrollbackし、同時 / 再実行でも重複行を作らず `reviewStatus` を変更しない
48. sourceと同サイズだが内容が異なるstaged file、copy中のsource差し替え、再生不能codec / 破損finalを拒否し、DB、旧管理動画、全記録を不変にする
49. rootのバックアップ除外read-back失敗では最初の動画byteを書き込まず、commit前クラッシュ相当で残るtmp / finalも除外済みroot内にある
50. `videos` root、record directory、fileの各symlink fixtureで、resolve、初回添付、差し替え、動画削除、症例削除、reconciliation、属性設定を拒否し、root外targetとDBを不変にする

### 11-2. レビュー保存の自動テスト

1. 時刻保存は評価と反省点を変更しない
2. レビュー保存は開始・終了時刻を変更しない
3. 時刻保存成功は同じtransactionで `reviewStatus = reviewed` にし、失敗時はstatusもrollbackする
4. 評価 / 反省点を含む明示保存はstatusをreviewedにし、メモだけの保存はstatusを変更しない
5. 複数レビュー＋メモの一括保存成功ですべての新値が残る
6. 複数レビュー＋メモの途中失敗ですべてrollbackされる
7. 同じ初期行から得た古いsnapshot A / Bを使い、時刻→レビュー、レビュー→時刻の両順序で両方の新値が残る
8. 両APIを同時開始しても直列化され、時刻とレビューの両方の新値が残る
9. 初期表示はclean、編集でdirty、保存値へ戻すとclean。保存時に正規化する空白も同じ基準で比較する
10. 時刻操作だけではdirtyにならない
11. 通常保存成功で基準値とControllerをcommit済み値へ更新する
12. 通常保存失敗で入力とdirtyを保持し、再試行できる
13. 制御可能な時刻保存Futureの完了前はレビュー保存と他工程の時刻操作を開始しない
14. 制御可能なレビュー保存Futureの完了前は入力、時刻操作、多重保存を開始しない
15. `保存して閉じる` はRepositoryを正確に1回呼び、成功時だけ閉じる
16. `保存して閉じる` 失敗時は画面、入力、dirtyを保持する
17. `変更を破棄` はドラフトをDBへ書かず、即時保存済み時刻を残す
18. dirty中のProvider refreshはドラフトを保持し、時刻だけ更新する
19. clean中のProvider refreshは最新レビューを基準値へ反映する
20. dirtyかつ入力中のProvider refresh失敗でもTextField、文字列、selection、IME composing、dirty、選択タブを保持し、非破壊エラーと再試行を表示する
21. 前項の再試行成功では最新時刻だけを反映し、ドラフトを上書きしない
22. 古い非同期応答が新しい保存結果を上書きしない
23. 位置通知100回後もレビュー画面本体と工程フォームのbuild countが初期値から増えず、時間表示だけが更新される
24. タブ切り替え後も再生速度を維持する
25. dispose済みControllerの遅延完了を無視する
26. clean時のiOS edge swipeはpopできる
27. dirty時のedge swipeはpopせず入力を保持する
28. dirty時のAppBar戻るで離脱ダイアログを表示する
29. 時刻保存中はedge swipeとAppBar戻るの両方でpopしない
30. レビュー保存中はedge swipeとAppBar戻るでpopせず、離脱ダイアログや第2保存を開始しない
31. dirtyから保存済み値へ戻すとedge swipeが再び有効になる
32. 開始、終了、再設定の各成功でハプティクスを1回実行する
33. 競合、時刻不正、確認キャンセル、DB失敗ではハプティクスを実行しない
34. ハプティクス失敗後もcommit済み時刻操作は成功として扱う
35. 動画の全エラー状態でも既存記録を表示し、レビューのドラフト保存ができる
36. 動画未登録 `null`、欠損管理参照、不正参照では開始 / 終了 / シークだけを理由付きで無効化し、確認付きの個別工程再設定は最新参照をexpected値としてcommitできる。再設定中に参照が変わればrollbackし、再試行 / 再リンク後に位置依存操作が復帰する
37. 動画エラーとProvider refreshが工程時刻やdirtyドラフトを消去しない
38. レビュー明示保存と症例削除を競合させ、削除後の0行UPDATEを成功扱いせず、入力をread-onlyで保持してコピー / 破棄 / 一覧へ戻る操作を提供し、症例を復活させない
39. 明示保存commit成功後のProvider再読込失敗で、Controllerと基準値をcommit済み値のままcleanに保ち、保存済み・表示更新失敗と再読込を示す
40. 開始 / 終了 / 再設定commit成功後のProvider再読込失敗で新時刻をインライン保持し、成功ハプティクスは1回だけ、再読込後もDBと一致する
41. レビュー画面の実体なし / 不正参照状態で、同じ動画の再登録は全時刻を保持し、別動画は明示確認後だけ全時刻を消去し、キャンセルではDB / 動画 / ドラフトを不変にする
42. CCCだけかつ動画なしの旧DBでレビューを開くと全項目を表示し、欠損だった工程の評価 / 反省点を保存でき、既存CCC / 旧工程を変更しない

### 11-3. 画面要件の自動テスト

#### 症例進捗

- 0/10、一部、10/10
- 開始のみを完了へ含めない
- 総手術時間の有無に影響されない
- 旧工程と未知工程を含めない

#### 一覧

- 空状態、CTA、0件カード非表示
- 月別表示と年またぎ
- 総時間の表示 / 非表示
- 全動画状態
- 補助取得失敗時の基本情報維持
- 読み取り副作用なし

#### 新規登録

- 初期エラーなし
- 不足項目、最初のエラーへのスクロール、live region
- 動画確認中、再生不能動画
- Sliderローカル追従と `onChangeEnd` のseek 1回
- 正常登録、保存失敗後の入力保持

#### 詳細

- 全動画状態
- 同一動画再リンク / 別動画差し替えの文言と結果
- 工程進捗、総時間
- 手術日 / 左右眼編集の成功、キャンセル、失敗、削除との競合
- 全破壊操作の成功、失敗、確認文

#### 分析

- `TextScaler` 変更時の再描画
- 0件ではadjustable nodeなし、1件では1/1を初期選択
- 2件、50件では最新を初期選択し、increment / decrement、両端、非循環を検証
- 指標変更時の同一症例保持と、値がない場合の最新症例fallback
- Light / Dark、文字倍率2.0で軸欠けなし
- 表示前後でDB不変、動画アクセスなし

各主要状態で以下を実行する。

```dart
await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
await expectLater(tester, meetsGuideline(textContrastGuideline));
```

これらのguidelineだけを44×44要件の証跡にしてはならない。Flutterのtap target guidelineがscrollable / viewport境界のnodeを検査対象外にする場合があるため、各scroll位置で表示中のtap / longPress / increase / decrease actionを持つSemantics nodeを列挙し、global rectの幅・高さがともに44 logical pixels以上で、clipとSafe Area内へ完全表示できることをcustom auditで直接検証する。主要 / custom controlを実際に操作し、期待handlerが1回だけ呼ばれることも確認する。

CustomPainter、アイコン、グラフ要素は色値からコントラスト比も検証する。

### 11-4. 旧版DB互換fixture

実患者データを使わず、次のfile-backed SQLite fixtureを用意する。

1. `1.0.0+1` 相当の旧スキーマ / CCC中心fixture
2. `1.0.0+14` 相当の直前基準fixture

fixtureには右眼 / 左眼、開始のみ / 完了 / 未着手、総時間、10工程、旧工程、評価、反省点、症例メモ、管理相対パス、旧絶対パス、欠損パスを含める。

検証事項：

- `PRAGMA integrity_check` が `ok`
- 既存互換処理が必要とする列追加以外に既存値の変更がない
- 症例数、日付、左右眼、全時刻、評価、反省点、メモが期待値と一致
- 旧工程を読めるが進捗 / 分析へ含めない
- 一覧表示だけでは旧動画コピーやDB更新が起きない
- 動画実体なしでも記録を閲覧できる
- 管理動画fixtureのSHA-256が更新前後で一致する

### 11-5. Golden / レイアウト

全マトリクスでoverflow、到達性、Semantics guidelineを実行する。Goldenは最低限以下を保持する。

- 最小phone縦：Light 1.0、Dark 2.0
- 最小phone横：Light 2.0
- 大型phone縦：Dark 1.0
- iPad縦：Light 2.0
- iPad横：Dark 2.0
- iPad compact Split View：Light / Dark 2.0

対象状態：空一覧、一覧、登録初期 / エラー、詳細の全動画状態、レビューの未着手 / 計測中 / 完了 / 未保存、分析、ダイアログ、キーボード表示中。

### 11-6. iOSネイティブ / 手動検証

最低限、以下で確認する。

- iOS 15.xのiPhoneとiPadOS 15.xのiPadを各1台以上（実機、シミュレータ、またはテストファーム）
- 現行iOSのiPhone
- 現行iPadOSのiPad
- 日本語、英語端末でのFlutter日本語fallback、VoiceOver、文字倍率2.0、Light / Dark、宣言済み全方向
- native picker、cold launch、AppIcon、バックアップ除外属性
- iPadの連続ウインドウリサイズ、全宣言方向への実行中回転

iOS / iPadOS 15環境を確保できない場合、未確認のまま合格にせず、環境確保または最低OS変更をユーザー判断事項として報告する。

バックアップ除外はiOS側で `URLResourceValues.isExcludedFromBackup == true` を読み戻すintegration / XCTestを実行する。no-op fakeだけをリリース証跡にしない。

cold launchは古いlaunch snapshotの再利用を避けるため、各試験ケースでアプリを端末 / Simulatorから削除し、fresh buildをinstallしてから実行する。最低限、現行iPhone / iPadのLight / Darkと縦 / 横、およびiOS / iPadOS 15.xのiPhone / iPad各1台で行い、60 fps以上で利用可能なら60 fpsで画面録画する。

録画をframe単位で確認し、launch surfaceがapp windowを覆ってから最初のFlutter contentが出るまで、次を満たす。

- 四隅付近の20×20 px sampling領域は、Light `#006D77` / Dark `#003F45` に対して各RGB channel差8以内
- app windowの95%以上が各RGB channel差8以内の純白または純黒となる中間frameが0件
- 最初のFlutter pre-content frameも対応するlaunch色で、content表示後の意図したsurface変化と区別できる

端末、OS、方向、appearance、install手順、録画fps、判定frame、sample値を証跡へ残す。目視の「違和感なし」だけで合格にしない。

---

## 12. 実装Phase

### Phase 0：安全性ブロッカーと試験seam

- 動画操作APIの分離
- 新規症例＋動画のstaged commit
- path classifier
- DB transaction、競合検出、再起動後reconciliationを含むcleanup方針
- 時刻保存 / レビュー保存APIの分離
- 旧DBの工程行を原子的・idempotentに補完するAPI
- バックアップ除外の失敗伝播と確認
- 旧版DB、fault injection fixture

Phase 0の終了条件は、§11-1の全試験と、§11-2の1〜8、動画なし再設定を扱う36、および症例削除競合を扱う38のRepository / Service部分が成功し、既存データを破壊する既知経路がなくなること。§11-2の9以降に含まれるWidget / UI部分はPhase 1で完了する。

### Phase 1：コアUXの正しさ

- 生例外表示の除去
- 新規登録バリデーション
- 詳細の動画状態と破壊操作
- レビューdirty、原子的保存、離脱
- Provider同期と再生tick局所化

### Phase 2：テーマと日本語化

- デザイントークン
- Light / Dark ThemeData
- Flutter / Xcode日本語localization
- 共通空状態、エラー、ダイアログ、SnackBar

### Phase 3：画面別の磨き込みとアクセシビリティ

- 一覧、登録、詳細、レビュー、分析
- adjustable graph semantics
- 全viewport、文字倍率、VoiceOver

### Phase 4：ブランド、起動画面、ドキュメント

- LaunchScreen背景とフラッシュ対策
- 正式原画受領後のAppIcon
- README、pubspec description
- 全リリースゲート

各Phase終了時に、変更ファイル、実装内容、データ層変更理由、テスト結果、未確認事項、残課題を報告する。各Phaseで `flutter analyze` と全 `flutter test` を成功させてから次へ進む。

---

## 13. リリースゲート

### RG-1. コード品質

- `flutter analyze` 成功
- 全 `flutter test` 成功
- Debug Simulator build成功
- 署名なしRelease build成功
- 配布時は署名済みarchiveとasset validation成功

### RG-2. データと動画

- 旧版DB fixture試験成功
- 動画SHA-256非回帰
- §11-1のfault injection試験成功
- 動画喪失状態で全記録を閲覧可能
- 新規および旧版fixture内の全管理動画で、バックアップ除外の単体 / iOSネイティブread-back試験成功

### RG-3. iOSプラットフォーム

- Release bundleに日本語localizationが存在
- 日本語DatePicker、編集メニュー、native pickerを確認
- 英語端末でFlutter UI / DatePicker / 編集メニューが日本語へfallbackし、OS所有pickerは端末言語でもよいことを確認
- iPhone / iPad、宣言済み全方向で主要フロー成功
- iOS 15.xのiPhone、iPadOS 15.xのiPad、および現行iOS / iPadOSで起動成功
- iPadで実行中回転と、幅320pt / OS最小高までの四辺・四隅連続リサイズを行い、主要状態を保持

### RG-4. UX、アクセシビリティ、テーマ

- 全viewportでoverflowと到達不能操作なし
- tap target、label、text contrast guideline成功
- 全scroll位置のactionable Semantics rect custom audit成功
- CustomPainterを含むコントラスト記録あり
- VoiceOverと文字倍率2.0で主要フロー成功
- runtime appearance切り替えで状態を失わない
- レビュー再生tickが画面全体を再ビルドしない

### RG-5. 起動画面

- 空のLaunchImage / Flutterロゴ参照なし
- Any / Darkのnamed colorと最初のFlutter pre-content背景がR12の指定色と一致
- §11-6のclean-install cold launch試験をiPhone / iPad、Light / Dark、縦 / 横、iOS / iPadOS 15.x各環境で通過
- frame samplingで意図しない全面白 / 黒frameなし
- asset / storyboard警告なし

### RG-6. AppIconと配布アセット

- 正式な15度ナイフ原画を使用
- Flutter標準アイコンを全slotから除去
- 実機のホーム、App Switcher、Spotlight、設定、archiveで確認
- アイコンのalpha、不要余白、二重角丸、asset警告なし

---

## 14. 実装完了報告

完了報告には以下を含める。

1. 完了したPhaseと通過したRelease Gate
2. 変更ファイル
3. 画面ごとの変更概要
4. Data / Service / Repository変更と必要性
5. 既存DB、記録、動画への非回帰結果
6. fault injection、fixture、アクセシビリティ試験結果
7. `flutter analyze`、`flutter test`、build / archive結果
8. 実機 / simulatorの端末、OS、方向、テーマ、文字倍率
9. 未確認事項
10. ユーザー入力または判断が必要な残課題

未確認事項を推測で合格としてはならない。

---

## 15. 現時点の外部入力と未実施検証

### 外部入力

- **正式な15度ナイフ原画**：未提供。RG-6ブロッカー

### 現環境で未実施

- iOS 15.x runtimeがローカルSimulatorにないため、最低OSでの起動 / 操作確認
- 署名済みarchive、TestFlight / App Store validation
- 実機のVoiceOver、AppIcon、cold launch、バックアップ除外属性
- 旧版file-backed DB fixtureによる自動互換試験
- Light / Darkおよび全viewportのGolden

ローカルにはiOS 17.5、26.0、26.5のSimulatorがある。実装完了後の自動 / 手動確認には利用できるが、iOS 15.xの代替にはしない。

---

## 16. 基準コード上の主な根拠

- 工程定義：`lib/src/domain/surgery_models.dart`
- 一覧取得と分析取得：`lib/src/data/surgery_repository.dart`
- 動画操作と旧パス移行：`lib/src/data/record_video_service.dart`
- 動画保存とバックアップ除外：`lib/src/data/video_storage_repository.dart`
- 動画Provider：`lib/src/data/providers.dart`
- レビュー状態、保存、再生tick：`lib/src/features/review/step_review_screen.dart`
- 詳細の動画 / 削除操作：`lib/src/features/records/record_detail_screen.dart`
- グラフSemanticsとgeometry：`lib/src/features/analysis/surgery_trend_chart.dart`
- iOSローカライズ、対象端末、最低OS：`ios/Runner.xcodeproj/project.pbxproj`
- 対応方向：`ios/Runner/Info.plist`
- 起動画面：`ios/Runner/Base.lproj/LaunchScreen.storyboard`

実装により行番号が変わるため、本書は恒久要件を行番号へ固定しない。

---

## 17. 重大欠陥の要件トレーサビリティ

以下の「閉鎖」は要件上の経路と合否判定が定義済みという意味であり、現コードの修正完了を意味しない。

| 基準コードの欠陥 / リスク | 規範要件 | 必須証跡 |
|---|---|---|
| 旧絶対パス移行が差し替え扱いとなり全時刻を消す | §5-4 | §11-1の6〜8 |
| 新規登録がDBと動画の片側だけを残し得る | §5-2、§5-3 | §11-1の1〜5 |
| 差し替え / 動画削除 / 症例削除がfile-firstまたは非原子的 | §5-2、§5-7〜§5-10 | §11-1の11〜20、25〜28 |
| 動画操作後に旧動画画面から時刻を書き戻せる | §5-2、R9-2、R9-3 | §11-1の34〜36 |
| 保存して閉じるが失敗後もpopする | R9-4 | §11-2の15、16 |
| 時刻保存とレビュー保存が互いの列を巻き戻す | R9-2、R9-3 | §11-2の1〜8 |
| レビュー一括保存が途中状態を残す | R9-2 | §11-2の5、6 |
| Provider refreshがdirty入力を上書き / 消失させる | R9-5 | §11-2の18〜22 |
| バックアップ除外失敗を握り潰し、既存動画を検証しない | §5-11 | §11-1の29、30、38、39、49、RG-2 |
| 同サイズ破損 / 再生不能動画をcommitして旧動画を消し得る | §5-2、§5-3 | §11-1の48 |
| symlink経由で管理root外を読書き / 削除し得る | §5-2、§5-9 | §11-1の43、44、50 |
| 画面全体が動画tickごとに再buildされる | R9-8 | §11-2の23、RG-4 |
| 外部原画不要のLaunchScreenが完了ゲートから漏れる | R12、RG-5 | §11-6のclean-install frame判定 |
| guidelineのskipにより44×44未満が偽合格し得る | §8-1、§11-3 | 全scroll位置のSemantics rect custom audit |
