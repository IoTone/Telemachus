<!-- source-sha1: 8e848e58b47fad01072ca7b1b756b1c1286518dc -->
# ワークフロー


## 仕様が契約である

ワークフローとは検証済みのデータ文書である。スラグ、型の付いた入力、そしてツールを使う・述語で分岐する・リストの上に展開するステップからなる。`define-workflow` はその文書を出力するマクロであり、API に POST された JSON 文書も同じ検証器を通る。二つ目の経路は存在しない。未知のフィールドは拒否される。これには、より新しい仕様バージョンや、このビルドに無いステップ種別も含まれる。束縛の下位言語は凍結されている — 参照と七つの述語だけで、算術も評価もない — そして逃げ道は「ツールを書く」ことである。

    (define-workflow process-upload
      #:input ([object_id string] [schema object] [template string] [locales array])
      (step text     (tool doc_text #:object (in object_id)))
      (step fields   (tool doc_extract_fields #:text (out text result) #:schema (in schema)
                                              #:object (in object_id) #:run (run-id) #:step "fields")
                     #:retry 1)
      (step has_form (choice (empty (in template)) #:then translate_source #:else form))
      (step form     (tool doc_render #:template (in template)
                                      #:data (out fields result fields) ...))
      (step translate_form (map #:over (in locales)
                                (tool doc_translate #:object (out form result object_id)
                                                    #:locale (item) ...))
            #:end)
      ...)

## 実行はリデューサである

エンジンはメモリに何も保持しない。`flow-advance!` はデータベースから実行を読み、その次のステップをスケジューラのジョブとして投入する。ジョブが終わると、そのステップの出力が書かれ、カーソルが進む。したがって永続性、キャンセル、クォータの受け入れ判定、チームごとの同時実行上限、組織のゲートは、作り直されるのではなくスケジューラから受け継がれる。展開は親の行一つと N 個の子ジョブであり、最後に終わった子がロックの下でカーソルを進める。そうしなければ、二つの子がそれぞれ次のステップを投入してしまう。

宣言された入力は必須であり型が付いている。一つでも欠けた実行は、三ステップ先で束縛が null に解決されるのではなく、開始時点で拒否される。プラグインが提供するワークフローは、最初に参照された時点でチームの定義へ実体化される。その挿入が冪等なのは、コンソールが二つの参照を並行して投げるからであり、二つ目が一度 500 を返したことがある — これを見つけたのは端から端までのゲートであって、一つずつ参照するどのスモークでもなかった。

## 開いてみるファイル

`domain/flow/spec.rkt`（規範である）、`domain/flow/dsl.rkt`、`domain/flow/bind.rkt`、`domain/flow/run.rkt`、`docs/design/workflow-engine.md`、`docs/reference/workflows.md`。
