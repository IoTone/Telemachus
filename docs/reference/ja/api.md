# HTTP API

Every route the server dispatches, in matching order, from the declared route table (`server/routes.rkt`). `auth` is how a route authenticates: **public** needs no credential; **bearer** a session or API token; **provision** the hosted-mode provisioning token; **superadmin** and **org-admin** the two multi-tenancy planes. The permission column says what a caller needs. A **role** permission is checked by the dispatcher before the handler runs, so the table is the enforcement and not a description of it. A **resource** permission is weighed against the particular note or document by `can?`, which also admits the OWNER and anyone holding a matching grant — so a caller whose role does not carry it may still be admitted for one object, which is what sharing is. A feature flag, when named, must be on for the team.

Path segments written `:name` are parameters; `*name` takes the rest of the path.

| Method | Path | Auth | Permission | Checked | Feature | Description |
|---|---|---|---|---|---|---|
| GET | `/` | public | — | — | — | コンソール（TELEMACHUS_HOME=beta のときはベータ申込フロー）。HTML のタイトルはインスタンスのブランディングから書き換えられます。 |
| GET | `/index.html` | public | — | — | — | コンソール |
| GET | `/login` | public | — | — | — | コンソール、まずサインイン — ベータのランディングに依存しない URL。 |
| GET | `/activate` | public | — | — | — | マジックリンク認証画面（ホストモード）のコンソール. |
| GET | `/health` | public | — | — | — | 死活確認：{ok, multitenant} のみ — バージョン、KDF、TLS の状態は GET /api/admin/status にあります。 |
| GET | `/beta-sdk.js` | public | — | — | — | Tier-B オンボーディングバンドルが読み込むブラウザ SDK（window.Telemachus.beta）。 |
| GET | `/console/*path` | public | — | — | — | コンソール自身のスクリプトファイル（static/console/*.js）。同一オリジンで配信されるため、コンソールの `script-src 'self'` ポリシーがインラインブロックも nonce もなしに許可する。 |
| GET | `/beta/bundle/:plugin/*path` | public | — | — | — | Tier-B オンボーディングプラグインの公開ランディングバンドル（plugins/<id>/landing/）内のファイル。見込み客がサインイン前に見るファネルです。 |
| POST | `/api/x/:plugin/bundle-ticket` | bearer | — | — | — | このプラグインの認証付きバンドル用に、短命のチケットを発行します。ブラウザでページを開けるようにするためです（issue #43）。最初の応答で、そのバンドルのパスに限定したクッキーとして設定されます。 |
| GET | `/api/x/:plugin/bundle/*path` | handler | — | — | — | 読み込まれたプラグインの認証付きバンドル（plugins/<id>/bundle/）内のファイル。ベアラートークン、または bundle-ticket が発行したチケット（?ticket= か、それが設定するクッキー）が必要で、応答が共有キャッシュに保存されることはありません。 |
| GET | `/beta/template` | public | — | — | — | Tier-C のサンドボックス化 HTML テンプレート。体験オーバーレイでローカライズされます。 |
| GET | `/api/config` | public | — | — | — | 公開インスタンス設定：ホームモード、マルチテナントフラグ、ローカライゼーションポリシー（既定ロケール、利用可能なロケール、切り替えの可否）。サインイン画面はトークンを持つ前に読み込みます。 |
| GET | `/api/branding` | public | — | — | — | タイトル、タグライン、ロゴ、テーマトークン。公開：サインイン画面が描画します。会社のホスト名では、またはその会社のサインイン済みユーザーには、会社自身のもの（TEN-2d）。 |
| PUT | `/api/branding` | bearer | `instance:manage` | role | — | インスタンスのタイトル、タグライン、テーマを設定します。不明な、不正な、または WCAG のコントラスト下限を下回るテーマトークンは、その名前を示す 400 になります。 |
| GET | `/api/retention` | bearer | `files:read` | role | — | 呼び出し元に実際に適用される保持ポリシーと、各値をどの層（インスタンス・組織・チーム）が設定したかを示す `sources`。層は常に厳しくなる方向にのみ作用します。短い保持期間が優先され、`null`（永久保持）は任意の数値に負けるため、チームは所属組織が許す期間より長くデータを保持できません。ルールが設定されていなければ何も削除されず、未設定のインスタンスは一切スイープしません。 |
| PUT | `/api/retention` | bearer | `settings:manage` | role | — | チームの保持ルールを設定します：`max_age_days`、`delete_derived_after_days`、`purge_job_payloads_after_days`。それぞれ日数の整数か null です。**0 は拒否されます**（アップロード直後に削除されてしまうため）。定義されていないフィールドも、黙って無視せず拒否します。データが削除されていると信じている一方で実際には何も起きていない状態が最悪の誤りだからです。チームは組織とインスタンスが許す範囲で短縮のみ可能です。 |
| GET | `/api/retention/plan` | bearer | `files:read` | role | — | 現在のポリシーが削除する「予定」のみを返し、実際には何も変更しません。対象のオブジェクトツリー、派生オブジェクト、ジョブのペイロード、そしてリーガルホールドによって保護されている件数を示します。保持ルールは無人で実行されるため、ドライランが最も必要な操作です。リーガルホールド中のオブジェクトは後から除外されるのではなく計画自体に現れないため、ルールが触れられないものを計画が約束することはありません。 |
| POST | `/api/repo-obj/:id/legal-hold` | bearer | `files:manage` | resource | — | オブジェクトにリーガルホールドを設定または解除します：`{"hold": true\|false}`。ホールド中は「ルールによる」削除が拒否され、保持スイープはそのオブジェクトを飛ばし、件数を報告します。これは r4 がプレフィックス単位の操作を構築する土台となるフラグであり、保持ルールと同時に提供されます。削除をともなうスケジュールは一方通行であり、それを止められるのはホールドだけだからです。 |
| GET | `/api/session-policy` | bearer | `instance:manage` | role | — | インスタンスのセッションタイムアウト（issue #38）：idle_seconds、absolute_seconds、warn_seconds と、出荷時の既定値および許容範囲。 |
| PUT | `/api/session-policy` | bearer | `instance:manage` | role | — | インスタンスのセッションタイムアウトを設定する。フィールドに null を指定するとその軸に上限を設けない。会社はこれを厳しくできるが、緩めることはできない。 |
| POST | `/api/branding/logo` | bearer | `instance:manage` | role | — | インスタンスロゴをアップロード（マークとワードマークを置き換えます） |
| GET | `/api/i18n/catalog` | public | — | — | — | ?locale= に対するコンソールの文字列。サーバー側でフォールバックチェーンを通して解決済み。公開：サインイン画面が必要とします。 |
| PUT | `/api/i18n` | bearer | `instance:manage` | role | — | インスタンスのデフォルト言語と、ユーザーが切り替える可否を設定します。 |
| GET | `/api/l10n/coverage` | bearer | `localization:read` | role | — | ローカライゼーションマネージャーのカタログのロケール別カバレッジ：総数、承認済み、機械翻訳、未翻訳、古いもの。 |
| GET | `/api/l10n/messages` | bearer | `localization:read` | role | — | 1つのロケールのメッセージ。?status=、?ns=、?q= で絞り込み、ページ送りできます。 |
| POST | `/api/l10n/import` | bearer | `localization:manage` | role | — | ディスク上のカタログをマネージャーのテーブルに取り込む。 |
| POST | `/api/l10n/export` | bearer | `localization:manage` | role | — | ロケールの承認済み文字列を locales/<locale>.json に書き戻す。承認済みが何もないロケールは拒否します。 |
| POST | `/api/l10n/draft` | bearer | `localization:manage` | role | — | ロケールの未翻訳文字列に対して AI の下書きを、20件ずつのスケジューラジョブでキューに入れる。クォータで計量されます。 |
| POST | `/api/l10n/discard` | bearer | `localization:manage` | role | — | ロケールの機械翻訳の下書きを削除する（人の作業には触れません）。 |
| PUT | `/api/l10n/messages/:id` | bearer | `localization:translate` | role | — | 1メッセージの翻訳を提出します。 |
| POST | `/api/l10n/review/:id` | bearer | `localization:review` | role | — | 翻訳を承認または差し戻す。翻訳者は自分の翻訳を承認できません。 |
| GET | `/api/beta/config` | public | — | — | — | 公開されたオンボーディング体験の公共セグメント（フィールド、コピー、テーマ）が1つの言語で表示されます。 |
| OPTIONS | `/api/beta/signup` | public | — | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| OPTIONS | `/api/beta/config` | public | — | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| OPTIONS | `/api/beta/challenge` | public | — | — | — | サンドボックス化された Tier-C テンプレートのための CORS プリフライト。 |
| GET | `/api/beta/experience` | bearer | — | — | — | チームの下書きのオンボーディング体験（判定プロンプトを含む）。 |
| PUT | `/api/beta/experience` | bearer | — | — | — | オンボーディング体験のドラフトを保存します。 |
| POST | `/api/beta/experience/publish` | bearer | — | — | — | 保存済みの下書きを公開する；以後は環境変数で投入された既定値より優先されます。 |
| POST | `/api/beta/assets` | bearer | — | — | — | オンボーディング資産（ロゴ、ヒーロー画像、フォント）をアップロード（base64でJSON形式）、2MiBまで |
| GET | `/api/beta/assets` | bearer | — | — | — | チームのオンボーディング資産をリストします。 |
| GET | `/api/beta/asset/:id` | public | — | — | — | オンボーディングアセットを1つ配信する。公開：申込フローとブランディングロゴはトークンなしで読み込みます。 |
| DELETE | `/api/beta/asset/:id` | bearer | — | — | — | オンボーディングアセットを削除します。 |
| GET | `/api/beta/challenge` | public | — | — | — | 申込前に申込フローが解く proof-of-work チャレンジ。 |
| POST | `/api/beta/signup` | public | — | — | — | オンボーディングフォームを送信する：公開された体験に対して検証され、不正利用対策で制限され、モデルが設定されていればモデルが判定します。 |
| GET | `/api/beta/prospects` | bearer | — | — | — | 申込フローが捕捉した見込み客を、シグナルと判定とともに一覧する。 |
| POST | `/api/beta/prospects/:id/decide` | bearer | — | — | — | 見込み客を受け入れる、または辞退する。 |
| POST | `/api/bootstrap` | public | — | — | — | 初回のみ：オペレーター、最初の組織とチームを作成する。オペレーターのトークンを返します。インスタンスにユーザーがいれば拒否します。 |
| POST | `/api/provision` | provision | — | — | — | ホストモード：このインスタンスに所有者1名とマジックアクティベーションリンクをプロビジョニングする。 |
| POST | `/api/activate` | public | — | — | — | ホストモード：アクティベーショントークンを交換し、所有者のパスワードを設定します |
| POST | `/api/instance/suspend` | provision | — | — | — | ホストモード：テナントを一時停止（書き込みは402で拒否されます） |
| POST | `/api/instance/resume` | provision | — | — | — | ホストモード：一時停止したテナントを再開 |
| POST | `/api/instance/quota` | provision | — | — | — | ホストモード：テナントチームのクォータ制限を設定します。 |
| POST | `/api/login` | public | — | — | — | ユーザー名とパスワード（2FA 有効時は TOTP コードも）でサインインする。ベアラートークンを返す。試行はアドレス単位とアカウント単位で制限され、遅延は段階的に伸びる（429 と `Retry-After`）。すべての試行は `user.login` として監査に記録される。運用者が TELEMACHUS_LOGIN_LOCK_FAILURES を設定した場合はアカウントがロックされる（423、解除は運用者によるパスワードリセット）。 |
| GET | `/api/sessions` | bearer | — | — | — | 呼び出し元自身のブラウザセッション一覧 — プレフィックス、作成時刻と最終使用時刻、有効期限、そしてこのリクエストが使っているセッションの印。トークンそのものは返さない。 |
| POST | `/api/logout` | bearer | — | — | — | このリクエストが使っているセッションを終了する。これ以前はコンソールのサインアウトが何も呼んでいなかったため、ベアラーは期限まで有効なままだった。 |
| DELETE | `/api/sessions` | bearer | — | — | — | 呼び出し元の「他のすべて」のセッションを終了する（他の場所からサインアウト）。すべてではない — パスワード変更はすべてを終了するが、こちらは今使っているセッションを残す。 |
| DELETE | `/api/sessions/:id` | bearer | — | — | — | 呼び出し元自身のセッションを 1 つ終了する。自分のものでないセッションと存在しないセッションは同じ 404 を返す。 |
| POST | `/api/2fa/enable` | bearer | — | — | — | 呼び出し元の TOTP 二要素認証を有効にします。シークレットと単回使用のリカバリコード一組を、一度だけ返します。 |
| POST | `/api/2fa/recovery-codes` | bearer | — | — | — | 単回使用のリカバリコードを新しく一組発行し、未使用のものはすべて無効化します。一度だけ返されます（issue #26）。 |
| GET | `/api/2fa/recovery-codes` | bearer | — | — | — | 呼び出し元のリカバリコードのうち、未使用のものが何件残っているか。コード自体は返しません。 |
| DELETE | `/api/2fa` | bearer | — | — | — | 呼び出し元自身の TOTP を無効化します。古いシードとそのリカバリコードは使えなくなり、再登録が必要です。 |
| DELETE | `/api/admin/users/:id/2fa` | bearer | `instance:manage` | role | — | ユーザーの TOTP シードを失効させます（issue #19）。データベースダンプに残っている可能性のあるシードは、本人が使うことでは交換できないため、オペレーターが再登録を強制できます。 |
| POST | `/api/password` | bearer | — | — | — | 呼び出し元のパスワードを変更する。古いパスワードで発行され得たセッションは、この呼び出し自身のものも含めてすべて失効するため、再度サインインが必要です。マシン用トークン（api、worker）はそのまま残ります。 |
| GET | `/api/whoami` | bearer | — | — | — | 呼び出し元：ユーザー、チーム、オペレーターフラグ、組織、組織ロール、ロケール、権限。 |
| POST | `/api/profile` | bearer | — | — | — | 呼び出し元自身の永続的な設定を更新する: `locale` と `timezone`（IANA ゾーン名、例: "Europe/London"）。どちらか一方だけでも送信できます。未知のタイムゾーンは暗黙に置き換えられず拒否されます — 入力ミスで黙って UTC を割り当てられた人は、間違った時刻に届いたレポートで初めて気づくことになります。応答には有効なタイムゾーンと、どの層がそれを決めたかが含まれます。 |
| POST | `/api/members` | bearer | `members:manage` | role | — | 呼び出し元のチームに役割を付けてメンバーを追加；新しいメンバーの最初のトークンを返します。 |
| GET | `/api/members` | bearer | — | — | — | チームのメンバーと役割 |
| GET | `/api/timezones` | bearer | — | — | — | このインスタンスがデータを持つすべての IANA タイムゾーン。ソース中のリストではなく、ディスク上の tz データベースから導出されるため、tzdata の更新にリリースは不要です。 |
| PATCH | `/api/members/:id` | bearer | `members:manage` | role | — | メンバーのチームロールを変更する：{role}。最後のオーナーは降格できません — オーナーのいないチームは、それを修正する権限を誰にも付与できないためです。 |
| DELETE | `/api/members/:id` | bearer | `members:manage` | role | — | メンバーをチームから外す：メンバーシップを無効化し、そのメンバーがこのチームに対して保持しているトークンをすべて失効させます。最後のオーナーは削除できません。 |
| GET | `/api/admin/status` | bearer | `instance:read` | role | — | インスタンスの状態：バージョン、KDF、TLS、マルチテナント、保存時暗号化の状態、そしてユーザー・チーム・組織・ノート・トークン・監査イベント・テナントの件数。 |
| POST | `/api/orgs` | superadmin | `instance:manage` | role | — | 会社を作成：org、最初のチーム、所有者。明示的なスラッグは自然キーです（再実行で409エラー） |
| GET | `/api/orgs` | superadmin | `instance:manage` | role | — | インスタンス上のすべての組織をリスト表示します。 |
| POST | `/api/orgs/:ref/suspend` | superadmin | `instance:manage` | role | — | 会社（id またはスラッグ）を停止する；その中のすべてのチームが読み取り専用になります。 |
| POST | `/api/orgs/:ref/resume` | superadmin | `instance:manage` | role | — | 一時停止中の企業を再開します。 |
| POST | `/api/orgs/:ref/quota` | superadmin | `instance:manage` | role | — | 組織レベルのクォータを設定；チームはその下に配置されます |
| GET | `/api/orgs/:ref` | superadmin | `instance:manage` | role | — | 1つの会社、そのチームとクォータ。 |
| PATCH | `/api/orgs/:ref` | superadmin | `instance:manage` | role | — | 会社の名前を変更する、プランを変更する（そのプランの上限を再適用します）、および／またはホスト名を設定する（{domain}、null でクリア）：そのホストで配信されるコンソールは、サインイン前から会社のブランディングをまといます（TEN-2d）。 |
| POST | `/api/admin/users/:id/password` | bearer | `instance:manage` | role | — | サインインできなくなったユーザーのパスワードを設定する：{new_password}。そのユーザーのセッションは失効します。リセットリンクを送るメール送信手段がないため、サインインできない人にとって唯一の復帰手段です。 |
| POST | `/api/admin/seed-tenants` | superadmin | `instance:manage` | role | — | 既知の開発用パスワードで Acme と Globex を投入する — デモ用の固定データのみ。 |
| GET | `/api/org` | org-admin | `org:read` | role | — | 呼び出し元の会社 |
| GET | `/api/org/teams` | org-admin | `org:read` | role | — | 呼び出し元の会社のチーム。 |
| POST | `/api/org/teams` | org-admin | `org:manage` | role | — | 呼び元の会社でチームを作成します。 |
| POST | `/api/org/teams/:ref/quota` | org-admin | `org:manage` | role | — | 組織管理プレーンから単一チームのクォータ上限を設定する（issue #113）: 呼び出し元自身の会社に属するチームを id または slug で指定し、{dimension, limit, window?} を渡します。チーム層の POST /api/quota は常に呼び出し元自身のチームにしか設定しないため、これがないと複数チームを管理する組織管理者はチームごとにトークンを持つ必要がありました。会社外のチームは 404 を返します — この呼び出し元にとっては存在しません。 |
| POST | `/api/org/members` | org-admin | `org:manage` | role | — | 呼び出し元の会社のチームに人物を追加します。オプションで組織ロール（org_admin, org_owner, org_reader）も指定できます。 |
| PATCH | `/api/org/members/:id` | org-admin | `org:manage` | role | — | 人の組織ロールを設定またはクリアする — 既存ユーザーを org_reader にする方法（TEN-2h）。自分自身には不可。 |
| GET | `/api/org/audit` | org-admin | `org:read` | role | — | 会社の監査ログ。 |
| GET | `/api/org/retention` | org-admin | `org:read` | role | — | 会社自身の保持ルール（#86 r3）。組織は自社のデータについてインスタンスが許す期間を短縮できますが、延長はできません。 |
| PUT | `/api/org/retention` | org-admin | `org:manage` | role | — | 会社の保持ルールを設定します。語彙と拒否条件はチーム向けの経路と同一で、チームに適用される実効値はインスタンス・組織・チームのうち最短のものになります。 |
| GET | `/api/timezone` | bearer | `instance:read` | role | — | インスタンス既定のタイムゾーン、何も設定されていないときに使われるフォールバック（UTC）、およびこのインスタンスがデータを持つゾーン数。 |
| PUT | `/api/timezone` | bearer | `instance:manage` | role | — | インスタンス既定のタイムゾーンを設定する: {timezone}。これは下限ではなくフォールバックです — タイムゾーンは制御ではなく、間違った時計を強制して守られる人はいないため、会社も個人もそれぞれ自分のものを選べます。 |
| GET | `/api/org/timezone` | org-admin | `org:read` | role | — | 会社自身の既定タイムゾーン、インスタンスの既定、および自分で設定していないこの会社のメンバーに適用される値。 |
| PUT | `/api/org/timezone` | org-admin | `org:manage` | role | — | 会社の既定タイムゾーンを設定する: {timezone}。ユーザー自身の選択は引き続きこれより優先されます。 |
| DELETE | `/api/org/timezone` | org-admin | `org:manage` | role | — | 会社の既定タイムゾーンを削除する。所属ユーザーはインスタンス既定にフォールバックします。 |
| GET | `/api/org/session-policy` | org-admin | `org:read` | role | — | 会社自身のセッションタイムアウト、インスタンスのもの、そしてインスタンスの下限を適用した実効ポリシー。 |
| PUT | `/api/org/session-policy` | org-admin | `org:manage` | role | — | 会社のセッションタイムアウトを設定する。厳しくする変更だけが有効になる：インスタンスより緩い値を指定すると、インスタンスの値が返されます。 |
| DELETE | `/api/org/session-policy` | org-admin | `org:manage` | role | — | 会社のセッションタイムアウトを取り下げる；そのユーザーはインスタンスのポリシーに戻ります。 |
| GET | `/api/org/branding` | org-admin | `org:read` | role | — | 会社自身のブランディング（TEN-2d）— 何も設定していなければ、own:false を添えてインスタンスのもの。 |
| PUT | `/api/org/branding` | org-admin | `org:manage` | role | — | 会社のタイトル・タグライン・ロゴ・テーマを設定する：会社のホスト名で、またその会社のサインイン済みユーザーに対して、コンソールがまとうもの。テーマトークンはインスタンスの場合とまったく同じように検証され、コントラストの下限で制限されます。 |
| DELETE | `/api/org/branding` | org-admin | `org:manage` | role | — | 会社のブランディングを取り下げる；そのユーザーには再びインスタンスのものが表示されます。 |
| POST | `/api/org/branding/logo` | org-admin | `org:manage` | role | — | 会社のロゴをアップロードし（base64）、会社のマークにする。 |
| POST | `/api/notes` | bearer | `notes:write` | role | — | 公開範囲を指定してノートを作成する。 |
| GET | `/api/notes` | bearer | `notes:read` | role | — | 呼び出し元が読めるノートを一覧する；?scope=org は会社内のすべてのチームにわたります（org_reader にはチーム公開のノートだけが見え、非公開のものは見えません）。 |
| POST | `/api/documents` | bearer | `files:write` | role | — | テキストドキュメントを作成する（content_type が text/markdown のrepositoryオブジェクト）。 |
| GET | `/api/documents` | bearer | `files:read` | role | — | 文書をリスト表示します。 |
| GET | `/api/documents/:id` | bearer | `files:read` | resource | — | 一つのテキストドキュメントとその本文。 |
| PUT | `/api/documents/:id` | bearer | `files:write` | resource | — | テキスト文書のタイトル・本文・公開範囲を更新する（新しいバージョン）。 |
| DELETE | `/api/documents/:id` | bearer | `files:delete` | resource | — | テキストドキュメントを削除します。 |
| POST | `/api/notes/:id/share` | bearer | `notes:manage` | resource | — | ユーザー（所有者、またはnotes:manage）とメモを共有します。与えられた権限はnotes:*のものでなければなりません。 |
| GET | `/api/notes/:id` | bearer | `notes:read` | resource | — | 1件のノート。 |
| PUT | `/api/notes/:id` | bearer | `notes:write` | resource | — | ノートを更新します。 |
| DELETE | `/api/notes/:id` | bearer | `notes:delete` | resource | — | ノートを削除します。 |
| POST | `/api/ai/echo` | bearer | `chat:use` | role | — | クォータの動作確認用の、モデルを使わない計量付きエコー。 |
| POST | `/api/ai/chat` | bearer | `chat:use` | role | `chat` | モデルの1ターン。`prompt` は文字列またはコンテンツパートの配列です。`response_format`（{type: text\|json_object\|json_schema}）はモデルへ渡され、応答がそれに従わない場合は拒否されます。クォータで許可され（ai.requests、ai.tokens.total）、チームの ai.concurrency で制御されます。名前付きエグゼキュータへのルーティングには instance:manage が必要です。応答の `simulated: true` は、モデルが一切応答していないことを意味します：TELEMACHUS_MODEL_URL が未設定で、返答はプロンプトを決まった形で返したものです。実際のモデル呼び出しではこのキーは付きません。 |
| POST | `/api/ai/chat/stream` | bearer | `chat:use` | role | `chat` | 同じターンを Server-Sent Events で返し、終了時に計量します。response_format はストリーム終了後に判定され、最後のイベントに `parsed`、またはモデルが従わなかった場合は `schema_error` が入ります。モデルが一切応答していない場合は `simulated: true` が入ります。 |
| POST | `/api/agent` | bearer | `chat:use` | role | `agent` | チームの有効なツールに対してツールを使用するエージェントループを実行；すべてのツール呼び出しはRBACチェックとメーター処理が行われます。 |
| POST | `/api/translate/catalog` | bearer | `chat:use` | role | `translate` | ロケールカタログ全体を、プレースホルダーを保ったまま翻訳する。 |
| POST | `/api/translate` | bearer | `chat:use` | role | `translate` | 目標言語にテキストを翻訳し、チーム用語集を使用します。 |
| GET | `/api/translate` | bearer | `chat:use` | role | — | チームの翻訳履歴 |
| POST | `/api/glossary` | bearer | `settings:manage` | role | — | 対象言語の用語集に用語を追加または更新する。 |
| GET | `/api/glossary` | bearer | `chat:use` | role | — | チーム用語集. |
| GET | `/api/ai/model` | bearer | — | — | — | 設定されているモデル（またはシミュレーションの代替が使われていること）。 |
| GET | `/api/model-roles` | bearer | — | — | — | チームの一括処理をロールごとにどのエグゼキュータへ送るか（utility：知識グラフとフィールド抽出、翻訳の下書き）、およびインスタンスの既定値。 |
| PUT | `/api/model-roles` | bearer | `settings:manage` | role | — | チームのモデルロールを設定する：{roles: {utility: <エグゼキュータ名> \| null}}。エグゼキュータは存在している必要があります；null はインスタンスの既定値に戻り、それもなければローカルモデルになります。 |
| GET | `/api/executors` | bearer | — | — | — | ローカルエグゼキュータ、環境変数で設定されたプッシュ型、API で作成されたもの（プッシュ型、またはワーカー付きのプル型）を、状態とともに。 |
| POST | `/api/executors` | bearer | `instance:manage` | role | — | エグゼキュータを作成する：{name, mode: pull\|push, model?, url?, key?, capabilities?, org_id?}。プル型エグゼキュータのワーカートークンはこのレスポンスに含まれ、二度と表示されません。 |
| DELETE | `/api/executors/:id` | bearer | `instance:manage` | role | — | エグゼキュータを退役させる：ワーカートークンは失効し、保持していたジョブはキューに戻ります。 |
| GET | `/api/admin/workers` | bearer | `instance:read` | role | — | ワーカー群（FLEET-2）：各エグゼキュータの稼動状態、ワーカー自身の申告、保持中のジョブ、一定期間（?hours=、既定 24）の処理結果とリース失効の回数、直近の失敗 — さらにキュー：種別ごとの件数、最も古い待機ジョブの経過時間、そして稼動中のどのエグゼキュータでも実行できないリモートジョブの件数。この最後の数値は、深いキューを他の方法では説明できないものである：停止したワーカー群と稼動中のワーカー群は、件数だけでは同じように見える。すべての数値は導出され、クォータで保留されているジョブは実行不能には数えない — それは GET /api/jobs が `waiting` としてすでに示している。 |
| GET | `/api/admin/queue` | bearer | `instance:read` | role | — | キューを全チーム横断でジョブ単位に表示する（FLEET-4）：各行の待機時間、試行回数、保持しているホスト、リースの残り時間、そして待機中のジョブについては、プラットフォームがなぜ保留しているか（`waiting`、GET /api/jobs が返すものと同じ理由）と、そもそも稼働中のワーカーで実行できるのか（`runnable`）。絞り込みは `kind`、`status`、`executor`、`team`。`limit`（最大200）と `offset` でページングし、`total` は絞り込み後の総件数である。`status=queued` を指定した場合、並び順は要求処理そのものの順序になるため、先頭が本当に次のジョブである — どの並び順になったかは `order` が示す。ペイロードと結果は含まない：キューは種別、待機時間、チーム、保持しているホストで管理するものであり、この読み取りはインスタンス上のすべてのチームにまたがる。 |
| POST | `/api/executors/:id/rotate-token` | bearer | `instance:manage` | role | — | プルエグゼキュータに新しいワーカートークンを発行する（issue #60）。新しいトークンはこのレスポンスにのみ含まれ、二度と表示されません。置き換えられたトークンは `overlap_seconds` のあいだ有効なままなので、ホストが停止する時間帯を作らずに再デプロイできます。自分でローテーションできないワーカー向け、そして漏洩が疑われるトークン向けの経路です — ワーカー自身の呼び出しとは異なり、ローテーションの頻度を理由に拒否されることはありません。 |
| POST | `/api/executors/:id/drain` | bearer | `instance:manage` | role | — | プルエグゼキュータをローテーションから外す（FLEET-3）：新しい仕事は渡されず、トークンは保持されるため、要求とハートビートを続け、稼働していることが見える状態を保つ。トークンを失効させる廃止とは異なり、元に戻せる。すでに保持しているジョブはそのまま実行される — 実行中の作業を止めるのはキャンセルの役目である。 |
| POST | `/api/executors/:id/resume` | bearer | `instance:manage` | role | — | 停止したエグゼキュータをローテーションに戻す（FLEET-3）。次回の要求から再び仕事を受け取る。 |
| POST | `/api/org/executors` | org-admin | `org:manage` | role | — | 呼び出し元の会社に紐づくエグゼキュータを作成する（TEN-2e）：その会社のチームにだけ提供されます。 |
| POST | `/api/workers/claim` | bearer | `jobs:execute` | role | — | プル型ワーカーが実行可能な次のリモートジョブを取得する：{kinds, models, max_wait}；何もなければ 204。ジョブにはリースと claim_token が付き、以降そのジョブに対する書き込みはすべてこの claim_token を返送する必要があります。 |
| POST | `/api/workers/state` | bearer | `jobs:execute` | role | — | プル型ワーカーが自分の状態を報告する：{state} — ready、busy、paused のいずれか。ジョブを保持していないワーカーが使える唯一の経路です：停止中のホストは取得を止めており、ハートビートを送るジョブも持たないため、これが無ければその沈黙を障害と区別できません。`state` は claim とハートビートでも受け付けるので、通常のループに追加のリクエストは不要です。state を指定しない呼び出しは、保存済みの状態をそのまま残します。 |
| GET | `/api/workers/token` | bearer | `jobs:execute` | role | — | このワーカー自身の資格情報の状態（issue #60）：{expires_at, rotate, overlap_seconds, ttl_seconds}。`rotate` はプラットフォーム側の判断であり、どのワーカーも同じ判断を行い、フリートを再デプロイせずに猶予期間を変更できます。ワーカーはこれを定期的に確認し、この真偽値ひとつに従って動作します。claim のフィールドではなく読み取り専用の経路である理由は、待機中のワーカーの claim は 204 を返し本文を持たないためです — 仕事がないまま今夜トークンが失効するホストこそ、知らせる必要のある相手です。 |
| POST | `/api/workers/token` | bearer | `jobs:execute` | role | — | このワーカーが保持しているトークンを次のトークンと交換する（issue #60）：{token, expires_at, overlap_seconds}。根拠はすでに保持している資格情報そのものであり、PULL-9 の読み取りや PULL-13 の書き込みと同じです。古いトークンは重複期間のあいだ有効なままなので、ワーカーは新しいトークンを使う前に必ず永続化しなければなりません — 永続化できないワーカーはローテーションしてはいけません。さもなければ重複期間の終了時に停止します。5 分以内に 2 回ローテーションすると Retry-After 付きの 429 になります。 |
| POST | `/api/workers/jobs/:id/heartbeat` | bearer | `jobs:execute` | role | — | このワーカーが保持するジョブのリースを延長する：{claim_token}、取得時に返されたトークン。トークンが無い、または古い場合は 409 になります。 |
| POST | `/api/workers/jobs/:id/complete` | bearer | `jobs:execute` | role | — | 結果を送信する：{result, claim_token}。現在のリース保持者であり、かつ claim_token が示す試行からのみ受け付けます（失効した試行は、それを置き換えた試行に結果を書き込めません）。種別ごとに検証されます。 |
| POST | `/api/workers/jobs/:id/fail` | bearer | `jobs:execute` | role | — | 失敗を報告する：{error, claim_token}。現在のリース保持者、かつその試行からのみ受け付けます。 |
| POST | `/api/workers/jobs/:id/release` | bearer | `jobs:execute` | role | — | 試行回数を消費せずにジョブを返却する（issue #61）：{claim_token, reason?} — busy、unsupported、shutdown のいずれか。それ以外は拒否せず `other` として記録する。ワーカーはすでにそのジョブを実行できないと申告しているためである。ジョブは直ちにキューへ戻り、他のワーカーはすぐに取得できる一方、返却したエグゼキュータには30秒間そのジョブを渡さない — これが返却ループの歯止めであり、試行回数を変えないこの経路では他に止めるものがない。10回を超えて返却された場合はジョブを失敗とし、返却したホストの名前を記録する：どのワーカーも実行しない作業には人の判断が必要である。 |
| POST | `/api/workers/jobs/:id/document` | bearer | `jobs:execute` | role | — | このジョブが指定したドキュメントを読む：{object, claim_token, version?, as?}。新しい認可コードは不要で、条件は3つ — 呼び出し元がこの試行を保持していること、オブジェクト ID がそのジョブ自身のペイロードに現れること、そして読み取りがそのジョブのユーザーとして行われること（公開範囲・付与・組織ゲートがすべて適用されます）。`as: "bytes"`（base64、上限は TELEMACHUS_MAX_UPLOAD）または `as: "text"` で、スキャンの場合は {text: null, reason: "needs-ocr"} を返します。 |
| POST | `/api/workers/jobs/:id/derive` | bearer | `jobs:execute` | role | — | このジョブが指定したドキュメントから派生した文書を書き込む（issue #62）：{source, key, bytes_b64, claim_token, content_type?, filename?}。上記の読み取りの書き込み版で、同じ3条件の下にある — 呼び出し元がこの試行を保持していること、`source` がそのジョブ自身のペイロードに現れること、そして書き込みがそのジョブのユーザーとして行われること（files:write、ストレージクォータ、組織ゲートがすべて適用される）。出力はソースの公開範囲を受け取り、次にその付与を継承する。派生としてマークされるため、オプトインしたトリガーがワーカー自身の出力で発火することはない。TELEMACHUS_MAX_UPLOAD が上限となる：ワーカーは正面玄関の上限を迂回する手段ではない。独立した put は意図的に存在しない — 何にも結び付かない出力は、ワーカートークンをチームのリポジトリへの鍵にしてしまうためである。 |
| GET | `/api/usage` | bearer | — | — | — | チームのクォータ指標を、使用量・上限・残量・期間のリセット時刻とともに返す。さらに `held` が、現在このチームのキュー内ジョブを保留している上限を示します（保留がなければ null）。 |
| POST | `/api/quota` | bearer | `quota:manage` | role | — | 呼び出し元チームのクォータ上限を設定する（次元、上限、ウィンドウ）。必要な権限は `instance:manage` ではなく `quota:manage` です（issue #113）: チームのオーナーが自チームの上限を設定でき、組織管理者も設定できます。チームがいくら要求しても会社自身の上限が依然として効く（受け入れ判定は組織の判断を先に取る）ためです。チームの ADMIN は意図的にこの権限を持ちません — 支出はオーナーの判断です。 |
| GET | `/api/tools` | bearer | — | — | — | 登録済みのツールとその権限、ソースおよびチーム別に有効化された状態。 |
| POST | `/api/tokens` | bearer | `settings:manage` | role | — | API トークンを発行する。任意でスコープと ttl（秒。既定は90日；長寿命のマシントークンには "never"）を指定；生のトークンは一度だけ表示されます。 |
| GET | `/api/tokens` | bearer | `settings:manage` | role | — | チームのAPIトークン |
| DELETE | `/api/tokens/:id` | bearer | `settings:manage` | role | — | API トークンを失効させる。 |
| GET | `/api/search` | bearer | — | — | `search` | ノート、リポジトリオブジェクト（キー、ファイル名、抽出テキスト）、知識グラフのエンティティを検索する；各行は can? でフィルタ；?scope=org は org_reader 向けに会社内のチームにわたります。 |
| GET | `/api/webhooks` | bearer | `webhooks:manage` | role | — | チームの送信 Webhook 購読の一覧。あわせて購読がフィルタに使えるイベント名の閉じたリストと、デッドレターになるまでの配信試行回数を返します。シークレットが一覧に含まれることはありません。 |
| POST | `/api/webhooks` | bearer | `webhooks:manage` | role | — | イベントを購読する: `url`（http(s)）と `events` — `"*"` または `GET /api/webhooks` が示す名前のカンマ区切り部分集合。未知のイベント名は保存されずに拒否されます。何も発火しない購読が黙って存在する方が、拒否されるより悪いからです。署名シークレットは応答に含まれ、一度だけ表示されます。置き換えるにはローテーションしてください。 |
| GET | `/api/webhooks/:id` | bearer | `webhooks:manage` | role | — | 購読 1 件。他チームの ID は 403 ではなく 404 になります。 |
| PATCH | `/api/webhooks/:id` | bearer | `webhooks:manage` | role | — | `url`、`events`、`active`、`description` を変更する。`{"rotate": true}` で新しい署名シークレットを発行します — 一度だけ表示され、以前のシークレットは直ちに何も署名しなくなります。検証は変更後の購読に対して行われるため、パッチで作成できない状態に到達することはありません。 |
| DELETE | `/api/webhooks/:id` | bearer | `webhooks:manage` | role | — | 購読とその配信履歴を削除する。監査エントリは残ります。 |
| POST | `/api/webhooks/:id/ping` | bearer | `webhooks:manage` | role | — | この購読に `ping` イベントを今すぐ同期的に配信し、その結果を返す。実際のイベントが依存する前に、受信側の署名検証を確認する手段です。購読が無効、または `ping` を購読していない場合は 409 で拒否されます。 |
| GET | `/api/webhooks/:id/deliveries` | bearer | `webhooks:manage` | role | — | この購読の配信試行を新しい順に返す: 状態（`pending`/`delivered`/`dead`）、試行回数、最後の応答コード、最後のエラー、レイテンシ、次回試行予定。`?status=dead` がデッドレター一覧です。 |
| POST | `/api/deliveries/:id/redeliver` | bearer | `webhooks:manage` | role | — | デッドまたは配信済みのイベントを再送する。試行回数はリセットされます — 再送を選んだ運用者は判断を下しており、10 回のうち既に消費された 1 回分しか残っていなければこの操作は役に立ちません。配信 ID は変わらないため、すでに適用した受信側は冪等キーとして認識できます。 |
| GET | `/api/feeds` | bearer | `feeds:manage` | role | — | チームに設定された外部フィードの一覧。あわせて、このビルドが取得できるフィード種別の閉じたリストと、資格情報の提示方法を返します。シークレットが読み取りに含まれることはありません。行が返すのは `has_secret` で、`polling` はこのフィードを定期的に取得する仕組みがまだあるかどうかを示します。 |
| POST | `/api/feeds` | bearer | `feeds:manage` | role | — | フィードを設定します。`slug`（取得した項目が置かれるキー接頭辞）、`kind`、`url`、必要に応じて `auth` とその `secret`（`bearer`、`header`、`query`）。`query` を許しているのは、実際の取得元の多くがその方式で認証するためで、拒否してもトークンが暗号化されないまま URL に書かれるだけです。シークレットは保存時に封印され、`telemachus-secrets rewrap` で鍵を更新できます。`user_id` は取得が代理するチームメンバーで、既定では呼び出し元です。チーム外のユーザーは拒否されます — フィードがその人を代理することはできません。 |
| GET | `/api/feeds/:id` | bearer | `feeds:manage` | role | — | フィード 1 件。他チームの ID は 403 ではなく 404 になります。 |
| PATCH | `/api/feeds/:id` | bearer | `feeds:manage` | role | — | `slug`、`name`、`kind`、`url`、`auth`、`auth_name`、`secret`、`user_id`、`active` のいずれかを変更します。フィードとして妥当かを同じ基準で検証するため、作成では到達できない状態に変更で至ることはありません。シークレットを添えた同じリクエストで `bearer` に切り替えるのは受け付けられ、添えずに切り替えるのは拒否されます。`secret` に `null` を指定すると保存された資格情報を消去します。 |
| DELETE | `/api/feeds/:id` | bearer | `feeds:manage` | role | — | フィードの設定を削除します。すでに取得済みの項目は通常のリポジトリ文書であり、影響を受けません — フィードの削除は、その項目の取り消しではありません。 |
| POST | `/api/feeds/:id/probe` | bearer | `feeds:manage` | role | — | フィードの URL を、その資格情報を用いて、いま 1 回だけ取得し、結果を返します。ステータス、本文が JSON として解釈できたか、返ってきたバイト数です。保存されるのは結果だけで、文書は作成されません。そのため設定中に実行しても安全です。資格情報が誤っていれば、定期実行の沈黙ではなく取得元自身の 401 としてここに現れます。記録されるエラーはホスト、パス、ステータスコードを示し、クエリ文字列・ヘッダー・本文を含むことはありません。 |
| GET | `/api/audit` | bearer | `settings:manage` | role | — | チームの最近の監査イベント。 |
| POST | `/api/jobs` | bearer | `chat:use` | role | — | 登録された種類のスケジューラジョブをキューイングします。 |
| GET | `/api/jobs` | bearer | — | — | — | チームのジョブを新しい順に返す。プラットフォームが保留しているキュー内ジョブには `waiting` が付きます — {reason: "quota"\|"concurrency", …}。何も保留しておらず空きワーカーを待っているだけの場合、このキーはありません。 |
| POST | `/api/jobs/:id/cancel` | bearer | — | — | — | ジョブをキャンセルする。自分のものであればキュー内でも実行中でも可能で、他人のものには jobs:cancel が必要です。キュー内のジョブは直ちにキャンセルされ、実行中のジョブは `canceling` に移ります — 結果は即座に破棄され、ハンドラが実際に停止した時点でチームの同時実行枠が解放されます。 |
| DELETE | `/api/jobs/:id/content` | bearer | — | — | — | 確定済みジョブのペイロードと結果を削除し、行自体は保持します。自分のジョブは常に可能で、他人のジョブには jobs:purge が必要です。`infer.chat` や文書パイプラインではペイロードが文書本文そのもの、結果がモデルの応答にあたるため、削除要求に応じる呼び出し側が必要とする操作です。queued・running・canceling のジョブでは拒否されます（ペイロードはハンドラがこれから読む入力のため、まずキャンセルしてください）。ステータス・時刻・試行回数・監査記録はすべて残り、ジョブには `purged_at` が報告されるので、空のペイロードと削除済みのペイロードを区別できます。 |
| GET | `/api/jobs/:id` | bearer | — | — | — | 1件のジョブと、その結果またはエラー。プラットフォームが保留している場合は `waiting` も含みます（GET /api/jobs を参照）。 |
| GET | `/api/schedules` | bearer | `jobs:schedule` | role | — | チームのジョブスケジュールを次回実行が近い順に返す。各行には実行方式（cadence）、プリンシパル、最後に実行した時刻と投入したジョブ、さらに `skipped` と `last_skip_reason` が含まれます — プラットフォームが見送ったティックで、理由は前回の実行が終わっていなかった（`overrun`）か、その現地時刻が時計の繰り上げで存在しなかった（`dst-gap`）かです。`cadences` はこのビルドが受け付ける 3 種類を示します。 |
| POST | `/api/schedules` | bearer | `jobs:schedule` | role | — | ジョブスケジュールを作成する。`kind`（登録済みのジョブ種別）と実行方式が必須です。`interval` は `interval_seconds`（60 秒以上）、`daily` と `weekly` は `at_minute`（現地時刻の 0〜1439 分）と `timezone`（省略時は呼び出し元のゾーン）、`weekly` はさらに `days_of_week`（0〜6 のカンマ区切り集合、日曜が 0）を使います。`payload`、`requirements`、`priority`、`name`、`paused` は任意です。最初の実行が即時になることはありません。タイムゾーンは実行時に所有者から解決するのではなくスケジュール自身に保存されます: スケジュールは恒久的な指示であり、作成者が移動してプロフィールを変更したときに「朝会前の 7:00」が他の全員にとって黙って動いてはならないからです。スケジュールは呼び出し元として実行され、投入されるジョブはその権限を使います。未登録の種別は、実行できない仕事を永久に投入し続ける前にここで拒否されます。 |
| GET | `/api/schedules/:id` | bearer | `jobs:schedule` | role | — | ジョブスケジュール 1 件。他チームの ID は 403 ではなく 404 になります。 |
| PATCH | `/api/schedules/:id` | bearer | `jobs:schedule` | role | — | スケジュールを調整する: `cadence`、`interval_seconds`、`at_minute`、`days_of_week`、`timezone`、`paused`、`payload`、`priority`、`name`。検証は変更後の状態に対して行われるため、`daily` への切り替えと `at_minute` を同じリクエストで送るのは受け付けられ、`at_minute` なしの切り替えは拒否されます — パッチで作成できない状態に到達することはありません。実行タイミングに関わる変更は次回実行を再計算します。古い時刻で一度実行してから編集に従う、という挙動にはなりません。プリンシパルは変更できません: タイマーが誰の権限を使うかを変えることは編集ではなく新しいスケジュールです。一時停止を解除すると、見送ったティックをまとめて実行するのではなく次回実行が先に進みます。 |
| DELETE | `/api/schedules/:id` | bearer | `jobs:schedule` | role | — | ジョブスケジュールを削除する。すでに投入されたジョブは通常のジョブであり、影響を受けません。 |
| DELETE | `/api/repo` | bearer | `files:delete` | resource | — | `?prefix=` 配下のすべてのオブジェクトを削除し、各オブジェクトの派生物にもカスケードします（#86）。既定はドライランです。`confirm=1` がなければ何も削除せず、削除対象となる件数・バイト数・ID を返します。プレフィックスが空または未指定の場合は「チームの全オブジェクト」とは解釈せず拒否します。`?cascade=0` は列挙されたオブジェクトのみを削除し、派生物は残します。対象は呼び出し側自身の一覧取得を通じて決まるため、可視性・共有・組織ゲートは `GET /api/repo?prefix=` と同一に適用され、削除ごとにオブジェクト単位の権限確認が再実行されます。 |
| GET | `/api/repo` | bearer | `files:read` | role | — | リポジトリのオブジェクトを ?prefix= で一覧（ページング対応）。?shared=1 は、呼び出し元が有効な権限付与を持ち、かつ所有していないものだけを一覧します。?scope=org は会社内のすべてのチームにまたがります（TEN-2h）。?attr=key:value はチーム定義のメタデータが一致するものに絞り込みます（繰り返し指定可、LAY-4）。 |
| POST | `/api/repo-obj/:id/share` | bearer | `files:manage` | resource | — | 組織内のユーザーまたはチームと共有する：{principal_type, principal_id, capability: view\|edit\|manage, expires_at?}。{user_id} は従来どおり view を意味します。 |
| POST | `/api/repo-obj/:id/unshare` | bearer | `files:manage` | resource | — | プリンシパルがそのオブジェクトに持つすべての権限付与を取り消す。 |
| GET | `/api/repo-obj/:id/grants` | bearer | `files:manage` | resource | — | 1つのプリンシパルにつき1行: 能力、権限、授与者、期限、期限切れ |
| GET | `/api/repo-obj/:id/derivations` | bearer | `files:read` | resource | — | 由来: 文書がどの実行とステップから派生したか |
| GET | `/api/repo-fields` | bearer | `files:read` | role | — | チームのオブジェクトメタデータ項目：ドキュメントに付与できる情報（プロジェクト、場所、期間、ステータスなど）。検証は required / digits / minlength / maxlength のみで、正規表現は使いません。 |
| PUT | `/api/repo-fields` | bearer | `settings:manage` | role | — | チームのオブジェクトメタデータ項目を定義する：{fields: [{key, label, required?, digits?, minlength?, maxlength?, help?}]}。項目の追加にマイグレーションは不要です。 |
| PATCH | `/api/repo-obj/:id/attributes` | bearer | `files:read` | resource | — | ドキュメントにチーム定義のメタデータを設定する：{attributes: {key: value}}。そのドキュメントに対する files:write が必要です。チームが定義していないキーは保存されずに拒否され、空の値は設定を解除します。 |
| GET | `/api/repo-obj/:id/spans` | bearer | `files:read` | resource | — | 抽出したテキストの出典：各断片のページと領域（LAY-5）。?at=<文字オフセット> を付けると、その位置を含む範囲だけを返します。抽出した値から、それが読み取られた箇所へレビュー担当者が辿るための仕組みです。 |
| GET | `/api/repo-obj/:id/processing` | bearer | `files:read` | resource | — | 「処理履歴」：派生した文書、元の文書、そしてこの文書に触れたすべての実行。 |
| GET | `/api/admin/anchor` | bearer | `instance:read` | role | — | アンカーの状態（#66）：受領証の発行が設定されているか、受領証の署名に使う公開鍵、このインスタンスのシリーズ ID、受領証の総数、最新の連番とハッシュを返す。報告するのは「発行された」内容だけであり、「保管された」ことは決して主張しない —— アンカーとなるのは外部に保管された写しであり、他者がそれを保持しているかどうかをプラットフォームは検証できない。 |
| POST | `/api/admin/anchor/emit` | bearer | `instance:manage` | role | — | アンカー受領証を直ちに発行する：監査チェーンを封印し、両方のチェーンのヘッド（チームごとのレビューチェーン、組織ごとの監査チェーン）を読み、その測定値を TELEMACHUS_ANCHOR_KEY で署名する。アンカー鍵が未設定の場合は 400。同時に 2 件発行しようとした場合は、再試行せず連番の一意インデックスで拒否する —— 分岐したシリーズは偽造と区別できないからである。 |
| GET | `/api/admin/anchor/receipts` | bearer | `instance:read` | role | — | アンカー受領証を新しい順に返す。`?since_seq=` を指定した場合は古い順。各受領証は署名対象となった正確なバイト列、その署名、署名に使われた公開鍵、連番、直前の受領証のハッシュを含む。`limit` の上限は 1000。 |
| GET | `/api/admin/anchor/export` | bearer | `instance:read` | role | — | アンカー受領証を JSONL（古い順）で返す。このインスタンスの信頼境界の外に保管するためのもの。`?since_seq=` は保管側がまだ持っていない分だけを要求するので、ファイルに追記できる。保管した写しは `racket cli/telemachus-anchor.rkt verify <file> --public-key <hex>` でオフライン検証する —— このサーバーもそのデータベースも必要としない。アンカーが意味を持つのは、まさにそのインスタンス自身が疑われている場合だからである。 |
| GET | `/api/admin/audit/verify` | bearer | `instance:read` | role | — | 1つの組織の監査ログのハッシュチェーンを検証し、最初に壊れたエントリを示す。 |
| GET | `/api/admin/audit/export` | bearer | `instance:manage` | role | — | 1つの組織の監査ログを日付範囲で JSONL として書き出す。チェーンのフィールドを含む。 |
| GET | `/api/repo-obj/:id/reads` | bearer | `files:read` | resource | — | この文書を誰がいつどこから読んだか：読み取り、署名付きリンクの発行と利用、拒否された試行を含む。 |
| GET | `/api/share-targets` | bearer | `files:read` | role | — | 文書を誰と共有できるか：チームのメンバーと組織内のチーム。 |
| POST | `/api/repo-obj/:id/visibility` | bearer | `files:manage` | resource | — | プライベート、チームまたは共有に設定します。 |
| GET | `/api/repo-obj/:id/content` | bearer | `files:read` | resource | — | バイト列をダウンロードする（履歴は ?version=）。型がインライン許可リストにない限り、添付ファイルとして nosniff 付きで返します。 |
| POST | `/api/repo-obj/:id/presign` | bearer | `files:read` | resource | — | 呼び出し元自身の最新の S3 キーで署名された、期限付きの事前署名 S3 URL。 |
| GET | `/api/repo-obj/:id/traces` | bearer | `files:read` | resource | — | オブジェクトに何が残っているか：バージョン、抽出テキスト、派生文書、派生関係の行、共有、残存するブロブ、そしてペイロードや結果がその ID をまだ含むジョブ。削除要求に対する検証用の読み取りです（#86）。「DELETE を呼んで 200 が返った」ことは証拠になりませんが、これは証拠になります。`audit` は報告されますが、ゼロにすべき痕跡ではありません。監査ログは消去後も意図的に残るものです。 |
| GET | `/api/repo-obj/:id` | bearer | `files:read` | resource | — | バージョン付きのオブジェクトメタデータ |
| DELETE | `/api/repo-obj/:id` | bearer | `files:delete` | resource | — | オブジェクトを削除します。バイト列は、同一組織内で参照が一切なくなった時点で解放されます（別バージョン、別オブジェクト、または進行中アップロードのステージ済みパート）。`?cascade=1` はそのオブジェクトから派生したすべて（抽出 JSON、記入済みフォーム、各翻訳）を再帰的に削除し、単一の監査対象操作として扱います。`?detach=1` を併用すると派生物は保持し、代わりに派生関係の行を削除するため、存在しないものを出自として主張する記録が残りません。`?dry_run=1` は削除対象を報告するだけで何も変更しません。カスケードは権限について全か無かです。削除権限のないオブジェクトがツリーに含まれる場合、操作全体を名前付きで拒否します。途中まで実行されたツリーは完了したツリーと区別できないためです。 |
| PUT | `/api/repo/*key` | bearer | `files:write` | resource | — | 生のボディをキーにアップロードする（?filename=, ?visibility=）；既存のキーへの書き込みはバージョンを追加します。トリガーはここで評価されます。 |
| GET | `/api/s3/credentials` | bearer | — | — | — | 呼び出し元の S3 アクセスキー（シークレットは二度と表示されません）と、それを使うエンドポイント／バケット。 |
| POST | `/api/s3/credentials` | bearer | — | — | — | S3アクセスキーを発行し、オプションで範囲指定（トリガーが発生するプレフィックスに対してworkflows:runを追加します）。 |
| DELETE | `/api/s3/credentials/:id` | bearer | — | — | — | S3アクセスキーを無効にする；そのアクセスキーで署名されたプレシグナードリンクも無効になります。 |
| POST | `/api/workflows` | bearer | `workflows:write` | role | `workflows` | ワークフロー仕様を公開する（検証済み；未知のフィールドは拒否）；同じスラッグの再公開はバージョンを上げます。 |
| GET | `/api/workflows` | bearer | `workflows:read` | role | `workflows` | チームのワークフロー定義。プラグイン提供のものは初回参照時に実体化されます。 |
| GET | `/api/workflows/schema` | public | — | — | — | ワークフロー仕様フォーマット：バージョン、ステップ種類、バインディング参照、述語 |
| POST | `/api/workflows/:slug/run` | bearer | `workflows:run` | role | `workflows` | {input} で実行を開始する；宣言された入力は必須で型付きです。202 と実行を返します。 |
| GET | `/api/doc-triggers` | bearer | `workflows:read` | role | `workflows` | チームのアップロードトリガーと、チームの残り AI 予算。 |
| POST | `/api/doc-triggers` | bearer | `workflows:write` | role | `workflows` | トリガーを作成：workflow_slug, match_prefix, match_types, input, fire_on_derived. |
| GET | `/api/doc-triggers/:id` | bearer | `workflows:read` | resource | — | 1つのトリガーとその発火履歴（どのバージョン、どの実行、あるいはなぜ発火しなかったか）。 |
| PATCH | `/api/doc-triggers/:id` | bearer | `workflows:write` | resource | — | トリガーのフィールドを変更；存在しないフィールドはそのままにします。 |
| DELETE | `/api/doc-triggers/:id` | bearer | `workflows:write` | resource | — | トリガーとその履歴を削除します；開始した実行は残ります。 |
| GET | `/api/workflows/:slug` | bearer | `workflows:read` | resource | `workflows` | 1つのワークフロー定義とその仕様 |
| GET | `/api/runs` | bearer | `workflows:read` | role | `workflows` | チームの実行、新しい順。 |
| POST | `/api/runs/:id/cancel` | bearer | `workflows:run` | role | `workflows` | 実行を取消；既に実行中のステップが終了し、次のステップは開始しません。 |
| GET | `/api/runs/:id` | bearer | `workflows:read` | resource | `workflows` | 1つの実行とそのステップ、インプット、アウトプット、およびエラー |
| GET | `/api/reviews` | bearer | `reviews:read` | role | — | チームのレビューキュー、新しい順。?status=pending（既定）、decided、canceled、all。 |
| GET | `/api/reviews/stats` | bearer | `reviews:read` | role | — | AI の出力をレビュー担当者がそのまま承認した割合：ワークフローとステップごとの承認・差し戻し・却下の件数と、判断までの平均時間。別個の評価システムではなく、すでに記録済みの判断に対する集計です。?since=<エポックミリ秒> で期間を絞れます。 |
| GET | `/api/reviews/verify` | bearer | `audit:read` | role | — | チームの判断チェーンを再計算して検証し、保存されたハッシュが内容と一致しない最初の判断を示します。records の改ざんや中間の削除は検出しますが、テーブルに書き込める者による書き換えは検出できません（以降のリンクを再計算できるため）。それには外部のアンカーが必要です。 |
| GET | `/api/reviews/:id` | bearer | `reviews:read` | role | — | 1つのレビュー：対象、回答すべきチェックリスト、そして判断済みであればその内容。 |
| POST | `/api/reviews/:id/decide` | bearer | `reviews:decide` | role | — | レビューを判断する：{verdict: approve\|revise\|reject, rationale, answers}。差し戻しと却下には理由が必須です。ダブルチェック指定のレビューは作成者本人を拒否します。待機していた実行は、判定が示す分岐へ進んで再開します。 |
| GET | `/api/kg/entities` | bearer | `files:read` | role | — | ?q= と ?type= でエンティティを検索する；呼び出し元が読める言及を持つものだけ。 |
| GET | `/api/kg/entities/:id` | bearer | `files:read` | resource | — | 1つのエンティティとその関係・言及。各言及は元文書の公開範囲でフィルタされます。 |
| POST | `/api/kg/extract` | bearer | `workflows:run` | role | `workflows` | チームの未抽出文書をインデックス化するワークフローをキューに追加します。 |
| POST | `/api/admin/seed` | bearer | `settings:manage` | role | — | 呼び出し元のチームにサンプルのノートと文書を投入する。 |
| GET | `/api/metrics` | bearer | `instance:read` | role | — | 運用メトリクス。 |
| GET | `/api/features` | bearer | — | — | — | チームの機能フラグ |
| POST | `/api/features/:name` | bearer | `settings:manage` | role | — | チームの機能を有効または無効にする。チームは上位の層が許可する範囲で厳しくできるが、緩めることはできない。 |
| GET | `/api/instance-features` | bearer | `instance:manage` | role | — | インスタンスがどの機能を許可しているか。キーが無い場合は許可。 |
| PUT | `/api/instance-features` | bearer | `instance:manage` | role | — | インスタンス全体で機能を無効にする。組織もチームも再び有効にはできない。 |
| GET | `/api/org/features` | bearer | `org:read` | role | — | 呼び出し元の会社がどの機能を許可しているか。 |
| PUT | `/api/org/features` | bearer | `org:manage` | role | — | 呼び出し元の会社で機能を無効にする。その配下のチームは再び有効にはできない。 |
| GET | `/api/plugins` | bearer | — | — | — | 読み込まれたプラグインと、そのツールおよびワークフロー。 |
| GET | `/api/mcp` | bearer | — | — | — | 接続されたMCPサーバー |
| GET | `/api/oop` | bearer | — | — | — | 接続済みのサンドボックス化（プロセス外）プラグインと、それらが要求できる機能。 |
| POST | `/api/tools/:name` | bearer | `settings:manage` | role | — | チーム用のツールを有効にする/無効にする |

## Plugin routes

Routes contributed by loaded plugins, mounted under `/api/x/<plugin>/`. Every one requires a bearer token; the permission, when named, is checked before the plugin's handler runs. Matched after the core routes above.

| Method | Path | Plugin | Permission | Description |
|---|---|---|---|---|
| GET | `/api/x/example-tools/word-count` | `example-tools` | `chat:use` | ?text= の単語数を数える。 |
| POST | `/api/x/example-tools/word-count` | `example-tools` | `chat:use` | {text} の単語数を数える。 |
| GET | `/api/x/integrator-demo/eta` | `integrator-demo` | `chat:use` | ?lane= で指定したレーンの推定日数。 |
| POST | `/api/x/integrator-demo/eta` | `integrator-demo` | `chat:use` | {lane} の推定日数。 |

