# Test Matrix v1.1

- 対象: 白内障執刀ノート v1.1 非対応動画形式・外部変換運用
- 文書版: 1.1
- 作成日: 2026-08-16
- 要件: [v1.1 要件定義書](../../requirements/unsupported_video_external_conversion_requirements.md)
- 対象ブランチ: `feature/external-video-compatibility-v1-1`
- 対象アプリ版: `1.1.0+19`
- 対象commit: `PENDING`（検証対象をfreezeした後に記入）
- fixture manifest: [fixture-manifest-v1.1.yaml](fixture-manifest-v1.1.yaml)
- 総合状態: **BLOCKED**

本書は、v1.1の検証範囲と証跡の記録先を固定するための台帳である。2026-08-16時点では、実fixture、固定実機、Release Archiveおよび実行結果が登録されていない。テストコードが存在することは、テストが成功したことを意味しない。

## 1. 状態と証跡の規則

| 状態 | 意味 |
| --- | --- |
| `PASS` | freeze済みcommit/buildに対して実行し、再確認可能な証跡がある |
| `FAIL` | 実行済みで期待結果を満たさない |
| `PENDING` | 実行または判定をまだ行っていない |
| `BLOCKED` | fixture、実機、Archive、担当者などの前提がないため実行できない |
| `NOT_RUN` | 実行対象は確定しているが、この台帳へ実行記録がない |
| `N/A` | 適用外。理由と承認者を必須とする |

`PASS`へ変更する際は、対象commit、アプリbuild、fixture IDとSHA-256、環境、実行者、日時、結果、ログまたは画像の相対pathを同じ行または実行記録へ残す。患者情報、filename、端末内path、recordId、raw player errorを証跡へ含めてはならない。

## 2. 検証対象のfreeze

| 項目 | 値 | 状態 |
| --- | --- | --- |
| Git commit | `PENDING` | `BLOCKED` |
| App version / build | `1.1.0+19`（最終確認前） | `PENDING` |
| Release configuration | `PENDING` | `BLOCKED` |
| fixture manifest version / SHA-256 | `v1.1 / PENDING` | `BLOCKED` |
| dependency lockfile / SBOM version | `PENDING` | `BLOCKED` |
| Privacy Manifest inventory | `PENDING` | `BLOCKED` |
| 実行証跡root | `docs/release/v1.1/evidence/`（未作成） | `PENDING` |

freeze後にcommitまたはfixtureが変わった場合、影響する行は再び`PENDING`へ戻す。

## 3. 自動検証

| Test ID | 対象 | 実行コマンド / suite | 必須環境 | 現在状態 | 証跡 |
| --- | --- | --- | --- | --- | --- |
| AUTO-001 | 静的解析 | `flutter analyze` | 固定Flutter / Dart SDK | `NOT_RUN` | `PENDING` |
| AUTO-002 | 全Dart / Flutter test | `flutter test` | 固定Flutter / Dart SDK | `NOT_RUN` | `PENDING` |
| AUTO-003 | policy・preflight・probe・hash | `test/video_import_preflight_test.dart`, `test/video_playback_probe_test.dart`, `test/file_sha256_test.dart` | host test | `NOT_RUN` | `PENDING` |
| AUTO-004 | storage・DB・service・crash境界 | `test/video_storage_*`, `test/record_video_service_*`, `test/surgery_repository_safety_test.dart`, `test/video_crash_boundary_test.dart`, `test/protected_storage_test.dart` | host test | `NOT_RUN` | `PENDING` |
| AUTO-005 | 共通dialog・help・loading・世代管理 | `test/video_import_*`, `test/video_registration_guidance_screen_test.dart`, `test/video_timeline_identity_dialog_test.dart` | widget test | `NOT_RUN` | `PENDING` |
| AUTO-006 | 全入口・既存機能回帰 | new record / record detail / step review / list / analysis / transport suites | widget / integration相当 | `NOT_RUN` | `PENDING` |
| AUTO-007 | layout・semantics | `test/review_video_layout_test.dart`, dialog / guidance suites, design system goldens | fixed fonts / viewport | `NOT_RUN` | `PENDING` |
| AUTO-008 | iOS native contract | `ios/RunnerTests/RunnerTests.swift` | Xcode、iOS test destination | `NOT_RUN` | `PENDING` |
| AUTO-009 | Release Archive inspection | archive、link map、embedded frameworks、privacy manifest、entitlements | Xcode Release Archive | `BLOCKED` | Archive未作成 |

上記suiteのsourceが現行working treeに存在することは確認対象の列挙であり、成功結果の記録ではない。ワイルドカードを実行記録へ転記せず、実際に実行されたtest fileをログへ保存する。

## 4. 固定実機inventory

| Environment ID | 必須条件 | device model | OS build | app build | 担当 | 状態 |
| --- | --- | --- | --- | --- | --- | --- |
| DEV-IP15 | iOS 15.0.xを実行するiPhone実機 | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `BLOCKED` |
| DEV-IPAD15 | iPadOS 15.0.xを実行するiPad実機 | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `BLOCKED` |
| DEV-IP-LATEST | 最新対象iOSのiPhone実機 | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `BLOCKED` |
| DEV-IPAD-LATEST | 最新対象iPadOSのiPad実機 | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `BLOCKED` |

シミュレータは補助確認に利用できるが、上記4環境およびData Protection、音声route、App Switcher、低容量の実機判定を代替しない。UDIDそのものは文書へ記載せず、社内端末台帳の匿名化IDを用いる。

## 5. fixture・形式matrix

全行ともmanifestに実artifactとSHA-256が登録されるまで`BLOCKED`である。

| Test ID | シナリオ | fixture ID | 期待結果 | 必須環境 | 現在状態 |
| --- | --- | --- | --- | --- | --- |
| MEDIA-001 | MP4 / H.264 / AAC-LC stereo | `RF-MP4-H264-AAC-STEREO-60S` | preflight、destination検証、登録、review成功 | 4実機 | `BLOCKED` |
| MEDIA-002 | MOV / H.264 / AAC-LC stereo | `RF-MOV-H264-AAC-STEREO-60S` | 同上 | 4実機 | `BLOCKED` |
| MEDIA-003 | M4V / H.264 / AAC-LC stereo | `RF-M4V-H264-AAC-STEREO-60S` | 同上 | 4実機 | `BLOCKED` |
| MEDIA-004 | MP4 / H.264 / AAC-LC mono | `RF-MP4-H264-AAC-MONO-60S` | 登録後reviewでdecode / 出力可否を確認 | 4実機 | `BLOCKED` |
| MEDIA-005 | MP4 / H.264 / 音声なし | `RF-MP4-H264-NO-AUDIO-60S` | 登録後review成功、音声なし | 4実機 | `BLOCKED` |
| MEDIA-006 | MP4拡張子・非対応codec | `NEG-MP4-UNSUPPORTED-CODEC` | 登録せず、原因未確定dialog | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-007 | MP4拡張子・random bytes | `NEG-MP4-RANDOM-BYTES` | 登録せず、原因を推測しない | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-008 | truncated MP4 | `NEG-MP4-TRUNCATED` | 登録せず、原因を推測しない | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-009 | DRM / 暗号化明示double | `NEG-PROTECTED-MEDIA-DOUBLE` | 登録せず、解除・変換を案内しない | automated + 代表実機 | `BLOCKED` |
| MEDIA-010 | MPG / MPEG正常代表 | `GDN-MPG-MPEG2-VALID`, `GDN-MPEG-MPEG2-VALID` | sourceをopenせずguidance-only表示 | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-011 | MPEG-PS random / truncated | `GDN-MPEG-PS-RANDOM`, `GDN-MPEG-PS-TRUNCATED` | 正常性や変換可否を断定しない | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-012 | MTS / M2TS正常代表 | `GDN-MTS-H264-VALID`, `GDN-M2TS-H264-VALID` | sourceをopenせずguidance-only表示 | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-013 | M2TS random / truncated / protected-looking | `GDN-M2TS-RANDOM`, `GDN-M2TS-TRUNCATED`, `GDN-M2TS-PROTECTED-LIKE` | 正常性・保護状態を断定しない | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-014 | AVI / MKV / WMV / WEBM | `GDN-AVI-VALID`, `GDN-MKV-VALID`, `GDN-WMV-VALID`, `GDN-WEBM-VALID` | guidance-only表示 | 4実機の代表2台以上 | `BLOCKED` |
| MEDIA-015 | picker契約外 / 拡張子なし | `META-PICKER-CONTRACT-OUTSIDE`, `META-NO-EXTENSION` | metadataのみで登録対象外、source openなし | automated + 代表実機 | `BLOCKED` |
| MEDIA-016 | 外部変換相当の再選択 | `EXT-CONVERTED-MP4-H264-AAC` | 新generationで再preflight後、通常登録 | 4実機 | `BLOCKED` |
| MEDIA-017 | 非同一timeline | `TL-HEAD-TRIM`, `TL-SPEED-CHANGE`, `TL-FRAME-DROP` | 初期選択なし3択、変更/不明時のみ確認後に工程時刻消去 | automated + 代表実機 | `BLOCKED` |

## 6. Files、通信状態、容量、保護状態

| Test ID | シナリオ | 期待結果 | 必須環境 | 現在状態 |
| --- | --- | --- | --- | --- |
| ENV-001 | Files「このiPhone/iPad内」 | source read-only、登録成功後もoriginal不変 | 4実機 | `BLOCKED` |
| ENV-002 | iCloud / File Provider取得成功 | provider取得phaseとapp管理phaseを分離し、登録可能 | 4実機 | `BLOCKED` |
| ENV-003 | provider unavailable / source消失 / read拒否 | 形式・写真権限と誤分類せずDB / managed file不変 | double + 4実機の代表2台 | `BLOCKED` |
| ENV-004 | 機内モード | local help、preflight、登録、reviewが完了しapp outbound 0 | 4実機 | `BLOCKED` |
| ENV-005 | 低空き容量 / ENOSPC相当 | 容量message、元state保持、tmp / orphan規則どおり | 4実機 | `BLOCKED` |
| ENV-006 | 選択後source差替え（同size・同mtime含む） | `sourceChanged`、copy / DB commitなし | automated + 代表実機 | `BLOCKED` |
| ENV-007 | device lockでprotected data unavailable | preflight / copy / commit / reconciliationを開始せず、unlock後の明示再試行 | 4実機 | `BLOCKED` |
| ENV-008 | background / foreground / cancel / crash境界 | original不変、古いcallback無効、回収規則どおり | automated + 4実機 | `BLOCKED` |

## 7. Data Protection、backup、DB family

| Test ID | 対象 | 必須操作 | 期待結果 | 現在状態 |
| --- | --- | --- | --- | --- |
| DP-001 | videos / record / tmp / orphan / final | 新規作成、失敗、reconciliationを含むread-back | 全対象が厳密に`NSFileProtectionComplete` | `BLOCKED` |
| DP-002 | database directory、DB / WAL / SHM | 初回生成、WAL / SHM再生成、checkpoint、close / reopen | 全ライフサイクルで厳密に`NSFileProtectionComplete` | `BLOCKED` |
| DP-003 | managed video | import後と再起動後にresource value read-back | backup除外がtrue | `BLOCKED` |
| DP-004 | 旧version storage | 最初のaccess前にmigration、失敗注入 | 不完全保護時はfail closed、DB不変 | `BLOCKED` |

native / Dart test sourceは補助証跡であり、実機resource valueのread-back証跡なしに本節を`PASS`へしない。

## 8. 再生・音声・UI・アクセシビリティ

| Test ID | シナリオ | 期待結果 | 必須環境 | 現在状態 |
| --- | --- | --- | --- | --- |
| PLAY-001 | 正常fixtureの再生・seek・5秒/15秒・速度変更・工程記録 | 既存レビュー機能に回帰なし | 4実機 | `BLOCKED` |
| AUDIO-001 | source / destination probe、内蔵speaker | probe開始前から終了 / disposeまでmute、漏出なし | 4実機 | `BLOCKED` |
| AUDIO-002 | BluetoothまたはAirPlay route接続中のprobe | routeへ音声漏出なし | 対応実機2系統以上 | `BLOCKED` |
| AUDIO-003 | mono / stereo / no-audio登録後review | decodeと意図した出力可否を個別記録 | 4実機 | `BLOCKED` |
| UI-DEV-001 | App Switcher snapshot | 動画frame、filename、症例情報なし | 4実機 | `BLOCKED` |
| UI-DEV-002 | VoiceOver | 状態、全action、loading通知1回、focus復帰 | 4実機 | `BLOCKED` |
| UI-DEV-003 | Dynamic Type 2.0、320x568、横画面、iPad Split View | clip / overflowなし、全action到達可 | 対応実機 | `BLOCKED` |
| UI-DEV-004 | 外部keyboard、Switch Control、Voice Control | 代替操作とsemantics / focus到達性 | 対応実機 | `BLOCKED` |
| UI-DEV-005 | 全dialog family | guidance-only、unplayable、provider、容量、保護、integrity、commit、unknown | 4実機の代表2台以上 | `BLOCKED` |

## 9. privacy・distribution

| Test ID | シナリオ | 期待結果 | 必須環境 | 現在状態 |
| --- | --- | --- | --- | --- |
| PRIV-001 | synthetic canary注入 | Release log / crash / telemetry / analytics / artifactにeventと禁止値0件 | Release build + 観測環境 | `BLOCKED` |
| PRIV-002 | help / error / preflight / 再選択中のnetwork観測 | app起因outbound / queued payload 0件。再起動・SDK flush後も0件 | 4実機の代表2台 | `BLOCKED` |
| PRIV-003 | filename露出 | dialog、help、snapshot、test artifactへ露出なし | automated + 4実機 | `BLOCKED` |
| DIST-001 | dependency / SBOM / license照合 | FFmpeg、変換engine、変換専用SDKなし。3台帳が一致 | 最終Archive | `BLOCKED` |
| DIST-002 | Privacy manifest / Required Reason API / App Store回答 | dependency inventory、実挙動と一致 | 最終Archive | `BLOCKED` |
| DIST-003 | signing / entitlement / minimum OS / archive validation | 配布設定が承認済みrelease値と一致 | 最終Archive | `BLOCKED` |

## 10. 実行記録

現時点の確定実行記録はない。

| Run ID | Test ID | commit / build | fixture ID / SHA-256 | environment | 実行日時 | 実行者 | 結果 | evidence path |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` | `PENDING` |

## 11. 完了条件

- [ ] [traceability-v1.1.md](traceability-v1.1.md)の全FR / UI / NFR / ACに、freeze済み実行記録が対応している
- [ ] 必須fixtureすべてにartifact、SHA-256、生成手順、由来、license、非臨床確認がある
- [ ] 4固定実機と必須route / 状態の結果がある
- [ ] 自動test、実機test、privacy、Archive検査がすべて`PASS`である
- [ ] `FAIL`、`BLOCKED`、理由未承認の`N/A`がない
- [ ] [release-gates-v1.1.md](release-gates-v1.1.md)の承認が完了している

現在はこれらを満たしていないため、v1.1の配布判定は**BLOCKED**である。
