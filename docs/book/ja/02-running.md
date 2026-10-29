<!-- source-sha1: eaaaaa264238a398d41c4e2e20adfa0f0779094d -->
# 動かしてみる


## ツールチェーン

    nix develop                         # リポジトリのルートで。Racket 9.3 を固定し、PLTCOLLECTS を設定する
    cd refimpl/racketmaximus
    raco make server/main.rkt           # 事前コンパイル。これをしないと起動が遅い
    raco test test/*-tests.rkt          # ユニットスイート
    racket server/main.rkt              # http://127.0.0.1:8835

シェルに入るのはリポジトリのルートからであって、`refimpl/racketmaximus` の中からではない。シェルのフックは現在のディレクトリから `PLTCOLLECTS` を組み立てるので、一段下で入るとパスが二重になり、すべての `db-kit` の読み込みが「collection not found」で壊れる。

`raco test test/*.rkt` は決して実行しないこと。このグロブは `test/mock-*.rkt` を含んでしまうが、これは永久にブロックするモックサーバである。ユニットスイートは `test/*-tests.rkt` である。

## 環境変数

    DATABASE_URL=sqlite:///$PWD/data/telemachus.db   # または postgres://user:pass@host:port/db
    TMACH_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions   # OpenAI 互換のエンドポイント
    TMACH_MODEL=qwen2.5:7b
    TMACH_HOME=login          # `beta` にするとオンボーディング用の導線を / で配信する
    TMACH_S3_PORT=8836        # S3 エンドポイントを有効にする。二つ目のリスナーである
    TMACH_MULTITENANT=1       # 一つのインスタンスに複数の会社を載せる
    PORT=8835

これらはかつて `TELEMACHUS_*` という綴りだった。その綴りはいまも応える。プラットフォームは新しい名前を先に読み、なければ古い名前へ落ちる。期限はなく、移行すべきものもない。古い名前で書かれた配備はそのまま動き続ける。プラットフォームが読む変数の一覧は `docs/ops/configuration.md` にある。

`TMACH_MODEL_URL` がないと、プラットフォームは入力を大文字で返すだけの模擬モデルで動く。チャットは動き、スモークスイートも動き、本物の推論を必要とするものだけが動かない。モデルを必要とするツール — 翻訳の下書き生成、ドキュメントパイプライン、知識グラフの抽出 — は、誤解を招くメッセージで毎回の検証に失敗するのではなく、実行そのものを拒否する。これは意図的である。運用者が読む必要があるのは「モデルが設定されていない」であって、「応答が JSON ではなかった」ではない。

## 最初の起動

ユーザー名とパスワードを添えて `POST /api/bootstrap` を呼ぶと、運用者、最初の組織、最初のチームが作られ、運用者のトークンが返る。これはちょうど一度だけ成功する。その後は `/` から、あるいは `POST /api/login` でサインインする。

## 開いてみるファイル

リポジトリのルートにある `CLAUDE.md` が作業ノートである。午後を一つ潰したすべての落とし穴が、サブシステムごとにそこへ書かれている。`flake.nix` がツールチェーンであり、`refimpl/racketmaximus/config.rkt` が環境である。
