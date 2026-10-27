# Tools

Every tool the agent may call and a workflow step may use, from `define-tool` declarations and plugin registrations. Each tool checks its own permission when invoked; a workflow step also needs `tools:invoke`.

| Tool | Permission | Source | Description |
|---|---|---|---|
| `chat_message` | `chat:use` | translate-chat | モデルにチャットメッセージを1つ送り、その返答を返す。 |
| `create_note` | `notes:write` | built-in | 現在のユーザーのチームにメモを作成します。 |
| `doc_classify` | `files:write` | built-in | この文書がどの種類かを、呼び出し側が与えるラベル集合から判定する。ラベル一つと確信度、一行の根拠を返します。決定的なキーワード／コンテンツタイプのルールを先に試し、次にモデルを使います（`backends` で順序を変更できます）。結果は doc_type / doc_type_confidence / doc_type_source として文書に書き込まれるため、後続のステップ — あるいはトリガー — が種類に応じてスキーマを選べます。また <key>.classification.json として文書の隣に保存されます。 |
| `doc_classify_eval` | `files:read` | built-in | ラベル付きのフィクスチャ集合に対して分類器を測定する: キー接頭辞配下で doc_type_expected 属性を持つ文書が対象です。バックエンドごと、かつラベルごとの正解率とカバレッジ、各ラベルが何と誤認されたか、そして正答と誤答それぞれの平均確信度 — レビューのしきい値で両者を切り分けられるかを示す数値 — を報告します。各バックエンドは連鎖させずに個別に実行するため rules と llm を比較でき、連鎖自体の答えも並べて報告します。何も書き込みません: 種別は記録されず、トリガーも起動しません。 |
| `doc_extract_fields` | `files:write` | built-in | JSON スキーマに照らして文書のテキストから構造化フィールドを抽出する。モデルの返答は検証され、適合しなければ拒否されます — 必須フィールドの欠落、型の誤り、勝手に作られたキーなど。`object` を指定すると、フィールドは元文書の隣に <key>.extracted.json として書き出されます。 |
| `doc_fill_form` | `files:write` | built-in | リポジトリ内の PDF の AcroForm フィールドに、フィールド名と値の JSON オブジェクトから値を埋め込み、結果をその隣に <key>.filled.pdf として書き出します。テキストフィールドは文字列、チェックボックスは true または false、ラジオグループ・コンボボックス・リストボックスはそれ自身の選択肢のいずれかを取ります。フォームが持たないフィールド名は `unmatched` で報告されます（すべての名前が誤っている場合は代わりに拒否されます）。flatten が true のときはフィールドがページに描き込まれ、文書は編集できなくなります。 |
| `doc_list_unclassified` | `files:read` | built-in | まだ文書種別が付いていない、キー接頭辞配下のリポジトリ文書を一覧する — 分類バックフィルへの入力です。オブジェクト ID を返し、1 バッチで打ち切ります。続きはバックフィルをもう一度実行してください。すでに doc_type を持つ文書は飛ばされるため再実行は無償で、他の実行が派生させた出力は一覧されません。 |
| `doc_redact` | `files:write` | built-in | 文書テキスト中の識別子を安定したトークン — <PERSON_1>、<DATE_2>、<ID_3> — に置き換え、残りからモデルへの要求を組み立てられるようにする。検出器は呼び出し側が記述するのではなく名前で選びます: email、date、id_number、dictionary（語句は呼び出し側が渡します）、phone。置き換え後のテキストは元文書の隣に <key>.redacted.txt として書き出し、トークンから値へ戻す対応表は、どのエンドポイントも返さない封緘済みの行に保存します。検出器ごとの件数を報告するため、取りこぼしが見て分かります。 |
| `doc_render` | `files:write` | built-in | フォームテンプレート（リポジトリ内の Markdown、HTML、DOCX 文書）にデータを埋め込む：{{field}}、{{a.b}}、{{#each items}}…{{/each}}（内側で {{this}} / {{@index}}）。DOCX では {{#each items}} だけの表の行が項目ごとの行ブロックを開きます。結果は元文書の隣に <key>.form.<ext> として、format が "pdf" のときは <key>.form.pdf として書き出します（Markdown または HTML テンプレートを pandoc と tectonic で変換）。 |
| `doc_set_type` | `files:write` | built-in | レビュー後に、人が判断した文書の種類を記録する。ラベルは分類が提示したラベル集合に照らして検証されるため、どのトリガーも一致し得ない種類は保存されずに拒否されます。空のラベルは種類を取り下げます — doc_type に「unknown」は存在しないため、却下の正直な記録はこれです。doc_type / doc_type_confidence / doc_type_source を source「review」、確信度 1.00 で書き込み、文書の隣の <key>.classification.json を新しいバージョンとして保存するので、バックエンドの当初の推測もその履歴に残ります。 |
| `doc_text` | `files:read` | built-in | リポジトリ文書のテキストを返す（PDF、DOCX、HTML、Markdown、プレーンテキスト）。文書パイプラインの最初のステップで、検索インデックスの実行に依存しません。 |
| `doc_translate` | `files:write` | built-in | リポジトリ文書をチーム用語集を適用して翻訳し、結果をその隣に書き出す（ロケールは拡張子の前：report.md -> report.ja.md；PDF のテキストは report.ja.txt になります）。 |
| `get_usage` | `chat:use` | built-in | チームの現在の AI 使用量をクォータと比べて報告する。 |
| `kg_extract` | `files:read` | built-in | 1つのリポジトリ文書から、エンティティ（人、組織、製品、場所、イベント、概念）とそれらの関係を知識グラフに抽出する。各言及には原文どおりの抜粋が付きます。検証を通らない返答は拒否します。 |
| `kg_list_unextracted` | `files:read` | built-in | テキストがまだ知識グラフに抽出されていない（または上書き後に古くなった）リポジトリ文書を一覧する。オブジェクト ID をバッチ上限まで返します；続けるには index-knowledge ワークフローを再実行してください。 |
| `kg_query` | `files:read` | built-in | チームの文書がエンティティについて述べていること：その関係と、それに言及する文書を抜粋付きで。名前（またはエンティティ ID）を指定；hops 1 は近傍を、hops 2 はその近傍まで返します。 |
| `list_notes` | `notes:read` | built-in | 現在のユーザーのメモ（タイトルと表示設定）を一覧表示します。 |
| `repo_extract_text` | `files:write` | built-in | 1つのリポジトリドキュメントのテキストを検索インデックスに抽出します。 |
| `repo_list_unindexed` | `files:read` | built-in | 検索用に抽出されていないリポジトリドキュメントをリストします（または、上書き後に古くなっています）。オブジェクトIDを返し、バッチ分まで；インデキシングワークフローを再実行して続行します。 |
| `shipment_eta` | `chat:use` | integrator-demo | 輸送レーンの到着日数を推定します。 |
| `translate_text` | `chat:use` | translate-chat | 目標言語にテキストを翻訳します。 |
| `update_note` | `notes:write` | built-in | ID でノートのタイトルまたは本文を更新する。 |
| `word_count` | `chat:use` | example-tools | テキストの単語数を数える。 |

## `chat_message`

モデルにチャットメッセージを1つ送り、その返答を返す。

Permission: `chat:use` · source: translate-chat

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | ユーザーが言ったこと |

## `create_note`

現在のユーザーのチームにメモを作成します。

Permission: `notes:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `body` | string | yes | ノートの本文。 |
| `title` | string | yes | 短いノートタイトル |
| `visibility` | string (team, private, shared) | no | 誰が見られるか；既定はチーム。 |

## `doc_classify`

この文書がどの種類かを、呼び出し側が与えるラベル集合から判定する。ラベル一つと確信度、一行の根拠を返します。決定的なキーワード／コンテンツタイプのルールを先に試し、次にモデルを使います（`backends` で順序を変更できます）。結果は doc_type / doc_type_confidence / doc_type_source として文書に書き込まれるため、後続のステップ — あるいはトリガー — が種類に応じてスキーマを選べます。また <key>.classification.json として文書の隣に保存されます。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `backends` | array of string | no | バックエンドの順序: "rules"、"llm"（既定は rules のあと llm） |
| `labels` | array of object | yes | 判定の対象となる文書の種類 — 答えになり得るのはこの中のいずれかだけです |
| `object` | string | yes | リポジトリオブジェクトID |
| `redact` | boolean | no | モデルへの要求を伏せ字のテキストから組み立てる: プロンプトを組み立てる前に識別子を安定したトークンへ置き換え、保存する前に元の値へ戻します |
| `redact_detectors` | array of string | no | redact が true のときに実行する検出器: "email"、"date"、"id_number"、"dictionary"、"phone"（既定は dictionary 以外のすべて） |
| `redact_terms` | array of string | no | dictionary 検出器のための名前や語句そのもの — パターンではありません |
| `rules` | array of object | no | 決定的なルール。順に試し、最初に一致したものが決定します。正規表現ではなく語句で指定し、ルールには少なくとも一つの条件が必要です |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `text` | string | no | 文書のテキスト（既定では文書から抽出します。テキストレイヤーのないスキャンでも、コンテンツタイプのルールには一致し得ます） |

## `doc_classify_eval`

ラベル付きのフィクスチャ集合に対して分類器を測定する: キー接頭辞配下で doc_type_expected 属性を持つ文書が対象です。バックエンドごと、かつラベルごとの正解率とカバレッジ、各ラベルが何と誤認されたか、そして正答と誤答それぞれの平均確信度 — レビューのしきい値で両者を切り分けられるかを示す数値 — を報告します。各バックエンドは連鎖させずに個別に実行するため rules と llm を比較でき、連鎖自体の答えも並べて報告します。何も書き込みません: 種別は記録されず、トリガーも起動しません。

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `backends` | array of string | no | 個別に測定するバックエンド: "rules"、"llm"（既定は両方） |
| `labels` | array of object | yes | 評価対象の文書種別 — これ以外を期待値とするフィクスチャは除外し、その旨を報告します |
| `prefix` | string | no | キーがこれで始まる文書のみ（既定: チーム内のすべての文書）。 |
| `rules` | array of object | no | 評価するルールセット — パイプラインが実行するのと同じルールです |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |

## `doc_extract_fields`

JSON スキーマに照らして文書のテキストから構造化フィールドを抽出する。モデルの返答は検証され、適合しなければ拒否されます — 必須フィールドの欠落、型の誤り、勝手に作られたキーなど。`object` を指定すると、フィールドは元文書の隣に <key>.extracted.json として書き出されます。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | no | 元文書のオブジェクト ID — フィールドをその隣に派生文書として書き出します。 |
| `redact` | boolean | no | モデルへの要求を伏せ字のテキストから組み立てる: プロンプトを組み立てる前に識別子を安定したトークンへ置き換え、保存する前に元の値へ戻します |
| `redact_detectors` | array of string | no | redact が true のときに実行する検出器: "email"、"date"、"id_number"、"dictionary"、"phone"（既定は dictionary 以外のすべて） |
| `redact_terms` | array of string | no | dictionary 検出器のための名前や語句そのもの — パターンではありません |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `schema` | object | yes | 抽出オブジェクトが適合するJSONスキーマ |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `text` | string | yes | ドキュメントのテキスト |

## `doc_fill_form`

リポジトリ内の PDF の AcroForm フィールドに、フィールド名と値の JSON オブジェクトから値を埋め込み、結果をその隣に <key>.filled.pdf として書き出します。テキストフィールドは文字列、チェックボックスは true または false、ラジオグループ・コンボボックス・リストボックスはそれ自身の選択肢のいずれかを取ります。フォームが持たないフィールド名は `unmatched` で報告されます（すべての名前が誤っている場合は代わりに拒否されます）。flatten が true のときはフィールドがページに描き込まれ、文書は編集できなくなります。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `flatten` | boolean | no | 埋め込んだフィールドをページの内容に描き込んで取り除き、結果を編集できないようにします（qpdf が必要） |
| `object` | string | yes | フォーム文書のオブジェクト ID — AcroForm フィールドを持つ PDF |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `values` | object | yes | フィールド名から値へ。例：{"applicant": "Arun Patel", "urgent": true} |

## `doc_list_unclassified`

まだ文書種別が付いていない、キー接頭辞配下のリポジトリ文書を一覧する — 分類バックフィルへの入力です。オブジェクト ID を返し、1 バッチで打ち切ります。続きはバックフィルをもう一度実行してください。すでに doc_type を持つ文書は飛ばされるため再実行は無償で、他の実行が派生させた出力は一覧されません。

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `prefix` | string | no | キーがこれで始まる文書のみ（既定: チーム内のすべての文書）。 |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |

## `doc_redact`

文書テキスト中の識別子を安定したトークン — <PERSON_1>、<DATE_2>、<ID_3> — に置き換え、残りからモデルへの要求を組み立てられるようにする。検出器は呼び出し側が記述するのではなく名前で選びます: email、date、id_number、dictionary（語句は呼び出し側が渡します）、phone。置き換え後のテキストは元文書の隣に <key>.redacted.txt として書き出し、トークンから値へ戻す対応表は、どのエンドポイントも返さない封緘済みの行に保存します。検出器ごとの件数を報告するため、取りこぼしが見て分かります。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `detectors` | array of string | no | 実行する検出器: "email"、"date"、"id_number"、"dictionary"、"phone"（既定は dictionary 以外のすべて。dictionary には語句が必要です） |
| `object` | string | yes | リポジトリオブジェクトID |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `terms` | array of string | no | dictionary 検出器が置き換える名前や語句そのもの — パターンではありません |
| `text` | string | no | 伏せる対象のテキスト（既定では文書から抽出します） |

## `doc_render`

フォームテンプレート（リポジトリ内の Markdown、HTML、DOCX 文書）にデータを埋め込む：{{field}}、{{a.b}}、{{#each items}}…{{/each}}（内側で {{this}} / {{@index}}）。DOCX では {{#each items}} だけの表の行が項目ごとの行ブロックを開きます。結果は元文書の隣に <key>.form.<ext> として、format が "pdf" のときは <key>.form.pdf として書き出します（Markdown または HTML テンプレートを pandoc と tectonic で変換）。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `data` | object | yes | 埋め込むデータ。例：抽出されたフィールド。 |
| `engine` | string (latex, weasyprint, libreoffice) | no | format が "pdf" のときに使う PDF エンジン："latex"（既定 — pandoc と tectonic。文章中心の文書に向く）、"weasyprint"（HTML テンプレート自身の CSS を解釈し、@page の余白、ページをまたぐヘッダーとフッター、"Page X of Y" を描画）、または "libreoffice"（埋め込み済みの DOCX テンプレートを変換）。HTML エンジンは HTML テンプレートを必要とし、src="repo:<オブジェクト ID>" でリポジトリの文書を画像として埋め込めます。LibreOffice エンジンは DOCX テンプレートを必要とし、soffice がサーバーの PATH に無ければ無効で、外部参照を宣言しているテンプレートを拒否します。 |
| `format` | string | no | 出力形式：テンプレート自身の形式（既定）または "pdf" — Markdown と HTML のテンプレートのみ |
| `object` | string | no | 元文書のオブジェクト ID — フォームはその隣に書き出されます（既定：テンプレートの隣）。 |
| `pdf_variant` | string (pdf/a-2b) | no | HTML エンジンに保存用 PDF を要求します："pdf/a-2b"。ラスター画像があると出力は規格に適合しません（エンジンが画像に Interpolate true を付け、PDF/A はこれを禁じています）— ロゴには SVG を使ってください。 |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `template` | string | yes | テンプレートドキュメントのオブジェクトIDまたはキー |

## `doc_set_type`

レビュー後に、人が判断した文書の種類を記録する。ラベルは分類が提示したラベル集合に照らして検証されるため、どのトリガーも一致し得ない種類は保存されずに拒否されます。空のラベルは種類を取り下げます — doc_type に「unknown」は存在しないため、却下の正直な記録はこれです。doc_type / doc_type_confidence / doc_type_source を source「review」、確信度 1.00 で書き込み、文書の隣の <key>.classification.json を新しいバージョンとして保存するので、バックエンドの当初の推測もその履歴に残ります。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `label` | string | yes | 判断された種類。ラベル集合とまったく同じ綴りで指定します。空にすると種類を取り下げます |
| `labels` | array of object | yes | 判断の基準となったラベル集合 — doc_classify に与えたものと同じもの |
| `object` | string | yes | リポジトリオブジェクトID |
| `rationale` | string | no | 理由をレビュー担当者自身の言葉で — 記録には残りますが、属性には書き込まれません |
| `review` | string | no | レビュー ID（由来の記録用）。 |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `verdict` | string | no | これが生じたレビューの判定: approve、revise または reject |

## `doc_text`

リポジトリ文書のテキストを返す（PDF、DOCX、HTML、Markdown、プレーンテキスト）。文書パイプラインの最初のステップで、検索インデックスの実行に依存しません。

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | yes | リポジトリオブジェクトID |
| `version` | string | no | 特定のバージョンID（デフォルト：現在のバージョン） |

## `doc_translate`

リポジトリ文書をチーム用語集を適用して翻訳し、結果をその隣に書き出す（ロケールは拡張子の前：report.md -> report.ja.md；PDF のテキストは report.ja.txt になります）。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `locale` | string | yes | 目標言語コード、例：ja, nl, es-419 |
| `object` | string | yes | ドキュメントのオブジェクトID |
| `redact` | boolean | no | モデルへの要求を伏せ字のテキストから組み立てる: プロンプトを組み立てる前に識別子を安定したトークンへ置き換え、保存する前に元の値へ戻します |
| `redact_detectors` | array of string | no | redact が true のときに実行する検出器: "email"、"date"、"id_number"、"dictionary"、"phone"（既定は dictionary 以外のすべて） |
| `redact_terms` | array of string | no | dictionary 検出器のための名前や語句そのもの — パターンではありません |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |

## `get_usage`

チームの現在の AI 使用量をクォータと比べて報告する。

Permission: `chat:use` · source: built-in

No parameters.


## `kg_extract`

1つのリポジトリ文書から、エンティティ（人、組織、製品、場所、イベント、概念）とそれらの関係を知識グラフに抽出する。各言及には原文どおりの抜粋が付きます。検証を通らない返答は拒否します。

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | yes | リポジトリオブジェクト ID |

## `kg_list_unextracted`

テキストがまだ知識グラフに抽出されていない（または上書き後に古くなった）リポジトリ文書を一覧する。オブジェクト ID をバッチ上限まで返します；続けるには index-knowledge ワークフローを再実行してください。

Permission: `files:read` · source: built-in

No parameters.


## `kg_query`

チームの文書がエンティティについて述べていること：その関係と、それに言及する文書を抜粋付きで。名前（またはエンティティ ID）を指定；hops 1 は近傍を、hops 2 はその近傍まで返します。

Permission: `files:read` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `hops` | integer | no | 1（デフォルト）または2 |
| `name` | string | yes | エンティティ名（大文字小文字を区別しない）またはエンティティ ID |
| `type` | string | no | 名前検索を1つのエンティティ種別に絞る。例：organization |

## `list_notes`

現在のユーザーのメモ（タイトルと表示設定）を一覧表示します。

Permission: `notes:read` · source: built-in

No parameters.


## `repo_extract_text`

1つのリポジトリドキュメントのテキストを検索インデックスに抽出します。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | リポジトリオブジェクトID |

## `repo_list_unindexed`

検索用に抽出されていないリポジトリドキュメントをリストします（または、上書き後に古くなっています）。オブジェクトIDを返し、バッチ分まで；インデキシングワークフローを再実行して続行します。

Permission: `files:read` · source: built-in

No parameters.


## `shipment_eta`

輸送レーンの到着日数を推定します。

Permission: `chat:use` · source: integrator-demo

| Parameter | Type | Required | Description |
|---|---|---|---|
| `lane` | string | yes | レーン（例：SIN-LAX） |

## `translate_text`

目標言語にテキストを翻訳します。

Permission: `chat:use` · source: translate-chat

| Parameter | Type | Required | Description |
|---|---|---|---|
| `source` | string | no | ソース言語コード、または自動 |
| `target` | string | yes | 対象言語コード、例えばes、nl、is |
| `text` | string | yes | 翻訳するテキスト |

## `update_note`

ID でノートのタイトルまたは本文を更新する。

Permission: `notes:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `body` | string | no | 新しい本文（任意） |
| `id` | string | yes | ノートの ID |
| `title` | string | no | 新しいタイトル（任意） |

## `word_count`

テキストの単語数を数える。

Permission: `chat:use` · source: example-tools

| Parameter | Type | Required | Description |
|---|---|---|---|
| `text` | string | yes | 単語数を数えるテキスト |

