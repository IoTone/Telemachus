# Workflows

Workflows shipped by plugins. Each is a validated spec (the public contract, WF‑9); a team sees them under `GET /api/workflows` and runs one with `POST /api/workflows/<slug>/run {input}`. Declared inputs are required and typed.

| Workflow | Plugin | Version | Steps | Description |
|---|---|---|---|---|
| `index-documents` | doc-indexer | 1 | 2 | リポジトリのドキュメントから検索インデックスにテキストを抽出します。未インデックス化されたものや上書き後の古い情報を見つけたら、それぞれを抽出します。再実行しても安全で、1回につき最大40ドキュメントを処理します。 |
| `index-knowledge` | knowledge-graph | 1 | 2 | インデキシングされたリポジトリドキュメントから知識グラフにエンティティや関係を抽出します。未抽出のもの（または上書き後に古いもの）を見つけ次第、それぞれのものをモデルを使用して抽出します；検証されない回答は拒否されます。再実行しても安全で、1回につき最大40ドキュメントを処理します。 |
| `process-upload` | doc-pipeline | 1 | 6 | テキストを抽出し、JSON スキーマに照らして構造化フィールドを取り出し（適合しなければ拒否）、フォームテンプレートに埋め込み、結果をチームの言語に翻訳する。すべての出力は元文書の隣にあるリポジトリ文書で、由来が記録されます。 |
| `translate-chat` | translate-chat | 1 | 3 | 1回チャットし、返答をスペイン語・オランダ語・アイスランド語に展開してから、それぞれを戻す。 |

## `index-documents` — 文書のインデックス作成

リポジトリのドキュメントから検索インデックスにテキストを抽出します。未インデックス化されたものや上書き後の古い情報を見つけたら、それぞれを抽出します。再実行しても安全で、1回につき最大40ドキュメントを処理します。

Plugin: `doc-indexer` · version 1 · max steps 50 · starts at `find`

Takes no input.

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:repo_list_unindexed` | `{}` | next in order |
| `extract` | `map` | over `${steps.find.output.result}` → `tool:repo_extract_text` with `{"id":"${item}"}` | end |

## `index-knowledge` — 知識のインデックス作成

インデキシングされたリポジトリドキュメントから知識グラフにエンティティや関係を抽出します。未抽出のもの（または上書き後に古いもの）を見つけ次第、それぞれのものをモデルを使用して抽出します；検証されない回答は拒否されます。再実行しても安全で、1回につき最大40ドキュメントを処理します。

Plugin: `knowledge-graph` · version 1 · max steps 50 · starts at `find`

Takes no input.

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:kg_list_unextracted` | `{}` | next in order |
| `extract` | `map` | over `${steps.find.output.result}` → `tool:kg_extract` with `{"object":"${item}"}` | end |

## `process-upload` — アップロードした文書を処理する

テキストを抽出し、JSON スキーマに照らして構造化フィールドを取り出し（適合しなければ拒否）、フォームテンプレートに埋め込み、結果をチームの言語に翻訳する。すべての出力は元文書の隣にあるリポジトリ文書で、由来が記録されます。

Plugin: `doc-pipeline` · version 1 · max steps 40 · starts at `text`

Input:

| Name | Type |
|---|---|
| `locales` | array |
| `object_id` | string |
| `schema` | object |
| `template` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schema}","step":"fields","text":"${steps.text.output.result}"}` | next in order · retry 1 |
| `has_form` | `choice` | when `{"empty":["${input.template}"]}` then `translate_source` else `form` | next in order |
| `form` | `tool:doc_render` | `{"data":"${steps.fields.output.result.fields}","object":"${input.object_id}","run":"${run.id}","step":"form","template":"${input.template}"}` | next in order |
| `translate_form` | `map` | over `${input.locales}` → `tool:doc_translate` with `{"locale":"${item}","object":"${steps.form.output.result.object_id}","run":"${run.id}","step":"translate"}` | end |
| `translate_source` | `map` | over `${input.locales}` → `tool:doc_translate` with `{"locale":"${item}","object":"${input.object_id}","run":"${run.id}","step":"translate"}` | end |

## `translate-chat` — 翻訳チャットワークフロー

1回チャットし、返答をスペイン語・オランダ語・アイスランド語に展開してから、それぞれを戻す。

Plugin: `translate-chat` · version 1 · max steps 20 · starts at `chat`

Input:

| Name | Type |
|---|---|
| `message` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `chat` | `tool:chat_message` | `{"text":"${input.message}"}` | next in order |
| `to_all` | `map` | over `["es","nl","is"]` → `tool:translate_text` with `{"source":"${principal.locale}","target":"${item}","text":"${steps.chat.output.result}"}` | next in order |
| `back_home` | `map` | over `${steps.to_all.output.results}` → `tool:translate_text` with `{"target":"${principal.locale}","text":"${item.result}"}` | end |

