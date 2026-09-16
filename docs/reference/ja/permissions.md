# Permissions

Permissions are `resource:action` strings; roles are named sets of them. `instance:*` is held only by the operator and `org:*` only by a company's org role — neither is reachable from a team role, whatever wildcard it grants. A resource's owner holds every team-tier permission on it (owner-ok), and a grant on one resource delegates the permission it names.

## Catalog

| Permission | Tier | Description |
|---|---|---|
| `*:*` | team | チーム層のすべて。instance:* や org:* には決して届きません。 |
| `*:read` | team | チームに公開されたすべてのリソースを読む；AI 利用なし、変更なし。 |
| `audit:read` | team | 監査ログを読む。 |
| `chat:use` | team | モデルと対話する：チャット、エージェント、翻訳、AIツール。従量制。 |
| `documents:delete` | team | テキストドキュメントを削除します。 |
| `documents:read` | team | 文書を読みます。 |
| `documents:write` | team | 文書を作成し、編集します。 |
| `features:manage` | team | チームごとに機能をオン／オフにする。 |
| `files:delete` | team | リポジトリの文書を削除する。 |
| `files:manage` | team | 文書を管理する：公開範囲の変更、共有と取り消し。所有者は owner-ok により保持し、manage 権限の付与で1つの文書の管理を委任できます。 |
| `files:read` | team | リポジトリの文書を開く・ダウンロードする・検索する；由来と知識グラフを読む。 |
| `files:write` | team | ドキュメントと新バージョンをアップロードします。 |
| `instance:*` | instance | インスタンス層のすべて；オペレーター（スーパー管理者）。 |
| `instance:manage` | instance | インスタンス管理：ブランド設定、ローカライゼーションポリシー、クォータ、組織、メトリクス |
| `jobs:execute` | team | プル型エグゼキュータに提供されたジョブの取得・ハートビート・完了・失敗報告。ワーカートークンのみが保持し、1つのエグゼキュータに紐づきます；チームのデータには届かず、実行も開始しません。 |
| `localization:manage` | team | カタログのインポートとエクスポート、AIドラフトのキュー管理、機械ドラフトの破棄 |
| `localization:read` | team | ローカライゼーションマネージャーのカバレッジとメッセージを見る。 |
| `localization:review` | team | 同僚の翻訳を承認または差し戻す（自分のものは不可）。 |
| `localization:translate` | team | 翻訳を提出します。 |
| `members:manage` | team | チームメンバーを追加・削除し、役割を設定します。 |
| `memory:read` | team | エージェントのメモリを読む。 |
| `memory:write` | team | エージェントのメモリに書き込む。 |
| `models:serve` | team | チームのモデルエグゼキュータを登録する。 |
| `notes:delete` | team | ノートを削除 |
| `notes:manage` | team | 自分が所有していないノートを共有する。 |
| `notes:read` | team | ノートを読む |
| `notes:write` | team | ノートの作成と編集 |
| `org:*` | org | 会社層のすべて。instance:* には決して届きません。 |
| `org:manage` | org | 会社の管理：チームとメンバー。チームデータは管理するが読まない（TEN-2a）。 |
| `org:read` | org | 会社、そのチーム、メンバー、監査ログを見る。 |
| `org:read-data` | org | 会社内のすべてのチームにわたり、チームに公開されたノート・文書・検索結果を読む（TEN-2h）。非公開のものは対象外；書き込み不可；AI 利用不可。org_reader ロールが保持します。 |
| `quota:manage` | team | クォータを設定する。 |
| `quota:read` | team | クォータを見る。 |
| `research:use` | team | リサーチ機能を使う。 |
| `roles:manage` | team | チーム役割の作成と編集 |
| `roles:read` | team | チームの役割とそれが与えるものを見る |
| `settings:manage` | team | チーム設定：トークン、機能フラグ、ツールの有効化、用語集、シード投入、監査ログ。 |
| `tasks:delete` | team | タスクを削除します。 |
| `tasks:read` | team | タスクを読む。 |
| `tasks:write` | team | タスクを作成し、編集します。 |
| `team:create` | team | 会社でチームを作成します。 |
| `team:delete` | team | チームを削除します。 |
| `team:read` | team | 会社内のチームを確認してください。 |
| `team:write` | team | 会社のチーム名を変更します。 |
| `tokens:manage` | team | チームに対してAPIトークンを発行および取り消します。 |
| `tools:invoke` | team | 代理機またはワークフローのステップからツールを呼び出します；各ツールは自分の権限を確認します |
| `webhooks:manage` | team | 外向きの Webhook を設定する。 |
| `workflows:read` | team | ワークフロー定義、実行とトリガーを確認します。 |
| `workflows:run` | team | 実行の開始と取り消し。アップロードでトリガーを発火させるには、S3 キーにこのスコープが必要です。 |
| `workflows:write` | team | ワークフローを公開し、トリガーを管理します。 |

## Built-in roles

| Role | Tier | Grants |
|---|---|---|
| Owner (`owner`) | team | `*:*` |
| Admin (`admin`) | team | `members:manage`, `tokens:manage`, `webhooks:manage`, `settings:manage`, `models:serve`, `roles:read`, `audit:read`, `chat:use`, `tools:invoke`, `research:use`, `documents:read`, `documents:write`, `documents:delete`, `notes:read`, `notes:write`, `notes:delete`, `tasks:read`, `tasks:write`, `tasks:delete`, `memory:read`, `memory:write`, `files:read`, `files:write`, `files:delete`, `files:manage`, `localization:read`, `localization:translate`, `localization:review`, `localization:manage`, `workflows:read`, `workflows:write`, `workflows:run` |
| Member (`member`) | team | `chat:use`, `tools:invoke`, `research:use`, `documents:read`, `documents:write`, `notes:read`, `notes:write`, `tasks:read`, `tasks:write`, `memory:read`, `memory:write`, `files:read`, `files:write`, `files:delete`, `localization:read`, `localization:translate`, `workflows:read`, `workflows:run` |
| Viewer (`viewer`) | team | `*:read` |
| Organization Owner (`org_owner`) | org | `org:*`, `team:read`, `team:write`, `team:create`, `team:delete`, `members:manage`, `roles:manage`, `roles:read`, `quota:manage`, `quota:read`, `settings:manage`, `features:manage`, `tokens:manage`, `audit:read`, `workflows:read` |
| Organization Admin (`org_admin`) | org | `org:read`, `org:manage`, `team:read`, `team:write`, `team:create`, `members:manage`, `roles:manage`, `roles:read`, `quota:manage`, `quota:read`, `settings:manage`, `features:manage`, `tokens:manage`, `audit:read`, `workflows:read` |
| Organization Reader (`org_reader`) | org | `org:read`, `org:read-data`, `team:read` |

## Role matrix

Which built-in role covers which permission (wildcards expanded).

| Permission | owner | admin | member | viewer | org_owner | org_admin | org_reader |
|---|---|---|---|---|---|---|---|
| `audit:read` | ✓ | ✓ |  | ✓ | ✓ | ✓ |  |
| `chat:use` | ✓ | ✓ | ✓ |  |  |  |  |
| `documents:delete` | ✓ | ✓ |  |  |  |  |  |
| `documents:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `documents:write` | ✓ | ✓ | ✓ |  |  |  |  |
| `features:manage` | ✓ |  |  |  | ✓ | ✓ |  |
| `files:delete` | ✓ | ✓ | ✓ |  |  |  |  |
| `files:manage` | ✓ | ✓ |  |  |  |  |  |
| `files:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `files:write` | ✓ | ✓ | ✓ |  |  |  |  |
| `instance:manage` |  |  |  |  |  |  |  |
| `jobs:execute` | ✓ |  |  |  |  |  |  |
| `localization:manage` | ✓ | ✓ |  |  |  |  |  |
| `localization:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `localization:review` | ✓ | ✓ |  |  |  |  |  |
| `localization:translate` | ✓ | ✓ | ✓ |  |  |  |  |
| `members:manage` | ✓ | ✓ |  |  | ✓ | ✓ |  |
| `memory:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `memory:write` | ✓ | ✓ | ✓ |  |  |  |  |
| `models:serve` | ✓ | ✓ |  |  |  |  |  |
| `notes:delete` | ✓ | ✓ |  |  |  |  |  |
| `notes:manage` | ✓ |  |  |  |  |  |  |
| `notes:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `notes:write` | ✓ | ✓ | ✓ |  |  |  |  |
| `org:manage` |  |  |  |  | ✓ | ✓ |  |
| `org:read` |  |  |  |  | ✓ | ✓ | ✓ |
| `org:read-data` |  |  |  |  |  |  | ✓ |
| `quota:manage` | ✓ |  |  |  | ✓ | ✓ |  |
| `quota:read` | ✓ |  |  | ✓ | ✓ | ✓ |  |
| `research:use` | ✓ | ✓ | ✓ |  |  |  |  |
| `roles:manage` | ✓ |  |  |  | ✓ | ✓ |  |
| `roles:read` | ✓ | ✓ |  | ✓ | ✓ | ✓ |  |
| `settings:manage` | ✓ | ✓ |  |  | ✓ | ✓ |  |
| `tasks:delete` | ✓ | ✓ |  |  |  |  |  |
| `tasks:read` | ✓ | ✓ | ✓ | ✓ |  |  |  |
| `tasks:write` | ✓ | ✓ | ✓ |  |  |  |  |
| `team:create` | ✓ |  |  |  | ✓ | ✓ |  |
| `team:delete` | ✓ |  |  |  | ✓ |  |  |
| `team:read` | ✓ |  |  | ✓ | ✓ | ✓ | ✓ |
| `team:write` | ✓ |  |  |  | ✓ | ✓ |  |
| `tokens:manage` | ✓ | ✓ |  |  | ✓ | ✓ |  |
| `tools:invoke` | ✓ | ✓ | ✓ |  |  |  |  |
| `webhooks:manage` | ✓ | ✓ |  |  |  |  |  |
| `workflows:read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |  |
| `workflows:run` | ✓ | ✓ | ✓ |  |  |  |  |
| `workflows:write` | ✓ | ✓ |  |  |  |  |  |

