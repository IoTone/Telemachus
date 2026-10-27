# Workflows

Workflows shipped by plugins. Each is a validated spec (the public contract, WF‑9); a team sees them under `GET /api/workflows` and runs one with `POST /api/workflows/<slug>/run {input}`. Declared inputs are required and typed.

| Workflow | Plugin | Version | Steps | Description |
|---|---|---|---|---|
| `classify-and-extract` | doc-pipeline | 1 | 7 | この文書がどの種類かを判定し（まず決定的なルール、次にモデル）、その種類を文書に記録し、その種類に対応するスキーマに照らしてフィールドを抽出する。スキーマのない種類は、分類だけ行ってそのままにします。 |
| `classify-backfill` | doc-pipeline | 1 | 2 | 接頭辞配下の文書種別をバックフィルする。まだ種別のない文書を探し、1 回の実行で最大 25 件を分類します。すでに種別のある文書は飛ばされるため再実行は安全で、大きな滞留は見つからなくなるまで繰り返し実行して解消します。モデルの予算を使わずにバックフィルするには backends に ["rules"] を渡してください。 |
| `classify-eval` | doc-pipeline | 1 | 1 | チームのラベル付きフィクスチャ — 接頭辞配下で doc_type_expected 属性を持つ文書 — に対して分類器を測定する。各バックエンドを単独で、かつラベルごとに正解率とカバレッジを報告し、各ラベルが何と誤認されたか、正答と誤答がどれほど確信を持っていたかも併せて示します。何も書き込みません: 種別は記録されずトリガーも起動しないため、フィクスチャ集合は何度でも評価できます。 |
| `classify-review-extract` | doc-pipeline | 1 | 14 | この文書がどの種類かを判定し、分類器の確信度が `min_confidence` を下回る場合は、推測せずに実行を保留して人に尋ねる。その判断は文書に記録されます — そのまま承認、別の種類へ訂正、あるいはいずれでもないときは取り下げ — そのうえで、その種類に対応するスキーマに照らしてフィールドを抽出します。 |
| `feed-propose` | feeds | 1 | 2 | エージェントが取得済みの項目 1 件を読み、その隣に提案を書き出します。その後、実行は人の判断を待って停止します。提案に対して何も実行されません — v1 に実行するツールはなく、将来できたとしても approve の分岐にのみ置かれます。 |
| `feed-triage` | feeds | 1 | 1 | 取得済みの項目 1 件を、優先度・期限・スキルとともに作業キューに載せます。キューはインデックスであり、これはトリアージが決めた内容の記録です。 |
| `index-documents` | doc-indexer | 1 | 2 | リポジトリのドキュメントから検索インデックスにテキストを抽出します。未インデックス化されたものや上書き後の古い情報を見つけたら、それぞれを抽出します。再実行しても安全で、1回につき最大40ドキュメントを処理します。 |
| `index-knowledge` | knowledge-graph | 1 | 2 | インデキシングされたリポジトリドキュメントから知識グラフにエンティティや関係を抽出します。未抽出のもの（または上書き後に古いもの）を見つけ次第、それぞれのものをモデルを使用して抽出します；検証されない回答は拒否されます。再実行しても安全で、1回につき最大40ドキュメントを処理します。 |
| `process-upload` | doc-pipeline | 1 | 6 | テキストを抽出し、JSON スキーマに照らして構造化フィールドを取り出し（適合しなければ拒否）、フォームテンプレートに埋め込み、結果をチームの言語に翻訳する。すべての出力は元文書の隣にあるリポジトリ文書で、由来が記録されます。 |
| `redact-document` | doc-pipeline | 1 | 1 | 文書テキスト中の識別子を安定したトークンに置き換え、その結果を元文書の隣に <key>.redacted.txt として書き出す。モデルへの要求が何から組み立てられるのかを、そのまま読んで確認できます。検出器は名前で選び — email、date、id_number、dictionary、phone — トークンから値へ戻す対応表は、どのエンドポイントも返さない封緘済みの行に保存します。 |
| `translate-chat` | translate-chat | 1 | 3 | 1回チャットし、返答をスペイン語・オランダ語・アイスランド語に展開してから、それぞれを戻す。 |

## `classify-and-extract` — 文書を分類してフィールドを抽出する

この文書がどの種類かを判定し（まず決定的なルール、次にモデル）、その種類を文書に記録し、その種類に対応するスキーマに照らしてフィールドを抽出する。スキーマのない種類は、分類だけ行ってそのままにします。

Plugin: `doc-pipeline` · version 1 · max steps 20 · starts at `classify`

Input:

| Name | Type |
|---|---|
| `labels` | array |
| `object_id` | string |
| `rules` | array |
| `schemas` | object |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `classify` | `tool:doc_classify` | `{"labels":"${input.labels}","object":"${input.object_id}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | next in order |
| `is_invoice` | `choice` | when `{"eq":["${steps.classify.output.result.label}","invoice"]}` then `invoice_text` else `is_letter` | next in order |
| `invoice_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `invoice_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.invoice}","step":"invoice_fields","text":"${steps.invoice_text.output.result}"}` | end · retry 1 |
| `letter_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `letter_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.letter}","step":"letter_fields","text":"${steps.letter_text.output.result}"}` | end · retry 1 |
| `is_letter` | `choice` | when `{"eq":["${steps.classify.output.result.label}","letter"]}` then `letter_text` | next in order |

## `classify-backfill` — 滞留分を分類する

接頭辞配下の文書種別をバックフィルする。まだ種別のない文書を探し、1 回の実行で最大 25 件を分類します。すでに種別のある文書は飛ばされるため再実行は安全で、大きな滞留は見つからなくなるまで繰り返し実行して解消します。モデルの予算を使わずにバックフィルするには backends に ["rules"] を渡してください。

Plugin: `doc-pipeline` · version 1 · max steps 30 · starts at `find`

Input:

| Name | Type |
|---|---|
| `backends` | array |
| `labels` | array |
| `prefix` | string |
| `rules` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `find` | `tool:doc_list_unclassified` | `{"prefix":"${input.prefix}","run":"${run.id}","step":"find"}` | next in order |
| `classify` | `map` | over `${steps.find.output.result.ids}` → `tool:doc_classify` with `{"backends":"${input.backends}","labels":"${input.labels}","object":"${item}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | end |

## `classify-eval` — 分類器を評価する

チームのラベル付きフィクスチャ — 接頭辞配下で doc_type_expected 属性を持つ文書 — に対して分類器を測定する。各バックエンドを単独で、かつラベルごとに正解率とカバレッジを報告し、各ラベルが何と誤認されたか、正答と誤答がどれほど確信を持っていたかも併せて示します。何も書き込みません: 種別は記録されずトリガーも起動しないため、フィクスチャ集合は何度でも評価できます。

Plugin: `doc-pipeline` · version 1 · max steps 5 · starts at `measure`

Input:

| Name | Type |
|---|---|
| `backends` | array |
| `labels` | array |
| `prefix` | string |
| `rules` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `measure` | `tool:doc_classify_eval` | `{"backends":"${input.backends}","labels":"${input.labels}","prefix":"${input.prefix}","rules":"${input.rules}","run":"${run.id}","step":"measure"}` | end |

## `classify-review-extract` — 分類し、迷ったら人に尋ね、そのうえで抽出する

この文書がどの種類かを判定し、分類器の確信度が `min_confidence` を下回る場合は、推測せずに実行を保留して人に尋ねる。その判断は文書に記録されます — そのまま承認、別の種類へ訂正、あるいはいずれでもないときは取り下げ — そのうえで、その種類に対応するスキーマに照らしてフィールドを抽出します。

Plugin: `doc-pipeline` · version 1 · max steps 30 · starts at `classify`

Input:

| Name | Type |
|---|---|
| `labels` | array |
| `min_confidence` | number |
| `object_id` | string |
| `rules` | array |
| `schemas` | object |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `classify` | `tool:doc_classify` | `{"labels":"${input.labels}","object":"${input.object_id}","rules":"${input.rules}","run":"${run.id}","step":"classify"}` | next in order |
| `gate` | `choice` | when `{"lt":["${steps.classify.output.result.confidence}","${input.min_confidence}"]}` then `confirm` else `is_invoice` | next in order |
| `confirm` | `review` | `{}` | next in order |
| `accept` | `tool:doc_set_type` | `{"label":"${steps.classify.output.result.label}","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"accept","verdict":"approve"}` | `is_invoice` |
| `correct` | `tool:doc_set_type` | `{"label":"${steps.confirm.output.result.answers.doc_type}","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"correct","verdict":"revise"}` | `r_is_invoice` |
| `withdraw` | `tool:doc_set_type` | `{"label":"","labels":"${input.labels}","object":"${input.object_id}","rationale":"${steps.confirm.output.result.rationale}","review":"${steps.confirm.output.result.review_id}","run":"${run.id}","step":"withdraw","verdict":"reject"}` | end |
| `invoice_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `invoice_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.invoice}","step":"invoice_fields","text":"${steps.invoice_text.output.result}"}` | end · retry 1 |
| `letter_text` | `tool:doc_text` | `{"object":"${input.object_id}"}` | next in order |
| `letter_fields` | `tool:doc_extract_fields` | `{"object":"${input.object_id}","run":"${run.id}","schema":"${input.schemas.letter}","step":"letter_fields","text":"${steps.letter_text.output.result}"}` | end · retry 1 |
| `is_invoice` | `choice` | when `{"eq":["${steps.classify.output.result.label}","invoice"]}` then `invoice_text` else `is_letter` | next in order |
| `is_letter` | `choice` | when `{"eq":["${steps.classify.output.result.label}","letter"]}` then `letter_text` else `r_is_invoice` | next in order |
| `r_is_invoice` | `choice` | when `{"eq":["${steps.correct.output.result.label}","invoice"]}` then `invoice_text` else `r_is_letter` | next in order |
| `r_is_letter` | `choice` | when `{"eq":["${steps.correct.output.result.label}","letter"]}` then `letter_text` | next in order |

## `feed-propose` — フィード項目について何をすべきかを提案する

エージェントが取得済みの項目 1 件を読み、その隣に提案を書き出します。その後、実行は人の判断を待って停止します。提案に対して何も実行されません — v1 に実行するツールはなく、将来できたとしても approve の分岐にのみ置かれます。

Plugin: `feeds` · version 1 · max steps 100 · starts at `propose`

Input:

| Name | Type |
|---|---|
| `object_id` | string |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `propose` | `tool:feed_propose` | `{"object":"${input.object_id}","run":"${run.id}","step":"propose"}` | next in order |
| `decide` | `review` | `{}` | next in order |

## `feed-triage` — 取得したフィード項目をトリアージする

取得済みの項目 1 件を、優先度・期限・スキルとともに作業キューに載せます。キューはインデックスであり、これはトリアージが決めた内容の記録です。

Plugin: `feeds` · version 1 · max steps 100 · starts at `queue`

Input:

| Name | Type |
|---|---|
| `due` | number |
| `object_id` | string |
| `priority` | number |
| `skills` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `queue` | `tool:feed_queue_put` | `{"due":"${input.due}","object":"${input.object_id}","priority":"${input.priority}","skills":"${input.skills}"}` | end |

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

## `redact-document` — 文書の識別子を伏せる

文書テキスト中の識別子を安定したトークンに置き換え、その結果を元文書の隣に <key>.redacted.txt として書き出す。モデルへの要求が何から組み立てられるのかを、そのまま読んで確認できます。検出器は名前で選び — email、date、id_number、dictionary、phone — トークンから値へ戻す対応表は、どのエンドポイントも返さない封緘済みの行に保存します。

Plugin: `doc-pipeline` · version 1 · max steps 5 · starts at `redact`

Input:

| Name | Type |
|---|---|
| `detectors` | array |
| `object_id` | string |
| `terms` | array |

Steps:

| Step | Uses | Binding | Next |
|---|---|---|---|
| `redact` | `tool:doc_redact` | `{"detectors":"${input.detectors}","object":"${input.object_id}","run":"${run.id}","step":"redact","terms":"${input.terms}"}` | end |

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

