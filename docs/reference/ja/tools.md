# Tools

Every tool the agent may call and a workflow step may use, from `define-tool` declarations and plugin registrations. Each tool checks its own permission when invoked; a workflow step also needs `tools:invoke`.

| Tool | Permission | Source | Description |
|---|---|---|---|
| `chat_message` | `chat:use` | translate-chat | モデルにチャットメッセージを1つ送り、その返答を返す。 |
| `create_note` | `notes:write` | built-in | 現在のユーザーのチームにメモを作成します。 |
| `doc_extract_fields` | `files:write` | built-in | JSON スキーマに照らして文書のテキストから構造化フィールドを抽出する。モデルの返答は検証され、適合しなければ拒否されます — 必須フィールドの欠落、型の誤り、勝手に作られたキーなど。`object` を指定すると、フィールドは元文書の隣に <key>.extracted.json として書き出されます。 |
| `doc_render` | `files:write` | built-in | フォームテンプレート（リポジトリ内の Markdown、HTML、DOCX 文書）にデータを埋め込む：{{field}}、{{a.b}}、{{#each items}}…{{/each}}（内側で {{this}} / {{@index}}）。DOCX では {{#each items}} だけの表の行が項目ごとの行ブロックを開きます。結果は元文書の隣に <key>.form.<ext> として、format が "pdf" のときは <key>.form.pdf として書き出します（Markdown または HTML テンプレートを pandoc と tectonic で変換）。 |
| `doc_text` | `files:read` | built-in | リポジトリ文書のテキストを返す（PDF、DOCX、HTML、Markdown、プレーンテキスト）。文書パイプラインの最初のステップで、検索インデックスの実行に依存しません。 |
| `doc_translate` | `files:write` | built-in | リポジトリ文書をチーム用語集を適用して翻訳し、結果をその隣に書き出す（ロケールは拡張子の前：report.md -> report.ja.md；PDF のテキストは report.ja.txt になります）。 |
| `get_usage` | `chat:use` | built-in | チームの現在の AI 使用量をクォータと比べて報告する。 |
| `kg_extract` | `files:read` | built-in | 1つのリポジトリ文書から、エンティティ（人、組織、製品、場所、イベント、概念）とそれらの関係を知識グラフに抽出する。各言及には原文どおりの抜粋が付きます。検証を通らない返答は拒否します。 |
| `kg_list_unextracted` | `files:read` | built-in | テキストがまだ知識グラフに抽出されていない（または上書き後に古くなった）リポジトリ文書を一覧する。オブジェクト ID をバッチ上限まで返します；続けるには index-knowledge ワークフローを再実行してください。 |
| `kg_query` | `files:read` | built-in | チームの文書がエンティティについて述べていること：その関係と、それに言及する文書を抜粋付きで。名前（またはエンティティ ID）を指定；hops 1 は近傍を、hops 2 はその近傍まで返します。 |
| `list_notes` | `notes:read` | built-in | 現在のユーザーのメモ（タイトルと表示設定）を一覧表示します。 |
| `repo_extract_text` | `files:write` | built-in | 1つのリポジトリドキュメントのテキストを検索インデックスに抽出します。 |
| `repo_list_unindexed` | `files:read` | built-in | 検索用に抽出されていないリポジトリドキュメントをリストします（または、上書き後に古くなっています）。オブジェクトIDを返し、バッチ分まで；インデキシングワークフローを再実行して続行します。 |
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

## `doc_extract_fields`

JSON スキーマに照らして文書のテキストから構造化フィールドを抽出する。モデルの返答は検証され、適合しなければ拒否されます — 必須フィールドの欠落、型の誤り、勝手に作られたキーなど。`object` を指定すると、フィールドは元文書の隣に <key>.extracted.json として書き出されます。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `object` | string | no | 元文書のオブジェクト ID — フィールドをその隣に派生文書として書き出します。 |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `schema` | object | yes | 抽出オブジェクトが適合するJSONスキーマ |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `text` | string | yes | ドキュメントのテキスト |

## `doc_render`

フォームテンプレート（リポジトリ内の Markdown、HTML、DOCX 文書）にデータを埋め込む：{{field}}、{{a.b}}、{{#each items}}…{{/each}}（内側で {{this}} / {{@index}}）。DOCX では {{#each items}} だけの表の行が項目ごとの行ブロックを開きます。結果は元文書の隣に <key>.form.<ext> として、format が "pdf" のときは <key>.form.pdf として書き出します（Markdown または HTML テンプレートを pandoc と tectonic で変換）。

Permission: `files:write` · source: built-in

| Parameter | Type | Required | Description |
|---|---|---|---|
| `data` | object | yes | 埋め込むデータ。例：抽出されたフィールド。 |
| `format` | string | no | 出力形式：テンプレート自身の形式（既定）または "pdf" — Markdown と HTML のテンプレートのみ |
| `object` | string | no | 元文書のオブジェクト ID — フォームはその隣に書き出されます（既定：テンプレートの隣）。 |
| `run` | string | no | ワークフロー実行 ID（由来の記録用）。 |
| `step` | string | no | ワークフローステップ ID（由来の記録用）。 |
| `template` | string | yes | テンプレートドキュメントのオブジェクトIDまたはキー |

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

