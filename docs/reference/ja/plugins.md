# Plugins

A plugin is a directory under `plugins/` with a `plugin.json` manifest (`id`, `name`, `version`, `description`, `entry`, and optionally `csp`) and an entry module. Plugins run in-process with platform privileges; placing one in the directory is the consent.

## Loaded plugins

**CSP** is the Content-Security-Policy its bundle pages are served under: `strict` is the default and the console's own posture (no inline script, this origin only), and `relaxed` is the escape hatch a manifest asks for with `"csp": "relaxed"` — the baseline policy every other response carries, which permits an inline `<script>`. An operator reads it here because a relaxed page is a deliberate narrowing of what this instance enforces on code it links to.

| Plugin | Version | CSP | Tools | Workflows | Routes | Public routes | Job kinds | Formats | Description |
|---|---|---|---|---|---|---|---|---|---|
| Founders beta onboarding (`beta-onboarding`) | 0.1.0 | strict | — | — | — | — | — | — | SDK の init! フックで登録された、カスタマイズ済みのベータ申込フロー（founders プログラム）。 |
| Document Indexer (`doc-indexer`) | 0.1.0 | strict | — | `embed-documents`, `index-documents`, `transcribe-documents` | — | — | — | — | リポジトリの文書からテキストを抽出して検索インデックスに入れるワークフロー：未インデックスのものを見つけ、分散して、それぞれ抽出します。いつでも再実行でき、変更のあったものにしか触れません。 |
| Document Pipeline (`doc-pipeline`) | 0.1.0 | strict | — | `classify-and-extract`, `classify-backfill`, `classify-eval`, `classify-review-extract`, `process-upload`, `redact-document` | — | — | — | — | アップロードされた文書を処理：テキストを抽出し、JSONスキーマに従って構造化フィールドを取得（適合しない場合は拒否）、フォームテンプレートに埋め込み、結果をチームの言語に翻訳します。すべての出力はソースと共にレポジトリ文書で、元情報が示されます。 |
| Example Tools (`example-tools`) | 0.1.0 | strict | `word_count` | — | `GET /ping`, `GET /word-count`, `POST /word-count` | `GET /ping` | `x.example-tools.word-count` | `application/rtf` | サードパーティ製プラグインのサンプル：word_count ツールを追加します。 |
| Feed work queue (`feeds`) | 0.1.0 | strict | `feed_propose`, `feed_queue_put`, `feed_queue_status` | `feed-propose`, `feed-triage` | `GET /queue`, `POST /items/:id/status` | — | — | — | イシュー #114 のスライス 5 と 6：フィードが取得したドキュメントに対する、優先度付きで型のあるインデックスと、その 1 件について何をすべきかを「提案する」エージェント。提案と実行のあいだにはレビュー手順が入ります。 |
| Inbox — things that need a person's attention (`inbox`) | 0.1.0 | strict | `inbox_raise` | — | `GET /digest`, `GET /items`, `GET /items/:id`, `POST /items`, `POST /items/:id/ack`, `POST /items/:id/reopen`, `POST /items/:id/resolve`, `POST /items/:id/snooze`, `POST /items/:id/suppress`, `POST /items/batch` | — | `x.inbox.wake` | — | 外部の何かが登録し、人が対応する項目を集めるチームの受信箱です。`(source, key)` を鍵とする冪等な取り込み、閉じたライフサイクル（open、acknowledged、snoozed、suppressed、resolved）、自由形式のスコープ・ラベル、スコープを考慮したダイジェストを持ちます。項目の意味については何も決めず、項目の出所にも関与しません。 |
| Integrator demo (`integrator-demo`) | 0.1.0 | strict | `shipment_eta` | — | `GET /eta`, `POST /eta` | — | `x.integrator-demo.lane-report` | — | docs/integrators-guide.md の実装例：ツール、認証付きルート、バックグラウンドジョブ種別、テーマを適用した画面。 |
| Knowledge Graph (`knowledge-graph`) | 0.1.0 | strict | — | `index-knowledge` | — | — | — | — | チームのインデックスド文書から知識グラフへエンティティや関係を抽出するワークフロー。すべての事実は元となる文書とバージョンに追溯可能。変更があった部分のみが影響を受けます。再実行可能です。 |
| Matrix — notify a team in a room (`matrix`) | 0.1.0 | strict | — | — | `DELETE /rooms/:id`, `GET /rooms`, `PATCH /rooms/:id`, `POST /rooms`, `POST /rooms/:id/test` | — | `x.matrix.notify` | — | プラットフォーム自身のイベントを、運用者が自分で運用する Matrix ホームサーバーのルームへ送信します。任意の構成要素です。ホームサーバーが設定されていなければ、何も登録しません。 |
| OCR (`ocr`) | 0.1.0 | strict | — | — | — | — | — | — | 写真やスキャンされた PDF から Tesseract でテキストを読み取り、単語単位でページと領域の由来を記録します。 |
| Research Archive (`research`) | 0.1.0 | strict | — | `distil-bookmarks` | — | — | — | — | ブックマークしたページを蒸留するワークフロー。まだ処理が追いついていない保存済みページを見つけ、検索用にテキストを抽出し、そこから事実をナレッジグラフへ取り出す。いつ再実行してもよく、追いついていないものだけに触れる。 |
| rs3 — local content-addressed blob store (`rs3`) | 0.1.0 | strict | — | — | — | — | — | — | 文書のバイト列を SHA-256 でアドレス指定してローカルファイルシステムに保存します。文書リポジトリの既定の保存先です。 |
| s3 — object-storage blob store (`s3blobs`) | 0.1.0 | strict | — | — | — | — | — | — | SHA-256 でアドレス指定し、既定でサーバー側暗号化を行って、S3 互換バケット（AWS S3、MinIO、Ceph RGW）に文書のバイト列を保存します。 |
| Translate Chat (`translate-chat`) | 0.1.0 | strict | `chat_message`, `translate_text` | `translate-chat` | — | — | — | — | デモワークフロープラグイン：一度チャットし、返答をスペイン語/オランダ語/アイスランド語に拡散させ、それぞれをユーザーの母国語に戻す |

## The seams a plugin may fill

| Seam | How | Where it lands |
|---|---|---|
| Tools | `(provide tools)` — a list of `(name schema permission handler [agent?])`; the handler is `(conn principal args) -> result`, and the optional fifth element is `#f` for a tool only a workflow step should call | the same registry as built-ins: per-tool RBAC and per-team activation apply |
| Workflows | `(provide workflows)` — specs from `define-workflow`, or `workflows/*.json` | validated like an API-published spec; materialized into a team on first lookup |
| HTTP routes | `(provide routes)` — a list of `(method path permission handler [doc] [auth])`; the handler is `(conn principal args) -> jsexpr or response` with `args` = `{params, query, body, headers}`, and a route declared `'public` takes `(conn args)` instead | mounted at `/api/x/<plugin>/<path>`; authenticated by default with the permission checked first, or served with no credential at all when the route declares `'public` (G13). Listed in [api.md](api.md) |
| Job kinds | `(provide init!)` calling `register-job-kind!`; the kind must be named `x.<plugin-id>.<name>` | the same queue as core kinds: per-team cap, quota admission, the org gate, cancel and the lease |
| Formats | `(provide init!)` calling `register-extractor!` with a content type | the search index, `doc_text` and every workflow over them. Claiming a type the platform already reads REPLACES its reader — that is how a local OCR engine takes over `application/pdf` |
| Anything else | `(provide init!)` — runs with full SDK access at load | e.g. `register-blob-store!` (the `rs3` local store), `register-onboarding!` (a beta funnel experience) |
| A beta funnel bundle | a `landing/` directory, served PUBLICLY at `/beta/bundle/<id>/` | a Tier-B custom frontend over `window.Telemachus.beta`, for prospects who have no token. Served under the strict policy unless the manifest declares `"csp": "relaxed"` |
| Authenticated screens | a `bundle/` directory, served at `/api/x/<id>/bundle/` | a bearer token is required and the response is `private, no-store`; served under the strict policy (no inline script), so its own code is a file in the bundle — `"csp": "relaxed"` is the escape hatch |

See [sdk.md](sdk.md) for the authoring surfaces.
