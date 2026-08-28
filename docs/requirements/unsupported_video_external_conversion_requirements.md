# 白内障執刀ノート

## v1.1 非対応動画形式・外部変換運用 要件定義書

- 文書バージョン：1.1
- 作成日：2026年8月16日
- 対象プロジェクト：cataract_surgery_note
- 対象リリース：iOS / iPadOS向けv1.1
- 最低対象OS：iOS / iPadOS 15.0
- 基準コード：main@9d05407
- ステータス：実装前確定要件
- 優先度：高

---

## 0. 本書の効力

本書は、v1.1における非対応動画の扱いと外部変換後の再登録運用を定める正式要件である。

本書は、同じv1.1を対象として作成された「動画互換性拡張・端末内自動変換機能 要件定義書」を全面的に置き換える。旧文書に含まれるDirect Copy / Remux / Hybrid / Transcode、FFmpeg、変換engine、変換Job、変換進捗、変換用feature flag、engine採否Gateは、v1.1の実装要件ではない。

本書と過去の検討資料が矛盾する場合は、本書を優先する。

用語の強さは次のとおりとする。

- 「必須」「する」「してはならない」は、実装および受け入れの必須条件である。
- 「推奨」は、不採用理由と代替策を実装報告へ記載する条件である。
- 「将来」は、v1.1の実装範囲外であり、独自判断で先行実装してはならない。

本書の完成は要件確定を意味し、機能実装完了を意味しない。実装完了は、13章の全受け入れ基準と17章のRelease Gateを満たした時点とする。

---

## 1. 背景とプロダクト判断

白内障執刀ノートでは、手術動画をアプリ内で再生しながら各工程の開始・終了時刻を記録し、記録した工程を後からすぐに動画で確認できることを主要価値としている。

一方、手術動画にはMPEG-PS、MPEG-TS、MTS、M2TSなど、現在のアプリで利用できないcontainerやcodecが存在する。

アプリ内へFFmpeg等を組み込む場合、次の責務が新たに発生する。

- engineのlicense、SBOM、再現build、App Store配布条件
- binary sizeとarchitecture管理
- 長時間動画の処理時間、memory、発熱、storage容量
- background、lock、cancel、crash recovery
- 映像品質、色、interlace、frame timing、A/V同期
- 元動画、一時動画、変換後動画、DBのatomicな整合性
- codecやOS更新に追従する継続保守

これらはv1.1の目的と実装規模を大きく超えるため、v1.1では次を正式なプロダクト判断とする。

> 白内障執刀ノートは動画変換を行わない。再生可能な手術動画を安全に登録し、レビュー、工程記録、振り返りを行うことへ責務を集中する。

非対応動画については、所属施設が承認した方法でユーザーがアプリ外に対応動画を用意し、その動画を新たに選択する運用とする。

アプリは外部変換を実行、仲介、監視、再開しない。ただし、非対応動画を選んだユーザーを行き止まりにせず、理由、次の操作、安全上の注意をアプリ内で案内する。

---

## 2. 目的と成功状態

### 2.1 目的

次を同時に達成する。

1. 現在のアプリ内動画レビューと工程記録の体験を維持する。
2. 対応動画は正常系の操作数を増やさず登録できる。
3. 非対応動画、読込失敗、破損の可能性、容量不足を誤った文言で混同しない。
4. 非対応動画で空症例、変更済み工程時刻、参照のない正式動画を作らない。
5. 外部変換の案内によって手術動画を未承認のWebまたはcloud serviceへ誘導しない。
6. 外部変換後の時間軸変化により、既存工程時刻が別の場面を指すことを防ぐ。
7. FFmpegその他の変換engineをv1.1のdependency、binary、運用責務へ追加しない。
8. 将来のアプリ内変換は、実需要を確認した別versionで再評価できる状態にする。

### 2.2 成功状態

- 対応動画を選ぶと、従来どおり症例登録、再生、seek、5秒・15秒移動、速度変更、工程記録ができる。
- 登録対象外の拡張子を選ぶと、保存処理より前に拡張子policyの案内と静的helpへ到達できる。
- 原因を断定できない再生失敗では、「形式が原因」「変換すれば解決」と断定しない。
- access、cloud取得、copy、容量、DB競合は、それぞれ回復可能な原因別文言となる。
- 失敗、cancel、画面離脱、強制終了で元動画と既存症例を変更しない。
- 外部で用意した動画は、過去jobの続きではなく、最初から全検査を受ける新しい選択として扱う。
- ユーザーが「以前この症例で使用したfileから変換・編集・再書き出しした」または「同一性を判断できない」と申告した場合、既存工程時刻を保持するrelinkへ進まない。

---

## 3. 対象範囲と責任境界

### 3.1 v1.1の必須範囲

- Filesからの動画選択
- 登録候補形式と、外部準備案内だけを行う形式の選択範囲分離
- create、attach、relink、attachWithTimingReset、replaceの全入口で共通する保存前preflight
- 保存先動画に対する既存の最終再生検証
- 非対応、読込不能、保護media、容量、copy、DB競合の型付き分類
- 登録対象外拡張子のdialogと、アプリ同梱のoffline help
- 外部で用意した動画を再選択する完全な新規フロー
- 以前の登録後に変更された動画と既存工程時刻の安全な分離
- 現行のatomic保存、補償削除、起動時reconciliation
- privacy、accessibility、回帰test

### 3.2 v1.1の非要件

次を実装しない。

- アプリ内Remux、Transcode、圧縮、解像度変更、音声変換
- MPEG-PS、MPEG-TS、MTS、M2TSの直接再生保証
- FFmpeg、FFmpegKit、その他codec / conversion engineの同梱
- cloud動画変換
- 外部変換toolへのupload、Share Sheet、Open In、Deep Link
- 特定の変換app、Web service、製品名、App Store linkの推薦
- 外部変換appのインストール確認、進捗取得、完了監視
- 外部変換待ちstate、変換履歴、変換元と派生fileのprovenance DB
- 変換済みfileの自動検出または自動再選択
- 破損動画の修復、DRMまたは暗号化の解除
- 外部playerでのレビュー、再生位置取得、工程時刻同期
- 既存動画の一括変換
- 写真ライブラリ用pickerの新設
- 非対応形式またはcodecの利用状況を送信するanalytics

「アプリ内変換を実装しない」ことと、「通常の動画importで失敗した一時fileをcleanupしない」ことは別である。既存importの安全なcleanupとcrash recoveryは必ず維持する。

### 3.3 責任分担

| 主体 | 責任 |
| --- | --- |
| 白内障執刀ノート | 選択範囲の公開、保存前判定、再選択動画の検証、安全な保存・cleanup、アプリ固有errorの案内 |
| ユーザー・所属施設 | 使用可能な外部準備方法の承認、院内規程・契約・必要な同意の確認、元動画保管、派生動画の内容確認 |
| 第三者tool提供者 | toolの動作、変換品質、privacy policy、cache / backup / cloud同期、料金、障害、保存・削除 |

「すべてユーザーの責任」という包括的な免責表現は使用せず、上記の責任境界をhelpへ明示する。

---

## 4. 現行実装の基準と解消すべき差分

本節はmain@9d05407のread-only調査結果である。実装時に基準commitが変わった場合は再調査する。

### 4.1 現在維持できている保証

| 項目 | 現行動作 |
| --- | --- |
| picker | FileType.customでmp4、mov、m4vだけを表示 |
| 新規症例 | 元fileのvideo_player初期化後に入力画面へ留まり、登録操作後に保存開始 |
| 正式保存 | Application Support/videos/<recordId>/<UUID>.<ext> |
| copy | 同一record directoryのtmpへcopyし、sizeとSHA-256を照合後にrename |
| 保存後検証 | destinationをvideo_playerで初期化し、durationと短時間再生を確認 |
| create | destination検証後に症例rowと初期reviewを同一transactionで作成 |
| attach / relink | destination検証後にvideoPathをcompare-and-setし、工程時刻を保持 |
| replace | destination検証後にvideoPath更新と全工程時刻消去を同一transactionでcommit |
| DB失敗 | 新規destinationの補償削除を試行し、後続reconciliationへ引き継ぐ |
| 元動画 | read-onlyで扱い、削除しない |

このcopy、hash、検証、DB commitの順序、record単位の競合検出、起動時reconciliationを弱体化してはならない。

### 4.2 v1.1で解消する差分

1. MPEG等がpickerに表示されないため、「選択して非対応案内を見る」フローが成立しない。
2. 新規症例だけが元fileを事前初期化し、attach / relink / replaceは全体copy後まで非対応を判定しない。
3. video_player由来error、破損、access、copy、容量がFileSystemException等へ混在し、誤った容量文言になる場合がある。
4. 現在の再生probeにはtimeout、mute、表示寸法、再生位置進行、seek確認がない。
5. 新規症例で動画変更候補を検証する前に、直前の正常動画、手術日、左右眼を破棄している。
6. 非対応helpがなく、画面ごとに異なるerror文言が重複している。
7. 外部変換後fileを「同じ動画」としてrelinkすると、変換による開始位置、frame、durationの変化で工程時刻がずれ得る。
8. Files選択失敗に「写真へのアクセス権限」を案内する画面があり、選択元と原因が一致しない。
9. 動画surface内の長いerrorは、Dynamic Typeや狭幅画面でoverflowする可能性がある。

---

## 5. 用語と互換性ポリシー

### 5.1 Selectable File Types

pickerへ表示する拡張子は、次の2集合に分ける。

| 集合 | 拡張子 | 意味 |
| --- | --- | --- |
| registrationCandidateExtensions | mp4、mov、m4v | 登録前preflightを実行する候補。拡張子だけでは対応保証しない |
| guidanceOnlyExtensions | mpg、mpeg、mts、m2ts、avi、mkv、wmv、webm | v1.1では登録せず、登録対象外の案内と外部準備helpを表示するために選択可能にする |

FileType.anyは使用せず、このversion付きallowlistをpickerとpolicy testが共有する。

guidanceOnlyExtensionsをpickerへ追加することは、再生対応形式の拡張ではない。OSや端末が偶然再生できる場合でも、v1.1では登録対象にしない。

拡張子の権威値は、OS pickerが返す`SelectedSurgeryVideo.displayName`の最後のsuffixをASCII小文字へ正規化した値とする。File Providerの一時`path`、保存先path、UIごとの再計算値を判定に使用しない。大文字・小文字は区別せず、拡張子なしとallowlist外は登録しない。

allowlist外のfileはpickerで選択対象にしない。providerがpicker契約外のfileを返した場合もcopyせず、nonCandidateExtensionとして安全に終了する。常設の「登録できる動画の目安」helpはpickerを開く前から到達可能にする。

### 5.2 登録可能動画

登録可能動画とは、次をすべて満たすfileである。

1. registrationCandidateExtensionsのいずれかである。
2. 選択元が存在し、通常fileとしてread可能で、sizeが0より大きい。
3. 7.2のsource preflightを通過する。
4. copy中に元fileが変化せず、sizeとSHA-256の完全性検証を通過する。
5. managed destinationに対する最終再生検証を通過する。
6. backup除外、path containment、symlink拒否等の既存storage保証を通過する。

`.mp4`、`.mov`、`.m4v`という拡張子だけで「対応」と断定してはならない。

### 5.3 登録対象外拡張子

guidanceOnlyExtensionsまたはpicker契約外の拡張子に一致した場合はnonCandidateExtensionとする。この判定はpicker metadataだけで行い、アプリは判定のためにsource本体をopen、download、materializeしない。OS pickerまたはFile Providerがcallback前に行う取得処理は、この保証の対象外である。

この分類は拡張子policyだけを表す。fileが正常な動画であること、container、codec、破損、DRM / 暗号化の有無、外部変換の成否は検査も断定もしない。

### 5.4 原因未確定の再生失敗

registrationCandidateExtensionsでsource accessに成功しても、video_playerの初期化、frame decode、seekに失敗する場合がある。

この失敗だけでcodec非対応またはfile破損と断定してはならず、unplayableMediaとする。ユーザーには「形式・codecが非対応、またはfileが破損している可能性」を示し、まず選択元でfileを確認するよう案内する。

このdialogから外部準備helpを直接表示せず、まず選択元での確認と再選択を案内する。常設helpは利用できるが、「変換すれば解決する」と断定してはならない。

### 5.5 推奨外部出力プロファイル

helpで示す対応の目安をRecommended External Output Profile v1.1として固定する。

| 項目 | 目安 |
| --- | --- |
| container | MP4 |
| video | H.264 / AVC、8bit、4:2:0 |
| scan | progressive |
| audio | AAC-LCまたは音声なし |
| timeline | 元動画の全区間を維持し、trim、速度変更、結合、frame補間を行わない |
| geometry | 元の向きとaspect ratioを維持し、不要なcropを行わない |
| source | 元動画を上書きせず、新しいfileとして作成 |

この表は外部toolの操作手順または再生保証ではない。実際の利用可否は、変換後fileを再選択した時点の全preflightで決定する。

受け入れtestの循環定義を避けるため、Reference Fixture Profile v1.1を次で固定する。

| 項目 | test基準 |
| --- | --- |
| container variants | MP4、MOV、M4V |
| video codec | H.264 / AVC Main Profile、Level 4.0 |
| pixel format | 8bit、4:2:0 |
| scan / frame rate | progressive、constant 30 fps |
| geometry | 1920×1080、正方pixel |
| video bitrate | 8 Mbps以下 |
| timestamp | 0以上で単調増加し、edit listによる開始offsetなし |
| audio variants | AAC-LC 48 kHz mono、AAC-LC 48 kHz stereo 128 kbps以下、音声なし |
| duration | 60秒のsynthetic非臨床素材 |

このprofileはrelease regressionの固定anchorであり、これ以外を一律に拒否する上限または全端末での再生保証ではない。各fixtureの実値、生成手順、SHA-256、licenseをversion付きmanifestへ固定する。

### 5.6 登録後変更fileと同一性申告

登録後変更fileとは、以前その症例で工程時刻を記録した際に使用したfileから、その後に再encode、remux、trim、編集、速度変更または再書き出しを行ったfileをいう。以前使用したfile自体が撮影原本からの外部変換結果であっても、その登録後に変更していない同じfileを再選択する場合は登録後変更fileとしない。

v1.1は変換履歴またはprovenanceを技術的に検出しない。工程時刻保持可否はユーザーの明示申告に基づき、判断できない申告は登録後変更と同じ安全側へ扱う。この限界をUIと受け入れ基準へ明示し、自動検出による絶対保証を表明しない。

---

## 6. ユーザーフロー

### 6.1 共通フロー

~~~text
動画を選択
  ↓
picker metadataの拡張子policy
  ├─ cancel → 元画面へ戻る
  ├─ guidance-only / allowlist外 → 登録対象外dialog → offline help / 再選択 / 閉じる
  ↓
registration candidateのsource access確認
  ├─ access / cloud取得失敗 → 読込用の案内
  ↓
source preflight
  ├─ protected media → 解除・変換を案内せず安全終了
  ├─ 再生確認不能 → 原因未確定dialog → file確認 / 再選択
  ↓
操作別の最終確認
  ↓
既存storageのcopy・完全性検証・destination再生検証
  ├─ 失敗 → DBを変更せずcleanup
  ↓
短いDB transactionでcommit
  ↓
アプリ内レビュー
~~~

### 6.2 新規症例

1. 症例一覧から動画を選択する。
2. preflight中は症例rowを作成しない。
3. preflight成功後に新規症例入力画面を表示する。
4. 動画変更では、候補をpending stateで検証する。
5. 新候補が不合格またはcancelなら、直前の正常動画、手術日、左右眼、入力値を保持する。
6. 新候補が合格した場合だけ選択状態を置き換え、手術日と左右眼の再確認を求める。
7. 登録操作後、destination検証に成功してから症例と初期reviewをcommitする。

### 6.3 attach、relink、attachWithTimingReset、replace

全入口で、選択後かつ最終確認前に共通preflightを実行する。

| 操作 | 成功時 | preflight / 保存失敗時 |
| --- | --- | --- |
| attach | videoPathを追加。工程時刻とレビューを保持 | 既存症例を変更しない |
| relink | 以前使用したfileと同じで、その後変更していないという申告に基づきvideoPathを更新。工程時刻を保持 | 旧videoPathと工程時刻を保持 |
| attachWithTimingReset | videoPathがnullの症例へvideoPathを追加し、全工程時刻を同一transactionで消去 | nullのvideoPathと工程時刻を保持 |
| replace | videoPath更新と全工程時刻消去を同一transactionで実行 | 旧videoPathと工程時刻を保持 |

### 6.4 登録後に変更されたfileと工程時刻

外部変換は、開始offset、duration、frame timing、frame数を変える可能性がある。durationが同じだけでは同一timelineを証明できない。

既存工程時刻が1件でもあるattachまたはrelinkでは、最終確認に次の選択肢を表示する。

- 「以前この症例で使用したfileと同じで、その後変換・編集していない」：既存のattach / relink確認へ進む。
- 「以前の登録後に変換・編集・再書き出しした、または同じか判断できない」：videoPathがnullならattachWithTimingReset、それ以外ならreplaceへ切り替え、全工程時刻を消去する確認を表示する。
- 「キャンセル」：candidateと既存症例を変更せず終了する。

初期選択は設けず、ユーザーがどちらかを明示するまで続行actionを有効にしない。判断できない場合は2番目を選ぶよう案内する。

ユーザーが2番目を申告した状態で、工程時刻を保持するoverrideをv1.1へ設けない。アプリが変換履歴を自動検出したという表示をしない。

1番目を申告した場合も、最終保存物から得たdurationがcommit時点の保存済み最大工程時刻以上でなければattach / relinkを拒否し、attachWithTimingResetまたはreplaceを案内する。

### 6.5 外部準備後の再選択

- appは変換待ちstateを保存しない。
- appは外部appを開かない。
- appは変換完了をpollしない。
- appへ戻ったユーザーは、通常の動画選択から変換後fileを選ぶ。
- 変換後fileは過去の選択結果を継承せず、source access、preflight、copy、destination検証をすべてやり直す。

---

## 7. 機能要件

### 7.1 選択とsource取得

#### FR-001 picker allowlist

SurgeryVideoPickerは5.1の2集合を選択可能にする。UIへ表示する拡張子とstorageが登録可能とする拡張子を同一集合にしてはならない。

#### FR-002 Filesの原因表示

Files picker、File Provider、iCloud上のfile取得失敗を、写真ライブラリ権限の失敗として表示してはならない。

cloud上の選択済みfileをOSまたはFile Providerが端末へdownloadする動作と、アプリが動画を外部へuploadする動作を区別する。

#### FR-003 cancel

picker cancelは正常なユーザー操作とし、error dialog、help、DB、managed fileを作らず元画面へ戻る。

#### FR-004 source read-only

元動画をread-onlyとして扱う。success、failure、cancel、background、crashのすべてで、元動画のbytes、size、mtime、metadata、pathを変更または削除しない。

#### FR-005 source lease

選択直後のUI preflightでは、選択元へのfile handle、security-scoped access相当を取得し、preflightの完了、失敗、cancelまたは画面破棄で解放する。新規症例の入力中は選択referenceを画面session内のmemoryへ保持してよいが、source URLまたはbookmarkをDBや永続storageへ保存しない。

登録操作時はserviceがaccessを再取得し、FR-011からFR-015のimport admission preflightを必ず再実行する。そのaccess leaseはpreflight成功後もcopyとsource / destination完全性確認が終わるまで連続して保持し、成功、失敗またはcancelで直ちに解放する。

UI preflightではsourceをstreaming読込してSHA-256を計算する。登録操作時は、UI preflight時と登録操作時のsource SHA-256、identifier、size、mtimeを比較する。identifierがproviderから取得できない場合は、同じsession内のsource reference、size、mtimeをfallback tupleとする。SHA-256の不一致、その他tupleの相違、再取得不能または比較不能はsourceChangedとし、古いpreflight結果を流用しない。

### 7.2 共通preflight

#### FR-010 実行位置

create、attach、relink、attachWithTimingReset、replaceの全入口は同じVideoImportPreflight interfaceを使用する。Widgetごとに独自の再生可否判定を実装しない。

選択直後のUI preflightは早期feedback用、登録操作時のimport admission preflightは保存許可用とする。後者はDB transaction、Application Supportへの動画copy、既存videoPath変更、工程時刻変更より前に完了し、その成功結果を1回のservice操作内だけで消費する。

#### FR-011 access check

sourceが存在する通常fileで、read可能かつsizeが0より大きいことを確認する。source消失、access拒否、provider取得失敗を別codeへ正規化する。

#### FR-012 拡張子policy

5.1の権威値がguidanceOnlyExtensionsまたはallowlist外なら、source本体へaccessせずnonCandidateExtensionとする。registrationCandidateExtensionsの場合だけFR-011のsource accessとplayer probeへ進む。

#### FR-013 playback probe

registrationCandidateExtensionsでは、実際にレビューで使用するvideo_player系統で次を確認する。

1. controller初期化が10秒以内に完了する。
2. isInitializedがtrueで、durationが0より長い。
3. 表示widthとheightが0より大きく、aspect ratioが有限かつ0より大きい。
4. volumeを0にして再生し、3秒以内にpositionが0より大きく、かつ`min(100ms, durationの25%)`以上へ進む。
5. durationが2秒を超える場合、min(5秒、durationの50%)へseekし、5秒以内に完了してerrorがない。
6. pauseし、controllerをdisposeする。

probe全体は20秒を上限とする。source probeのstage timeoutはplaybackVerificationTimedOutへ、timeout以外のgeneric player errorはunplayableMediaへ正規化し、いずれも原因を推測しない。

probeはfile全編の完全性を保証しない。ユーザー向けhelpでは、登録後に冒頭、中間、終端を確認するよう案内する。

#### FR-014 音声を出さない

preflightとdestination検証では、controllerを再生前にmuteする。確認処理により端末speaker、Bluetooth、AirPlayへ音声を出さない。

#### FR-015 generationと重複操作

各preflightはselection generationを持つ。新しい選択、cancel、画面破棄後に古いcallbackが選択状態、dialog、DB、保存処理を更新してはならない。

同じ画面でactive preflightは1件とし、連打による重複dialogと多重importを防ぐ。

#### FR-016 candidate commit

新規症例画面で動画を変更する場合、pending candidateがpreflight成功するまで現在の選択動画、手術日、左右眼、入力値を変更しない。

#### FR-017 verified candidate境界

UI preflight成功時は、selection generation、5.1の正規化拡張子、in-memory source reference、source file identifierが取得可能ならその値、size、mtime、SHA-256、duration、寸法を持つephemeral VerifiedVideoCandidateを作る。candidateはmemory内だけに置き、filename、path、bookmarkまたはSHA-256をdiagnosticへ渡さない。

create / attach / relink / attachWithTimingReset / replaceのpublic service APIはVerifiedVideoCandidateを受け取り、raw sourcePathだけでpreflightを迂回できるpublic入口を残さない。legacy migrationは通常importと混在させず、既存のread-only契約を持つ専用入口とする。

### 7.3 非対応案内とhelp

#### FR-020 nonCandidateExtension

guidance-onlyまたはpicker契約外の拡張子には9.2の登録対象外dialogを表示する。fileの正常性、破損、保護状態を確認済みと表示せず、DB、Application Support内の動画file、工程データを作成または変更しない。

#### FR-021 unplayableMedia

registration candidateの再生確認に失敗し、原因を一意に断定できない場合は9.3の文言を表示する。「codecが原因」「fileが破損」「変換すれば解決」のいずれも断定しない。

#### FR-022 protected media

platformまたはcontainerがDRM / 暗号化を明示した場合はprotectedMediaとし、変換、解除、回避を案内しない。正規に利用できる保護されていないcopyについて所属施設へ確認するよう案内する。

#### FR-023 offline help

「登録できる動画の目安」helpはapp bundle内のlocal contentとして表示し、network接続を必要としない。

helpは、picker前の常設入口とnonCandidateExtension dialogから到達できる。unplayableMediaまたはplaybackVerificationTimedOut dialogからは直接開かず、原因未確定の確認を優先する。

#### FR-024 外部連携禁止

helpとdialogからbrowser、App Store、外部app、Share Sheetを起動せず、source URL、file、filename、metadataを第三者へ渡さない。

#### FR-025 再選択

「別の動画を選ぶ」は現在の不合格candidateだけを破棄し、同じ画面のpickerへ戻す。既存の正常candidate、症例、工程時刻を変更しない。

### 7.4 storageとDB

#### FR-030 destination再検証

import admission preflight成功後も、既存storageのcopy、size / SHA-256照合、safe rename、backup除外、managed destination playback probeを省略しない。

source preflight結果を理由に、copy中のsource変更またはdestination破損を成功扱いにしてはならない。

storageはVerifiedVideoCandidateのSHA-256をexpected hashとして受け取り、`candidate SHA-256 == sourceHashBefore == sourceHashAfter == destinationHash`を確認する。不一致はsourceChangedまたはcopyIntegrityFailedとし、DBを変更しない。

destination probeはvoidではなく、少なくともduration、width、height、aspect ratioを含むVideoPlaybackEvidenceを返し、同一service操作のDB判定へ渡す。

#### FR-031 DB commit順序

managed destinationの最終検証前に症例またはvideoPathをcommitしない。

- createは症例rowと初期reviewを同一transactionで作成する。
- attach / relinkは期待videoPathとのcompare-and-setを維持する。
- attachWithTimingResetは`expectedVideoPath: null`をCAS条件とし、videoPath追加と全工程時刻消去を同一transactionで実行する。
- replaceはvideoPath更新と全工程時刻消去を同一transactionで実行する。

#### FR-032 失敗時不変条件

preflightまたは保存が失敗した場合は次を満たす。

- createでは症例rowと初期reviewを作らない。
- attach / relink / attachWithTimingReset / replaceでは旧videoPath、工程時刻、評価、振り返り、症例メモを変更しない。
- 新規managed destinationをDBから参照しない。
- 元動画を変更しない。

#### FR-033 cleanup

通常失敗ではappが作成したtmpと未参照destinationの即時削除を試行する。

delete失敗またはcrashで残るfileは、通常resolverから非公開かつDB未参照のcleanup対象とする。未参照finalは完全なDB参照snapshotを取得できた次回reconciliationで回収し、`.tmp`は現行の保守契約どおりmtimeから24時間未満は削除せず、24時間経過後のreconciliationで回収する。「失敗時に必ず即時0 file」または「次回起動直後に必ず0 file」とは要求しない。

cleanupは完全なDB参照snapshotとpath containmentを確認し、参照中fileまたは判断不能fileを削除しない。

#### FR-034 storage error分類

容量不足、copy中のsource read失敗、destination write / rename失敗、copy完全性不一致、backup除外失敗、destination probe失敗を別のdomain errorへ正規化する。FileSystemExceptionだけからユーザー文言を決定しない。

insufficientStorageへ分類できるのは、platformが信頼できるENOSPC / EDQUOT相当を返した場合、またはdestination volumeの利用可能容量がsource size未満と確認できた場合に限る。事前容量照会は助言的であり、その他のwrite / rename失敗を容量不足と推測しない。

#### FR-035 schema

外部変換運用のためにconversion job、engine設定、変換履歴、変換元path、外部tool名をDBへ追加しない。

既存video_display_name契約の変更は本要件の範囲外とする。ただしfilenameは患者識別情報を含み得る値として扱い、error、help、diagnostic log、analytics、crash reportへ転記しない。

#### FR-036 durationと工程時刻のatomic判定

工程時刻を保持するattach / relinkでは、VideoPlaybackEvidenceのdestination durationをmillisecondへ正規化して使用する。record mutation lock取得後、DB transaction内で期待videoPathと最新工程行を再読込し、全工程の非nullな`startMilliseconds`と`endMilliseconds`の最大値がduration以下であることを確認してからvideoPathを更新する。値がない場合の最大値は0とし、負値その他の不正値は保持可と推測せずdurationConflictとする。暗黙の許容差を設けない。

競合またはduration不足ならDBを変更せず、新規destinationを補償削除する。UI preflightのdurationだけで判定を確定してはならない。

#### FR-037 logical outcomeとmaintenance outcome

import結果はlogicalOutcomeとmaintenanceOutcomeを別軸で返す。DB commit成功後のrecord refresh失敗またはcleanup延期でcommitを失敗扱いに戻さず、DB参照中のdestinationを補償削除しない。

commit成功かつcleanup延期はsuccess + maintenancePendingとする。commit失敗かつcleanup延期はprimary domain errorを維持し、maintenancePendingをsecondary stateとする。

#### FR-038 iOS Data Protection

保護classはApple Foundationの`NSFileProtectionComplete`、Swiftの`FileProtectionType.complete`へ固定し、「相当」する別classへの置換を認めない。

appが作成するvideos格納directory、record directory、`.tmp`、未参照final、正式managed videoへこのclassを設定する。directoryは最初の子file作成前、動画fileは最初の非0-byte write前とrename後に属性をread-backする。

database格納directory、database本体、WAL、SHMにも同じclassを設定する。アップデート後の初回DB accessでは、databaseをopenする前に既存directory、database、存在するWAL / SHMをこのclassへ移行してread-backする。database directoryはWAL / SHM生成前に設定し、DB open直後、journal file生成・再生成後、checkpoint後、reopen後に存在するdatabase / WAL / SHMの属性を確認する。不一致時はDB操作を開始または継続せず、安全にcloseしてfileProtectionFailedとする。

backup除外はtmp、未参照final、正式managed videoのすべてへ適用し、属性をread-backする。保護classまたはbackup除外を確認できない新規動画はcommitせず、元動画と既存症例を保持する。既存managed videoと格納directoryはprotected data利用可能時の保守処理で同じclassへ収束させ、確認前に再生または更新しない。

#### FR-039 protected data availability

`UIApplication.isProtectedDataAvailable`相当がfalseの間はpreflight、copy、DB commit、reconciliationを開始しない。「端末のロックを解除して、もう一度お試しください」と案内し、protected data利用可能通知後にユーザー操作で再試行する。lockにより中断された処理はDBを変更せず、tmpをFR-033のcleanup対象とする。

### 7.5 既存動画とレビュー

#### FR-040 アプリ内再生維持

外部playerを主要レビュー手段にせず、登録後は現在のアプリ内video_playerで再生する。

#### FR-041 レビュー操作

次を回帰させない。

- play / pause
- 任意seek
- 5秒・15秒移動
- 再生速度変更
- 総手術時間と各工程の開始・終了記録
- 登録済み工程からの動画位置確認

#### FR-042 既存media

アップデートだけで既存動画を再encode、rename、削除しない。既存managed相対pathとlegacy absolute pathの読取、既存legacy移行flowを維持する。

#### FR-043 legacy external

legacy external originalはread-only sourceとし、移行成功、失敗、fallback再生のいずれでも削除または変更しない。managed copyだけをappのstorage管理対象とする。

### 7.6 将来需要の確認

#### FR-050 telemetryを追加しない

アプリ内変換需要の調査を理由に、v1.1へ新しいanalytics SDK、codec、filename、extension、error、動画選択履歴の送信を追加しない。

需要は、実患者動画を収集しないsupport問い合わせ、任意のuser research、privacy review済みの別施策で評価する。

#### FR-051 将来version

将来アプリ内変換を検討する場合は、v1.1の小変更またはfeature flag追加として扱わず、別versionの要件、ADR、security / privacy / license / quality Gateを作成する。

---

## 8. 状態と不変条件

### 8.1 UI state

最低限、次を区別する。

| state | 意味 |
| --- | --- |
| idle | 選択待ち |
| selecting | Files picker表示中 |
| checkingPolicy | picker metadataの拡張子policy確認中 |
| checkingSource | source access確認中 |
| checkingCompatibility | 再生preflight中 |
| nonCandidate | 登録対象外拡張子の案内中 |
| unplayable | 原因未確定の再生失敗案内中 |
| ready | 登録可能candidate確定 |
| checkingImportAdmission | 登録操作後の再preflight中 |
| importing | copy、完全性確認、destination検証中 |
| committing | DB commit中 |
| completed | 登録成功 |
| failed | 原因別失敗 |
| canceled | ユーザーcancel |

### 8.2 不変条件

すべての時点で次を満たす。

1. 1画面でactive selection generationは最大1件である。
2. nonCandidateExtensionまたはimport admission preflight不合格fileをApplication Supportへcopyしない。
3. destination検証前のfileをDBから参照しない。
4. create失敗で空症例を作らない。
5. attach / relink / attachWithTimingReset / replace失敗で既存症例を変更しない。
6. ユーザーが「以前の登録後に変更した」または「同じか判断できない」と申告したfileで、既存工程時刻を保持しない。
7. 元動画へwrite、rename、deleteを行わない。
8. 古いcallbackが新しい選択を上書きしない。
9. error分類不能時は、形式、破損、容量、権限のいずれかを推測しない。
10. 外部準備helpから動画または識別情報を外部送信しない。
11. raw sourcePathだけでimport admission preflightを迂回できない。
12. app作成動画とDB関連fileを、確認済みData Protection属性なしでcommitまたは利用しない。
13. DB commit済みのlogical successを、後続refreshまたはcleanup延期だけでfailureへ反転しない。

---

## 9. エラー分類とユーザー文言

### 9.1 domain error

`recoveryAction`は、`dismiss`、`reselect`、`checkSourceAndReselect`、`retry`、`unlockAndRetry`、`freeStorageAndRetry`、`reloadRecord`、`resetTimingsAndAttach`、`resetTimingsAndReplace`、`contactSupport`、`openReferenceHelp`の閉じたenumとする。

`presentation`は`none`、`blockingDialog`、`persistentInline`の閉じたenumとする。消えるSnackBarだけでprimary errorを通知しない。

| code | 条件 | message family | primary recovery | presentation | 外部準備help |
| --- | --- | --- | --- | --- | --- |
| userCanceled | pickerまたは確認をcancel | なし | dismiss | none | 表示しない |
| nonCandidateExtension | guidance-onlyまたはpicker契約外の拡張子 | 9.2 | reselect | blockingDialog | openReferenceHelpをsecondary表示 |
| sourceNotFound | source消失 | 9.4 | checkSourceAndReselect | blockingDialog | 表示しない |
| sourceAccessDenied | read権限なし | 9.4 | checkSourceAndReselect | blockingDialog | 表示しない |
| providerUnavailable | File Provider / cloud取得失敗 | 9.4 | checkSourceAndReselect | blockingDialog | 表示しない |
| protectedDataUnavailable | iOS protected dataを利用できない | 9.8 A | unlockAndRetry | blockingDialog | 表示しない |
| protectedMedia | player / platformがDRM・暗号化を明示 | 9.6 | checkSourceAndReselect | blockingDialog | 表示しない |
| unplayableMedia | 形式・codec・破損等の原因を断定不能 | 9.3 | checkSourceAndReselect | blockingDialog | 直接表示しない |
| playbackVerificationTimedOut | source probeのstageまたは全体timeout | 9.3 | retry | blockingDialog | 直接表示しない |
| sourceChanged | preflight後またはcopy中にsource identityが変化 | 9.8 B | checkSourceAndReselect | blockingDialog | 表示しない |
| insufficientStorage | FR-034の確認済み容量不足 | 9.5 | freeStorageAndRetry | blockingDialog | 表示しない |
| sourceReadFailed | copy中にsourceを読めない | 9.4 | checkSourceAndReselect | blockingDialog | 表示しない |
| destinationWriteFailed | tmp / destinationのwriteまたはrename失敗 | 9.8 C | retry | blockingDialog | 表示しない |
| copyIntegrityFailed | size / hash不一致 | 9.8 B | checkSourceAndReselect | blockingDialog | 表示しない |
| fileProtectionFailed | Data Protection属性の設定またはread-back失敗 | 9.8 C | retry | blockingDialog | 表示しない |
| backupExclusionFailed | backup除外の設定またはread-back失敗 | 9.8 C | retry | blockingDialog | 表示しない |
| destinationPlaybackFailed | copy後の再生検証失敗 | 9.8 C | retry | blockingDialog | 直接表示しない |
| durationConflict | destination durationが最新最大工程時刻未満 | 9.8 D | resetTimingsAndAttachまたはresetTimingsAndReplace | blockingDialog | 表示しない |
| videoReferenceConflict | 操作中にvideoPath更新 | 9.8 E | reloadRecord | blockingDialog | 表示しない |
| commitFailed | DB transaction失敗 | 9.8 F | retry | blockingDialog | 表示しない |
| unknown | 想定外 | 9.8 G | retry | blockingDialog | 表示しない |

error objectはcode、entryPoint、phase、primaryRecoveryAction、secondaryRecoveryActions、localizationKey、dataInvariantSuffix、VideoImportInternalReasonV1を持ち、処理中のmemory内だけで使用する。secondaryRecoveryActionsは同じ閉じたrecoveryAction enumの集合とする。`dataInvariantSuffix`は`createNotRegistered`、`existingRecordUnchanged`、`none`の閉じたenumとし、entry pointに応じて本文末尾へ適用する。

VideoImportInternalReasonV1は`guidanceOnlyExtension`、`pickerContractViolation`、`sourceMissing`、`sourcePermissionDenied`、`providerUnavailable`、`protectedDataUnavailable`、`drmSignaled`、`playerInitFailed`、`playerInvalidDuration`、`playerInvalidDimensions`、`playerNoProgress`、`playerSeekFailed`、`stageTimeout`、`sourceIdentityChanged`、`sourceStatChanged`、`sourceHashMismatch`、`destinationHashMismatch`、`errnoEnospc`、`errnoEdquot`、`sourceReadIo`、`destinationWriteIo`、`renameFailed`、`protectionAttributeMismatch`、`backupAttributeMismatch`、`destinationPlayerFailed`、`durationBelowRecordedTiming`、`referenceCasMismatch`、`dbTransactionFailed`、`userCanceled`、`unexpected`の閉じたenumとする。`userCanceled`はuserCanceled codeだけ、`destinationHashMismatch`はcopyIntegrityFailed codeだけに使用する。各reasonは必ず1つのdomain codeへ写像し、未知のnative値をenumへ動的追加しない。

raw player error、raw exception、filename、path、native messageをUIまたはproduction diagnostic sinkへ渡さない。maintenancePendingはdomain errorへ含めず、FR-037のsecondary stateとして扱う。

### 9.2 登録対象外拡張子のdialog

**タイトル**

> この拡張子のファイルは登録対象外です

**本文**

> 選択したファイルの拡張子は、現在の白内障執刀ノートでは登録対象外です。
> ファイルが正常な動画かどうかや、保護の有無は確認していません。選択元で正常に利用できる動画であることを確認してください。
> 必要な場合は、所属施設が承認した方法で、再登録できる設定の別ファイルを用意し、あらためて選択してください。
> 手術動画を、所属施設が承認していないWebサイトやcloud serviceへuploadしないでください。
> 元のファイルは変更されていません。

createでは「症例への登録は行っていません」、既存症例では「登録済みの動画と工程位置は変更していません」を末尾へ加える。

**操作**

- 別の動画を選ぶ
- 登録できる動画の目安を見る
- 閉じる

「変換する」というaction labelを使用せず、外部appを起動しない。

### 9.3 原因未確定またはtimeoutの再生確認失敗dialog

**タイトル**

> この動画は使用できません

**本文**

> この動画を白内障執刀ノートで再生できることを確認できませんでした。
> 動画形式やコーデックに対応していないか、ファイルが破損している可能性があります。
> 選択元で動画を確認してください。症例への登録は行っていません。

timeout時も同じ文言を使用し、形式、codec、破損のいずれかへ原因を絞り込まない。

既存症例では最後の文を次へ置き換える。

> 登録済みの動画と工程位置は変更していません。

**操作**

- unplayableMedia：別の動画を選ぶ
- playbackVerificationTimedOut：もう一度試す
- 閉じる

### 9.4 読込・cloud取得失敗

**タイトル**

> 動画を読み込めませんでした

**本文**

> ファイルへのアクセスが終了したか、選択元から動画を取得できなかった可能性があります。
> Filesでファイルを利用できることを確認して、もう一度選択してください。

形式変換を主な解決策として表示しない。

### 9.5 容量不足

**タイトル**

> 動画を保存できませんでした

**本文**

> 端末の空き容量を増やしてから、もう一度お試しください。
> 症例、登録済み動画、工程位置は変更していません。

### 9.6 protected media

**タイトル**

> この動画は利用できません

**本文**

> この動画は保護されているため利用できません。
> 利用可能な動画について、所属施設の担当者へ確認してください。

DRM解除、暗号解除、保護回避、外部変換を案内しない。

### 9.7 禁止表現

次を表示してはならない。

- 「MP4へ変換すれば必ず再生できます」
- 「変換しても動画の時刻、画質、色、内容は変わりません」
- 「この外部app / serviceは安全です」
- 「信頼できるオンライン変換serviceです」
- 原因未確定時の「動画形式が原因です」
- Filesの失敗に対する「写真へのアクセス権限を確認してください」
- 「動画は外部へ送信されません」という主体・範囲が不明な断定
- 「ユーザー自身の責任で利用してください」だけで責任分担を終える文言
- 外部変換済み動画を無条件に「同じ動画」と呼ぶ文言

### 9.8 その他のmessage family

#### A. protected data unavailable

- タイトル：「端末のロックを解除してください」
- 本文：「保護された動画と症例データを利用できません。端末のロックを解除して、もう一度お試しください。」
- 操作：「閉じる」「もう一度試す」

#### B. source changed / integrity

- タイトル：「動画が変更されています」
- 本文：「選択後にファイルが変更されたか、同じファイルであることを確認できませんでした。選択元を確認して、もう一度選択してください。」
- 操作：「別の動画を選ぶ」「閉じる」

#### C. safe storage verification

- タイトル：「動画を安全に保存できませんでした」
- 本文：「動画の保存または保存後の確認を完了できなかったため、登録していません。もう一度お試しください。」
- 操作：「もう一度試す」「閉じる」

#### D. duration conflict

- タイトル：「工程位置を保持できません」
- 本文：「選択した動画は、記録済みの工程位置より短いため、その位置を保持したまま登録できません。工程位置を消去して登録し直すか、同じ動画を選択してください。」
- 操作：videoPathがnullなら「工程位置を消去して動画を登録」、それ以外なら「工程位置を消去して動画を差し替え」、「別の動画を選ぶ」、「閉じる」

#### E. reference conflict

- タイトル：「症例が更新されました」
- 本文：「操作中にこの症例の動画が更新されました。最新の状態を読み込んで、もう一度お試しください。」
- 操作：「最新の状態を読み込む」「閉じる」

#### F. commit failure

- タイトル：「症例に動画を登録できませんでした」
- 本文：「症例データの更新を完了できませんでした。動画と工程位置は変更していません。」
- 操作：「もう一度試す」「閉じる」

#### G. unknown

- タイトル：「操作を完了できませんでした」
- 本文：「原因を確認できませんでした。動画、症例、工程位置は変更していません。もう一度お試しください。繰り返し発生する場合は、実際の患者動画を添付せずsupportへ連絡してください。」
- 操作：「もう一度試す」「閉じる」

createではdataInvariantSuffixとして「症例への登録は行っていません」、既存症例では「登録済みの動画と工程位置は変更していません」を該当本文末尾へ使用する。同じ意味の文を重複表示しない。

---

## 10. offline help要件

help titleは「登録できる動画の目安」とする。

### 10.1 対応の目安

次の内容を表示する。

> 対応の目安は、MP4ファイル、H.264（AVC）映像、AAC音声です。音声がない動画も利用できます。
>
> 詳細設定を選べる場合は、8bit、4:2:0、progressiveを目安にしてください。
>
> `.mp4`というファイル名でも、内部設定やファイルの状態によって再生できない場合があります。変換後の動画も、選択時に再生確認を行います。

### 10.2 外部で動画を用意する場合

次の手順を表示する。

1. 所属施設で承認された方法を確認する。
2. 原則として、施設が承認した端末内・offlineの方法で、元動画を上書きせず別fileを作成する。
3. MP4、H.264 / AVC、8bit、4:2:0、progressive、AACまたは音声なしを出力の目安にする。
4. trim、結合、速度変更、frame補間、不要なcropを行わない。
5. 変換後fileを白内障執刀ノートで改めて選択する。
6. 登録後に冒頭、中間、終端、duration、向き、音声を確認する。

### 10.3 医療情報に関する必須警告

次の趣旨を省略せず表示する。

> 手術動画は機微な医療情報として取り扱ってください。映像だけでなく、音声、ファイル名、メタデータにも患者を識別できる情報が含まれる場合があります。
>
> 所属施設が明示的に承認していないWebサイトやcloud変換serviceへ動画をuploadしないでください。使用できる方法が不明な場合は、所属施設の情報管理・個人情報保護担当者へ確認してください。
>
> 「端末内処理」と表示する第三者appでも、telemetry、crash log、cache、backup、cloud同期の有無を白内障執刀ノートは保証できません。
>
> 変換元と変換後のfileが残る場合があります。保管と廃棄は所属施設の規程に従ってください。実際の患者動画をアプリsupportへ送付しないでください。

### 10.4 工程時刻に関する必須警告

> 変換により動画の長さや時刻位置が変わる場合があります。工程位置が記録済みの症例では、以前その症例で使用したfileから変換・編集・再書き出しした動画、または同じfileか判断できない動画を「同じ動画」として登録しないでください。工程位置を消去する選択肢を使用すると、既存の工程位置は消去されます。

### 10.5 第三者toolのsupport境界

白内障執刀ノートのsupport対象は、登録できる動画の目安、再選択、アプリのerror codeまでとする。第三者toolの操作、契約、料金、出力品質、安全性、保存、削除、障害はsupport対象外であることを表示する。

---

## 11. プライバシー・セキュリティ要件

### 11.1 アプリからの外部通信

本機能は動画、音声、frame、thumbnail、filename、path、URL、metadataを外部送信しない。

help表示、登録対象外error、再選択、preflightを契機とするnetwork request、analytics event、crash attachmentを追加しない。

File Providerがユーザー選択済みcloud fileを端末へdownloadする通信は、白内障執刀ノートからのuploadとは区別する。

### 11.2 外部toolへの連携

特定tool名、App Store / Web link、affiliate link、Deep Link、Open In、Share Sheetを設けない。source fileを外部toolへ直接渡す機能を実装しない。

### 11.3 diagnostic data

v1.1で新しい永続diagnostic logまたはanalytics SDKを追加しない。VideoImportErrorとinternal reasonは処理中のmemory、unit test、synthetic fixture testだけで判別できる構造とする。

本機能eventに対するproduction sinkのallowlistは空とする。OSLog、Flutter / native logger、analytics、crash / telemetry SDK、breadcrumb、attachment、support exportへ、error code、entryPoint、phase、timestampを含む本機能eventを渡さない。debug buildで出力が必要な場合はcompile-time debug限定かつsynthetic fixture限定とし、Release Archiveから除去する。

次を禁止する。

- video、audio、frame、thumbnail、波形
- 元filename、display name、絶対・相対path、URL、bookmark
- recordId、手術日、左右眼、工程時刻、評価、メモ
- duration、解像度、codecのraw文字列、file size、hash
- media metadata
- raw native error、stdout、stderr、stack内path
- crash breadcrumb / attachment、analytics property、support artifactへの転記

### 11.4 filename

既存UIとvideo_display_nameの互換性は維持するが、filenameを機微情報として扱う。

- selectionと確認に必要な画面以外へ表示しない。
- 登録対象外dialogとhelp本文へ埋め込まない。
- diagnostic、analytics、crash、supportへ渡さない。
- screenshot、test artifact、fixture名に実患者filenameを使用しない。

### 11.5 App Switcher

動画frame、filename、症例情報を表示中にappがinactiveまたはbackgroundへ移る前に、App Switcher snapshotをprivacy overlayで覆う。active復帰後に除去する。

外部appを使うためにapp切替が増えることを理由に、この要件を省略しない。

### 11.6 医療情報運用

本書の文言は法的助言を代替しない。Release時点の所属施設運用と、公的な医療情報・個人情報保護guidelineに照らしてprivacy担当者が確認する。

---

## 12. UI・アクセシビリティ・非機能要件

### UI-001 表示形式

非対応、原因未確定、protected mediaは、消えるSnackBarだけで通知せず、scroll可能なdialogまたはfull-screen stateを使用する。

動画surfaceは短い状態だけを表示し、長文と操作を固定16:9領域へ詰め込まない。

### UI-002 多重表示

1 selection generationにつき主error dialogを1回だけ表示する。rebuild、provider更新、遅延callbackで同じdialogを重ねない。

### UI-003 継続導線

dialogを閉じた後も、短いerror state、「別の動画を選ぶ」、「登録できる動画の目安」を画面から再度利用できるようにする。

### UI-004 VoiceOver

- dialog表示時にfocusをtitleへ移す。
- alertとして原因、データが変更されていないこと、次の操作を1回通知する。
- close後は起点または「別の動画を選ぶ」へfocusを戻す。
- help見出しをSemantics headingとして公開する。

### UI-005 layout

Dynamic Type 2.0、320×568相当、横画面、iPad compact Split Viewでoverflowせず、本文と全actionへscrollで到達できる。

actionは狭幅で縦並びにし、48 logical pixels以上のtouch targetを確保する。色またはiconだけで状態を表さない。

### UI-006 loadingとcancel

app管理下のsource取得またはpreflightが500msを超えた場合は、phaseに応じて「動画を取得しています…」または「動画を確認しています…」を表示する。SHA-256計算では読込済みbytesとsource sizeから実値の進捗を表示してよい。確定できる進捗値がない場合は偽のpercentageを表示しない。

loading中は「キャンセル」を常に到達可能にする。cancelはselection generationを無効化し、controller、timer、file handle、access leaseを解放し、DBと既存candidateを変更しない。VoiceOver live regionはphase変更時に1回だけ通知し、position更新ごとに読み上げない。

OS pickerまたはFile Providerが管理するcallback前のdownload UIとcancelはOS側の責任範囲とし、appが制御可能であると表示しない。

### UI-007 代替操作

全actionへ一意なaccessible nameと論理的focus順を付ける。iPad外部keyboardのTab / Shift+Tab、Escapeによるcancel、Switch Control、Voice Controlでtouchと同じ操作へ到達できる。

### NFR-001 応答性

guidance-onlyまたはpicker契約外の拡張子は、OS picker callback受領から登録対象外dialog表示までをlocal synthetic fileでP95 500ms以内とする。source accessを待たない。player probeにはFR-013のtimeoutを適用し、無期限にloading表示を続けない。

### NFR-002 resource

preflightで動画全体をmemoryへ読み込まない。SHA-256はbounded bufferのstreaming処理とし、cancelを確認しながら読む。controller、timer、file handle、hash streamを全終了経路で解放する。

storageのglobal mutex内でsource preflightを実行せず、長時間のplayer初期化で別のcleanupを不要にblockしない。

### NFR-003 offline

local fileの選択、preflight、help、登録、レビューはnetwork接続なしで動作する。cloud sourceのdownloadはこの保証の対象外である。

### NFR-004 dependency

v1.1のRelease ArchiveへFFmpeg、変換engine、変換専用SDK、追加network permissionを含めない。既存のfile_pickerとvideo_playerを基本経路とする。

### NFR-005 localization

error codeとlocalization keyを一元管理し、new record、record detail、reviewで同じ原因に同じ文言を使用する。

### NFR-006 compatibility

iOS / iPadOS 15.0と最新対象OSのiPhone / iPadで同じ分類、help、正常再生を確認する。Release test開始前にmodel identifier、OS version / build、app commit、build number、fixture manifest checksumをTestMatrix-v1.1へ固定し、結果とともに保存する。

---

## 13. 受け入れ基準

| ID | 条件 | 合格基準 |
| --- | --- | --- |
| AC-001 | reference candidate | 5.5のReference Fixture Profile v1.1に一致するMP4 / MOV / M4V fixtureがpreflightとdestination検証を通り、従来フローで登録できる |
| AC-002 | guidance-only選択 | MPG / MPEG / MTS / M2TS / AVI / MKV / WMV / WEBMとpicker契約外をmetadataだけでnonCandidateExtensionとし、source open / app起因download / copy前に「正常性と保護状態は未確認」と表示する。random、truncated、protectedを装ったfixtureでも正常動画または変換可能と断定しない |
| AC-003 | 拡張子だけの誤判定防止 | MP4拡張子でも再生不能fixtureを登録せず、原因を断定しないdialogを表示する |
| AC-004 | 偽装・random bytes | registration candidate拡張子の非動画を登録せず、「変換すれば必ず解決」と表示しない |
| AC-005 | access・provider | source消失、read拒否、cloud取得失敗を形式問題や写真権限として表示しない |
| AC-006 | protected media | 明示的なDRM / 暗号化を登録せず、解除または変換を案内しない |
| AC-007 | picker cancel | dialog、DB、managed fileを作らず元画面へ戻る |
| AC-008 | create失敗 | 登録対象外、probe失敗、copy失敗、DB失敗で症例rowと初期reviewを残さない |
| AC-009 | 新規動画変更失敗 | 直前の正常動画、手術日、左右眼、入力値を保持する |
| AC-010 | attach / relink失敗 | 旧videoPath、全工程時刻、評価、振り返り、症例メモを保持する |
| AC-011 | replace失敗 | 旧videoPathと全工程時刻を保持し、新規fileをDB参照しない |
| AC-012 | 登録後変更の申告 | 工程時刻がある症例で3択を初期選択なしで表示する。「登録後に変更／同一性不明」は、videoPathがnullならattachWithTimingReset、それ以外ならreplaceの再確認後だけ時刻を消去する。「同じfileで登録後変更なし」はrelinkを許可し、過去に外部変換されたという理由だけで拒否しない。cancelは不変とする |
| AC-013 | duration下限 | 「同じfile」と申告してもdestination durationがcommit時点の最新最大工程時刻未満ならattach / relinkせず、DBを変更しない |
| AC-014 | 再選択 | 外部で用意したfixtureを再選択するとUI preflightとimport admission preflightを新しいgenerationで実行し、成功後は通常動画と同じ登録を行う |
| AC-015 | source preflight | init、正duration、正寸法、mute、position進行、seek、stage / 全体timeoutを全入口の共通実装で実行する |
| AC-016 | destination検証 | import admission成功後もcopy完全性、Data Protection、backup除外、destination playback probeを省略せず、VideoPlaybackEvidenceをserviceへ返す |
| AC-017 | source不変 | 成功、失敗、cancel、background、crashで元動画のbytes、size、mtime、metadata、pathを変更しない |
| AC-018 | cleanup | 通常失敗はtmp / orphanを即時清掃する。crash後の未参照finalは完全snapshot時、`.tmp`は24時間未満を保持し24時間経過後のreconciliationで回収する |
| AC-019 | DB整合性 | create transaction、videoPath CAS、attachWithTimingReset、replace、duration再確認のatomicityを維持する |
| AC-020 | help内容 | MP4、H.264 / AVC、8bit、4:2:0、progressive、AAC / 音声なし、元動画非上書き、施設承認、未承認upload禁止、複製管理、工程時刻警告、第三者toolのsupport境界、実患者動画をsupportへ送らない注意をoffline表示する |
| AC-021 | 外部連携禁止 | 特定tool名、browser / Store link、Deep Link、Open In、Share Sheet、source引渡しが存在しない |
| AC-022 | 外部通信 | help、error、preflight、再選択を起因とするapp outbound通信、queued payload、analytics eventが操作中・app再起動・SDK flush後も0件である |
| AC-023 | diagnostic privacy | 本機能event自体とcanary filename、path、metadata、raw error、recordIdがReleaseのOSLog、Flutter / native log、crash、telemetry、analytics、support artifactへ出ない |
| AC-024 | filename | filenameを登録対象外dialog、help、App Switcher snapshot、test artifactへ露出しない |
| AC-025 | App Switcher | inactive / background snapshotへ動画frame、filename、症例情報が映らない |
| AC-026 | accessibility | VoiceOver、Dynamic Type 2.0、320×568、横画面、iPad Split View、外部keyboard、Switch Control、Voice Controlで状態と全actionへ到達できる |
| AC-027 | common UI | create / attach / relink / attachWithTimingReset / replaceが同じerror code、文言resource、help componentを使用する |
| AC-028 | 回帰 | 既存動画の再生、seek、5秒・15秒移動、速度変更、工程記録、一覧、詳細、分析が正常である |
| AC-029 | legacy | legacy external移行とfallback再生で外部originalを変更せず、既存工程時刻を保持する |
| AC-030 | dependency | Release ArchiveにFFmpeg、変換engine、変換専用SDKがなく、lockfile、dependency inventory、SBOM、license noticeが相互一致する |
| AC-031 | offline | local fileのhelp、preflight、登録、reviewが機内モードで完了する |
| AC-032 | player callback race | cancel、再選択、画面破棄後の古いcallbackがdialog、candidate、保存処理を更新しない |
| AC-033 | 音声漏出防止 | source / destination probe中にspeaker、Bluetooth、AirPlayへ音声を出さない |
| AC-034 | 現行品質gate | flutter analyze、既存全test、新規testが成功する |
| AC-035 | preflight binding | public serviceがraw sourcePathでpreflightを迂回できず、UI preflightのSHA-256をcandidateへ保持する。登録操作時にaccess再取得と全preflightを行い、`candidate hash == sourceHashBefore == sourceHashAfter == destinationHash`を確認し、そのleaseをcopy / hash完了まで保持する。同size・同mtimeを含むpreflight後のsource差替えはsourceChangedとなる |
| AC-036 | Data Protection | 新規・既存の動画格納directory、record directory、tmp、未参照final、正式managed video、database directory、DB / WAL / SHMが厳密に`NSFileProtectionComplete`であることを実機でread-backする。WAL / SHMの生成・再生成・checkpoint・reopen後も維持し、動画はbackup除外済みであることを確認する |
| AC-037 | protected data unavailable | device lock等でprotected dataを利用できない間はpreflight、copy、commit、reconciliationを開始せず、解除案内後の明示的再試行までDBを変更しない |
| AC-038 | error contract | 全domain code、VideoImportInternalReasonV1、message family、primary / secondary recoveryAction、presentation、dataInvariantSuffixの写像が完全かつ未知値をunknownへ閉じる |
| AC-039 | logical / maintenance outcome | commit成功後のrefresh / cleanup失敗はlogical successを反転せず、参照中fileを削除しない。commit失敗時はprimary errorを維持してmaintenancePendingをsecondaryへ返す |
| AC-040 | loading / cancel | 500ms超のapp管理処理で正しいphase、indeterminate表示、cancel、1回のVoiceOver通知を提供し、cancel後はleaseとresourceを解放して既存stateを保持する |
| AC-041 | 拡張子権威値 | displayNameと一時pathの拡張子不一致、大文字拡張子、拡張子なしで、5.1の同じ正規化値をpicker、preflight、storageが使用する |
| AC-042 | audio variants | Reference Fixture ProfileのAAC-LC mono、stereo、音声なしが登録でき、登録後のreview実機testでdecode / 出力可否を確認する。probe中は常にmuteする |
| AC-043 | timing concurrency | duration確認後からcommitまでに工程時刻を更新する競合を注入し、最終durationを超える時刻を保持したvideoPath更新が成功しない |
| AC-044 | privacy release metadata | 最終ArchiveのPrivacyInfo.xcprivacy、全SDK Privacy Manifest、Required Reason API、App Store privacy回答、実際のnetwork / diagnostic挙動が一致し、privacy担当が証跡を承認する |

---

## 14. 試験要件

### 14.1 traceability

各FR、UI、NFR、ACを少なくとも1件のtest IDへ対応付け、対象commit、fixture、実行環境、結果を記録する。実行可能要件を人の承認だけで合格扱いにしない。

### 14.2 unit test

- registrationCandidateExtensionsとguidanceOnlyExtensionsの排他・allowlist外
- displayName / path不一致、大文字、拡張子なしの権威値正規化
- domain error、VideoImportInternalReasonV1、localization key、recovery action、presentation、suffixの全写像
- timeout、generation、遅延callback無効化
- streaming hashのcancel、candidate hash保持、diagnostic非露出
- durationと保存済み最大工程時刻の比較
- 登録後変更なし、変更済み、同一性不明、未選択、cancelからattach / relink / attachWithTimingReset / replaceへの遷移
- filename、path、raw errorのredaction
- entry pointごとの同一policy使用
- logicalOutcomeとmaintenanceOutcomeの直交contract

### 14.3 widget test

- 症例一覧から正常動画、guidance-only、picker契約外、unplayable、timeout、cancel
- 新規症例の初回preflight、動画変更成功・失敗
- 失敗時に手術日、左右眼、直前candidateを保持
- record detailとreviewのattach / relink / attachWithTimingReset / replace
- 原因別dialog、message familyごとのaction、data invariant suffix
- offline helpの全section
- dialogの多重表示防止
- loading phase、cancel、VoiceOver live regionとfocus復帰
- Dynamic Type 2.0、狭幅、横画面、iPad compact Split View
- 外部keyboard、Switch Control、Voice Control相当のsemantics / focus contract
- App Switcher privacy overlay

現行new_record_flow_testのようにpreviewを無効化したtestだけで、preflight UXを完了扱いにしない。

### 14.4 storage・service integration test

- nonCandidateExtensionとimport admission preflight不合格時にimportVideoを呼ばない
- public serviceのraw path迂回禁止、access再取得、lease解放、preflight後の同size・同mtime source差替え
- candidate / source before / source after / destinationの4者SHA-256不一致
- source変更、copy read / write失敗、ENOSPC / EDQUOT、size / hash不一致
- destination player init、duration、寸法、position、seek、timeout
- probe中mute
- `NSFileProtectionComplete`とbackup除外の設定・read-back失敗、protected data unavailable
- 旧versionの動画・DB・WAL・SHMからの初回access前Data Protection移行
- WAL / SHMの初回生成、再生成、checkpoint、DB reopen後の保護class確認
- create DB失敗の補償削除
- attach / relink CAS競合
- attachWithTimingResetとreplaceのvideoPath更新・工程時刻消去transaction
- duration確認と同時工程更新を含むtransaction競合
- commit後refresh失敗、commit後cleanup延期、commit失敗 + cleanup延期
- cleanup delete失敗、未参照final、24時間未満 / 経過後tmpのreconciliation
- tmp copy中、rename後probe前、probe後DB前、DB後cleanup前の強制終了

### 14.5 fixture

実患者動画を使用せず、自作または適切に利用許諾された非臨床素材を使う。

最低限、次を用意する。

- MP4 / H.264 / AAC
- MOV / H.264 / AAC
- M4V / H.264 / AAC
- MP4 / H.264 / AAC-LC mono
- MP4 / H.264 / AAC-LC stereo
- MP4 / H.264 / 音声なし
- MP4拡張子で非対応codec
- MP4拡張子のrandom bytes
- truncated MP4
- DRM / 暗号化を明示するtest doubleまたはfixture
- MPEG-PS / MPEG-2の正常、random bytes、truncated代表
- M2TS / H.264の正常、random bytes、truncated、protectedを装う代表
- AVI、MKV、WMV、WEBMの各guidance-only代表
- File Provider取得失敗test double
- 外部変換相当のMP4 / H.264 / AAC派生fixture
- 先頭trim、速度変更、frame dropを含む非同一timeline fixture

各fixtureはID、SHA-256、生成手順、由来、license、container / codec / profile / level / pixel format / scan / frame rate / geometry / bitrate / timestamp / audio期待値、期待error、患者情報を含まないことをversion付きmanifestへ記録する。

### 14.6 実機test

- TestMatrix-v1.1で固定したiOS / iPadOS 15.0実機
- TestMatrix-v1.1で固定した最新対象OSのiPhone / iPad
- Files localとiCloud / File Provider
- 機内モード
- 低空き容量
- BluetoothまたはAirPlay routeが存在する状態でprobe mute
- AAC-LC mono / stereo / 音声なしの登録後review
- background / foregroundとApp Switcher snapshot
- 代表正常fixtureで再生、5秒・15秒移動、seek、速度変更、工程記録
- guidance-only、unplayable、provider失敗の全dialog

### 14.7 privacy test

synthetic canaryのfilename、path、metadata、raw player errorを注入し、本機能eventと禁止値がReleaseのOSLog、Flutter / native log、crash、telemetry、analytics、support / test artifactへ出ないことを確認する。

help、error、preflight、再選択中のURLSession、Network.framework、socket、DNS、analyticsを観測し、本機能起因のoutbound eventとqueued payloadが0件であることを確認する。app再起動とSDK flush後も再確認し、File Providerのsource downloadは別phaseとして識別する。

最終ArchiveのPrivacyInfo.xcprivacy、全SDK Privacy Manifest、Required Reason API inventory、App Store privacy回答をdependency inventoryと照合する。

---

## 15. 実装境界と変更候補

本章は実装箇所の候補を示す。WidgetからstorageやDBを直接操作するshortcutを作らない。

### 15.1 追加する共通責務

- VideoImportPreflight：source access、player probe、timeout、generation、import admission再検証
- VerifiedVideoCandidate：権威拡張子、selection generation、ephemeral evidence
- VideoPlaybackEvidence：destination duration、寸法、aspect ratio
- VideoImportError：閉じたerror code、phase、recovery action、localization key
- VideoSelectionPolicy：candidate / guidance-only allowlist
- NonCandidateVideoDialog：登録対象外拡張子の共通dialog
- VideoRegistrationGuidanceScreen：offline help
- VideoTimelineIdentityPolicy：ユーザー申告と工程時刻保持可否
- VideoImportOutcome：logical outcomeとmaintenance outcome

命名は実装時に変更してよいが、責務をWidgetへ分散しない。

### 15.2 主な変更候補file

| file | 主な変更 |
| --- | --- |
| lib/src/data/surgery_video_picker.dart | picker選択集合、権威拡張子、登録可能集合を分離 |
| lib/src/data/providers.dart | 共通preflight / admission / policy provider |
| lib/src/data/video_storage_repository.dart | timeout、mute、寸法、position、seek、VideoPlaybackEvidence、Data Protection、型付きerror |
| lib/src/data/record_video_service.dart | candidate必須化、登録時preflight、attachWithTimingReset、duration再確認、outcome分離。現行copy→probe→DB順序、CAS、compensationを維持 |
| lib/src/data/surgery_repository.dart | expected null CAS + 工程時刻消去、durationと最新工程時刻のatomic判定 |
| lib/src/features/records/record_list_screen.dart | 初回preflight、常設help、Files用error |
| lib/src/features/records/new_record_screen.dart | pending candidate、入力保持、共通dialog |
| lib/src/features/records/record_detail_screen.dart | attach / relink / attachWithTimingReset / replace前preflight、共通error |
| lib/src/features/review/step_review_screen.dart | 同じpreflight、timeline policy、共通error |
| ios/Runnerおよびapp lifecycle / shell | Data Protection、protected data availability、App Switcher privacy overlay |
| localization resource | 全文言の一元管理 |

### 15.3 変更してはならない契約

- Application Support/videos/<recordId>/<UUID>.<ext>
- sourceのsize / SHA-256完全性確認
- path containment、symlink拒否、UUID保存名
- backup除外read-back
- createの症例・初期review transaction
- attach / relinkのvideoPath CAS
- `expectedVideoPath: null`を扱うrepositoryの原子的参照更新能力
- replaceの参照更新・工程時刻消去transaction
- DB失敗時の補償削除
- 起動時の保守的reconciliation
- legacy external originalを削除しない契約

### 15.4 実装禁止

本要件を理由に次を追加しない。

- dependencyとしてのFFmpegまたはcodec package
- native conversion command
- conversion progress UI
- conversion用DB migration
- conversion用background mode
- 外部toolのURL schemeまたはShare extension
- analytics SDK

---

## 16. 実装順序

### Phase 1：contractとhelp

- VideoSelectionPolicy
- VideoImportError
- localization resource
- NonCandidateVideoDialog
- VideoRegistrationGuidanceScreen
- unit / widget test

**終了条件**：AC-020、AC-026、AC-038が通り、同じerror codeが全入口で同じ文言とactionへ写像され、helpがoffline・accessibleに表示できる。

### Phase 2：source preflight

- timeout付き、mute済みplayer probe
- VerifiedVideoCandidateとimport admission再preflight
- generation、cancel、dispose
- loading / cancel / accessibility
- pending candidate
- record list / new record統合

**終了条件**：AC-001、AC-002、AC-003、AC-004、AC-005、AC-006、AC-007、AC-008、AC-009、AC-015、AC-032、AC-033、AC-035、AC-040、AC-041が通る。

### Phase 3：既存症例統合

- record detail / reviewのpreflight
- attach / relink / attachWithTimingReset / replaceの共通フロー
- timeline identity申告policy
- destination evidenceとatomic duration判定

**終了条件**：AC-010、AC-011、AC-012、AC-013、AC-014、AC-019、AC-027、AC-043が通る。

### Phase 4：storage・hardening

- destination probe強化
- typed storage error
- Data Protection、protected data availability
- outcome分離、fault injection、reconciliation
- App Switcher overlay
- privacy / device matrix

**終了条件**：全AC、既存全test、analyze、Release Gateが通る。

各Phaseはreview可能な小さい変更へ分割し、前Phaseの未解決問題を後PhaseのUIで隠さない。

---

## 17. Release Gate

| Gate | 必須証跡 | 承認者 |
| --- | --- | --- |
| Gate 1 要件・UX | 本書、閉じた全error契約、offline help、loading / cancel、timeline申告policy | プロダクト責任者、QA |
| Gate 2 privacy | 外部連携なし、network / queued payload 0件、production diagnostic event 0件、Data Protection、App Switcher、医療情報警告、Privacy Manifest / App Store回答整合 | privacy / 情報管理担当、QA |
| Gate 3 機能・安全 | 全入口、preflight binding、attachWithTimingReset、atomic duration、logical / maintenance outcome、fault injection、DB / file不変条件、全AC | Tech Lead、QA |
| Gate 4 配布 | 最終Archive dependency / SBOM / license検査、analyze、全test、固定実機matrix、既知制限 | 配布責任者、Tech Lead、QA |

次のいずれかが残る場合は配布しない。

- guidance-only形式を選べず、登録対象外案内または常設helpへ到達できない。
- 拡張子policyだけでfileの正常性、破損、保護状態または変換成功を断定する。
- generic player errorを形式、容量、権限のいずれかへ推測分類する。
- ユーザーが「登録後変更済み」または「同一性不明」と申告した動画で工程時刻を保持できる。
- videoPathがnullのattachWithTimingResetを原子的に実行できない。
- raw sourcePathでimport admission preflightを迂回できる。
- app作成動画、格納directory、database、WAL、SHMの`NSFileProtectionComplete`属性を全ライフサイクルで確認できない。
- preflight不合格後にDBまたはmanaged videoが残る。
- 特定外部tool、upload、Share、Deep Linkが含まれる。
- privacy文言の承認がない。
- Release Archiveに変換engineが含まれる。
- 全AC、既存test、analyze、実機testの証跡がない。

---

## 18. 将来のアプリ内変換を再検討する条件

将来の導入を確約しない。次を満たす別versionの企画としてのみ再検討する。

- 個人情報を含まない方法で確認した十分な実需要
- 対象container / codec / device / OS matrix
- engine license、SBOM、再現build、配布方法
- Privacy Manifest、network無効化、threat model
- 画質、色、interlace、frame timing、A/V同期の実機評価
- 長時間処理、storage、memory、thermal、background、cancel
- 元動画、一時file、正式file、DBのatomic commitとcrash recovery
- 医療情報、法務、privacy、QA、配布責任者の承認

この検討結果をv1.1へ遡及適用しない。

---

## 19. v1.1再構成での主な変更

- 端末内自動変換方針を撤回し、外部準備・再選択へ一本化した。
- FFmpeg、Remux、Hybrid、Transcode、変換Job、engine Gateを削除した。
- 登録候補拡張子とguidance-only拡張子を分離した。
- 全入口でApplication Supportへのcopy前に共通preflightを必須化した。
- player失敗、access、provider、容量、copy、DB競合を型付きerrorへ分離した。
- 原因未確定時に「形式が原因」「変換すれば解決」と断定しない文言へ改めた。
- 外部tool推薦ではなく、施設承認、未承認upload禁止、責任分担を中心とするhelpへ改めた。
- 以前の登録後に変更した、または同一性不明とユーザーが申告した動画を、工程時刻保持relinkへ使用しない方針を追加した。
- videoPathがnullの症例へ動画を付けながら工程時刻を原子的に消去するattachWithTimingResetを追加した。
- 登録時のpreflight再実行、source access lease、destination evidence、atomic duration判定を追加した。
- Data Protectionとlogical / maintenance outcomeの分離を追加した。
- 新規動画変更に失敗しても、直前動画、手術日、左右眼を保持する要件を追加した。
- App Switcher、diagnostic privacy、accessibility、fault injectionを受け入れ条件へ追加した。

---

## 20. 参考情報

Release時には最新版と改定日を確認し、本書の具体的運用は所属施設の規程と責任者判断へ従う。

- 厚生労働省「医療情報システムの安全管理に関するガイドライン 第7.0版（令和8年6月）」
  - https://www.mhlw.go.jp/stf/shingi/0000516275_00006.html
- 個人情報保護委員会・厚生労働省「医療・介護関係事業者における個人情報の適切な取扱いのためのガイダンス」（令和8年4月一部改正）
  - https://www.ppc.go.jp/personalinfo/legal/iryoukaigo_guidance/
- Apple Developer Documentation「NSFileProtectionComplete」
  - https://developer.apple.com/documentation/foundation/fileprotectiontype/complete
- Apple Developer Documentation「UIApplication.isProtectedDataAvailable」
  - https://developer.apple.com/documentation/uikit/uiapplication/isprotecteddataavailable
- Flutter video_playerの採用versionに対応するofficial documentation
- file_pickerの採用versionに対応するofficial documentation
- 現行repositoryのvideo storage、record transaction、cleanup、review test

本書は法令、guideline、所属施設規程の解釈を代替しない。外部service利用可否は、実際の運用、契約、情報管理体制を含めて所属施設が判断する。
