# 白内障執刀ノート

## 分析グラフ横軸モード改善 要件定義書

- 文書版：2.0（全面改訂版）
- 対象プロジェクト：`cataract_surgery_note`
- 対象画面：分析画面（`AnalysisScreen`）、時間推移グラフ（`SurgeryTrendChart`）
- 基準コード：`030fc02`（確認時点の `main`）
- 初版作成日：2026年8月23日
- 改訂日：2026年8月27日
- ステータス：改訂案・レビュー待ち。承認前は実装へ着手しない

---

## 0. 本書の位置付け

本書は、総手術時間および個別工程時間の推移グラフについて、横軸の意味、横座標、ラベル、選択操作および表示モードを改善するための要件を定義する。

本書は、次の既存要件を補足する差分要件である。

- `docs/requirements/design_ux_update_requirements.md` の R10「分析」
- `docs/requirements/process_chart_detail_button_jump_requirements.md`
- `docs/requirements/process_chart_video_direct_jump_requirements.md`

`process_chart_detail_button_jump_requirements.md` と `process_chart_video_direct_jump_requirements.md` が、グラフ上の起動操作、選択カード、案内文またはSemanticsについて矛盾する場合は、後発差分である `process_chart_detail_button_jump_requirements.md` を優先する。本書は旧来の「点をactivateして直接遷移する」仕様を復活させない。

横軸のモード、domain、正規化座標、tick／label、chart interaction rectangle、hit-test、症例別選択領域、症例順表示、選択カードの位置表示、同日cluster案内、marker密度、Semantics value／increasedValue／decreasedValueおよび本改善に伴うfocus遷移については本書を優先する。既存の症例別縦帯geometryと位置表示のテストは、本書の決定的な選択規則と `n / R`、`k / M` の契約へ改訂する。次の既存契約は本書によって変更しない。

- グラフ上のタップは症例選択だけを行う
- 前後操作と VoiceOver の増減操作は症例選択だけを行う
- 選択カードのボタンから症例詳細または個別工程動画へ進む
- 動画導線の識別には `recordId` と `step.storageId` を使用する
- グラフは1つの adjustable Semantics node とする
- Snapshot取得、横軸操作および症例選択は読み取り専用とし、工程行作成、DB更新および動画アクセスを行わない。個別工程で利用者が選択カードのボタンを明示的に押した後だけ、既存要件に従う動画状態確認へ移る
- Light／Dark、文字倍率、対応端末、画面方向、Split View、動的リサイズ、コントラストおよびデータ保全に関する共通要件を維持する

縦軸スケール、縦軸目盛り、縦軸ラベルおよび横グリッド線は本書の対象外である。`docs/requirements/analysis_chart_duration_axis_scale_requirements.md` が承認された場合、縦軸については同書を適用する。

本書は2026年8月23日作成の「グラフ横軸改善 要件定義書」文書版1.0を全面的に置き換える。旧版と矛盾する場合は本書を優先する。

本書の「必須」「する」「しない」「維持する」「してはならない」は、実装および受け入れの必須条件である。「推奨」は、不採用の場合に理由と代替策を実装完了報告へ記載する事項である。

本書の完成は要件確定を意味し、実装完了または配布可能を意味しない。

---

## 1. v1.0からの主な改訂

| 論点 | v2.0での決定 |
|---|---|
| 分析対象の意味 | 生涯の経験症例数ではなく、アプリへ登録された症例の範囲内の推移とする |
| 臨床的な解釈 | 手術時間から手術成績、技術水準または臨床アウトカムを判定しない |
| 日付データ | 「手術日時」ではなく、時刻を持たない「手術日」とする |
| 横軸名称 | UIの正式名称を「症例順」「時系列」とする |
| 症例順 | 全登録症例を `surgeryDate → createdAt → recordId` の昇順で並べた派生順位とする |
| 件数 | 全登録症例の組 `(R, n)` と、選択指標の有効点列の組 `(M, k)` を分離する。表示順は `n / R`、`k / M` とする |
| 時系列domain | 選択指標の有効点ではなく、全登録症例の手術日と基準日から決定する |
| 同日症例 | 同じ `xRatio` へ置き、架空の手術時刻や横方向jitterを与えない |
| 将来日 | 除外または現在へclampせず、基準日とともにdomainへ含める |
| 欠損 | 0秒を生成せず横位置を保持し、有効観測間の線だけを接続する |
| 高密度表示 | 有効観測をsamplingせず、非選択markerの視覚的省略だけを許容する |
| 動画導線 | 「グラフで選択→選択カードのボタンで遷移」という現行仕様を正式に継承する |
| モード保持 | 同一画面route内だけ保持し、v2.0では永続化しない |

---

## 2. 背景と目的

### 2.1 アプリの振り返りサイクル

本アプリは、術者本人が次のサイクルを安全かつ短時間で完了するためのローカル専用アプリである。

1. 症例と動画を登録する
2. 動画を見ながら総手術時間と個別工程時間を記録する
3. 時間の推移を確認する
4. 動画、自己評価、反省点から変化の理由を振り返る
5. 次の症例で意識する

分析グラフはこのうち「時間の推移を確認する」入口であり、数値を見た後に実際の症例と動画へ戻れることを重視する。

### 2.2 現状の課題

現行グラフは、選択指標について有効な時間を持つ症例だけを手術日順に並べ、横方向へ等間隔で配置している。横軸ラベルには手術日を表示するが、実際の暦日間隔は横方向の距離へ反映していない。

この構成には次の課題がある。

- 選択指標の未計測症例が除外された後の通し位置となり、総手術時間と各工程で同一症例の横位置が一致しない
- 登録済み症例全体の中で何番目に位置する症例かを把握できない
- 長期間の空白と短期間に集中した登録を横方向の距離から区別できない
- 日付ラベルは確認できるが、症例順による変化と暦日経過による変化を切り分けられない

### 2.3 目的

本改善では、横軸を次の2つの観点で切り替えられるようにする。

1. **症例順**：登録済み症例全体を手術日基準で並べた表示用順位に沿って変化を確認する
2. **時系列**：実際の手術日の暦日間隔に沿って変化と空白期間を確認する

各モード内で、総手術時間とすべての個別工程が同じ全登録症例catalog、同じ症例IDおよび同じ横軸domainを共有する。症例順モードと時系列モードどうしが同じ型または数値範囲のdomainを持つという意味ではない。

### 2.4 解釈上の制限

本画面は、アプリに登録された症例の範囲で、総手術時間および個別工程時間の推移を振り返るための補助機能である。

次を意味するものではない。

- 術者の生涯執刀件数
- 同日における実際の執刀順
- 手術技術の優劣または習得度
- 手術成績、合併症、視力予後その他の臨床アウトカム
- 時間短縮が臨床的に望ましいという評価
- 観察された変化が経験症例数によって生じたという因果関係

UI、ヘルプ、Semanticsおよび配布文言で、症例順を「生涯の第n症例」「実際の経験症例数」または「アプリへ登録操作した順番」等と表現してはならない。

---

## 3. 検証済みの現状

### 3.1 手術日は時刻を持たない

症例作成および症例編集では、選択された日付を入力／model上でローカルの `DateTime(year, month, day)` へ正規化し、元の時分秒を保持しない。DB上の物理表現は§3.1末尾のとおりepoch millisecondである。

- `createdAt` はアプリへの登録日時であり、手術時刻ではない
- `updatedAt` は更新日時であり、手術順の判定に使用しない
- 同日内の実際の執刀順は現行データから復元できない

現行DBは日付をepoch millisecondとして保持するため、端末timezoneを変更した場合に既存の手術日のローカル解釈が変わり得る。この既存保存形式の解消は本書の対象外とする。本書のcalendar-day計算は、同一Snapshotで既存modelから取得した `surgeryDate` の年月日を使用し、さらにDSTや時刻差による距離の歪みを加えないことを保証する。

### 3.2 現行の安定した並び順

分析取得とdomain計算は、現在次の順序を使用している。

1. `surgeryDate` 昇順
2. `createdAt` 昇順
3. `recordId` のlocale非依存なbinary文字列昇順

本書はこの順序を正式な表示用順序として固定する。

### 3.3 現行Snapshotの制約

現行の `SurgeryAnalysisSnapshot` は、全登録症例数と工程measurementを返すが、工程行のない症例を含む全登録症例の順序付きmetadataを返さない。

そのため、現行Snapshotの `recordCount` と、有効measurementから得た一意な `recordId` だけを使って、欠損症例を含む正しい症例順をUI側で推測してはならない。

### 3.4 現行の有効点

現行グラフは、選択指標について開始位置と終了位置が存在し、終了位置が開始位置より後であるmeasurementだけを有効点とする。

- 未入力、開始のみ、終了のみ、0秒、逆転した時間は点にしない
- 明示的skipは0秒の点にしない
- 総手術時間がない場合に個別工程の合計から推定しない
- 旧工程と未知工程を現在の分析指標へ含めない

### 3.5 現行の選択と遷移

- グラフ上の点、線または空白のタップは最寄りの有効点を選択する
- グラフタップ、前後選択およびVoiceOver増減だけではrouteを生成しない
- 総手術時間では選択カードのボタンから症例詳細画面を開く
- 個別工程では選択カードのボタンから安全な事前確認後に対象工程動画を開くか、症例詳細へfallbackする
- 選択identityは `recordId` である

本改善ではこれらを維持する。

---

## 4. 用語と正式なデータ定義

### 4.1 登録症例

「登録症例」は、`surgery_records` に現在存在する1行を指す。

工程記録、総手術時間、動画、`reviewStatus`、レビューschema、自己評価、反省点または症例メモの有無や値によって、登録症例の母集団から除外してはならない。

### 4.2 全登録症例catalog

「全登録症例catalog」は、同一の分析Snapshotに含まれる全登録症例の軽量metadataを、§5の正式な順序で並べた列を指す。

各要素は少なくとも次を論理的に識別できること。

- `recordId`
- `surgeryDate`
- `createdAt`
- `eyeSide` のraw保存値と、既知enumへdecodeしたnullable値または同等の明示的なunknown状態
- 症例順 `n`

具体的なclass名や内部表現は本書で固定しない。

### 4.3 症例順

「症例順」は、全登録症例catalogへ1から順に付与する表示用の整数を指す。アプリへの登録操作順ではなく、手術日を第一キーにした§5の派生順位である。

- 1始まりである
- 全登録症例に対して連続する
- 同一Snapshot内で一意である
- DBへ保存しない派生値である
- 症例の永続identityまたはroute intentとして使用しない

### 4.4 有効観測と症例点

「有効観測」は、次をすべて満たす1症例・1指標のmeasurementを指す。この定義を `M`、`k`、初期選択、最新値、直前最大5件平均、折れ線、marker、前後操作、Semanticsおよび動画導線候補へ共通して用いる。

- 選択指標と `step.storageId` が一致する
- 対応するcatalog要素の `eyeSide` が既知の値へdecodeできる
- `isSkipped != true` である
- `startMilliseconds` と `endMilliseconds` がともに存在する
- `endMilliseconds > startMilliseconds` である
- 差分が `1...9,223,372,036,854,775` millisecondsの範囲内にあり、現行の安全な `Duration` 表現を超えない

分析Snapshotの論理measurement契約には、明示的skipを古い不正データでも判定できるよう、少なくとも `isSkipped` または同等の状態を含める。skip時刻が通常はnullへ保存されることだけへ依存してはならない。

「症例点」は、有効観測がグラフdomain上に持つ論理座標を指す。高密度表示でmarker glyphが省略されても、症例点は有効観測列、折れ線、選択順および集計に残る。

### 4.5 marker

「marker」は、症例点の座標に描く円等の視覚要素を指す。markerの非表示は有効観測の除外を意味しない。

### 4.6 件数と位置

本書では次の4値を区別する。

| 記号 | 意味 |
|---|---|
| `R` | 全登録症例数 |
| `n` | 選択症例の症例順。`1 <= n <= R` |
| `M` | 選択指標について有効観測を持つ症例数 |
| `k` | 選択症例の有効点列中の位置。`1 <= k <= M` |

データ組 `(R, n)` と `(M, k)` を同じ「症例位置」として表示または読み上げてはならない。分数形式で表示する場合は、必ず位置を先にして `n / R`、`k / M` とする。

### 4.7 手術日

本書の「手術日」は、時刻を持たないローカル暦日の年月日を指す。「手術日時」「手術時刻」と呼ばない。

### 4.8 基準日

「基準日」`referenceDate` は、分析画面が表示基準として保持する端末ローカルの暦日を指す。同じローカル暦日かつ同じtimezone contextの間は固定し、§8 T-8の更新条件でだけ再確定する。catalogとmeasurementから成るdata Snapshotとは別の表示contextであり、日付変更だけを理由にDBを再取得する必要はない。

「timezone context」は、OSが返すtimezone identifierを指す。UTC offset単独をidentifierとして使用せず、同じtimezone内のDSTによるoffset変化をtimezone変更と誤認しない。data Snapshot取得の開始前とdecode完了後にidentifierを照合し、途中で変化していた場合は結果を表示せず、1回再取得する。再取得中にも変化した場合は既存の再試行可能な分析エラー状態とする。

### 4.9 calendar-day ordinal

「calendar-day ordinal」は、年月日を連続した整数日へ変換した値を指す。時刻、UTC offsetまたはDSTによる1日の長さへ依存してはならない。

### 4.10 横軸モード

横軸モードの正式なUI名称と論理名称は次とする。

| UI名称 | 論理名称 | 意味 |
|---|---|---|
| 症例順 | `caseOrder` | 全登録症例catalog上の症例順に基づく等間隔軸 |
| 時系列 | `chronological` | 手術日の暦日間隔を反映する連続軸 |

論理名称は実装classやenumの厳密な識別子を拘束しない。ただし `date` だけの名称で両モードを表してはならない。

---

## 5. 全登録症例の並び順と再計算

### O-1. 正式な比較順

全登録症例は、次のキーを上から順に比較して昇順に並べる。

1. `surgeryDate`
2. `createdAt`
3. `recordId` のlocale非依存なbinary文字列昇順

`surgeryDate` はDateTime instantではなく `(year, month, day)` のcalendar tuple、`createdAt` は保存済みtimestampとして比較する。`recordId` の比較へ言語、地域または大文字小文字を無視するcollationを使用しない。同値時の比較キーを実装ごと、画面ごと、指標ごとに選択してはならない。`updatedAt`、工程行の作成日時、動画ファイル名、表示中の点数またはDBの未指定行順を使用してはならない。

### O-2. 同日内の意味

同じ手術日を持つ症例では、`createdAt` と `recordId` は表示を決定的にするtie-breakにすぎない。実際の執刀時刻または執刀順を表すとは案内しない。

### O-3. 症例順の付与

全登録症例catalogの先頭を1とし、末尾まで連続した `n` を付与する。

```text
ordinal(record) = 1 + 正式な比較順でrecordより前に並ぶ登録症例数
```

### O-4. 非永続化

`n` をDBカラム、SharedPreferences、ファイルまたはその他の永続領域へ保存してはならない。

### O-5. 再計算

次の後に新しい分析Snapshotを取得した場合、`R` と全症例の `n` を再計算する。

- 新規症例登録
- 過去日の症例追加
- 症例削除
- 手術日の編集
- 旧データ読み込みによる登録症例catalogの変化

再計算前後の同一症例判定には `recordId` を使用する。

### O-6. 同一Snapshot

全登録症例catalog、`R`、各症例の `n` および工程measurementは、同一の論理的な分析Snapshotから導出する。

別時点で取得した症例一覧Providerと工程measurementをUI層で合成し、追加・削除・日付編集の途中状態から順位を作ってはならない。

論理Snapshotの取得は、次のいずれかで原子的に行う。

1. catalogと必要なmeasurementを1つのSQL statementで取得する
2. 複数statementが必要な場合は、すべてを同じread transaction内で実行し、同じDB snapshotを参照する

一部のqueryだけが成功した結果を返してはならない。取得、decode、整合性検証のいずれかが失敗した場合はSnapshot全体を失敗させ、既存の分析エラー状態と再試行導線を表示する。

---

## 6. 横軸モードの共通契約

### X-1. 提供モード

分析グラフは「症例順」「時系列」の2モードを提供する。

### X-2. 初期モード

新しい `AnalysisScreen` routeを開いた時の初期モードは、常に「症例順」とする。

### X-3. 共通domain

同一Snapshotかつ同一モード内では、総手術時間とすべての個別工程で横軸domainを共有する。選択指標の有効点が欠けることを理由にdomainを縮小してはならない。

### X-4. 同一症例位置

同じ `recordId` は、選択指標にかかわらず同一モード内で同じ `xRatio` を持つ。縦軸ラベル幅等によって各グラフのplot rectangleが異なる場合、画面上の絶対pixel座標まで一致することは要求しない。

### X-5. 選択identity

モード切替前後で、選択中の有効点の `recordId` を維持する。モードは表示属性であり、症例identityの一部ではない。

### X-6. 縦軸と集計の不変

横軸モードを切り替えても、次を変更してはならない。

- 各症例点の所要時間
- 縦座標
- 縦軸scaleとtick
- 最新値
- 直前最大5件平均
- 差分
- 有効観測の採否

### X-7. 全件俯瞰

両モードとも、全domainを横スクロールなしで一画面へ表示する。横方向のzoom、pan、範囲選択またはページングを追加しない。

---

## 7. 症例順モード

### C-1. domain

症例順モードの横軸domainは、選択指標の有効点数にかかわらず `1...R` とする。

### C-2. 座標

plot左端を `L`、右端を `Q` とする。

`R == 1` の場合、唯一の登録症例のx座標を中央に置く。

```text
xRatio = 0.5
x = L + (Q - L) * xRatio
```

`R >= 2` の場合、症例順 `n` の症例のx座標を次で算出する。

```text
xRatio = (n - 1) / (R - 1)
x = L + (Q - L) * xRatio
```

### C-3. 欠損位置

選択指標の有効観測がない症例を理由にdomainまたは `n` を詰めてはならない。

例として、症例順98・100の症例だけがCCCの有効時間を持つ場合、CCCグラフの点はそれぞれ `n = 98` と `n = 100` の位置へ置く。症例順100の症例をCCCの「99症例目」へ置き換えない。

### C-4. ラベル

横軸ラベルは症例順の整数を表示する。軸または切替UIから「症例順」であることを認識できなければならない。

- 候補間隔 `I` は `1, 2, 5 × 10^p`、すなわち `1, 2, 5, 10, 20, 50, ...` から昇順に選ぶ
- 各 `I` の候補集合は `{1, R}` と、`1 < mI < R` を満たす正の倍数 `mI` の和集合とし、重複を除く
- 候補数を式から先に算出し、32件を超える集合を生成してはならない
- 現在のplot幅、文字倍率、文字方向およびラベル実測幅に対し、全ラベルがchart layout内へ収まり、隣接するlabel bounds間に8 logical pixels以上の間隔を確保できる最小の `I` を採用する
- 端のlabelはchart layout内へ収まるようedge-alignしてよいが、domain上のtick座標は変更しない
- `1` と `R` が同時に収まる候補がない場合は `{R}` だけを表示する。`R == 1` では `{1}` を表示する
- ラベルは有効点indexではなく `1...R` のdomain上へ配置する
- `1...R` の全整数ラベルを生成した後に間引いてはならない

例として `R = 37` で `I = 10` が最初に収まる場合、表示候補は `1, 10, 20, 30, 37` とする。

---

## 8. 時系列モード

### T-1. 基準日

`referenceDate` は、新しい分析画面routeで最初のdata Snapshotを正常にcommitする時、注入可能なclockから端末ローカルの年月日として確定する。その後は§8 T-8の成功条件またはclock／timezone変更条件でだけ再確定する。同じローカル暦日とtimezone contextの間は固定し、widgetの再buildごとに現在時刻を読み直して座標またはラベルを揺らしてはならない。

### T-2. domain

全登録症例の最古手術日を `oldestDate`、最新手術日を `latestDate` とする。

```text
domainStart = min(referenceDate, oldestDate)
domainEnd   = max(referenceDate, latestDate)
```

選択指標の欠損値を理由に `domainStart` または `domainEnd` を変更してはならない。

全症例が過去日の場合、最新手術日から `referenceDate` までの点がない区間を右側へ意図的に残す。この余白は「最後の登録症例以後、現在まで登録症例がない期間」を表し、欠損measurementを表すものではない。基準日が進めば、同じdata Snapshotでも過去症例の `xRatio` が変化し得る。

### T-3. 座標

`domainStart == domainEnd` の場合、全症例のx座標を中央へ置く。

```text
xRatio = 0.5
```

それ以外の場合は、calendar-day ordinalを用いて次で算出する。

```text
xRatio =
  (dayOrdinal(surgeryDate) - dayOrdinal(domainStart))
  / (dayOrdinal(domainEnd) - dayOrdinal(domainStart))
```

ローカル0時のepoch millisecond差を日数として使用してはならない。DST等による23時間または25時間の日を横方向へ異なる長さで描画しない。

### T-4. 将来日

将来日の登録症例を除外、現在位置へclamp、過去日として表示、または分析対象外にしてはならない。

- `referenceDate` と将来日の両方をdomainへ含める
- `referenceDate` は「現在」と表示する
- 将来側は「q日後」「q週間後」「qか月後」「q年後」等と表示する
- 将来日を禁止する場合は、症例登録・編集validationの変更を伴う別要件とする

### T-5. 相対ラベル

横軸ラベルは `referenceDate` との関係を日本語で表示する。

- 同日：`現在`
- 過去：`q日前`、`q週間前`、`qか月前`、`q年前`
- 未来：`q日後`、`q週間後`、`qか月後`、`q年後`

ラベルは症例点にだけ付けるのではなく、連続する時間domainのtickとして生成する。

相対labelの `q` は、`referenceDate` から移動した基礎単位の総数を表す正整数であり、症例順 `n` とは別の値である。例えば3か月間隔の最初のtickは「3か月前／後」、2年間隔の最初のtickは「2年前／後」とする。任意の日付差を30日または365日で割って月・年へ丸めてはならない。

### T-6. tick間隔

tick間隔の候補は、次の記載順を細かい順として選ぶ。

```text
1日、1週間、1か月、3か月、6か月、1年、2年、5年
```

- 全tickは `referenceDate` をanchorとして過去側と未来側へ生成し、`referenceDate` 自身を `現在` として必ず含める
- 日tickはanchorから正負のcalendar day、週tickは7 calendar daysの正負の倍数で求める
- 月tickと年tickは、anchorの年月日から正負の暦月数または暦年数を直接加減する。移動先に同じ日がなければその月の末日へclampし、各tickを常にanchorから独立して計算して月末clampの累積driftを起こさない
- 5年より粗い間隔が必要な場合は、`1, 2, 5 × 10^p` 年の規則で10年、20年、50年等へ拡張する
- 各候補間隔について、domain内のtick数を式から先に求める。32件を超える候補列を生成せず、次の粗い間隔へ進む
- 現在のplot幅、文字倍率、文字方向およびラベル実測幅に対し、全label boundsがchart layout内へ収まり、隣接bounds間に8 logical pixels以上の間隔を確保できる最も細かい候補を採用する
- 任意のdomain端は、anchorから求めたtickと一致しない限りラベル追加を要求しない。端の正確な症例日は選択カードとSemanticsで確認できるようにする
- 端のlabelはchart layout内へ収まるようedge-alignしてよいが、tickの `xRatio` は変更しない
- ラベル選択結果を「妥当」という目視判断だけで決めず、同じ入力から同じ結果を返す決定的な規則とする

例として `referenceDate = 2024-03-31` の1か月tickは、`2024-02-29` を「1か月前」、`2024-04-30` を「1か月後」、`2024-05-31` を「2か月後」とする。2か月後を4月30日から連鎖的に求めて5月30日としてはならない。`referenceDate = 2024-02-29` の1年tickでは、`2023-02-28` を「1年前」、`2025-02-28` を「1年後」とする。

### T-7. 正確な日付

時系列モードでも、選択カードとSemanticsには正確な手術日を表示する。相対ラベルだけを症例の詳細情報として使用しない。

### T-8. 基準日の更新

次の場合に `referenceDate` を再確定する。

- 分析画面への新規入場で、最初のdata Snapshotをcommitする時
- pull-to-refresh、Provider invalidation、症例詳細または工程レビューからの復帰等により、新しいdata Snapshotを正常にcommitする時
- appがforegroundのままローカル暦日が変わったことを検知した時
- foregroundへのresume、platformのsystem clock通知または後述の監視により、timezone identifierは同じままローカル暦日の変化を検知した時
- timezone identifierの変化を検知して開始したcontext refreshが成功し、新しいdata Snapshotと表示contextをcommitする時

timezone identifierが同じままrefreshまたは自動再取得が失敗し、従前のstable data Snapshotを表示し続ける場合は、取得試行の開始時刻で `referenceDate` を変更しない。ただし、同時にclock監視から暦日変更を検知した場合は、従前のdata Snapshotに対する暦日更新だけを適用する。

ローカル暦日だけが変わった場合は、取得済みのcatalogとmeasurementを再利用してdomain、tickおよび `xRatio` を再計算し、DB再取得を要求しない。timezone identifierが変わった場合は、§3.1の既存保存形式による日付解釈の変化を反映するため、新しいdata Snapshotを取得する。

timezone identifier変更時は、次を1つの表示bundleとして原子的にcommitする。

- 新timezone identifierと、そのcontextで取得した `referenceDate`
- 新timezoneでdecodeしたdata Snapshotと全登録症例catalog
- 再sortした `R`、`n`、各指標の `M`、`k`
- 両modeのdomain、tick、`xRatio` およびmarker geometry
- `recordId` で維持またはfallbackした選択

context refresh中は、旧timezone identifier、旧 `referenceDate`、旧data Snapshotおよび旧geometryから成る従前bundleを更新中表示とともに維持するか、既存のloading状態を表示する。新 `referenceDate` だけを旧catalogへ適用する等、新旧contextを混在させてはならない。context refreshが失敗した場合は従前graphを現在値として表示し続けず、既存の再試行可能な分析エラー状態へ移る。再試行成功時に新bundle全体をcommitする。

分析画面routeがforegroundかつactiveである間は、次を満たすclock schedulerを稼働させる。

1. active化またはresume時に現在のローカル暦日とtimezone identifierを直ちに比較する
2. `now + 24時間` ではなく次のローカルcalendar dayの0時を対象とするone-shotを予約し、発火時にclockを再読して更新後、次回分を再予約する
3. platformのclock／timezone変更通知を監視する。通知を利用できない、または通知漏れを検出するfallbackでは、60秒以下の間隔で比較し、foreground中の変更を実時間60秒以内に反映する
4. system clock／timezone変更の検知、手動refresh成功またはresume後は、既存予約を取消して現在値から再armする
5. routeが非active、backgroundまたはdisposeになった時はtimer／subscriptionを解除し、resume時に再比較する

clock、timezone contextおよびschedulerには、fake clockとfake schedulerで発火、再arm、取消および許容遅延を自動テストできる注入境界を設ける。theme変更、文字倍率変更、回転、resize、または同じ暦日内の通常の再buildだけでは更新しない。

個別工程動画の遷移前確認busy中に更新条件へ達した場合、暦日更新またはtimezone context refreshの開始と表示上のcommitをbusy解除後まで保留する。busy開始時に固定したモード、`recordId`、`step.storageId`、旧表示bundleおよびroute intentは変更しない。

---

## 9. 同日症例と選択規則

### D-1. 同日cluster

時系列モードでは、`surgeryDate` のcalendar-day ordinal、すなわちローカル年月日が同じ有効点を同一日clusterとする。DateTime instantまたは時刻成分で同日を判定しない。cluster内の全点を同じ `xRatio` へ配置する。

同日症例へ架空の手術時刻または横方向jitterを与えてはならない。

### D-2. cluster内順序

同日cluster内の論理順、折れ線の接続順、前後選択順は症例順 `n` の昇順とする。同じx上の縦方向の線分は、決定的な表示順で有効点を結んだ結果にすぎず、同日内の実際の執刀順、時刻差または時間的推移を表さない。

選択指標について、同じcalendar-day ordinalを持つ有効点が2点以上ある日が1日以上存在する場合に限り、グラフ付近へ次と同等の意味を持つ説明を表示する。

> 同日の症例は同じ横位置に表示されます。前後のボタンで各症例を確認できます。

### D-3. pointerによる選択

「chart interaction rectangle」は、`SurgeryTrendChart` のpainter／canvas領域全体を指す。軸label gutterは含み、画面見出し、横軸切替、グラフ外の案内、選択カードおよび遷移ボタンは含まない。

- gesture arenaでtapとして成立したtapだけを選択へ使用する。drag、縦scroll、scale、long press、cancelまたは生のpointer downだけでは選択を変更しない
- interaction rectangle外で成立したtapはグラフ選択として扱わない
- interaction rectangle内では、pointer座標のxとyをplot rectangleの各辺へclampして距離を計算する
- 軸label自体を別のinteractive targetにしない

clamp後のタップ位置は、次の順序で有効点を一意に決定する。

1. タップxとの画面上の距離が最小のx座標clusterを選ぶ
2. x距離が同値なら、より新しい手術日のclusterを選ぶ
3. cluster内でタップyとの画面上の距離が最小の有効点を選ぶ
4. y距離も同値で、現在選択中の点が候補に含まれる場合は選択を維持する
5. それ以外の同値では症例順 `n` が最大の点を選ぶ

症例順モードでは、最小x距離の有効点を選ぶ。同距離の場合は現在選択中の点を維持し、それ以外は `n` が大きい点を選ぶ。

### D-4. 到達性

同一座標へ重なる点を含め、全有効点へ次の操作から必ず到達できること。

- 前ボタン
- 次ボタン
- VoiceOver increment
- VoiceOver decrement

pointerは、完全同一座標の候補から上記規則による決定的な代表点を選ぶ。完全重複した全点をpointerだけで個別選択できることは要求しないが、支援技術および画面上の前後操作から到達不能にしてはならない。

### D-5. 欠損症例

有効観測がない症例の横位置はdomainへ残すが、選択可能なplaceholder、透明marker、0秒markerまたは独立したSemantics nodeを生成しない。

グラフの線または空白をタップした場合も、最寄りの有効点を選択する。

---

## 10. 欠損値、折れ線およびmarker

### V-1. 欠損値

§4.4の有効観測predicateを満たさないmeasurementには症例点を生成しない。特に次を含む。

- 開始位置なし
- 終了位置なし
- 開始位置と終了位置が同じ
- 終了位置が開始位置より前
- 明示的skip
- 選択指標の工程行なし
- 未知またはdecode不能な `eyeSide`
- 現行の安全なDuration表現範囲外

これらを0秒として描画または集計してはならない。ただし登録症例である限り、`R`、`n` および時系列domainの計算対象には残す。

### V-2. 折れ線

折れ線は、選択指標の有効点を症例順 `n` の昇順に並べ、隣り合う有効点同士を結ぶ。

`n` が連続していない場合も線を切断しない。欠損症例数または暦日の空白に応じた横方向距離は保持する。

線上に次を生成してはならない。

- 補間値
- 仮想の症例点
- tooltipまたは選択対象
- 平均や比較サマリーへ含める値

破線化、欠損ごとの線分断または欠損理由の可視化は本改善の対象外とする。

### V-3. 有効観測の保持

有効観測を、症例数、幅、モードまたは描画密度を理由にsampling、平均化、集約または除外してはならない。

全有効観測を次の母集団へ残す。

- 折れ線
- 選択順
- 前後操作
- VoiceOver増減
- 最新値、および最新点より前の最大5件だけを用いる既存の比較サマリー計算
- 個別工程動画導線の選択候補

### V-4. marker密度

各有効点について、plot rectangle上の実x・y座標から、最も近い別の有効点までのscreen-space Euclidean distance `d` をlogical pixelsで求める。`M == 1` では `d = +infinity` とする。

- `d >= 6` ではmarkerを描画する
- `d < 6` の非選択markerは描画しない
- 24／12／6 logical pixelsを境界とする現行marker sizeの段階表現は、`d` に基づく段階表現として維持してよい
- 密度判定に有効点数だけから求めた一律slot幅を使用しない
- 同じxでもyが十分離れた点のmarkerを、一律に省略してはならない
- 完全同一座標またはscreen-spaceで6 logical pixels未満に密集する非選択markerは省略する
- 選択中のmarkerは距離にかかわらず常に描画する

markerの省略をデータ点の除外、決定的なpointer選択候補からの除外、前後移動不能または集計除外として扱ってはならない。完全同一座標の個別到達性は§9 D-4に従う。

---

## 11. 切替UIと選択カード

### U-1. 切替UI

横軸切替は、分析画面内でグラフの対象を理解できる位置へ配置する。

推奨構成は次とする。

```text
横軸
[ 症例順 | 時系列 ]
```

標準の `SegmentedButton` 等、選択状態とSemanticsが明確な既存UIパターンを使用する。

切替UIの近傍に、1回のtapで同じroute内に説明を開ける「横軸の説明」controlを設ける。説明本文を常時併記することは許容するが、controlの代替にはしない。説明は最低限、次と同等の意味を含む。

> 症例順は、アプリ内の登録症例を手術日順に並べた表示です。同日内の実際の執刀順は表しません。時系列は手術日の暦日間隔を表します。表示件数は生涯の執刀件数ではなく、時間だけで手術成績は判断できません。

説明controlは、44×44 logical pixels以上のtarget、明確なlabel、VoiceOver action、閉じる操作および元のcontrolへ戻れるfocusを持たせる。説明を外部web、初回だけのonboarding、長押しまたはtooltipだけへ置いてはならない。

### U-2. 表示条件

- `R == 0`：症例なし状態を表示し、横軸切替、横軸の説明control、グラフ、選択カードおよびadjustable nodeを表示しない
- `R > 0` かつ `M == 0`：選択指標の計測データなし状態を表示し、グラフ、選択カードおよびadjustable nodeを表示しない。横軸切替と説明controlは表示しないが、同一route内の選択モードは保持する
- `M >= 1`：横軸切替、説明controlおよびグラフを表示する

### U-3. モード切替結果

モード切替では次を維持する。

- 選択指標
- 選択 `recordId`
- `k`
- 縦スクロール位置
- 遷移先を決める `recordId` と `step.storageId`
- 同一Snapshotの最新値と比較サマリー

### U-4. 選択カード

選択カードは最低限、次を表示する。

- `症例順 n / R`
- `この指標 k / M`
- 正確な手術日
- 左右眼
- 対象指標名
- 所要時間

例：

```text
症例順 100 / 100
この指標 2 / 2
2026年8月12日　右眼
CCC：1分42秒
```

`k / M` を「全症例中のn件目」と表現してはならない。

### U-5. 前後ボタン

前後ボタンは、選択指標の有効点列における前後の計測済み症例へ移動する。

- 欠損症例では停止しない
- 例として `n = 98` の次の有効点が `n = 100` なら、次ボタンで98から100へ移動する
- tooltipおよびSemanticsは「前の計測済み症例」「次の計測済み症例」と同等の意味を持たせる
- 先頭と末尾では不可能な方向のボタンを無効化する
- 端で循環させない

### U-6. グラフ案内

個別工程では、既存要件どおり次と同等の意味を持つ案内を維持する。

> グラフをタップして症例を選び、「症例詳細を見る」から選択した工程の動画を確認します。

総手術時間では工程動画に関する案内を表示しない。§9 D-2の同日cluster説明が必要な場合は、個別工程の案内と競合しないよう、1つの短い案内へ統合してもよい。ただし、症例選択と遷移ボタンの役割、および同日点の意味をどちらも失ってはならない。

### U-7. レイアウト

- 切替UIをグラフの左右へ置いて横方向のplot幅を減らさない
- 切替UIの追加を理由に横スクロールを追加しない
- 320×568 logical pixels、文字倍率2.0でも両選択肢へ到達できる
- ラベル、グラフ、選択カードおよび遷移ボタンがSafe Area外または到達不能な位置へ出ない
- iPadのSplit View、Stage Managerおよび動的リサイズでoverflowを起こさない

---

## 12. 選択状態とライフサイクル

### S-1. 非永続化

v2.0では横軸モードを永続化しない。

- SharedPreferencesへ保存しない
- DBへ保存しない
- app再起動後に以前の横軸モードを復元しない
- 分析画面を閉じて新しいrouteとして開いた場合は「症例順」へ戻す

### S-2. route内保持

同じ `AnalysisScreen` routeが存続する間は、次の操作または再buildで横軸モードを変更してはならない。

- 指標変更
- 症例点選択
- 前後選択
- pull-to-refresh
- 症例詳細または工程レビューからの復帰
- Provider再取得
- 画面回転
- iPadの動的resize
- Light／Dark切替
- 文字倍率変更
- appの一時的なbackground／foreground

### S-3. 選択症例

画面の初回表示または指標変更によって維持可能な選択 `recordId` がない場合は、選択指標の最新有効点を初期選択する。「最新」は§5の正式な比較順で最後の有効点を意味し、全登録症例catalogの末尾が欠損値でも、その欠損症例を選択してはならない。

新しいSnapshotでも選択 `recordId` が選択指標の有効点として残る場合、症例順が変化しても選択を維持する。

選択症例が削除された、または選択指標の有効点でなくなった場合は、現行仕様どおり、その指標の最新有効点へfallbackする。`M == 0` なら選択を解除する。

### S-4. busy

個別工程動画の遷移前確認busy中は、既存操作と同様に次を無効化する。

- 横軸モード切替
- 指標変更
- グラフ選択
- 前後選択
- 遷移ボタン
- VoiceOver増減
- pull-to-refresh

busy開始時のモード、`recordId` および `step.storageId` を、非同期処理中の再buildで置き換えない。

---

## 13. 既存の症例詳細・工程動画導線

### J-1. グラフ操作

両モードで、グラフの点、線または空白のタップは症例選択だけを行う。

- タップからrouteを生成しない
- ダブルタップまたは長押しへ隠し遷移を割り当てない
- グラフnodeへactivate actionを設定しない
- markerごとの独立したSemanticsボタンを作らない

### J-2. 総手術時間

総手術時間では、選択カードのボタンから選択 `recordId` に対応する症例詳細画面を開く。

- 工程動画用の事前確認を開始しない
- `StepReviewScreen` の直接ジャンプintentを作らない
- 動画状態を確認しない

### J-3. 個別工程

個別工程では、選択カードのボタンから選択 `recordId` と `step.storageId` を固定し、既存の事前確認契約に従って対象工程動画を開くか、安全なfallbackを行う。

横軸モード、症例順 `n`、有効点位置 `k`、表示ラベルまたはSnapshot取得時の開始位置をroute identityとして使用しない。

選択カードのボタン表示文言を既存どおり「症例詳細を見る」とする場合も、近傍の案内文とbutton Semantics hintで、個別工程では選択中の工程動画を開くことを明示する。総手術時間のbuttonは症例詳細を開くことだけを案内し、工程動画へ進むとは読み上げない。

### J-4. 軸切替の読み取り境界

横軸モード切替、グラフ選択、前後選択およびVoiceOver増減だけでは、次を開始しない。

- repositoryのfresh read
- DB更新
- 欠損工程行の作成
- 動画状態確認
- 動画ファイルアクセス
- legacy動画移行
- 動画controller生成
- 動画の自動再生またはシーク

---

## 14. アクセシビリティ

### A-1. 横軸切替

横軸切替は、VoiceOverで次を理解し操作できること。

- コントロールの目的が「横軸」であること
- 選択肢が「症例順」「時系列」であること
- 現在選択中のモード
- 操作後に選択されたモード
- 「横軸の説明」と、その説明に含まれる症例順、時系列、同日順、登録件数および臨床的解釈の制限

各選択肢のタップ可能なSemantics rectは44×44 logical pixels以上とする。

### A-2. グラフnode

グラフは引き続き1つのadjustable Semantics nodeとする。

valueには最低限、次を含める。

- 横軸モード
- `登録R症例中n番`
- `この指標M件中k件目`
- 正確な手術日
- 左右眼
- 指標名
- 所要時間

例：

> 横軸は症例順。アプリ内の登録100症例を手術日順に並べた100番。この指標2件中2件目。2026年8月12日、右眼、CCC、1分42秒。

組 `(R, n)` または `(M, k)` の一方を省略し、「全N件中K件目」とだけ読み上げてはならない。

個別工程のhintは、次と同等の意味を維持する。

> 上下スワイプで症例を選択します。選択後、「症例詳細を見る」ボタンからこの工程の動画を開けます。

総手術時間のhintは、上下スワイプで症例を選択できることだけを説明し、工程動画を開くとは案内しない。グラフnodeへtap／activate actionを付与せず、hintでもダブルタップによる遷移を案内しない。

### A-3. 増減操作

- incrementは次の計測済み症例へ移動する
- decrementは前の計測済み症例へ移動する
- 同一座標の点を含む全有効点へ到達できる
- 中間点の `increasedValue` は次の有効点、`decreasedValue` は前の有効点について、§14 A-2と同じ完全なvalueを返す。同日または完全同一座標でも有効点列の `k` 順を使用する
- 端で循環させない
- 不可能な方向では選択を変更しない
- 増減操作からrouteまたは動画確認を開始しない
- 先頭の `decreasedValue` と末尾の `increasedValue` は現在のvalueと同じ内容を返し、存在しない別症例へ移動するような読み上げを行わない

### A-4. フォーカス

- モード切替だけでVoiceOver focusを選択カードまたは遷移ボタンへ強制移動しない
- 選択中の `recordId` が維持される場合、グラフの現在値を更新する
- 詳細または工程レビューから戻りグラフが存在する場合、既存要件どおり同じadjustable graph nodeへfocusを復帰する
- 読み上げ順は、横軸切替とその説明control、グラフ、必要な案内、選択カード内容、遷移ボタンの順で理解できるようにする
- refreshまたは復帰後に `R == 0` となった場合は症例なし状態の見出しへ、`R > 0, M == 0` となった場合は選択指標の計測データなし状態の見出しへfocusを移す
- 0件状態では存在しないグラフnodeへfocus eventを送らず、破棄済みnodeへfocusを残さない

### A-5. 文字倍率とコントラスト

- 文字倍率1.0および2.0で横軸ラベルをclipまたは重複させない
- Light／Darkで軸、ラベル、線、marker、選択markerおよび切替UIの必要なコントラストを満たす
- `TextScaler`、themeおよびgeometryの変化を再描画判定へ反映する

---

## 15. データ保全・プライバシー・読み取り境界

### R-1. 読み取り専用

分析Snapshot取得、症例順計算、横軸座標計算、ラベル生成、モード切替および点選択は読み取り専用とする。

次を行ってはならない。

- `surgery_records` の作成、更新または削除
- `surgical_step_reviews` の作成、更新または削除
- `ensureStepReview` または `ensureStepReviews` の呼び出し
- 症例順を永続化するschema変更またはmigration
- 動画参照、動画ファイルまたは保護属性の変更
- 外部通信、cloud同期または利用状況analyticsの追加

### R-2. Snapshot一貫性

全登録症例catalogとmeasurementを、§5 O-6で定める同一の論理Snapshotとして取得する。

- 症例ごとまたは工程ごとにDB queryを繰り返さない
- UI側で別Providerの異なる取得時点を合成しない
- 取得途中の症例追加、削除または日付編集から、重複または欠落した症例順を生成しない
- catalogの `recordId` はSnapshot内で空でなく一意でなければならない
- 同じ `(recordId, step.storageId)` のmeasurementをSnapshot内で複数返してはならない
- 返却される論理Snapshot内でmeasurementがcatalogに存在しない `recordId` を参照する等、同一結果内で整合しない状態を黙って部分表示しない

1つの `LEFT JOIN` のraw結果に、同一症例の工程数だけ同じ `recordId` が現れることは正常であり、それ自体をcatalog重複としない。catalog構築後は1 `recordId` につき1要素とし、同じIDのraw行間で `surgeryDate`、`createdAt` またはraw `eyeSide` が競合する場合にSnapshotを失敗させる。

本要件は、record起点のquery結果へ現れないDB内の孤児工程行を毎回全件監査することまでは要求しない。DB全体のintegrity checkは別要件とし、本機能では返却結果と構築した論理Snapshotの自己整合性を検証する。

### R-3. 不正metadataの扱い

読み取り可能な登録症例は、工程記録や動画の欠損を理由にcatalogから除外しない。一方、表示用順位を安全かつ決定的に作れないmetadataを推測または補完してはならない。

- `eyeSide` が未知または解釈不能な症例は、`R`、`n` および両modeのdomainへ残すが、選択カードを安全に構成できないため各指標の有効点には含めない
- `surgeryDate` または `createdAt` が欠落、decode不能もしくは表現範囲外である場合、catalog構築後の `recordId` が空・重複またはraw行間でmetadata競合する場合、同じ `(recordId, step.storageId)` が重複する場合、または返却結果内でcatalogとmeasurementの参照整合性が壊れている場合は、Snapshot全体を失敗させる
- 不正行だけを除外して `R` や `n` を詰める、DB行順を代用する、現在日を補う、別の症例metadataを流用する、または永続データを自動修復してはならない
- 将来日、うるう日、非常に古い有効な日付、および工程measurementの欠損は、それ自体をmetadata不正とみなさない

これらの状態でも分析は読み取り専用を維持し、既存の分析エラー状態と再試行導線を使用する。

### R-4. データ最小化

分析に不要な動画byte、患者識別情報、症例メモ、反省点、自己評価本文または動画pathを横軸計算のために取得しない。

### R-5. 失敗時

Snapshot取得、座標計算または描画に失敗しても、既存の症例、工程記録、動画参照およびファイルを変更しない。既存の分析エラー状態と再試行導線を使用する。

---

## 16. 性能要件

### P-1. 計算量

- 全登録症例の並び順、症例順付与およびmeasurement mappingは、取得行数に対して線形または `O(R log R)` 以内とする
- 座標、screen-space近傍距離および選択候補のlayout計算は `O(M log M)` 以内、1回のpaintは `M` とtick数に対して線形とする
- 症例ごとのDB query、動画状態確認またはfile I/Oを行わない
- 欠損症例ごとに不要なinteractive widgetまたはSemantics nodeを生成しない

### P-2. モード切替

モード切替は、取得済みの同一Snapshot上で完結する。

- DB再取得を行わない
- mode切替のためだけに全工程measurementを再読込しない
- 動画I/Oを行わない
- 同じ座標計算を症例ごとの非同期処理として実行しない

### P-3. 検証fixture

最低限、次の件数を検証する。

- `R = 0`
- `R = 1`
- `R = 2`
- `R = 50`
- `R = 365`
- `R = 1000`

`R = 365` では全11指標の工程行を持つfixtureを用い、全点有効、大半欠損、局所的な密集、同日症例をそれぞれ検証する。

`R = 1000` はサポート上限を意味しない。長期利用時にoverflow、無限loop、巨大label list、クラッシュまたは操作不能状態を起こさない最低stress条件とする。

### P-4. 操作応答

profile modeを基本とし、次の最低性能baseline実機を用いて測定する。

- iPhone：iPhone 6s、A9、iOS 15.x
- iPad：iPad mini 4、A8、iPadOS 15.x

端末を調達不能または計測tool非対応のため変更する場合、同等以下の性能である根拠、代替機種、SoC、OSおよび閾値への影響を記載した試験計画改訂を、計測開始前に承認する。承認なしに高速な端末へ置き換えて合格としてはならない。release modeを用いる場合は、同等のframe timingを取得できる計測方法を実装報告へ記録する。

- Snapshot取得完了後の初期グラフ表示
- 横軸モード切替
- 指標切替
- 高密度グラフの点選択
- VoiceOverの連続増減
- 回転およびiPad動的resize

`R = 365` のfixtureでは、通常のモード切替と点選択について、60Hz端末でbuildおよびraster各frameのp95を16.7ms以内とする。本書のmissed frameは、build timeまたはraster timeの少なくとも一方が16.7msを超えたframeを指し、連続したmissed frameは同一操作列で2frame以上連続する状態を指す。連続したmissed frameを発生させない。

同じ `R = 365` fixtureでは、次の入力受理から目的の新状態を含む最初のframeおよびSemantics更新までを測定し、それぞれ100ms以内とする。

- data Snapshot commitからの初期グラフ表示。DB取得時間はこの区間へ含めない
- 指標切替から、新指標のgraph、summaryおよび選択カードがそろうまで
- VoiceOver increment／decrement受理から、次／前の選択marker、カードおよびadjustable valueがそろうまで

回転およびiPad動的resizeでは、最終的なstable constraintsがchartへ通知されてから、正しいplot rectangle、tick、line、markerおよびhit-test geometryを含む最初のframeまでを250ms以内とする。連続resize中の中間frame timingは診断値として記録するが、この250ms gateの起点にはしない。

`R = 1000` のfixtureでは、Snapshot取得後にモード切替操作が受理されてから、新しい横軸geometryを含む最初のframeが表示されるまでを100ms以内とし、操作不能、watchdog終了またはメモリ増加の継続を起こさない。

各操作は最初の5回をwarm-upとして結果から除外し、その後30回以上を計測する。端末機種、SoC、OS、refresh rate、build mode、fixture seed／内容、計測方法、計測回数、中央値、p95、連続missed frame数および合否を実装報告へ記録する。fixtureと端末条件を変えた結果を同一母集団へ混在させない。

### P-5. 資源

`R = 1000` fixtureを表示して5回のmode切替をwarm-upした後、profile modeのVM serviceまたは同等の計測手段でfull GCを要求し、2秒安定化してbaselineを記録する。その後、20回のmode切替を1 batchとして3 batch実施し、各batch後に同じGCと2秒安定化を行う。強制GCを利用できない場合は、Instruments等による同等のretained allocation計測方法を試験計画で先に承認する。

3 batch完了後も、次を満たす。

- 動画controller生成数が0である
- file handleを新規生成しない
- 同一fixture・同一modeへ戻した時のmarkerおよびSemantics node数がbaselineと一致する
- listener、subscription、pending async taskおよびclock timerのlive数がbaselineを超えない
- GC後のretained heap増加が、baselineの5%または1MiBの大きい方以内である
- 第2・第3 batch後のretained heapが直前batchを超える場合、その増分はbaselineの1%または256KiBの大きい方以内である

baselineに含まれるactive route用clock timerは1系統だけを許容し、mode切替回数に応じて増やしてはならない。計測値、GC方法、安定化時間および許容差を性能報告へ残す。

---

## 17. 非要件

今回の改善では、次を実装対象外とする。

- 術者の生涯執刀件数または実経験件数の入力
- 初回登録時の過去経験件数offset
- 手術時刻または同日内の実執刀順の入力
- 患者、病院または他施設の症例件数との連携
- 外部データからの執刀件数取得
- 手術成績、合併症、視力予後または症例難易度による補正
- 年次・月次症例数集計の新規追加
- 指標の期間filter、任意範囲指定、zoom、pan、横スクロールまたはページング
- 移動平均、回帰線、累積時間、ばらつきまたは安定性指標の新規追加
- 欠損区間の破線化、線分断または欠損理由marker
- 横軸モードの永続保存
- 手術日の保存形式またはDB schemaの変更
- record起点の分析queryへ現れない孤児工程行を含む、DB全体の新規integrity auditまたは自動修復
- 将来日の登録可否の変更
- 縦軸スケール、縦軸tickまたは縦軸labelの変更
- グラフからの点タップ即遷移
- markerごとの独立したSemanticsボタン
- 臨床的効果の測定または判定

将来指標については、本書の共通domainと座標契約を再利用できる可能性を残す。ただし、存在しない将来指標のために汎用framework、DB schemaまたは過度な抽象化を先行追加しない。

---

## 18. 自動テスト要件

### 18.1 症例順とデータ契約

- 0件、1件、2件、50件で `R` と `n` が正しい
- `n` が1始まり、連続、一意である
- 並び順が `surgeryDate → createdAt → recordId` で決まり、`recordId` はlocale非依存なbinary文字列昇順となる
- 同日5症例を症例順に並べる
- `surgeryDate` と `createdAt` が同一の場合に `recordId` で安定する
- 工程行なし、旧工程のみ、未知工程のみ、動画なし、未計測の症例も `R` と `n` の母集団へ残る
- 1 statementまたは同じread transaction内の複数statementからcatalogとmeasurementを取得する
- Snapshot取得と同時に症例追加、削除または手術日編集が起きても、新旧状態を混在した `R`、`n` またはmeasurementを返さない
- query、decodeまたは整合性検証の一部が失敗した場合に部分Snapshotを返さない
- 未知の `eyeSide` は `R`、`n`、domainへ残るが有効点から除外される
- 正常な `LEFT JOIN` による同一 `recordId` の工程別raw行を1 catalog要素へまとめる
- 同一 `recordId` のraw行でmetadataが競合する場合、欠落・decode不能な `surgeryDate`／`createdAt`、catalog構築後の空・重複 `recordId`、重複 `(recordId, step.storageId)` および返却結果内のcatalog外measurementではSnapshot全体が失敗する
- DB全体に存在してもrecord起点のqueryへ返らない孤児工程行の全件監査は、本機能のSnapshot取得へ追加しない
- `isSkipped == true` と一見有効なstart／endが併存する旧不正データも有効観測から除外する
- Snapshot取得途中でtimezone identifierが変わった場合は結果を破棄して1回再取得し、再度変われば再試行可能なエラーにする
- 症例順をDBへ書き込まない
- 分析取得前後でDBの行数と全永続fieldが不変である

### 18.2 症例順座標

- `R == 1` では中央へ置く
- `R >= 2` では先頭が0、末尾が1のratioを持つ
- `R = 100` で症例順87の症例だけが有効でも `n = 87` の位置へ置く
- 症例順98・100の症例だけが有効で、症例順99が欠損してもx座標を詰めない
- 総手術時間と全10個別工程で同じ `recordId` の `n` と `xRatio` が一致する。plot rectangleが異なる場合の絶対pixel x一致は要求しない
- ラベルが有効点indexではなく `1...R` のdomainへ配置される
- ラベルが重ならず、収まる場合は1とRを表示する
- `R = 37` かつ採用間隔10では `1, 10, 20, 30, 37` を候補とする
- ラベル候補を32件より多く生成せず、極端に大きい `R` でも全整数列を一時生成しない

### 18.3 時系列座標

- 固定した `referenceDate` で座標とラベルが決定的である
- 実際の暦日差がx距離へ比例する
- 1件だけ過去、全件過去、全件現在、全件将来、過去と将来の混在を処理する
- `domainStart == domainEnd` では中央へ置く
- 将来日を除外または現在へclampしない
- うるう日、月末、年末年始を処理する
- DST境界でcalendar-dayの等間隔を維持する
- 中間、先頭または末尾の指標欠損でdomainを変えない
- 選択指標を変えても同じSnapshotのdomainを維持する
- `現在`、過去側、将来側のラベルを正しく表示する
- 文字倍率に応じてtickを決定し、ラベルを重ねない
- すべて過去のfixtureで、最新症例から `referenceDate` までの意図した空白tailを表示する
- 同じdata Snapshotで基準日が翌日へ進むと、domain、tickおよび過去症例の `xRatio` を再計算する
- appがforegroundのまま0時をまたぐ場合、system clockで日付が変わる場合、およびbackground中に日付が変わる場合に基準日を更新する
- fake clock／schedulerで、foreground変更を60秒以内に反映し、0時・clock変更・timezone変更・refresh成功後に予約を再armする
- route非active、backgroundおよびdisposeでtimer／subscriptionを解除し、resume時に直ちに再比較する
- refresh／Provider再取得が失敗してstable Snapshotを維持する場合、取得試行開始だけでは基準日を変更しない
- timezone変更後のresumeでは、新しいdata Snapshotを取得し、§3.1の既存保存形式による解釈を含めて再計算する
- timezone変更後は、新しいローカル年月日からcatalogを再sortして `R`、`n` と両modeのdomainを再計算し、同じ `recordId` が有効なら選択を維持する
- timezone context refresh中は旧bundle全体またはloadingだけを表示し、新 `referenceDate` と旧catalog等を混在させない
- timezone context refresh成功時はidentifier、基準日、data Snapshot、順位、domain、geometryおよび選択を同じframe stateへ原子的にcommitする
- timezone context refresh失敗時は旧graphを現在値として表示し続けず、再試行可能な分析エラー状態へ移る
- 通常の再build、theme変更、文字倍率変更、回転または同日内のresizeでは基準日を更新しない
- `2024-03-31` anchorの月tickを `2024-02-29`、`2024-04-30`、`2024-05-31` とし、月末clampを連鎖させない
- `2024-02-29` anchorの年tickを `2023-02-28` と `2025-02-28` へclampする
- 日、週、月、年、将来側および過去側で `現在`、`1日前／後`、`1週間前／後`、`1か月前／後`、`1年前／後` を正しく生成する
- 数百年に及ぶ有効なdomainでもtick候補を32件以下に保ち、有限時間で決定する

### 18.4 同日clusterとpointer

- 同日症例を同一 `xRatio` へ置く
- 横方向jitterを加えない
- interaction rectangle外のpointerを無視し、軸gutter内のpointer座標はplot rectangleへclampして選択する
- interaction rectangle内から始まる縦drag／scroll、scale、long pressおよびcancelでは選択を変更せず、成立したtapだけで選択する
- 同日で異なるyの場合、最も近いyを選択する
- 同日かつ同じyの場合、選択中の点を維持する
- 未選択の完全同一座標では `n` が最大の点を選ぶ
- x距離が同じ別日clusterでは新しい日を選ぶ
- 同一座標の全点へ前後ボタンとVoiceOverから到達できる
- 完全同一座標の全点をpointerだけで個別選択できるとは扱わない
- 選択指標について同じcalendar-day ordinalの有効点が2点以上ある日が1日以上存在する時だけ、同じ横位置と前後確認を説明する案内を表示する

### 18.5 欠損、線およびmarker

- 未入力、片側欠損、0秒、逆転、skip、工程行なしを0秒として描画しない
- 欠損症例を `R`、`n` および時系列domainから除外しない
- 欠損を跨ぐ有効観測同士を接続する
- 線上に仮想点または選択対象を生成しない
- 全有効観測を折れ線と選択順へ残し、最新点とその前の最大5件から成る既存summary計算を密度処理で変えない
- `M == 1` では `d = +infinity` として非選択markerを表示する
- screen-space Euclidean distanceが6 logical pixels未満では非選択markerを必ず省略する
- 同じxでもy距離が6 logical pixels以上の非選択markerを一律に省略しない
- 選択markerは密度にかかわらず表示する
- marker省略点も決定的なpointer候補、前後操作およびVoiceOverの有効点列へ残す。完全重複点の個別到達は前後操作とVoiceOverで保証する

### 18.6 UIと状態

- 新しい分析画面の初期モードが症例順である
- 「横軸の説明」へ1回のtapとVoiceOverで到達でき、生涯件数、同日実順、時系列間隔および臨床的解釈の制限を確認できる
- 横軸の説明を画面上の閉じる操作、標準backおよびVoiceOverで閉じられ、閉じた後は起点の説明controlへfocusが戻る
- モードを永続保存しない
- モード切替後も同じ `recordId`、指標、`k`、scroll位置を維持する
- モード切替前後でduration、縦座標、縦軸scale／tick、最新値、直前最大5件平均、差分および有効観測集合が一致する
- 指標変更、refresh、詳細復帰、工程レビュー復帰、回転、theme変更およびresizeでモードを維持する
- 初回表示では選択指標の最新有効点を選び、catalog末尾の症例が欠損でもそれを選択しない
- 過去症例追加後に全症例の `n` を再計算する
- 症例削除後に `R` と `n` を再計算する
- 手術日編集後に `n` と座標を再計算する
- 選択 `recordId` が残る場合は再採番後も選択を維持する
- 選択点が消えた場合は最新有効点へfallbackする
- `R == 0` と `R > 0, M == 0` で不要なcontrolとSemantics nodeを生成しない
- busy中に横軸切替を受け付けない
- busy中に基準日またはtimezone変更条件へ達した場合はrefresh開始と描画更新を保留し、busy解除後に同じintentを壊さず反映する
- 両modeで横方向のScrollView、zoom／pan／scale gestureを生成せず、domain両端を同じplot rectangle内へ表示する

### 18.7 詳細・動画導線

- 両モードでグラフタップは選択だけを行う
- 総手術時間のボタンは同じ `recordId` の症例詳細を開く
- 全10個別工程のボタンは同じ `recordId + step.storageId` を使う
- 横軸モードをroute intentへ含めない
- モード切替、点選択、前後選択およびVoiceOver増減で動画状態確認を開始しない
- モード切替でDB read、DB write、動画I/Oまたはcontroller生成を行わない
- 詳細・工程レビューから戻った後もモードと選択を可能な限り維持する

### 18.8 Semanticsとレイアウト

- 横軸切替の目的、選択肢および現在値を読み上げる
- グラフを1つのadjustable nodeとして維持する
- valueにモード、`n / R`、`k / M`、日付、左右眼、指標名、時間を含める
- グラフnodeにtap／activate actionを持たせない
- 個別工程のグラフhintは選択後に別ボタンから工程動画を開くことを説明し、総手術時間では工程動画を案内しない
- 中間点の `increasedValue`／`decreasedValue` は、同日完全重複を含む次／前の有効点について、`n / R`、`k / M` を含む完全なvalueを返す
- 先頭の `decreasedValue` と末尾の `increasedValue` は現在値を保ち、存在しない症例を読み上げない
- 0件でadjustable nodeを作らない
- 読み上げ順が横軸切替と説明control、グラフ、必要な案内、選択カード、遷移ボタンとなる
- 詳細／工程レビュー復帰後はグラフへ、refresh後の `R == 0`／`M == 0` では対応する空状態見出しへfocusを移す
- 320×568、文字倍率1.0／2.0、Light／Darkでoverflowとラベル重複がない
- iPhone／iPadの宣言済み全方向、Split View、Stage Managerおよび動的resizeで操作可能である
- actionable Semantics rectが44×44 logical pixels以上でSafe Area内にある

### 18.9 描画証跡

- domain、tick、`xRatio`、screen-space座標、marker可視性およびhit-testをUI非依存のlayout modelまたは同等の純粋計算として検証する
- `CustomPainter` について、widget testと、goldenまたは決定的なdrawing-command seamの少なくとも一方を用い、両modeの線、marker、選択marker、tickおよびlabelの実描画位置を検証する
- 欠損を跨ぐ線、同日縦線、完全重複、将来日、1件、密集点および異なるplot rectangleを描画証跡へ含める
- `TextScaler`、文字方向、theme、size、domain、modeまたは選択 `recordId` が変わった時に必要な再layout／再paintが行われ、同一入力では不要な再paintを増やさない

### 18.10 性能

- §16の全fixtureでN+1 query、DB writeおよび動画I/Oがない
- `R = 365` と `R = 1000` でクラッシュ、overflowまたは無限loopがない
- 5回warm-up後の20回×3 batchで、listener、timer、marker、Semantics nodeおよびretained heapが§16 P-5の閾値を満たす
- §16 P-4のprofile計測が閾値を満たす
- 5回のwarm-upを除外した30回以上の測定と、端末・OS・fixture・計測方法を記録する

---

## 19. 手動受け入れ要件

### 19.1 実施環境

最低限、次の実機で確認する。Simulatorだけの結果をVoiceOver、操作性または性能の最終受け入れへ代用してはならない。

- iOS 15.xを実行する対応iPhone実機1台以上
- iPadOS 15.xを実行する対応iPad実機1台以上
- リリース判定時点の現行公開iOSを実行するiPhone実機1台以上
- リリース判定時点の現行公開iPadOSを実行するiPad実機1台以上

実機を提供するremote device farmは使用してよいが、Simulator／emulatorは実機件数へ数えない。同じ実機が複数条件を満たす場合は兼用してよい。端末、OS、画面方向、文字倍率、theme、VoiceOver状態、fixtureおよびbuild modeを受け入れ記録へ残す。

### 19.2 理解確認

本機能を実装していない担当者または想定利用者1名以上に、操作説明を先に読ませず画面を操作してもらい、次の質問へ回答してもらう。

1. 「症例順」は何の順番か
   - 合格回答：アプリ内の登録症例を手術日優先で並べた表示上の順番
   - 不合格回答：アプリへの登録操作順、生涯執刀順、実経験症例数、または同日内の実執刀順
2. 「時系列」で点の横方向の間隔は何を表すか
   - 合格回答：手術日どうしの実際の暦日間隔
   - 不合格回答：登録操作の間隔、有効点の通し番号、または手術動画内の時刻
3. 時間が短くなった点は、臨床的に優れた結果を意味するか
   - 合格回答：このグラフだけでは技術や臨床成績の優劣を判定できない
   - 不合格回答：短いほど必ず技術または手術成績が良い

全問で合格回答と同等の理解が得られること。実施者、確認者、実施日、質問ごとの実回答、合否、迷いまたは誤読、および必要になった文言修正を受け入れ記録へ残す。

### 19.3 操作確認

最低限、次を確認する。

1. 症例順98・100の症例だけ計測済みの画面で、症例順と有効点位置、および欠損を残した間隔を正しく理解できる
2. 同日複数症例が同じ横位置である理由を案内から理解でき、異なるyの点はpointerで、完全重複を含む全点は前後ボタンおよびVoiceOverで確認できる
3. 将来日を含む時系列軸で「現在」と未来側を区別できる
4. 全症例が過去の時系列軸で、最新症例から現在までの空白tailを「登録症例がない期間」と理解できる
5. 正確な手術日、左右眼、指標名、時間を選択カードで確認できる
6. 両モードから正しい症例詳細または工程動画へ進める
7. 横軸切替だけで動画確認中表示またはファイルアクセスが発生しない
8. VoiceOverだけでモード切替、症例選択、前後移動、詳細／工程動画導線を完了できる
9. VoiceOver focusが詳細／工程レビュー復帰後はグラフへ、0件遷移後は対応する空状態見出しへ戻る
10. 文字倍率2.0、Light／Dark、iPhone横向き、iPad Split Viewでcontrolとラベルを失わない
11. Reduce Motion有効時に、理解に必要な情報をanimationへ依存しない
12. 長期fixtureでモード切替と点選択に知覚可能な停止や連続したframe落ちがない

---

## 20. 完了条件

### 20.1 自動検証までの実装完了

以下をすべて満たした時点を「自動検証までの実装完了」とする。この段階だけでは最終受け入れ完了または配布可能と判定しない。

1. 横軸を「症例順」「時系列」で切り替えられ、新しい分析画面の初期モードが「症例順」である
2. 全登録症例catalogとmeasurementが原子的な同一Snapshotとして取得される
3. 症例順が `surgeryDate → createdAt → recordId` の昇順で決まり、DBまたは設定へ永続化されない
4. 欠損症例があっても `R`、`n` および横位置を詰めない
5. 総手術時間と各工程で同じ症例の `n` と `xRatio` が一致する
6. 時系列モードで暦日間隔がx距離へ反映され、domainが全登録症例と基準日を含み、将来日と現在までの空白tailを扱う
7. 同日症例を架空の時刻やjitterなしで扱い、pointerの決定的な代表選択と前後／VoiceOverによる全点到達を区別する
8. `n / R` と `k / M` を表示およびSemanticsで区別する
9. 欠損値を0秒として描画または集計せず、有効観測をsamplingしない
10. 選択markerを常に表示し、その他のmarker密度をscreen-space距離で決める
11. 横軸labelが現在の幅と文字倍率で重ならず、候補生成が有界で決定的である
12. モード切替後も同じ `recordId`、指標およびscroll位置を維持する
13. モードを永続保存せず、新しいrouteでは症例順へ戻る
14. foregroundの日付変更、clock変更およびtimezone変更で基準日を契約どおり更新する
15. グラフ操作は選択だけを行い、routeを生成しない
16. 総手術時間と個別工程の既存詳細／動画導線、案内およびhintを維持する
17. 横軸操作がDB、工程行、動画またはファイルを変更しない
18. グラフを1つのadjustable Semantics nodeとして維持し、focus遷移を含むアクセシビリティ契約を満たす
19. §18の自動テストと描画証跡がすべて合格する
20. 既存の分析summary、縦軸、症例詳細、工程動画導線、データ保全およびオフライン動作の自動回帰試験が合格する

### 20.2 最終受け入れ完了

§20.1に加え、次をすべて満たした時点を「最終受け入れ完了」とする。

1. §19.1のiPhone／iPad実機条件で主要フローを完了する
2. §19.2の理解確認に合格し、実回答と確認者を記録する
3. §19.3の操作確認に合格する
4. §16の性能条件を定めたprotocolで満たし、計測証跡を残す
5. VoiceOver、文字倍率2.0、Light／Dark、全対応方向およびiPadリサイズで主要フローを完了する
6. 既存の分析summary、縦軸、症例詳細、工程動画導線、データ保全およびオフライン動作を実機で破壊していない
7. 未解決の重大・高優先度不具合がなく、既知の制約と§3.1のtimezone caveatがリリース判断へ明示されている

---

## 21. 推奨する責務境界

本節は実装class名を拘束しないが、次の責務境界を推奨する。

1. repositoryは、unknownを保持できるraw `eyeSide`、`isSkipped`、全登録症例catalogおよび表示対象measurementを同一の論理Snapshotとして一括取得する
2. domain層は、正式な並び順、症例順、有効観測、`R`、`n`、`M`、`k`、基準日および各モードの `xRatio` を副作用なく算出する
3. clock／timezone context境界は、ローカル暦日とOS timezone identifierをテスト可能な形で提供し、foreground、resumeおよび取得中のcontext変更を検知する
4. chartの純粋なlayout modelは、受け取ったdomain、`xRatio`、縦軸scaleおよび選択identityから描画座標、tick、marker密度とpointer選択を算出する
5. screenは、選択指標、横軸モード、選択 `recordId`、scroll、busy、基準日更新およびroute遷移を管理する
6. 動画serviceと工程レビュー画面は横軸モードを認識せず、既存の `recordId + step.storageId` 契約だけを受け取る

横軸モードを将来指標へ再利用できる設計は許容するが、今回存在しない指標のためにDB schema、汎用chart frameworkまたは新しい永続モデルを追加しない。

---

## 22. 本改善の意義

本改善により、利用者は同じ記録を次の2つの観点から安全に振り返れる。

- 登録した症例を重ねる中で、総手術時間と個別工程時間がどのように変化したか
- 暦日が経過する中で、症例が集中した期間、空白期間および時間推移がどのように見えるか

これは単なるラベル変更ではなく、各mode内で総手術時間と全工程が共有できる横軸domain、安定した症例identity、欠損を保持する表示位置および既存の動画振り返り導線を統合する基盤改善である。

ただし、本改善だけから手術技術、臨床成績または因果的なlearning curveを判定しない。目的は、登録された記録を誤解なく見渡し、必要な症例と動画へ戻って術者本人が振り返ることにある。
