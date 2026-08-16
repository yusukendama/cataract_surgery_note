# Release Gates v1.1

- 対象: 白内障執刀ノート v1.1 非対応動画形式・外部変換運用
- 文書版: 1.1
- 作成日: 2026-08-16
- 要件: [v1.1 要件定義書](../../requirements/unsupported_video_external_conversion_requirements.md)
- Test Matrix: [TestMatrix-v1.1.md](TestMatrix-v1.1.md)
- Traceability: [traceability-v1.1.md](traceability-v1.1.md)
- Fixture manifest: [fixture-manifest-v1.1.yaml](fixture-manifest-v1.1.yaml)
- 対象commit / build: `PENDING`
- 現在の配布判定: **BLOCKED — DO NOT RELEASE**

2026-08-16時点では、実fixture、固定実機結果、Release privacy canary、SBOM / license照合、最終Archive検査および必要な承認がない。以下の未チェック項目は未実施であり、不合格または合格を示すものではない。

## 1. 判定規則

| 状態 | Release上の扱い |
| --- | --- |
| `PASS` | freeze済みcommit/buildで実行し、要件を満たす再確認可能な証跡と必要な承認がある |
| `FAIL` | 配布禁止。修正後に影響範囲を再実行する |
| `PENDING` | 配布禁止。実行または承認が未完了 |
| `BLOCKED` | 配布禁止。fixture、実機、Archive、担当者などの前提が不足 |
| `N/A` | 要件責任者とQAが理由を文書承認した場合だけ許可。実行可能項目への適用は禁止 |

GateはAND条件である。Gate 1からGate 4までの全必須項目が証跡付き`PASS`になるまで配布しない。部分的な自動test成功、test sourceの存在、シミュレータ結果、口頭確認は実機・privacy・Archive gateを代替しない。

## 2. Freeze前提

- [ ] 40桁の対象commit SHAを記録した。状態: `BLOCKED`
- [ ] `1.1.0+19`を含む最終version / buildを承認した。状態: `PENDING`
- [ ] Release configuration、signing identity、provisioning profileを固定した。状態: `BLOCKED`
- [ ] Flutter / Dart / Xcode / CocoaPodsのversionを記録した。状態: `PENDING`
- [ ] `pubspec.lock`、Pods lockfile、dependency inventory、SBOMをfreezeした。状態: `BLOCKED`
- [ ] fixture manifestの全必須項目を埋め、manifest自体のSHA-256を記録した。状態: `BLOCKED`
- [ ] iPhone iOS 15、iPad iPadOS 15、最新iOS iPhone、最新iPadOS iPadの匿名化端末IDとOS buildを固定した。状態: `BLOCKED`
- [ ] sanitize済み証跡の保存先、retention、閲覧権限、担当者を決めた。状態: `PENDING`

freeze後にcode、dependency、build setting、fixture bytesが変わった場合、影響するGateを`PENDING`へ戻す。

## 3. Gate overview

| Gate | 必須範囲 | 承認者 | 現在状態 | 主なblocker |
| --- | --- | --- | --- | --- |
| Gate 1 要件・UX | error contract、offline help、loading / cancel、timeline申告、accessibility | プロダクト責任者、QA | `BLOCKED` | 実行証跡と実機accessibility結果なし |
| Gate 2 privacy・情報保護 | outbound 0、diagnostic 0、Data Protection、App Switcher、privacy metadata | privacy / 情報管理担当、QA | `BLOCKED` | Release canary、実機read-back、最終metadataなし |
| Gate 3 機能・安全 | 全入口、preflight binding、atomicity、fault injection、全AC | Tech Lead、QA | `BLOCKED` | fixture、固定run、実機matrixなし |
| Gate 4 配布 | Archive、dependency / SBOM / license、analyze、全test、既知制限 | 配布責任者、Tech Lead、QA | `BLOCKED` | 最終Archiveと配布証跡なし |

## 4. Gate 1 — 要件・UX

### 4.1 要件と共通contract

- [ ] [traceability-v1.1.md](traceability-v1.1.md)の全92要件行にfreeze済みRun IDがある。状態: `BLOCKED`
- [ ] 全domain code、`VideoImportInternalReasonV1`、localization key、primary / secondary recovery action、presentation、data invariant suffixの完全写像を検証した。状態: `PENDING`
- [ ] 未知code / reasonが`unknown`へ閉じ、推測分類やraw error表示がない。状態: `PENDING`
- [ ] create / attach / relink / attachWithTimingReset / replaceが同じpolicy、preflight、error resource、help componentを使う。状態: `PENDING`
- [ ] guidance-only、原因未確定、protected、provider、容量、integrity、duration、reference、commit、unknownのdialogを全入口で確認した。状態: `BLOCKED`
- [ ] 過去に外部変換されたという理由だけで同一性を拒否しない。状態: `PENDING`
- [ ] timeline 3択は初期選択なしで、変更済み / 不明時だけ確認後に工程時刻を消去する。状態: `BLOCKED`

### 4.2 Help、loading、cancel

- [ ] offline helpに形式目安、元動画非上書き、施設承認、未承認upload禁止、複製管理、工程時刻警告、第三者tool境界、supportへ患者動画を送らない注意がある。状態: `PENDING`
- [ ] picker前の常設入口とnonCandidate dialogからhelpへ到達できる。状態: `PENDING`
- [ ] unplayable / timeout dialogから原因未確定のままhelpへ直接誘導しない。状態: `PENDING`
- [ ] app管理処理が500msを超えた際、取得 / 確認の正しいphaseとindeterminateまたは実測進捗を表示する。状態: `PENDING`
- [ ] loading中のcancelが常に到達でき、generation、controller、timer、stream、handle、leaseを解放する。状態: `PENDING`
- [ ] picker cancelとapp処理cancelの双方でDB、managed file、既存stateが不変である。状態: `PENDING`
- [ ] 1 selection generationにつき主dialogは1回だけで、古いcallbackがstateを更新しない。状態: `PENDING`

### 4.3 VoiceOver・表示・代替操作実機Gate

対象はTest Matrixの4固定実機。各行に動画・症例情報を含まない動画またはscreen recordingとaccessibility inspector結果を添付する。

- [ ] VoiceOverでdialog表示時にtitleへfocusが移る。状態: `BLOCKED`
- [ ] 原因、データ不変、次の操作をalertとして1回だけ読み上げる。状態: `BLOCKED`
- [ ] dialog close後に起点または「別の動画を選ぶ」へfocusが戻る。状態: `BLOCKED`
- [ ] loading live regionはphase変更時に1回だけ通知し、進捗更新ごとに読まない。状態: `BLOCKED`
- [ ] helpの見出しがheadingとして公開される。状態: `BLOCKED`
- [ ] Dynamic Type 2.0、320x568相当、横画面、iPad compact Split Viewで本文と全actionへ到達できる。状態: `BLOCKED`
- [ ] 狭幅でactionが縦並び、touch targetが48 logical pixels以上、色 / iconだけに依存しない。状態: `BLOCKED`
- [ ] 外部keyboardのTab / Shift+Tab / Escape、Switch Control、Voice Controlで全actionへ到達できる。状態: `BLOCKED`

Gate 1 evidence root: `PENDING`

Gate 1 approver / date: `PENDING`

Gate 1 result: **BLOCKED**

## 5. Gate 2 — privacy・情報保護

### 5.1 iOS Data Protection実機read-back

シミュレータ、設定codeの目視、unit testのみでは合格にしない。Foundation resource valueを実機でread-backし、pathやfilenameは匿名化した対象種別として記録する。

- [ ] videos格納directoryを最初の子file作成前に`NSFileProtectionComplete`としてread-backした。状態: `BLOCKED`
- [ ] record directoryを最初の子file作成前に同classとしてread-backした。状態: `BLOCKED`
- [ ] `.tmp`を最初の非0-byte write前に同class、backup除外trueとしてread-backした。状態: `BLOCKED`
- [ ] rename後の未参照finalを同class、backup除外trueとしてread-backした。状態: `BLOCKED`
- [ ] 正式managed videoを同class、backup除外trueとしてread-backした。状態: `BLOCKED`
- [ ] database directoryをDB open / WAL生成前に同classとしてread-backした。状態: `BLOCKED`
- [ ] DB本体、WAL、SHMを初回生成後に同classとしてread-backした。状態: `BLOCKED`
- [ ] WAL / SHMの再生成後、checkpoint後、DB close / reopen後もDB familyを同classとしてread-backした。状態: `BLOCKED`
- [ ] 旧versionのdirectory、managed video、DB / WAL / SHMを最初のaccess前に移行・read-backした。状態: `BLOCKED`
- [ ] 属性設定またはread-back失敗時にfail closedし、DB / 既存症例を変更しない。状態: `BLOCKED`
- [ ] lock中はpreflight、copy、commit、reconciliationを開始せず、unlock後のユーザー明示操作でのみ再試行する。状態: `BLOCKED`

### 5.2 Probe音声実機Gate

音量UIの見た目やmockのvolume値だけでは合格にしない。sourceとdestinationの双方を確認する。

- [ ] 内蔵speaker routeで、controller再生前からpause / disposeまで音声漏出がない。状態: `BLOCKED`
- [ ] Bluetooth audio routeで音声漏出がない。状態: `BLOCKED`
- [ ] AirPlay routeで音声漏出がない。状態: `BLOCKED`
- [ ] AAC-LC mono fixtureを登録し、reviewでdecode / 出力可否を記録した。状態: `BLOCKED`
- [ ] AAC-LC stereo fixtureを登録し、reviewでdecode / 出力可否を記録した。状態: `BLOCKED`
- [ ] no-audio fixtureを登録し、reviewで正常動作を記録した。状態: `BLOCKED`
- [ ] route変更、background / foreground、cancel時にもprobe音声漏出がない。状態: `BLOCKED`

### 5.3 App Switcher privacy実機Gate

- [ ] activeからinactiveへ遷移したsnapshotに動画frameがない。状態: `BLOCKED`
- [ ] snapshotにfilenameがない。状態: `BLOCKED`
- [ ] snapshotに症例情報、record detail、工程情報、評価、メモがない。状態: `BLOCKED`
- [ ] backgroundからforegroundへ戻った後にprivacy shieldが残留しない。状態: `BLOCKED`
- [ ] launch、system dialog、rotation、Split View、画面破棄の各状態でfail-openしない。状態: `BLOCKED`
- [ ] iOS 15 / 最新iOSのiPhone、iPadOS 15 / 最新iPadOSのiPadで確認した。状態: `BLOCKED`

### 5.4 Release synthetic canaryとnetwork観測

実患者情報は使用しない。canaryは生成規則と値のSHA-256だけを台帳へ残し、禁止値そのものを通常のtest reportへ複製しない。

- [ ] synthetic canary filename、source path、metadata、raw player error、recordIdをRelease buildへ注入した。状態: `BLOCKED`
- [ ] 本機能event自体と禁止値がRelease OSLogに0件である。状態: `BLOCKED`
- [ ] Flutter / native logに0件である。状態: `BLOCKED`
- [ ] crash reportに0件である。状態: `BLOCKED`
- [ ] telemetry / analytics / support artifact / test artifactに0件である。状態: `BLOCKED`
- [ ] dialog、help、App Switcher snapshotにfilenameがない。状態: `BLOCKED`
- [ ] help、error、preflight、再選択中のURLSession、Network.framework、socket、DNS、analyticsを観測した。状態: `BLOCKED`
- [ ] app起因outbound eventとqueued payloadが0件である。状態: `BLOCKED`
- [ ] app再起動後および存在するSDKのflush後も0件である。状態: `BLOCKED`
- [ ] File Providerによるsource downloadを別phaseとして識別し、app uploadと混同していない。状態: `BLOCKED`

### 5.5 Privacy metadata整合

- [ ] 最終Archive内のアプリおよび全embedded SDKから`PrivacyInfo.xcprivacy`をinventory化した。状態: `BLOCKED`
- [ ] 全Privacy Manifestのdeclared data / tracking / API usageを実dependencyと照合した。状態: `BLOCKED`
- [ ] Required Reason API inventoryとmanifest理由をcode / binary usageへ照合した。状態: `BLOCKED`
- [ ] App Store Connect privacy回答をmanifest、network観測、diagnostic観測へ照合した。状態: `BLOCKED`
- [ ] privacy / 情報管理担当が医療情報警告、証跡、最終回答を承認した。状態: `BLOCKED`

Gate 2 evidence root: `PENDING`

Gate 2 approver / date: `PENDING`

Gate 2 result: **BLOCKED**

## 6. Gate 3 — 機能・データ安全

### 6.1 Fixtureと形式

- [ ] manifestの全fixture / doubleが`READY`である。状態: `BLOCKED`
- [ ] file artifactごとにfinal bytesのSHA-256、再現可能な生成手順、由来、license、実測media metadataがある。状態: `BLOCKED`
- [ ] 全artifactについて「患者情報を含まない」ことをreviewerが署名した。状態: `BLOCKED`
- [ ] MP4 / MOV / M4V reference profileを4固定実機で登録・reviewした。状態: `BLOCKED`
- [ ] mono / stereo / no-audio variantsを4固定実機で登録・reviewした。状態: `BLOCKED`
- [ ] guidance-only全8拡張子とpicker契約外をsource open前に案内した。状態: `BLOCKED`
- [ ] random / truncated / protected-looking guidance fixtureで正常性・保護状態・変換成功を断定しない。状態: `BLOCKED`
- [ ] unsupported codec / random / truncated MP4を登録せず、原因を推測しない。状態: `BLOCKED`
- [ ] 外部変換相当fixtureを新generationで再選択し通常登録した。状態: `BLOCKED`
- [ ] head trim / speed change / frame dropでtimeline申告と工程時刻処理を確認した。状態: `BLOCKED`

### 6.2 Preflight、storage、DB

- [ ] public serviceからraw sourcePathによるpreflight迂回ができない。状態: `PENDING`
- [ ] UI candidate hashとsource before / after、destinationの4者SHA-256が一致しない限りcommitしない。状態: `PENDING`
- [ ] access leaseを登録時に再取得し、copyとhash完了まで連続保持して全終了経路で解放する。状態: `PENDING`
- [ ] 同size・同mtimeを含むsource差替えを`sourceChanged`とする。状態: `PENDING`
- [ ] destinationのsize / hash、safe rename、protection、backup、playback evidenceをDB前に検証する。状態: `BLOCKED`
- [ ] create transaction、attach / relink CAS、attachWithTimingReset、replaceのatomicityを確認した。状態: `PENDING`
- [ ] duration確認後の工程時刻競合で、durationを超えるvideoPath更新が成功しない。状態: `PENDING`
- [ ] failureごとにoriginal、旧videoPath、工程時刻、評価、振り返り、メモが不変である。状態: `PENDING`
- [ ] commit後refresh / cleanup失敗がlogical successを反転せず、参照中fileを削除しない。状態: `PENDING`
- [ ] commit失敗 + cleanup延期でprimary errorとsecondary maintenance stateを保持する。状態: `PENDING`
- [ ] incomplete DB snapshot時にreconciliationがfileを削除しない。状態: `PENDING`
- [ ] 未参照final、24時間未満 / 経過後tmp、各crash boundaryの回収規則を確認した。状態: `PENDING`

### 6.3 実機利用状態と回帰

- [ ] Files localからの登録とoriginal不変を4固定実機で確認した。状態: `BLOCKED`
- [ ] iCloud / File Providerの成功、失敗、source消失、read拒否を確認した。状態: `BLOCKED`
- [ ] 機内モードでlocal help、preflight、登録、reviewを完了した。状態: `BLOCKED`
- [ ] 低空き容量で誤分類せず、DB / file不変とcleanupを確認した。状態: `BLOCKED`
- [ ] background / foreground、cancel、画面破棄、再選択のraceを確認した。状態: `BLOCKED`
- [ ] 代表正常fixtureでplay / pause、任意seek、5秒 / 15秒移動、速度変更、工程記録を確認した。状態: `BLOCKED`
- [ ] 一覧、詳細、review、分析およびlegacy migration / fallbackに回帰がない。状態: `BLOCKED`

Gate 3 evidence root: `PENDING`

Gate 3 approver / date: `PENDING`

Gate 3 result: **BLOCKED**

## 7. Gate 4 — 自動品質・SBOM・Archive・配布

### 7.1 自動品質

- [ ] freeze済みcommitで`flutter analyze`が成功し、完全なlogがある。状態: `PENDING`
- [ ] freeze済みcommitで既存testと新規testを含む`flutter test`が成功し、完全なlogがある。状態: `PENDING`
- [ ] iOS native testsが承認済みdestinationで成功し、`.xcresult`がある。状態: `PENDING`
- [ ] flaky retryだけの成功を採用していない。retryした場合は初回失敗と原因を記録した。状態: `PENDING`
- [ ] 既知のskip / disabled / excluded testを列挙し、Tech LeadとQAが理由を承認した。状態: `PENDING`
- [ ] 全Test Matrix行とtraceability行が証跡付き`PASS`である。状態: `BLOCKED`

### 7.2 Dependency、SBOM、license

- [ ] Dart / Flutter、CocoaPods、Swift package、embedded framework / dylibを最終Archiveからinventory化した。状態: `BLOCKED`
- [ ] lockfile inventory、binary inventory、SBOMのpackage名とversionが相互一致する。状態: `BLOCKED`
- [ ] direct / transitive dependencyごとにlicense、copyright、notice義務を確認した。状態: `BLOCKED`
- [ ] 配布物へ必要なlicense noticeが含まれ、inventoryと一致する。状態: `BLOCKED`
- [ ] FFmpeg、libav系、変換engine、codec package、変換専用SDKがArchiveとSBOMにない。状態: `BLOCKED`
- [ ] analytics SDK、conversion用background mode、追加network permissionがない。状態: `BLOCKED`
- [ ] SBOM形式、生成tool / version、生成日時、対象commit、Archive SHA-256を記録した。状態: `BLOCKED`
- [ ] security / license reviewの未解決事項がない。状態: `BLOCKED`

### 7.3 最終Release Archive checklist

- [ ] clean buildからRelease Archiveを生成した。状態: `BLOCKED`
- [ ] `.xcarchive`のSHA-256、生成日時、Xcode version、対象commit、build numberを記録した。状態: `BLOCKED`
- [ ] bundle identifier、version、build、minimum OS、supported devicesが承認値と一致する。状態: `BLOCKED`
- [ ] signing identity、provisioning、entitlements、capabilities、background modesが承認値と一致する。状態: `BLOCKED`
- [ ] debug entitlement、development URL、test fixture、test-only flag、不要なsymbol / configが混入していない。状態: `BLOCKED`
- [ ] PrivacyInfo.xcprivacyと全SDK manifestをArchiveから抽出してGate 2のinventoryへ使用した。状態: `BLOCKED`
- [ ] executable、framework、resource、link map、stringsからconversion engine / 外部tool連携 / 禁止URLを検査した。状態: `BLOCKED`
- [ ] App Store validationまたは同等の配布前検証が成功した。状態: `BLOCKED`
- [ ] archiveからinstallしたbuildで4固定実機の必須smokeを再実行した。状態: `BLOCKED`
- [ ] privacy / QA / Tech Lead / 配布責任者が同一Archive SHA-256を承認した。状態: `BLOCKED`

### 7.4 既知制限と配布判断

- [ ] guidance-only形式はアプリ内変換しないことを既知仕様として明記した。状態: `PENDING`
- [ ] external toolの品質・privacy・supportを保証しない責任境界を明記した。状態: `PENDING`
- [ ] 原因未確定のplayer failureをcodec / 破損 / 容量 / 権限へ推測分類しない。状態: `PENDING`
- [ ] 未解決bug、risk、waiverを列挙し、owner、期限、影響、rollback条件を記録した。状態: `PENDING`
- [ ] rollback / hotfix判断者と連絡経路を確認した。状態: `PENDING`

Gate 4 evidence root: `PENDING`

Gate 4 approver / date: `PENDING`

Gate 4 result: **BLOCKED**

## 8. 即時配布停止条件

次のいずれかが1件でも存在する場合は、他の結果にかかわらず配布しない。

- guidance-only形式を選べず、登録対象外案内または常設helpへ到達できない。
- 拡張子だけで正常性、破損、保護状態、変換可能性を断定する。
- generic player errorをcodec、容量、権限などへ推測分類する。
- sourceを変更、削除、永続参照または第三者へ引き渡す。
- raw sourcePathでimport admission preflightを迂回できる。
- 4者SHA-256、destination probe、Data Protection、backup read-backを省略してcommitできる。
- Data Protectionの不一致またはprotected data unavailable時にDB操作を継続する。
- preflight / save失敗後に症例、工程、旧videoPathが変わる、または新managed fileが参照される。
- timeline変更済み / 不明の動画でユーザー確認なしに工程時刻を保持する。
- 参照中managed fileをcleanupまたは補償処理が削除する。
- probe音声がspeaker、Bluetooth、AirPlayへ漏れる。
- App Switcher snapshotへ動画frame、filename、症例情報が映る。
- app起因outbound / queued payload、禁止diagnostic値、本機能のproduction eventが1件でもある。
- 特定外部tool、browser / Store link、Deep Link、Share Sheet、upload導線が含まれる。
- Release ArchiveにFFmpeg、変換engine、変換専用SDK、未承認dependency / permissionが含まれる。
- 全AC、analyze、全test、固定実機、privacy、Archiveの証跡または必須承認がない。

## 9. Evidence sanitization

- 実患者動画、患者情報を含むfilename、症例情報をtestに使用しない。
- log / screenshot / video / `.xcresult`を共有する前にfilename、端末path、recordId、raw error、個人端末識別子を確認し、必要に応じてredactする。
- 証跡名にはTest ID、Run ID、匿名化Environment ID、日時だけを用いる。
- synthetic canaryは検出目的に限定し、canary値自体を通常のsupport artifactへ複製しない。
- 失敗証跡も成功証跡と同じretention / access controlに従う。
- 証跡をredactした事実、担当者、日時、原本の保管場所を監査logへ残す。

## 10. 最終sign-off

| Role | 氏名 / ID | 対象Archive SHA-256 | 判定 | 日時 | evidence / comment |
| --- | --- | --- | --- | --- | --- |
| プロダクト責任者 | `PENDING` | `PENDING` | `BLOCKED` | `PENDING` | 要件・UX未承認 |
| QA | `PENDING` | `PENDING` | `BLOCKED` | `PENDING` | Test Matrix未完了 |
| privacy / 情報管理担当 | `PENDING` | `PENDING` | `BLOCKED` | `PENDING` | canary / metadata未確認 |
| Tech Lead | `PENDING` | `PENDING` | `BLOCKED` | `PENDING` | 機能・安全 / SBOM未承認 |
| 配布責任者 | `PENDING` | `PENDING` | `BLOCKED` | `PENDING` | 最終Archive未承認 |

最終判定欄: **BLOCKED — DO NOT RELEASE**

判定更新条件: 全Gateの証跡付き`PASS`と、同一Archive SHA-256に対する全sign-off。
