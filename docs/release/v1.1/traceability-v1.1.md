# Traceability v1.1

- 対象要件: [v1.1 非対応動画形式・外部変換運用 要件定義書](../../requirements/unsupported_video_external_conversion_requirements.md)
- 文書版: 1.1
- 対象matrix: [TestMatrix-v1.1.md](TestMatrix-v1.1.md)
- fixture台帳: [fixture-manifest-v1.1.yaml](fixture-manifest-v1.1.yaml)
- 作成日: 2026-08-16
- 対象commit: `PENDING`（working treeをfreezeしていない）
- 総合状態: **BLOCKED**

この文書は全FR / UI / NFR / ACを検証IDへ対応付ける。現時点で確認したのはテストsourceの存在と検証候補だけであり、テスト実行、fixture作成、実機確認、Release Archive検査の成功ではない。このため`PASS`は1件も記録していない。

## 1. 記録規則

- `PENDING`: 検証候補はあるが、freeze済みcommitに対する実行証跡がない。
- `BLOCKED`: 必須fixture、実機、privacy観測、Archiveまたは承認が未準備で、要件全体を判定できない。
- 各表の`commit`は、最終検証時に同一の40桁commit SHAへ置換する。変更が混在する場合はrunごとに分割する。
- 自動test sourceが存在しても、それだけで要件を満たしたとは判定しない。
- 実行結果はTest MatrixのRun IDへ紐付け、fixture SHA-256、環境ID、ログpathを記録する。
- manual reviewだけで実行可能な要件を合格にしない。

### テストsource略号

| 略号 | 現行の検証候補source |
| --- | --- |
| `T-PREF` | `test/video_import_preflight_test.dart` |
| `T-PROBE` | `test/video_playback_probe_test.dart` |
| `T-HASH` | `test/file_sha256_test.dart` |
| `T-UI` | `test/video_import_ui_flow_test.dart`, `test/video_import_screen_flow_test.dart` |
| `T-DIALOG` | `test/video_import_dialogs_test.dart` |
| `T-LOAD` | `test/video_import_loading_dialog_test.dart` |
| `T-HELP` | `test/video_registration_guidance_screen_test.dart` |
| `T-TIMELINE` | `test/video_timeline_identity_dialog_test.dart` |
| `T-STORAGE` | `test/video_storage_repository_test.dart`, `test/video_storage_safety_test.dart` |
| `T-STORAGE-ERR` | `test/video_storage_error_classification_test.dart` |
| `T-SERVICE` | `test/record_video_service_test.dart`, `test/record_video_service_safety_test.dart` |
| `T-REPO` | `test/surgery_repository_safety_test.dart` |
| `T-PROTECTED` | `test/protected_storage_test.dart` |
| `T-CRASH` | `test/video_crash_boundary_test.dart` |
| `T-LEGACY` | `test/legacy_database_compatibility_test.dart` |
| `T-ENTRY` | `test/new_record_flow_test.dart`, `test/new_record_save_flow_test.dart`, `test/new_record_video_preview_change_test.dart`, `test/record_detail_screen_test.dart`, `test/step_review_screen_test.dart` |
| `T-REGRESSION` | `test/video_seek_coordinator_test.dart`, `test/video_transport_controls_test.dart`, record list / detail / review / analysis suites |
| `T-LAYOUT` | `test/review_video_layout_test.dart`, dialog / help widget suites、design-system golden suites |
| `T-IOS` | `ios/RunnerTests/RunnerTests.swift` |

略号は可読性のための参照である。合格時の証跡には実際のtest名と実行logを記録する。

## 2. Functional Requirements

| Requirement | 検証ID | source候補 | fixture / environment | commit | 現在結果 | 未完了条件 |
| --- | --- | --- | --- | --- | --- | --- |
| FR-001 | AUTO-003, MEDIA-010..015 | T-PREF | guidance-only全ID / host + 代表実機 | `PENDING` | `BLOCKED` | 全拡張子fixture未作成、未実行 |
| FR-002 | AUTO-005, ENV-002, ENV-003 | T-PREF, T-DIALOG, T-ENTRY | PROVIDER-UNAVAILABLE-DOUBLE / File Provider実機 | `PENDING` | `BLOCKED` | provider実機と文言証跡なし |
| FR-003 | AUTO-005, AUTO-006 | T-UI, T-ENTRY, T-SERVICE | test double / host | `PENDING` | `PENDING` | cancel後のDB / managed file不変を実行確認する |
| FR-004 | AUTO-004, ENV-001, ENV-008 | T-STORAGE, T-SERVICE, T-CRASH | checksummed fixture / 4実機 | `PENDING` | `BLOCKED` | originalのbytes / size / mtime / metadata / path実測なし |
| FR-005 | AUTO-003, AUTO-004, ENV-006 | T-PREF, T-HASH, T-SERVICE | source差替えdouble / host | `PENDING` | `PENDING` | lease全終了経路と非永続化をfreeze buildで未実行 |
| FR-010 | AUTO-003, AUTO-006 | T-PREF, T-ENTRY, T-SERVICE | candidate double / host | `PENDING` | `PENDING` | 5入口の同一interface証跡を確定する |
| FR-011 | AUTO-003, ENV-003 | T-PREF, T-DIALOG | PROVIDER-UNAVAILABLE-DOUBLE / host + 実機 | `PENDING` | `BLOCKED` | provider実機で消失 / 拒否 / 取得失敗を確認する |
| FR-012 | AUTO-003, MEDIA-010..015 | T-PREF | guidance-only / contract外ID | `PENDING` | `BLOCKED` | source openなしのfixture証跡がない |
| FR-013 | AUTO-003, MEDIA-001..008 | T-PROBE, T-PREF | reference / negative candidate / host + 4実機 | `PENDING` | `BLOCKED` | 実media fixtureと実機timing未確認 |
| FR-014 | AUTO-003, AUDIO-001, AUDIO-002 | T-PROBE, T-STORAGE | audio fixture / speaker・BT・AirPlay実機 | `PENDING` | `BLOCKED` | physical routeの漏出確認なし |
| FR-015 | AUTO-003, AUTO-005 | T-PREF, T-UI, T-ENTRY | generation doubles / host | `PENDING` | `PENDING` | 全入口・画面破棄raceをfreeze buildで未実行 |
| FR-016 | AUTO-005, AUTO-006 | T-UI, T-ENTRY | success / failure doubles / host | `PENDING` | `PENDING` | 入力・旧candidate保持の実行証跡なし |
| FR-017 | AUTO-003, AUTO-004 | T-PREF, T-SERVICE, T-HASH | candidate / source変更double / host | `PENDING` | `PENDING` | public API境界とdiagnostic非露出の確定証跡なし |
| FR-020 | AUTO-005, MEDIA-010..015 | T-DIALOG, T-UI, T-ENTRY | guidance-only全ID / host + 実機 | `PENDING` | `BLOCKED` | 全形式とDB / file不変をfixtureで未確認 |
| FR-021 | AUTO-003, AUTO-005, MEDIA-006..008 | T-PROBE, T-DIALOG | negative MP4 IDs / host + 実機 | `PENDING` | `BLOCKED` | 実media failure文言を未確認 |
| FR-022 | AUTO-005, MEDIA-009 | T-PREF, T-DIALOG | NEG-PROTECTED-MEDIA-DOUBLE | `PENDING` | `BLOCKED` | versioned double未登録・未実行 |
| FR-023 | AUTO-005, ENV-004 | T-HELP, T-DIALOG, T-ENTRY | bundled content / 機内モード4実機 | `PENDING` | `BLOCKED` | offline実機証跡なし |
| FR-024 | AUTO-005, PRIV-002, DIST-001 | T-HELP, T-DIALOG | Release build / network観測環境 | `PENDING` | `BLOCKED` | URL / Share不在とoutbound 0のRelease証跡なし |
| FR-025 | AUTO-005, AUTO-006 | T-UI, T-DIALOG, T-ENTRY | selection doubles / host | `PENDING` | `PENDING` | 旧state不変を全入口で未実行 |
| FR-030 | AUTO-004, MEDIA-001..005, DP-003 | T-STORAGE, T-SERVICE | reference fixtures / host + 4実機 | `PENDING` | `BLOCKED` | 4者hash、destination実probe、backup read-backの統合証跡なし |
| FR-031 | AUTO-004 | T-SERVICE, T-REPO | service doubles / host | `PENDING` | `PENDING` | create / CAS / reset / replace順序をfreeze commitで未実行 |
| FR-032 | AUTO-004, AUTO-006 | T-SERVICE, T-REPO, T-ENTRY | fault doubles / host | `PENDING` | `PENDING` | 全入口・全失敗phaseの不変条件を未実行 |
| FR-033 | AUTO-004, ENV-008 | T-STORAGE, T-SERVICE, T-CRASH | crash/fault doubles / host + 実機 | `PENDING` | `PENDING` | crash実行と24時間境界の統合証跡なし |
| FR-034 | AUTO-004, ENV-005 | T-STORAGE-ERR, T-STORAGE | storage fault doubles / 低容量実機 | `PENDING` | `BLOCKED` | ENOSPC / EDQUOTと実volume証跡なし |
| FR-035 | AUTO-009, DIST-001, PRIV-001 | schema / source / Archive inspection | Release Archive | `PENDING` | `BLOCKED` | 最終DB schema、Archive、diagnostic監査なし |
| FR-036 | AUTO-004 | T-REPO, T-SERVICE | duration / concurrency doubles / host | `PENDING` | `PENDING` | transaction競合をfreeze commitで未実行 |
| FR-037 | AUTO-004 | T-SERVICE, T-PROTECTED | refresh / cleanup / commit fault doubles | `PENDING` | `PENDING` | logical / maintenance全組合せを未実行 |
| FR-038 | AUTO-004, AUTO-008, DP-001..004 | T-PROTECTED, T-IOS | legacy storage + 4実機 | `PENDING` | `BLOCKED` | 実機read-back全ライフサイクル証跡なし |
| FR-039 | AUTO-004, AUTO-008, ENV-007 | T-PROTECTED, T-IOS, T-SERVICE | locked-device実機 | `PENDING` | `BLOCKED` | lock / unlock / 明示再試行の実機証跡なし |
| FR-040 | PLAY-001, MEDIA-001..005 | T-REGRESSION, T-ENTRY | reference fixtures / 4実機 | `PENDING` | `BLOCKED` | 登録後video_player実機再生未確認 |
| FR-041 | AUTO-006, PLAY-001 | T-REGRESSION | reference fixture / 4実機 | `PENDING` | `BLOCKED` | 全操作と工程記録の実機回帰なし |
| FR-042 | AUTO-004, AUTO-006 | T-LEGACY, T-STORAGE, T-REGRESSION | legacy DB / media / host + 実機 | `PENDING` | `PENDING` | upgrade時の非encode / rename / delete証跡を確定する |
| FR-043 | AUTO-004 | T-LEGACY, T-STORAGE, T-SERVICE | legacy external double / host | `PENDING` | `PENDING` | success / failure / fallbackのoriginal hash証跡なし |
| FR-050 | PRIV-001, PRIV-002, DIST-001 | source / Archive inspection | Release build + diagnostic / network観測 | `PENDING` | `BLOCKED` | SDK / payload / diagnosticのRelease監査なし |
| FR-051 | DIST-001 | requirement / ADR / feature inventory review | final commit + Archive | `PENDING` | `PENDING` | v1.1にconversion flag / engineがないことをfreeze後確認する |

## 3. UI Requirements

| Requirement | 検証ID | source候補 | fixture / environment | commit | 現在結果 | 未完了条件 |
| --- | --- | --- | --- | --- | --- | --- |
| UI-001 | AUTO-005, UI-DEV-005 | T-DIALOG, T-ENTRY | error doubles / narrow + 実機 | `PENDING` | `BLOCKED` | 全message familyの実機表示証跡なし |
| UI-002 | AUTO-005 | T-UI, T-DIALOG, T-ENTRY | generation / delayed callback doubles | `PENDING` | `PENDING` | rebuild / provider / callback全経路を未実行 |
| UI-003 | AUTO-005 | T-DIALOG, T-ENTRY | noncandidate / unplayable doubles | `PENDING` | `PENDING` | close後の継続導線を全入口で未実行 |
| UI-004 | AUTO-005, AUTO-007, UI-DEV-002 | T-DIALOG, T-HELP, T-LOAD | VoiceOver実機 | `PENDING` | `BLOCKED` | focus移動・1回通知・focus復帰の実機証跡なし |
| UI-005 | AUTO-007, UI-DEV-003 | T-LAYOUT, T-DIALOG, T-HELP | fixed viewport + 実機 | `PENDING` | `BLOCKED` | 320x568 / 横 / Split View / touch target実機確認なし |
| UI-006 | AUTO-005, UI-DEV-002 | T-LOAD, T-UI, T-PREF | delayed / cancel doubles + VoiceOver | `PENDING` | `BLOCKED` | 500ms、phase、resource解放、通知回数の統合証跡なし |
| UI-007 | AUTO-007, UI-DEV-004 | T-LAYOUT, T-DIALOG, T-HELP | keyboard / Switch / Voice Control実機 | `PENDING` | `BLOCKED` | 代替入力の実機操作証跡なし |

## 4. Non-functional Requirements

| Requirement | 検証ID | source候補 | fixture / environment | commit | 現在結果 | 未完了条件 |
| --- | --- | --- | --- | --- | --- | --- |
| NFR-001 | AUTO-003, AUTO-005, MEDIA-010..015 | T-PREF, T-PROBE, T-UI | local synthetic fixtures / profiled device | `PENDING` | `BLOCKED` | P95 500msの反復測定とprobe timeout実行記録なし |
| NFR-002 | AUTO-003, AUTO-004 | T-HASH, T-PREF, T-PROBE, T-STORAGE | large synthetic fixture / host profiler | `PENDING` | `PENDING` | bounded memory、cancel、全resource解放の計測証跡なし |
| NFR-003 | ENV-004, PRIV-002 | T-HELP, T-PREF, T-SERVICE | local reference fixture / 機内モード4実機 | `PENDING` | `BLOCKED` | offline end-to-end / outbound 0の実機証跡なし |
| NFR-004 | AUTO-009, DIST-001 | dependency / Archive inspection | final Release Archive | `PENDING` | `BLOCKED` | Archive、lockfile、SBOM、license未照合 |
| NFR-005 | AUTO-005, AUTO-006, UI-DEV-005 | T-DIALOG, T-ENTRY | all error doubles / host + 実機 | `PENDING` | `PENDING` | 全入口のcode-key-action同一性を未実行 |
| NFR-006 | 全MEDIA / ENV / UI-DEV、DEV-IP15..LATEST | T-ENTRY, T-REGRESSION | 4固定実機 | `PENDING` | `BLOCKED` | device model / OS build / manifest checksum未固定 |

## 5. Acceptance Criteria

| AC | 検証ID | source候補 | fixture / environment | commit | 現在結果 | 未完了条件 |
| --- | --- | --- | --- | --- | --- | --- |
| AC-001 | MEDIA-001..003, DP-001..003 | T-PREF, T-STORAGE, T-SERVICE | MP4 / MOV / M4V reference / 4実機 | `PENDING` | `BLOCKED` | reference fixture未作成、destinationと実機未実行 |
| AC-002 | MEDIA-010..015 | T-PREF, T-DIALOG | guidance-only全ID、random / truncated / protected-looking | `PENDING` | `BLOCKED` | 全artifact / double未登録、未実行 |
| AC-003 | MEDIA-006, MEDIA-008 | T-PROBE, T-DIALOG | unsupported codec / truncated MP4 | `PENDING` | `BLOCKED` | 実fixtureのprobe / dialog証跡なし |
| AC-004 | MEDIA-007 | T-PROBE, T-DIALOG | random bytes MP4 | `PENDING` | `BLOCKED` | fixture未作成、禁止表現未実行確認 |
| AC-005 | ENV-003 | T-PREF, T-DIALOG | provider / missing / denied doubles + 実機 | `PENDING` | `BLOCKED` | File Provider実機証跡なし |
| AC-006 | MEDIA-009 | T-PREF, T-DIALOG | protected media double | `PENDING` | `BLOCKED` | versioned doubleと実行証跡なし |
| AC-007 | AUTO-005, AUTO-006 | T-UI, T-ENTRY, T-SERVICE | picker cancel double / host | `PENDING` | `PENDING` | freeze commitで未実行 |
| AC-008 | AUTO-004, AUTO-006, MEDIA-006..009 | T-SERVICE, T-ENTRY | failure doubles / host | `PENDING` | `BLOCKED` | 実fixture failureとDB / file差分証跡なし |
| AC-009 | AUTO-005, AUTO-006 | T-UI, T-ENTRY | new-record success / failure doubles | `PENDING` | `PENDING` | 入力値・旧candidate保持を未実行 |
| AC-010 | AUTO-004, AUTO-006 | T-SERVICE, T-ENTRY | attach / relink failures | `PENDING` | `PENDING` | 全保持対象のDB snapshot証跡なし |
| AC-011 | AUTO-004, AUTO-006 | T-SERVICE, T-ENTRY | replace failures | `PENDING` | `PENDING` | old path / timings / new reference不変を未実行 |
| AC-012 | AUTO-005, AUTO-006, MEDIA-017 | T-TIMELINE, T-SERVICE, T-ENTRY | timeline fixtures / host + 実機 | `PENDING` | `BLOCKED` | 3種timeline fixture未作成・実機未実行 |
| AC-013 | AUTO-004 | T-REPO, T-SERVICE | exact boundary / 1ms short / negative doubles | `PENDING` | `PENDING` | commit時最新値の実行証跡なし |
| AC-014 | MEDIA-016 | T-UI, T-PREF, T-SERVICE | external-conversion-equivalent fixture / 4実機 | `PENDING` | `BLOCKED` | fixture未作成、再selection end-to-end未実行 |
| AC-015 | AUTO-003 | T-PROBE, T-PREF | probe stage doubles / host | `PENDING` | `PENDING` | 全入口の同一実装と全stageを未実行 |
| AC-016 | AUTO-004, MEDIA-001..005, DP-001..003 | T-STORAGE, T-SERVICE | reference fixtures / 4実機 | `PENDING` | `BLOCKED` | copy / protection / backup / destination probe統合証跡なし |
| AC-017 | ENV-001, ENV-008 | T-STORAGE, T-SERVICE, T-CRASH | checksummed source / 4実機 | `PENDING` | `BLOCKED` | success / fail / cancel / background / crashの実測なし |
| AC-018 | AUTO-004, ENV-008 | T-STORAGE, T-CRASH | tmp / orphan / crash doubles | `PENDING` | `PENDING` | 24時間境界と完全snapshotをfreeze commitで未実行 |
| AC-019 | AUTO-004 | T-SERVICE, T-REPO | transaction / CAS / concurrency doubles | `PENDING` | `PENDING` | 全atomicity test未実行 |
| AC-020 | AUTO-005, ENV-004 | T-HELP | bundled help / host + 機内モード実機 | `PENDING` | `BLOCKED` | 全必須文言とoffline実機証跡なし |
| AC-021 | AUTO-005, DIST-001 | T-HELP, T-DIALOG, source / Archive inspection | final commit + Archive | `PENDING` | `BLOCKED` | browser / Store / Deep Link / Share / source引渡し不在の最終監査なし |
| AC-022 | PRIV-002 | network / queue observation | Release build / network観測環境 | `PENDING` | `BLOCKED` | 操作中・再起動・SDK flush後の0件証跡なし |
| AC-023 | PRIV-001 | release diagnostic observation | synthetic canary / Release build | `PENDING` | `BLOCKED` | canary / event非露出の証跡なし |
| AC-024 | PRIV-003, UI-DEV-001 | T-DIALOG, T-HELP, snapshot / artifact inspection | canary filename / 4実機 | `PENDING` | `BLOCKED` | dialog / help / snapshot / artifact監査なし |
| AC-025 | UI-DEV-001 | T-IOS + snapshot inspection | background / inactive / 4実機 | `PENDING` | `BLOCKED` | privacy overlayの実snapshot証跡なし |
| AC-026 | AUTO-007, UI-DEV-002..004 | T-LAYOUT, T-DIALOG, T-HELP, T-LOAD | accessibility matrix / 4実機 | `PENDING` | `BLOCKED` | VoiceOver等の実機matrix未実行 |
| AC-027 | AUTO-005, AUTO-006, UI-DEV-005 | T-DIALOG, T-ENTRY | all entry-point error doubles | `PENDING` | `PENDING` | 5入口のcode / resource / component同一性未実行 |
| AC-028 | AUTO-006, PLAY-001 | T-REGRESSION | reference fixtures / 4実機 | `PENDING` | `BLOCKED` | 全既存操作の実機回帰なし |
| AC-029 | AUTO-004, ENV-001 | T-LEGACY, T-STORAGE, T-SERVICE | legacy DB / external source / host + 実機 | `PENDING` | `PENDING` | original hashと工程時刻保持の実行証跡なし |
| AC-030 | AUTO-009, DIST-001 | dependency / binary / SBOM inspection | final Release Archive | `PENDING` | `BLOCKED` | Archive / SBOM / license未作成・未照合 |
| AC-031 | ENV-004 | T-HELP, T-PREF, T-SERVICE, T-REGRESSION | local reference fixture / 機内モード4実機 | `PENDING` | `BLOCKED` | offline end-to-end実機証跡なし |
| AC-032 | AUTO-003, AUTO-005 | T-PREF, T-UI, T-ENTRY | cancel / reselection / dispose race doubles | `PENDING` | `PENDING` | 全古いcallback経路を未実行 |
| AC-033 | AUDIO-001, AUDIO-002 | T-PROBE, T-STORAGE | audio fixtures / speaker・BT・AirPlay | `PENDING` | `BLOCKED` | physical route漏出確認なし |
| AC-034 | AUTO-001..008 | all automated suites | fixed SDK / host + iOS test destination | `PENDING` | `PENDING` | analyze、既存全test、新規testの確定runなし |
| AC-035 | AUTO-003, AUTO-004, ENV-006 | T-PREF, T-HASH, T-STORAGE, T-SERVICE | same-size / same-mtime replacement double | `PENDING` | `PENDING` | public bypass、4者hash、lease連続性を未実行 |
| AC-036 | AUTO-004, AUTO-008, DP-001..004 | T-PROTECTED, T-IOS | legacy/new storage / 4実機 | `PENDING` | `BLOCKED` | 全対象・全DB family lifecycleの実機read-backなし |
| AC-037 | AUTO-004, AUTO-008, ENV-007 | T-PROTECTED, T-IOS, T-SERVICE | locked device / 4実機 | `PENDING` | `BLOCKED` | lock中禁止、DB不変、明示再試行の実機証跡なし |
| AC-038 | AUTO-003..006, UI-DEV-005 | T-PREF, T-STORAGE-ERR, T-DIALOG, T-ENTRY | all error / unknown-value doubles | `PENDING` | `PENDING` | domain / internal reason / message / actions / presentation / suffixの完全写像runなし |
| AC-039 | AUTO-004 | T-SERVICE, T-PROTECTED | post-commit refresh / cleanup fault doubles | `PENDING` | `PENDING` | logical / maintenance直交と参照file保持を未実行 |
| AC-040 | AUTO-003, AUTO-005, UI-DEV-002 | T-LOAD, T-PREF, T-UI | delayed / cancel doubles + VoiceOver | `PENDING` | `BLOCKED` | 500ms、実phase、通知1回、lease解放の統合証跡なし |
| AC-041 | AUTO-003, MEDIA-010..015 | T-PREF | displayName/path mismatch、uppercase、no extension doubles | `PENDING` | `PENDING` | picker / preflight / storage同一正規化の確定runなし |
| AC-042 | MEDIA-001, MEDIA-004, MEDIA-005, AUDIO-001..003 | T-PROBE, T-STORAGE | stereo / mono / no-audio fixtures / 4実機 | `PENDING` | `BLOCKED` | audio fixtures未作成、登録後reviewとmute実機未実行 |
| AC-043 | AUTO-004 | T-REPO, T-SERVICE | timing concurrency double / host | `PENDING` | `PENDING` | duration後の工程時刻更新競合runなし |
| AC-044 | PRIV-001, PRIV-002, DIST-002 | manifest / API / network / diagnostic inspection | final Archive + Release build | `PENDING` | `BLOCKED` | metadata一式、実挙動、privacy承認なし |

## 6. Release判定時の更新手順

1. 検証対象commit、build、fixture manifest SHA-256、4実機を[TestMatrix-v1.1.md](TestMatrix-v1.1.md)でfreezeする。
2. 各検証IDを実行し、Run IDとsanitize済み証跡を記録する。
3. 本表の各行へRun IDを追記し、要件の全条件を満たした行だけを`PASS`へ変更する。
4. 実行可能要件をmanual承認のみで`PASS`にしない。部分成功は`PENDING`または`BLOCKED`のままにする。
5. 全92件（FR 35件、UI 7件、NFR 6件、AC 44件）が証跡付き`PASS`となるまでRelease Gateを承認しない。

現在はfreeze commit、実fixture、固定実機、privacy観測、最終Archiveがないため、総合判定は**BLOCKED**である。
