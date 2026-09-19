# Plugins

A plugin is a directory under `plugins/` with a `plugin.json` manifest (`id`, `name`, `version`, `description`, `entry`) and an entry module. Plugins run in-process with platform privileges; placing one in the directory is the consent.

## Loaded plugins

| Plugin | Version | Tools | Workflows | Routes | Job kinds | Description |
|---|---|---|---|---|---|---|
| Founders beta onboarding (`beta-onboarding`) | 0.1.0 | — | — | — | — | SDK の init! フックで登録された、カスタマイズ済みのベータ申込フロー（founders プログラム）。 |
| Document Indexer (`doc-indexer`) | 0.1.0 | — | `index-documents` | — | — | リポジトリの文書からテキストを抽出して検索インデックスに入れるワークフロー：未インデックスのものを見つけ、分散して、それぞれ抽出します。いつでも再実行でき、変更のあったものにしか触れません。 |
| Document Pipeline (`doc-pipeline`) | 0.1.0 | — | `process-upload` | — | — | アップロードされた文書を処理：テキストを抽出し、JSONスキーマに従って構造化フィールドを取得（適合しない場合は拒否）、フォームテンプレートに埋め込み、結果をチームの言語に翻訳します。すべての出力はソースと共にレポジトリ文書で、元情報が示されます。 |
| Example Tools (`example-tools`) | 0.1.0 | `word_count` | — | `GET /word-count`, `POST /word-count` | — | サードパーティ製プラグインのサンプル：word_count ツールを追加します。 |
| Knowledge Graph (`knowledge-graph`) | 0.1.0 | — | `index-knowledge` | — | — | チームのインデックスド文書から知識グラフへエンティティや関係を抽出するワークフロー。すべての事実は元となる文書とバージョンに追溯可能。変更があった部分のみが影響を受けます。再実行可能です。 |
| rs3 — local content-addressed blob store (`rs3`) | 0.1.0 | — | — | — | — | 文書のバイト列を SHA-256 でアドレス指定してローカルファイルシステムに保存します。文書リポジトリの既定の保存先です。 |
| Translate Chat (`translate-chat`) | 0.1.0 | `chat_message`, `translate_text` | `translate-chat` | — | — | デモワークフロープラグイン：一度チャットし、返答をスペイン語/オランダ語/アイスランド語に拡散させ、それぞれをユーザーの母国語に戻す |

## The seams a plugin may fill

| Seam | How | Where it lands |
|---|---|---|
| Tools | `(provide tools)` — a list of `(name schema permission handler)`; the handler is `(conn principal args) -> result` | the same registry as built-ins: per-tool RBAC and per-team activation apply |
| Workflows | `(provide workflows)` — specs from `define-workflow`, or `workflows/*.json` | validated like an API-published spec; materialized into a team on first lookup |
| HTTP routes | `(provide routes)` — a list of `(method path permission handler doc)`; the handler is `(conn principal args) -> jsexpr` with `args` = `{params, query, body}` | mounted at `/api/x/<plugin>/<path>`, always authenticated, permission checked first; listed in [api.md](api.md) |
| Job kinds | `(provide init!)` calling `register-job-kind!`; the kind must be named `x.<plugin-id>.<name>` | the same queue as core kinds: per-team cap, quota admission, the org gate, cancel and the lease |
| Anything else | `(provide init!)` — runs with full SDK access at load | e.g. `register-blob-store!` (the `rs3` local store), `register-onboarding!` (a beta funnel experience) |
| A beta funnel bundle | a `bundle/` directory served at `/beta/bundle/<id>/` | a Tier-B custom frontend over `window.Telemachus.beta` |

See [sdk.md](sdk.md) for the authoring surfaces.
