# HTTP API

Every route the server dispatches, in matching order, from the declared route table (`server/routes.rkt`). `auth` is how a route authenticates: **public** needs no credential; **bearer** a session or API token; **provision** the hosted-mode provisioning token; **superadmin** and **org-admin** the two multi-tenancy planes. The permission is the one the handler enforces on its main path — owner-ok and resource grants may admit a caller the role would not. A feature flag, when named, must be on for the team.

Path segments written `:name` are parameters; `*name` takes the rest of the path.

| Method | Path | Auth | Permission | Feature | Description |
|---|---|---|---|---|---|
| GET | `/` | public | — | — | コンソール（TELEMACHUS_HOME=beta のときはベータ申込フロー）。HTML のタイトルはインスタンスのブランディングから書き換えられます。 |
| GET | `/index.html` | public | — | — | コンソール |
| GET | `/login` | public | — | — | コンソール、まずサインイン — ベータのランディングに依存しない URL。 |
| GET | `/activate` | public | — | — | マジックリンク認証画面（ホストモード）のコンソール. |
| GET | `/health` | public | — | — | 死活確認：{ok, multitenant} のみ — バージョン、KDF、TLS の状態は GET /api/admin/status にあります。 |
| GET | `/beta-sdk.js` | public | — | — | Tier-B オンボーディングバンドルが読み込むブラウザ SDK（window.Telemachus.beta）。 |
| GET | `/beta/bundle/:plugin/*path` | public | — | — | Tier-Bオンボーディングプラグインのバンドルディレクトリからのファイル |
| GET | `/api/x/:plugin/bundle/*path` | bearer | — | — | A file from a loaded plugin's AUTHENTICATED bundle (plugins/<id>/bundle/): a bearer token is required and the response is never cached by a shared cache. |
| GET | `/beta/template` | public | — | — | Tier-C のサンドボックス化 HTML テンプレート。体験オーバーレイでローカライズされます。 |
| GET | `/api/config` | public | — | — | 公開インスタンス設定：ホームモード、マルチテナントフラグ、ローカライゼーションポリシー（既定ロケール、利用可能なロケール、切り替えの可否）。サインイン画面はトークンを持つ前に読み込みます。 |
| GET | `/api/branding` | public | — | — | タイトル、タグライン、ロゴ。公開：サインイン画面が描画します。会社のホスト名では、またはその会社のサインイン済みユーザーには、会社自身のもの（TEN-2d）。 |
| PUT | `/api/branding` | bearer | `instance:manage` | — | インスタンスのタイトルとキャッチコピーを設定してください。 |
| POST | `/api/branding/logo` | bearer | `instance:manage` | — | インスタンスロゴをアップロード（マークとワードマークを置き換えます） |
| GET | `/api/i18n/catalog` | public | — | — | ?locale= に対するコンソールの文字列。サーバー側でフォールバックチェーンを通して解決済み。公開：サインイン画面が必要とします。 |
| PUT | `/api/i18n` | bearer | `instance:manage` | — | インスタンスのデフォルト言語と、ユーザーが切り替える可否を設定します。 |
| GET | `/api/l10n/coverage` | bearer | `localization:read` | — | ローカライゼーションマネージャーのカタログのロケール別カバレッジ：総数、承認済み、機械翻訳、未翻訳、古いもの。 |
| GET | `/api/l10n/messages` | bearer | `localization:read` | — | 1つのロケールのメッセージ。?status=、?ns=、?q= で絞り込み、ページ送りできます。 |
| POST | `/api/l10n/import` | bearer | `localization:manage` | — | ディスク上のカタログをマネージャーのテーブルに取り込む。 |
| POST | `/api/l10n/export` | bearer | `localization:manage` | — | ロケールの承認済み文字列を locales/<locale>.json に書き戻す。承認済みが何もないロケールは拒否します。 |
| POST | `/api/l10n/draft` | bearer | `localization:manage` | — | ロケールの未翻訳文字列に対して AI の下書きを、20件ずつのスケジューラジョブでキューに入れる。クォータで計量されます。 |
| POST | `/api/l10n/discard` | bearer | `localization:manage` | — | ロケールの機械翻訳の下書きを削除する（人の作業には触れません）。 |
| PUT | `/api/l10n/messages/:id` | bearer | `localization:translate` | — | 1メッセージの翻訳を提出します。 |
| POST | `/api/l10n/review/:id` | bearer | `localization:review` | — | 翻訳を承認または差し戻す。翻訳者は自分の翻訳を承認できません。 |
| GET | `/api/beta/config` | public | — | — | 公開されたオンボーディング体験の公共セグメント（フィールド、コピー、テーマ）が1つの言語で表示されます。 |
| OPTIONS | `/api/beta/signup` | public | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| OPTIONS | `/api/beta/config` | public | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| OPTIONS | `/api/beta/challenge` | public | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| GET | `/api/beta/experience` | bearer | — | — | チームの下書きのオンボーディング体験（判定プロンプトを含む）。 |
| PUT | `/api/beta/experience` | bearer | — | — | オンボーディング体験のドラフトを保存します。 |
| POST | `/api/beta/experience/publish` | bearer | — | — | 保存済みの下書きを公開する；以後は環境変数で投入された既定値より優先されます。 |
| POST | `/api/beta/assets` | bearer | — | — | オンボーディング資産（ロゴ、ヒーロー画像、フォント）をアップロード（base64でJSON形式）、2MiBまで |
| GET | `/api/beta/assets` | bearer | — | — | チームのオンボーディング資産をリストします。 |
| GET | `/api/beta/asset/:id` | public | — | — | オンボーディングアセットを1つ配信する。公開：申込フローとブランディングロゴはトークンなしで読み込みます。 |
| DELETE | `/api/beta/asset/:id` | bearer | — | — | オンボーディングアセットを削除します。 |
| GET | `/api/beta/challenge` | public | — | — | 申込前に申込フローが解く proof-of-work チャレンジ。 |
| POST | `/api/beta/signup` | public | — | — | オンボーディングフォームを送信する：公開された体験に対して検証され、不正利用対策で制限され、モデルが設定されていればモデルが判定します。 |
| GET | `/api/beta/prospects` | bearer | — | — | 申込フローが捕捉した見込み客を、シグナルと判定とともに一覧する。 |
| POST | `/api/beta/prospects/:id/decide` | bearer | — | — | 見込み客を受け入れる、または辞退する。 |
| POST | `/api/bootstrap` | public | — | — | 初回のみ：オペレーター、最初の組織とチームを作成する。オペレーターのトークンを返します。インスタンスにユーザーがいれば拒否します。 |
| POST | `/api/provision` | provision | — | — | ホストモード：このインスタンスに所有者1名とマジックアクティベーションリンクをプロビジョニングする。 |
| POST | `/api/activate` | public | — | — | ホストモード：アクティベーショントークンを交換し、所有者のパスワードを設定します |
| POST | `/api/instance/suspend` | provision | — | — | ホストモード：テナントを一時停止（書き込みは402で拒否されます） |
| POST | `/api/instance/resume` | provision | — | — | ホストモード：一時停止したテナントを再開 |
| POST | `/api/instance/quota` | provision | — | — | ホストモード：テナントチームのクォータ制限を設定します。 |
| POST | `/api/login` | public | — | — | ユーザー名とパスワードでサインインする（2FA が有効なら TOTP コードも）。ベアラートークンを返します。 |
| POST | `/api/2fa/enable` | bearer | — | — | 呼び出し元の TOTP 二要素認証を有効にする；シークレットを一度だけ返します。 |
| DELETE | `/api/2fa` | bearer | — | — | Turn the caller's own TOTP off, so the old seed stops working and they must enrol again. |
| DELETE | `/api/admin/users/:id/2fa` | bearer | `instance:manage` | — | Revoke a user's TOTP seed (issue #19): a seed that may sit in a database dump cannot be rotated by using it, so an operator can force a re-enrolment. |
| POST | `/api/password` | bearer | — | — | 呼び出し元のパスワードを変更します。 |
| GET | `/api/whoami` | bearer | — | — | 呼び出し元：ユーザー、チーム、オペレーターフラグ、組織、組織ロール、ロケール、権限。 |
| POST | `/api/profile` | bearer | — | — | 呼び出し元のプロフィール(表示名、ロケール)を更新します。 |
| POST | `/api/members` | bearer | `members:manage` | — | 呼び出し元のチームに役割を付けてメンバーを追加；新しいメンバーの最初のトークンを返します。 |
| GET | `/api/members` | bearer | — | — | チームのメンバーと役割 |
| GET | `/api/admin/status` | bearer | `instance:manage` | — | インスタンスの状態：バージョン、KDF、TLS とマルチテナントのフラグ、そしてユーザー・チーム・組織・ノート・トークン・監査イベント・テナントの件数。 |
| POST | `/api/orgs` | superadmin | `instance:manage` | — | 会社を作成：org、最初のチーム、所有者。明示的なスラッグは自然キーです（再実行で409エラー） |
| GET | `/api/orgs` | superadmin | `instance:manage` | — | インスタンス上のすべての組織をリスト表示します。 |
| POST | `/api/orgs/:ref/suspend` | superadmin | `instance:manage` | — | 会社（id またはスラッグ）を停止する；その中のすべてのチームが読み取り専用になります。 |
| POST | `/api/orgs/:ref/resume` | superadmin | `instance:manage` | — | 一時停止中の企業を再開します。 |
| POST | `/api/orgs/:ref/quota` | superadmin | `instance:manage` | — | 組織レベルのクォータを設定；チームはその下に配置されます |
| GET | `/api/orgs/:ref` | superadmin | `instance:manage` | — | 1つの会社、そのチームとクォータ。 |
| PATCH | `/api/orgs/:ref` | superadmin | `instance:manage` | — | 会社の名前を変更する、プランを変更する（そのプランの上限を再適用します）、および／またはホスト名を設定する（{domain}、null でクリア）：そのホストで配信されるコンソールは、サインイン前から会社のブランディングをまといます（TEN-2d）。 |
| POST | `/api/admin/seed-tenants` | superadmin | `instance:manage` | — | 既知の開発用パスワードで Acme と Globex を投入する — デモ用の固定データのみ。 |
| GET | `/api/org` | org-admin | `org:read` | — | 呼び出し元の会社 |
| GET | `/api/org/teams` | org-admin | `org:read` | — | 呼び出し元の会社のチーム。 |
| POST | `/api/org/teams` | org-admin | `org:manage` | — | 呼び元の会社でチームを作成します。 |
| POST | `/api/org/members` | org-admin | `org:manage` | — | 呼び出し元の会社のチームに人物を追加します。オプションで組織ロール（org_admin, org_owner, org_reader）も指定できます。 |
| PATCH | `/api/org/members/:id` | org-admin | `org:manage` | — | 人の組織ロールを設定またはクリアする — 既存ユーザーを org_reader にする方法（TEN-2h）。自分自身には不可。 |
| GET | `/api/org/audit` | org-admin | `org:read` | — | 会社の監査ログ。 |
| GET | `/api/org/branding` | org-admin | `org:read` | — | 会社自身のブランディング（TEN-2d）— 何も設定していなければ、own:false を添えてインスタンスのもの。 |
| PUT | `/api/org/branding` | org-admin | `org:manage` | — | 会社のタイトル・タグライン・ロゴを設定する：会社のホスト名で、またその会社のサインイン済みユーザーに対して、コンソールがまとうもの。 |
| DELETE | `/api/org/branding` | org-admin | `org:manage` | — | 会社のブランディングを取り下げる；そのユーザーには再びインスタンスのものが表示されます。 |
| POST | `/api/org/branding/logo` | org-admin | `org:manage` | — | 会社のロゴをアップロードし（base64）、会社のマークにする。 |
| POST | `/api/notes` | bearer | `notes:write` | — | 公開範囲を指定してノートを作成する。 |
| GET | `/api/notes` | bearer | `notes:read` | — | 呼び出し元が読めるノートを一覧する；?scope=org は会社内のすべてのチームにわたります（org_reader にはチーム公開のノートだけが見え、非公開のものは見えません）。 |
| POST | `/api/documents` | bearer | `files:write` | — | テキストドキュメントを作成する（content_type が text/markdown のrepositoryオブジェクト）。 |
| GET | `/api/documents` | bearer | `files:read` | — | 文書をリスト表示します。 |
| GET | `/api/documents/:id` | bearer | `files:read` | — | 一つのテキストドキュメントとその本文。 |
| PUT | `/api/documents/:id` | bearer | `files:write` | — | テキスト文書のタイトル・本文・公開範囲を更新する（新しいバージョン）。 |
| DELETE | `/api/documents/:id` | bearer | `files:delete` | — | テキストドキュメントを削除します。 |
| POST | `/api/notes/:id/share` | bearer | `notes:manage` | — | ユーザー（所有者、またはnotes:manage）とメモを共有します。与えられた権限はnotes:*のものでなければなりません。 |
| GET | `/api/notes/:id` | bearer | `notes:read` | — | 1件のノート。 |
| PUT | `/api/notes/:id` | bearer | `notes:write` | — | ノートを更新します。 |
| DELETE | `/api/notes/:id` | bearer | `notes:delete` | — | ノートを削除します。 |
| POST | `/api/ai/echo` | bearer | `chat:use` | — | クォータの動作確認用の、モデルを使わない計量付きエコー。 |
| POST | `/api/ai/chat` | bearer | `chat:use` | `chat` | モデルの1ターン。クォータで許可され（ai.requests、ai.tokens.total）、チームの ai.concurrency で制御されます。名前付きエグゼキュータへのルーティングには instance:manage が必要です。 |
| POST | `/api/ai/chat/stream` | bearer | `chat:use` | `chat` | 同じターンを Server-Sent Events で返し、終了時に計量します。 |
| POST | `/api/agent` | bearer | `chat:use` | `agent` | チームの有効なツールに対してツールを使用するエージェントループを実行；すべてのツール呼び出しはRBACチェックとメーター処理が行われます。 |
| POST | `/api/translate/catalog` | bearer | `chat:use` | `translate` | ロケールカタログ全体を、プレースホルダーを保ったまま翻訳する。 |
| POST | `/api/translate` | bearer | `chat:use` | `translate` | 目標言語にテキストを翻訳し、チーム用語集を使用します。 |
| GET | `/api/translate` | bearer | `chat:use` | — | チームの翻訳履歴 |
| POST | `/api/glossary` | bearer | `settings:manage` | — | 対象言語の用語集に用語を追加または更新する。 |
| GET | `/api/glossary` | bearer | `chat:use` | — | チーム用語集. |
| GET | `/api/ai/model` | bearer | — | — | 設定されているモデル（またはシミュレーションの代替が使われていること）。 |
| GET | `/api/model-roles` | bearer | — | — | チームの一括処理をロールごとにどのエグゼキュータへ送るか（utility：知識グラフとフィールド抽出、翻訳の下書き）、およびインスタンスの既定値。 |
| PUT | `/api/model-roles` | bearer | `settings:manage` | — | チームのモデルロールを設定する：{roles: {utility: <エグゼキュータ名> \| null}}。エグゼキュータは存在している必要があります；null はインスタンスの既定値に戻り、それもなければローカルモデルになります。 |
| GET | `/api/executors` | bearer | — | — | ローカルエグゼキュータ、環境変数で設定されたプッシュ型、API で作成されたもの（プッシュ型、またはワーカー付きのプル型）を、状態とともに。 |
| POST | `/api/executors` | bearer | `instance:manage` | — | エグゼキュータを作成する：{name, mode: pull\|push, model?, url?, key?, capabilities?, org_id?}。プル型エグゼキュータのワーカートークンはこのレスポンスに含まれ、二度と表示されません。 |
| DELETE | `/api/executors/:id` | bearer | `instance:manage` | — | エグゼキュータを退役させる：ワーカートークンは失効し、保持していたジョブはキューに戻ります。 |
| POST | `/api/org/executors` | org-admin | `org:manage` | — | 呼び出し元の会社に紐づくエグゼキュータを作成する（TEN-2e）：その会社のチームにだけ提供されます。 |
| POST | `/api/workers/claim` | bearer | `jobs:execute` | — | プル型ワーカーが実行可能な次のリモートジョブを取得する：{kinds, models, max_wait}；何もなければ 204。ジョブにはリースが付きます。 |
| POST | `/api/workers/jobs/:id/heartbeat` | bearer | `jobs:execute` | — | このワーカーが保持するジョブのリースを延長する。 |
| POST | `/api/workers/jobs/:id/complete` | bearer | `jobs:execute` | — | 結果を送信する：{result}。現在のリース保持者からのみ受け付け、種別ごとに検証されます。 |
| POST | `/api/workers/jobs/:id/fail` | bearer | `jobs:execute` | — | 失敗を報告する：{error}。現在のリース保持者からのみ受け付けます。 |
| GET | `/api/usage` | bearer | — | — | チームのクォータ次元ごとの使用量、上限、残り。 |
| POST | `/api/quota` | bearer | `instance:manage` | — | 呼び出し元チームのクォータ上限を設定する（次元、上限、ウィンドウ）。 |
| GET | `/api/tools` | bearer | — | — | 登録済みのツールとその権限、ソースおよびチーム別に有効化された状態。 |
| POST | `/api/tokens` | bearer | `settings:manage` | — | API トークンを発行する。任意でスコープと ttl（秒。既定は90日；長寿命のマシントークンには "never"）を指定；生のトークンは一度だけ表示されます。 |
| GET | `/api/tokens` | bearer | `settings:manage` | — | チームのAPIトークン |
| DELETE | `/api/tokens/:id` | bearer | `settings:manage` | — | API トークンを失効させる。 |
| GET | `/api/search` | bearer | — | `search` | ノート、リポジトリオブジェクト（キー、ファイル名、抽出テキスト）、知識グラフのエンティティを検索する；各行は can? でフィルタ；?scope=org は org_reader 向けに会社内のチームにわたります。 |
| GET | `/api/audit` | bearer | `settings:manage` | — | チームの最近の監査イベント。 |
| POST | `/api/jobs` | bearer | `chat:use` | — | 登録された種類のスケジューラジョブをキューイングします。 |
| GET | `/api/jobs` | bearer | — | — | チームのジョブ、最新から |
| POST | `/api/jobs/:id/cancel` | bearer | — | — | キューに並んでいるジョブをキャンセル（実行中のジョブは完了します）。 |
| GET | `/api/jobs/:id` | bearer | — | — | 1つのジョブとその結果またはエラー |
| GET | `/api/repo` | bearer | `files:read` | — | ?prefix= でリポジトリオブジェクトを一覧する（ページ送り）；?shared=1 は呼び出し元が有効な権限付与を持ち所有していないものだけ；?scope=org は会社内のすべてのチームにわたります（TEN-2h）。 |
| POST | `/api/repo-obj/:id/share` | bearer | `files:manage` | — | 組織内のユーザーまたはチームと共有する：{principal_type, principal_id, capability: view\|edit\|manage, expires_at?}。{user_id} は従来どおり view を意味します。 |
| POST | `/api/repo-obj/:id/unshare` | bearer | `files:manage` | — | プリンシパルがそのオブジェクトに持つすべての権限付与を取り消す。 |
| GET | `/api/repo-obj/:id/grants` | bearer | `files:manage` | — | 1つのプリンシパルにつき1行: 能力、権限、授与者、期限、期限切れ |
| GET | `/api/repo-obj/:id/derivations` | bearer | `files:read` | — | 由来: 文書がどの実行とステップから派生したか |
| GET | `/api/repo-obj/:id/processing` | bearer | `files:read` | — | 「処理履歴」：派生した文書、元の文書、そしてこの文書に触れたすべての実行。 |
| GET | `/api/share-targets` | bearer | `files:read` | — | 文書を誰と共有できるか：チームのメンバーと組織内のチーム。 |
| POST | `/api/repo-obj/:id/visibility` | bearer | `files:manage` | — | プライベート、チームまたは共有に設定します。 |
| GET | `/api/repo-obj/:id/content` | bearer | `files:read` | — | バイト列をダウンロードする（履歴は ?version=）。型がインライン許可リストにない限り、添付ファイルとして nosniff 付きで返します。 |
| POST | `/api/repo-obj/:id/presign` | bearer | `files:read` | — | 呼び出し元自身の最新の S3 キーで署名された、期限付きの事前署名 S3 URL。 |
| GET | `/api/repo-obj/:id` | bearer | `files:read` | — | バージョン付きのオブジェクトメタデータ |
| DELETE | `/api/repo-obj/:id` | bearer | `files:delete` | — | オブジェクトを削除する（他のバージョンから参照されなくなったブロブは解放されます）。 |
| PUT | `/api/repo/*key` | bearer | `files:write` | — | 生のボディをキーにアップロードする（?filename=, ?visibility=）；既存のキーへの書き込みはバージョンを追加します。トリガーはここで評価されます。 |
| GET | `/api/s3/credentials` | bearer | — | — | 呼び出し元の S3 アクセスキー（シークレットは二度と表示されません）と、それを使うエンドポイント／バケット。 |
| POST | `/api/s3/credentials` | bearer | — | — | S3アクセスキーを発行し、オプションで範囲指定（トリガーが発生するプレフィックスに対してworkflows:runを追加します）。 |
| DELETE | `/api/s3/credentials/:id` | bearer | — | — | S3アクセスキーを無効にする；そのアクセスキーで署名されたプレシグナードリンクも無効になります。 |
| POST | `/api/workflows` | bearer | `workflows:write` | `workflows` | ワークフロー仕様を公開する（検証済み；未知のフィールドは拒否）；同じスラッグの再公開はバージョンを上げます。 |
| GET | `/api/workflows` | bearer | `workflows:read` | `workflows` | チームのワークフロー定義。プラグイン提供のものは初回参照時に実体化されます。 |
| GET | `/api/workflows/schema` | public | — | — | ワークフロー仕様フォーマット：バージョン、ステップ種類、バインディング参照、述語 |
| POST | `/api/workflows/:slug/run` | bearer | `workflows:run` | `workflows` | {input} で実行を開始する；宣言された入力は必須で型付きです。202 と実行を返します。 |
| GET | `/api/doc-triggers` | bearer | `workflows:read` | `workflows` | チームのアップロードトリガーと、チームの残り AI 予算。 |
| POST | `/api/doc-triggers` | bearer | `workflows:write` | `workflows` | トリガーを作成：workflow_slug, match_prefix, match_types, input, fire_on_derived. |
| GET | `/api/doc-triggers/:id` | bearer | `workflows:read` | — | 1つのトリガーとその発火履歴（どのバージョン、どの実行、あるいはなぜ発火しなかったか）。 |
| PATCH | `/api/doc-triggers/:id` | bearer | `workflows:write` | — | トリガーのフィールドを変更；存在しないフィールドはそのままにします。 |
| DELETE | `/api/doc-triggers/:id` | bearer | `workflows:write` | — | トリガーとその履歴を削除します；開始した実行は残ります。 |
| GET | `/api/workflows/:slug` | bearer | `workflows:read` | `workflows` | 1つのワークフロー定義とその仕様 |
| GET | `/api/runs` | bearer | `workflows:read` | `workflows` | チームの実行、新しい順。 |
| POST | `/api/runs/:id/cancel` | bearer | `workflows:run` | `workflows` | 実行を取消；既に実行中のステップが終了し、次のステップは開始しません。 |
| GET | `/api/runs/:id` | bearer | `workflows:read` | `workflows` | 1つの実行とそのステップ、インプット、アウトプット、およびエラー |
| GET | `/api/kg/entities` | bearer | `files:read` | — | ?q= と ?type= でエンティティを検索する；呼び出し元が読める言及を持つものだけ。 |
| GET | `/api/kg/entities/:id` | bearer | `files:read` | — | 1つのエンティティとその関係・言及。各言及は元文書の公開範囲でフィルタされます。 |
| POST | `/api/kg/extract` | bearer | `workflows:run` | `workflows` | チームの未抽出文書をインデックス化するワークフローをキューに追加します。 |
| POST | `/api/admin/seed` | bearer | `settings:manage` | — | 呼び出し元のチームにサンプルのノートと文書を投入する。 |
| GET | `/api/metrics` | bearer | `instance:manage` | — | 運用メトリクス。 |
| GET | `/api/features` | bearer | — | — | チームの機能フラグ |
| POST | `/api/features/:name` | bearer | `settings:manage` | — | チーム用の機能を有効にする/無効にする |
| GET | `/api/plugins` | bearer | — | — | 読み込まれたプラグインと、そのツールおよびワークフロー。 |
| GET | `/api/mcp` | bearer | — | — | 接続されたMCPサーバー |
| GET | `/api/oop` | bearer | — | — | 接続済みのサンドボックス化（プロセス外）プラグインと、それらが要求できる機能。 |
| POST | `/api/tools/:name` | bearer | `settings:manage` | — | チーム用のツールを有効にする/無効にする |

## Plugin routes

Routes contributed by loaded plugins, mounted under `/api/x/<plugin>/`. Every one requires a bearer token; the permission, when named, is checked before the plugin's handler runs. Matched after the core routes above.

| Method | Path | Plugin | Permission | Description |
|---|---|---|---|---|
| GET | `/api/x/example-tools/word-count` | `example-tools` | `chat:use` | ?text= の単語数を数える。 |
| POST | `/api/x/example-tools/word-count` | `example-tools` | `chat:use` | {text} の単語数を数える。 |

