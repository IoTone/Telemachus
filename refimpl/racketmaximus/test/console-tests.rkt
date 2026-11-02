#lang racket/base

;; test/console-tests.rkt — the console's own file, as a shipped artifact (issue #27).
;;
;; The nonce policy only holds while the console has NO inline event handlers: a
;; nonce cannot authorize an `onclick` attribute, so one new inline handler would
;; silently stop working under the very policy this slice earned. That is not
;; something the e2e gate can be relied on to catch (it exercises the main paths,
;; not all 141 handlers), so it is pinned here, statically, where it is cheap.
;;   raco test test/console-tests.rkt

(require rackunit racket/file racket/string racket/list racket/runtime-path)

(define-runtime-path console-html "../static/index.html")
(define-runtime-path console-dir "../static/console")
;; anchored at this FILE, never at `current-directory`, which is `test/`
;; when raco runs from there — the "anchor at definition, never at use" rule
(define-runtime-path scheduler-rkt "../domain/sched/scheduler.rkt")

;; A TEXT SCAN OVER THE CONSOLE READS ITS OWN COMMENTS, and that has now cost
;; four separate assertions in these notes. A check for a code construct must
;; look at CODE: `09-repo.js` explains in prose why a modal would mean `Hk()`
;; and the Hk test below reported that as a sweep violation, while the one-seam
;; check for `navigate()` counted the router's own header three times.
(define (console-code f)
  (string-join
   (for/list ([ln (in-list (string-split (file->string (build-path console-dir f)) "\n"))]
              #:unless (regexp-match? #px"^\\s*(//|\\*|/\\*)" ln))
     ln)
   "\n"))
(define shell (file->string console-html))

;; #110 r6 moved the console's 2,295 lines of inline script into
;; static/console/*.js. This file named static/index.html and nothing else, so a
;; named-file read would have gone on passing while looking at a shell that no
;; longer holds a single handler — the same false PASS r3 had to fix in
;; test/route-perm-gate-tests.rkt. `html` is the shell PLUS every script it
;; loads, which is what the browser actually gets.
(define script-files
  (sort (for/list ([p (in-list (directory-list console-dir))]
                   #:when (regexp-match? #rx"[.]js$" (path->string p)))
          (path->string p))
        string<?))
(define html
  (string-join (cons shell (for/list ([n (in-list script-files)])
                             (file->string (build-path console-dir n))))
               "\n"))

(test-case "the console has no inline event handlers"
  ;; the delegated dispatcher replaced every one of them; adding a new
  ;; `onclick="…"` would need `script-src 'unsafe-inline'` back
  (define found
    (for*/list ([ev (in-list '("click" "input" "change" "keydown" "keyup" "submit"
                               "focus" "blur" "mouseover" "mouseout" "load" "error"))]
                [m (in-value (regexp-match* (pregexp (string-append "\\bon" ev "=\"")) html))]
                #:when (pair? m))
      (cons ev (length m))))
  (check-equal? found '()
                "use data-h-<event>=\"${H((el,ev)=>…)}\" instead — see the dispatcher at the top of the script"))

(test-case "…and it does use the delegated form"
  ;; a positive control: if the regexp above stopped matching for some unrelated
  ;; reason, this is what says the handlers are really there
  (check-true (> (length (regexp-match* #px"data-h-(click|input|change|keydown)=" html)) 100))
  (check-true (string-contains? html "function H(fn)") "the registry")
  (check-true (string-contains? html "ev.preventDefault()") "…and `return false` is honoured"))

;; The one bug this conversion actually produced, and the reason it is pinned:
;; `${live?'data-h-click="${H(…)}"':'disabled'}` puts the attribute inside a
;; SINGLE-QUOTED string, so `${H(…)}` is never interpolated — the button ships a
;; literal "${H(...)}" and does nothing at all. It cost the funnel's submit button
;; and was invisible until a browser test pressed it.
(test-case "no handler is stranded in a plain string instead of a template literal"
  (check-equal? (regexp-match* #px"'data-h-(click|input|change|keydown)" html) '()
                "a data-h attribute inside a single-quoted string never interpolates H()")
  ;; the double-quoted variant, spelled with a character class to keep the quote
  ;; out of the pattern's own delimiters
  (check-equal? (regexp-match* #px"[\"]data-h-(click|input|change|keydown)=" html) '())
  ;; There is no useful check here for "the RENDERED attribute holds an index": in
  ;; this file every one of them is literally the registry call, and is meant to be.
  ;; A browser is what sees the rendered form — funnel-l10n.sh is what caught the
  ;; stranded button.
  (void))

(test-case "the shell has NO inline script, and loads exactly the files on disk"
  ;; Since #110 r6 there is no inline block, which is why the console's CSP is a
  ;; plain `script-src 'self'` with neither 'unsafe-inline' nor a nonce. A bare
  ;; `<script>` reintroduced here would be silently DEAD under that policy, so it
  ;; is refused statically rather than discovered in a browser.
  (check-equal? (regexp-match* #px"<script>" shell) '()
                "no inline script: the console's CSP has no 'unsafe-inline' and no nonce")
  ;; …and the two sides agree. A file added to static/console/ but never loaded
  ;; is dead code that looks live; a tag naming a file that is not there is a 404
  ;; the console cannot recover from. Both directions, like the config gate.
  (define loaded
    (for/list ([m (in-list (regexp-match* #px"<script src=\"/console/([^\"]+)\">" shell
                                          #:match-select cadr))])
      (bytes->string/utf-8 (if (bytes? m) m (string->bytes/utf-8 m)))))
  (check-equal? loaded script-files
                "every file in static/console/ is loaded, in name order, and nothing else is")
  (check-true (> (length script-files) 1) "…and the split really happened"))

;; ---- sending a prompt (issues #174, #181) ----------------------------------
;; #174 was reported from outside: one Send billed two model calls. The console
;; has no JS test runner, so the wiring is pinned here the way the permission
;; gates are pinned — by reading the source. The claim is narrow and worth
;; stating: this proves the guard is WIRED, not that it holds under a race.
;; What makes the race uninteresting is that the check and the set are in the
;; same synchronous run (no `await` between them), which the third case pins.
(define (fn-body name)
  (define m (regexp-match
             (pregexp (string-append "(?s:(?:async )?function " name "[(][^)]*[)].*?\n[}])")) html))
  (and m (car m)))

(test-case "a send path cannot start twice"
  (for ([f '("doChat" "doAgent")] [flag '("chatAbort" "agentAbort")])
    (define body (fn-body f))
    (check-true (and body #t) (format "~a is still a function" f))
    ;; the early return IS the guard
    (check-true (string-contains? body (string-append "if(S." flag ") return;"))
                (format "~a returns early while one send is in flight" f))
    ;; …and it is released however the stream ends, or one network error leaves
    ;; the button dead with no way back but a reload
    (check-true (regexp-match? (pregexp (string-append "finally *[{] *S[.]" flag "=null")) body)
                (format "~a clears ~a in a finally" f flag))))

(test-case "the guard is set before anything can yield"
  ;; Two activations in one tick must not both get past the check, so nothing
  ;; between the early return and the assignment may `await`.
  (for ([f '("doChat" "doAgent")] [flag '("chatAbort" "agentAbort")])
    (define body (fn-body f))
    (define head (car (regexp-split (pregexp (string-append "S\\." flag "=ac")) body)))
    (check-false (string-contains? head "await")
                 (format "~a does not await between the check and the set" f))))

(test-case "Enter sends and Shift+Enter does not"
  (check-true (string-contains? html "function sendKey(ev, fn)") "the shared key handler")
  (define body (car (regexp-match #px"(?s:function sendKey[(]ev, fn[)][{].*?\n[}])" html)))
  (check-true (string-contains? body "ev.shiftKey") "Shift+Enter is not a send")
  ;; the Enter that CONFIRMS a Japanese IME conversion must not send
  (check-true (string-contains? body "ev.isComposing") "an IME confirmation is not a send")
  (check-true (string-contains? body "ev.preventDefault()") "…and the newline is suppressed when it sends")
  ;; both prompts are wired to it, through the delegated form like everything else
  (for ([id '("cp" "ap")])
    (check-true (regexp-match? (pregexp (string-append "id=\"" id "\"[^>]*data-h-keydown")) html)
                (format "#~a sends on a key" id))))

;; ---- the search control, and the fleet's figures (issues #176, #178) --------
;; Both were reported from outside, with a screenshot each, and both are layout
;; — which this file cannot judge. What it CAN pin is the half of each fix that
;; a later edit would silently undo: the Enter handler the search issue asks
;; twice to keep, and the per-figure explanations the workers issue is about.

(test-case "the search field and its button are one control, and Enter still searches"
  (define body (fn-body "searchView"))
  (check-true (and body #t) "searchView is still a function")
  (check-true (string-contains? body "class=\"searchbar\"") "one composed control")
  (check-false (string-contains? body "align-items:end")
               "not two flex columns of different heights, which is what hung the button low")
  (check-true (regexp-match? #px"id=\"sq\"[^>]*data-h-keydown" body) "#sq still sends on a key")
  ;; through #174's shared rule, so a Japanese IME confirmation is no longer a search
  (check-true (string-contains? body "sendKey(ev,doSearch)") "…and through the one Enter rule")
  ;; a button whose whole label is a glyph needs an accessible name
  (check-true (string-contains? body "aria-label=") "the magnifier button is named")
  (check-true (string-contains? shell ".searchbar:focus-within")
              "the focus ring is on the wrapper — a borderless input inside a bordered box shows none"))

(test-case "every fleet figure explains itself, and its window is selectable"
  (define body (fn-body "wkFigs"))
  (check-true (and body #t) "wkFigs is still a function")
  ;; one tooltip per figure, not one for the column: the three numbers answer
  ;; different questions and the lease expiry is the one worth finding
  (check-true (string-contains? body "title=\"${esc(t(key))}\"")
              "a figure is rendered with a tooltip of its own, not one for the column")
  (check-equal? (length (regexp-match* #px"fig[(]w[.]" body)) 3
                "done, failed and lease-expired are three figures, each with its own key")
  (for ([k '("wkdonehint" "wkerrhint" "wkexpiredhint")])
    (check-true (string-contains? body k) (format "~a is used" k)))
  ;; the header NAMES the window rather than hardcoding one, because the window moved
  (check-true (string-contains? html "t('wkwindow').replace('{window}'")
              "the column header carries the window that was actually asked for")
  (check-true (string-contains? html "function fleetQuery()") "…and the read asks for it")
  (check-true (string-contains? html "/api/admin/workers'+fleetQuery()")
              "the fleet read carries the selected window")
  (check-true (regexp-match? #px"WKWINDOWS[.]map[(]h=>`<option" html) "the window is a control")
  ;; the destructive button is not flush against an unexplained number any more
  (check-true (string-contains? html "class=\"btn sm bad\" style=\"margin-left:14px\"")
              "Retire stands apart from Drain, and looks irreversible")
  ;; `class="small"` and `class="small danger"` matched NO rule in the shell, so
  ;; these were bare user-agent buttons and the irreversible one did not look it
  (check-equal? (regexp-match* #px"class=\"small( danger)?\"" html) '()
                "the fleet card uses the shell's own button vocabulary (.btn.sm / .btn.bad)"))

;; ---- which build is this? (the version footer) ------------------------------
;; Two instances a day apart were identical on screen, and the console was where
;; a person would have looked. The version alone could not have told them apart
;; (0.1.0 on both), so the commit is what the footer is really for.

(test-case "every console page carries the build, and the sign-in screen does not"
  (define shell (fn-body "appShell"))
  (check-true (and shell #t) "appShell is still a function")
  (check-true (string-contains? shell "buildFooter()") "the footer is in the shell, so it is on every tab")
  (define f (fn-body "buildFooter"))
  (check-true (and f #t) "…and it exists")
  ;; #11: the version, the KDF and the TLS state were moved OFF the public
  ;; /health because an exact version is a shopping list. The footer reads
  ;; whoami, which is authenticated, and the sign-in screen must not show it.
  (check-true (string-contains? f "S.me && S.me.build") "it reads the authenticated whoami")
  (check-false (string-contains? (or (fn-body "authView") "") "buildFooter")
               "the sign-in screen carries no version")
  ;; an older server that does not send the field renders nothing rather than a
  ;; blank line or a guess
  (check-true (string-contains? f "if(!b) return ''") "absent build, absent footer")
  ;; the full commit is reachable (the short one is what is shown), and the
  ;; source link is what makes a self-hosted MIT instance checkable
  (check-true (string-contains? f "b.commit_short") "the line is short")
  (check-true (string-contains? f "title=") "…and the full sha is on hover")
  (check-true (string-contains? f "rel=\"noopener noreferrer\"") "the source link is safe to click")
  (check-true (string-contains? shell "<main class=\"wrap\" id=\"main\"></main>")
              "…and it sits after the page body, not inside it"))

;; ---- the operator's own feature switches (issue #177) -----------------------
;; Feature switches have had three layers since #63 and the INSTANCE layer — the
;; one that means "this deployment does not do that" — had no UI at all. These
;; cases pin the two things a later edit would silently undo, both of them rules
;; FEAT-1…6 already decided and a UI can contradict without failing anything.

(test-case "the instance tier has a card, and it sends the WHOLE document"
  (define card (fn-body "instFeatCard"))
  (check-true (and card #t) "instFeatCard is a function")
  (check-true (string-contains? (or (fn-body "adminView") "") "instFeatCard()")
              "…and the Admin tab renders it")
  ;; found by id, as every other asserted card on this tab is: a `.card` locator
  ;; with hasText matched the wrong card once already (#178's Queue/Workers clash)
  (check-true (string-contains? card "id=\"instfeat\"") "the table has an id to assert on")
  ;; the read is what makes the card appear at all; a non-operator gets no card
  ;; rather than an empty one
  (check-true (string-contains? html "api('/api/instance-features')") "the stored document is read")
  (check-true (string-contains? card "if(!F) return ''")
              "no document, no card — a non-operator is not shown an empty one")
  ;; THE TRAP. `PUT /api/instance-features` replaces the document: there is no
  ;; per-feature route at this tier, because `feature-problem` validates the
  ;; document as a unit. A card that sent one key would wipe every other switch.
  (define save (fn-body "doInstFeature"))
  (check-true (and save #t) "doInstFeature is a function")
  (check-true (string-contains? save "Object.assign({}, (S.instFeat&&S.instFeat.features)||{})")
              "the PUT carries every switch, not just the one that moved")
  (check-true (string-contains? save "method:'PUT'") "…to the instance route")
  ;; "allow" REMOVES the key. Absence and a stored `true` both mean "this layer
  ;; does not object", and nothing sits above the instance to object to, so a
  ;; written `true` would be a setting that computes nothing.
  (check-true (string-contains? save "delete doc[name]")
              "allowing clears the key rather than storing an inert true")
  ;; turning a feature off hides its tab for this team too, and the tab list is
  ;; built in render(), not renderTab()
  (check-true (regexp-match? #px"(?s:S\\.instFeat = r\\.json.*?\n *render\\(\\))" save)
              "the tab list is rebuilt after a switch moves")
  ;; the console is entirely in the catalogs, and two of doSearch's three
  ;; messages were English literals for a year — a Japanese operator was told
  ;; "no results" in English. A new one must not go in beside them.
  (check-true (string-contains? save "t(allow?'featallowdone':'featoffdone')")
              "the toast comes from the catalogs, not a literal")
  ;; and the read is not a fourth sequential round trip on the slowest tab
  (check-true (string-contains? (or (fn-body "adminView") "") "api('/api/instance-features')]")
              "the read joins the Promise.all it does not depend on"))

(test-case "a team is not offered a switch a layer above has locked"
  ;; FEAT-1 is tighten-only: a team cannot turn on what the instance or its
  ;; company turned off, and the attempt is a 409 naming the layer. A button
  ;; whose only outcome is a refusal should not be drawn.
  (define body (fn-body "teamView"))
  (check-true (and body #t) "teamView is still a function")
  (check-true (string-contains? body "x.disabled_by") "the deciding layer is read")
  (check-true (string-contains? body "by!=='team'")
              "…and a layer ABOVE the team is what withdraws the control")
  ;; the locked branch carries no handler at all
  (define locked
    (car (regexp-match #px"const act = above \\? [^\n]*" body)))
  (check-false (string-contains? locked "data-h-click")
               "the locked row has no control, not a disabled-looking one")
  (check-true (string-contains? locked "featlocked") "…it says why instead")
  ;; Disable stays available even under a layer that already says no: a team
  ;; recording its own intention survives the instance switch being flipped back,
  ;; which is the whole reason the team row is kept.
  (check-true (string-contains? body "t('disable')") "a team may still tighten"))

(test-case "the feature map and the deciding layer cannot disagree"
  ;; `GET /api/features` carries `disabled_by` and this used to drop it, which is
  ;; why the team card could only ever show two states. Two independently built
  ;; maps is LIVE-IN's shape; the map is DERIVED from the rows in one place.
  (check-true (string-contains? html "S.featRows = fr.ok ? fr.json.features : []")
              "the rows are kept as sent")
  (check-true (string-contains? html "S.features = Object.fromEntries(S.featRows.map(")
              "…and the map is derived from them, not built a second time")
  ;; the tab filter and the fallback still read the map, so neither changed
  (check-true (string-contains? html "S.features[x]!==false") "the tab filter is unchanged")
  (check-true (string-contains? html "S.features[S.tab]===false") "…and so is the fallback"))

;; ---- the health screen (issue #179) ----------------------------------------
;; The console has no JS test runner, so these are SOURCE assertions, as the
;; sign-in and feature cases above are. The claim is narrow and worth stating:
;; they prove the screen is WIRED and that it reuses rather than duplicates —
;; not that it renders correctly, which a browser is what sees.

(test-case "the health screen is gated on instance:read, not on being an operator"
  ;; #124 made `instance:read` exist so a monitoring credential need not also be
  ;; able to reset a password, and a dashboard is the case that justified it.
  ;; Gating this on `S.me.is_operator` — the way the Admin tab is gated — would
  ;; have made the narrower permission useless for the one screen it is for.
  (define sh (file->string (build-path console-dir "02-auth.js")))
  (check-true (string-contains? sh "canPerm('instance:read')")
              "the tab is spliced on the permission")
  (check-true (regexp-match? #px"canPerm\\('instance:read'\\)[^\n]*'health'" sh)
              "…and it is the health tab that it gates"))

(test-case "the health screen COMPOSES the workers and queue cards"
  ;; The issue asks for a fleet section and a queue section and both already
  ;; exist on the Admin tab. Drawing those figures again here would be two
  ;; renderings of one answer — `executor-can-run?`'s drift, LIVE-IN's shape —
  ;; so this asserts the reuse AND the absence of a second rendering.
  (define hv (fn-body "healthView"))
  (check-true (and hv #t) "healthView exists")
  (check-true (string-contains? hv "workersCard(") "the fleet card is reused")
  (check-true (string-contains? hv "queueCard(") "…and so is the queue card")
  (define health (file->string (build-path console-dir "14-health.js")))
  (for ([fig (in-list '("unclaimable" "held_by_paused" "oldest_queued_seconds"
                        "leases_expired"))])
    (check-false (string-contains? health fig)
                 (format "~a belongs to the queue/workers card, not to a second copy here" fig))))

(test-case "the health screen does not poll"
  ;; #38's idle clock counts from the last REQUEST, and the console polls nothing
  ;; except a live workflow run — so a screen that refreshed itself would hold a
  ;; session open for as long as the tab was left on screen, which is an idle
  ;; timeout switched off by a convenience. The refresh is a button.
  (define health (file->string (build-path console-dir "14-health.js")))
  (check-false (string-contains? health "setInterval") "no timer")
  (check-false (string-contains? health "setTimeout") "…and no deferred one either")
  (check-true (string-contains? health "renderTab()") "the refresh is an explicit re-render"))

(test-case "the boot call is in the file that sorts LAST"
  ;; It used to be the last line of 13-kg.js, which worked only because render()
  ;; is async and yields at its first await — long enough for the remaining
  ;; <script> tags to parse before it reached renderTab()'s dispatch table. A
  ;; view added in a file that sorts after the booting one would be undefined at
  ;; that moment and the console would die at load with a ReferenceError. #179
  ;; added the first such file, so the boot moved.
  (check-equal? (last script-files) "99-boot.js"
                "the boot file must sort after every numbered one")
  (define boots
    (for/list ([n (in-list script-files)]
               #:when (regexp-match? #px"(?m:^render\\(\\);[ \t]*$)"
                                     (file->string (build-path console-dir n))))
      n))
  (check-equal? boots '("99-boot.js")
                "exactly one file calls render() at top level, and it is the last one"))

;; ---- one editor, two surfaces (issue #180) ----------------------------------
;; The Markdown renderer is the one thing here a SOURCE assertion cannot
;; establish: it is effectively a sanitiser, and "does it escape" is a question
;; about what it computes. So the hostile inputs are asserted in the browser,
;; where the real function runs on the real page — test/e2e/demo-validate.mjs
;; §3c. What is pinned here is the structure: that there is ONE editor, that the
;; escape happens FIRST, and that the edit paths exist at all.

(test-case "there is ONE editor component, and both surfaces use it"
  ;; The issue asks this to be decided up front and names the outcome to avoid:
  ;; "three bare textareas becoming three different editors".
  (check-equal? 1 (length (regexp-match* #px"function editorHTML\\(" html))
                "exactly one editor component")
  (check-true (string-contains? html "editorHTML('note'") "Notes uses it")
  (check-true (string-contains? html "editorHTML('doc'") "…and so does Documents"))

(test-case "the editor keeps the ids the fields it replaced had"
  ;; `page.fill('#nb', …)` and `#dc` are in demo-validate, the screenshot tour
  ;; and the funnel harness. Renaming a field to tidy it would break three
  ;; harnesses for nothing.
  (check-true (string-contains? html "editorHTML('note', {id:'nb'") "the note body is still #nb")
  (check-true (string-contains? html "editorHTML('doc', {id:'dc'") "…and the document body still #dc"))

(test-case "the Markdown subset escapes BEFORE it renders"
  ;; What makes the preview safe is the order, not a sanitiser: everything is
  ;; escaped first and the rules then run over escaped text emitting a closed
  ;; set of tags, so nothing from the source is ever passed through as markup.
  (define body (fn-body "mdRender"))
  (check-true (and body #t) "mdRender exists")
  (check-true (string-contains? body "esc(String(src") "the first thing it does is escape")
  ;; …and the blockquote rule matches the ESCAPED form, which is the tell that
  ;; the rules really do run after the escape rather than before it.
  (check-true (string-contains? body "&gt;") "the block rules match escaped markup")
  ;; a link's scheme is allowlisted rather than filtered
  (check-true (string-contains? html "function mdSafeUrl") "there is a scheme allowlist")
  (check-true (string-contains? html "mdSafeUrl(url)") "…and the link rule consults it"))

(test-case "a note and a document can be EDITED, which they could not before"
  ;; `PUT /api/notes/:id` and `PUT /api/documents/:id` have existed as long as
  ;; the route table; the console called neither, so it could create and delete
  ;; and never change. #113's shape on this side of the wire.
  (check-true (regexp-match? #px"/api/notes/'\\+S\\.noteEdit[^\n]*method:'PUT'" html)
              "notes save through PUT")
  (check-true (regexp-match? #px"/api/documents/'\\+S\\.docEdit[^\n]*method:'PUT'" html)
              "…and documents too"))

(test-case "line numbers turn soft wrap off, rather than lying about it"
  ;; A wrapped logical line takes several visual rows, so a gutter of logical
  ;; numbers stops aligning the moment one line wraps — and a gutter that is
  ;; subtly wrong is worse than none. The tie is in one function.
  (define body (fn-body "edWrap"))
  (check-true (and body #t) "edWrap exists")
  (check-true (string-contains? body "nums") "…and it is the line-number preference that decides")
  (check-true (string-contains? body "false")
              "with numbers on, wrapping is off"))

(test-case "the editor's text lives in S, not in localStorage"
  ;; The four VIEW preferences are per-viewer conveniences and are stored, each
  ;; access wrapped because the accessor throws in a private window. The TEXT is
  ;; not: it belongs in S so a render pass does not lose what has been typed,
  ;; which is paintAuth()'s rule for the same reason.
  (check-true (string-contains? html "localStorage.setItem('tmx_ed'") "the preferences are stored")
  (define save (fn-body "edSavePrefs"))
  (check-true (and save (string-contains? save "try")) "…inside a try/catch")
  (define prefs (fn-body "edPrefs"))
  (check-true (and prefs (string-contains? prefs "try")) "…and so is the read")
  (check-false (regexp-match? #px"setItem\\('tmx_ed[^)]*value" html)
               "the text itself is never written to localStorage"))

;; ---- the command palette (issue #182) --------------------------------------

(test-case "the palette hooks the ONE delegated listener, not a second one"
  ;; 01-base.js registers one document listener per event type; a second one for
  ;; a global shortcut is where the handler-leak and double-fire risks the
  ;; dispatcher exists to remove would start over. The issue asks for this by
  ;; name.
  (check-equal? 1 (length (regexp-match* #px"document\\.addEventListener" html))
                "exactly one document listener is registered anywhere")
  (define base (file->string (build-path console-dir "01-base.js")))
  (check-true (string-contains? base "paletteKey(ev)") "the palette hooks it")
  ;; …and it runs BEFORE the element lookup, because a global shortcut is not
  ;; about an element.
  (define i (let ([m (regexp-match-positions #px"paletteKey\\(ev\\)" base)]) (and m (caar m))))
  (define j (let ([m (regexp-match-positions #px"closest\\('\\[data-h-" base)]) (and m (caar m))))
  (check-true (and i j (< i j)) "the global hook precedes the element dispatch"))

(test-case "the modifier is DETECTED and the label follows the detection"
  ;; A hardcoded Cmd is wrong on two platforms out of three, and a label that
  ;; disagrees with the binding is worse than no label.
  (check-true (string-contains? html "userAgentData") "platform detection")
  (check-true (string-contains? html "navigator.platform") "…with a fallback")
  (define lab (fn-body "palModLabel"))
  (check-true (and lab #t) "the label is computed")
  (check-true (string-contains? lab "PAL_MAC")
              "…from the same detection the binding uses")
  (define mod (fn-body "palMod"))
  (check-true (and mod (string-contains? mod "metaKey") (string-contains? mod "ctrlKey"))
              "and the binding tests the right key per platform"))

(test-case "a bare ? does nothing while something is being typed into"
  ;; The one way a help shortcut can make a console worse than it was: eating a
  ;; question mark. Cmd/Ctrl+K is deliberately NOT subject to this, because a
  ;; held modifier is unambiguous.
  (define k (fn-body "paletteKey"))
  (check-true (and k #t) "paletteKey exists")
  (check-true (regexp-match? #px"ev\\.key === '\\?'[^\n]*palTyping\\(\\)" k)
              "the ? branch consults palTyping()")
  (define typing (fn-body "palTyping"))
  (check-true (and typing #t) "palTyping exists")
  (for ([tag (in-list '("input" "textarea" "select" "isContentEditable"))])
    (check-true (string-contains? typing tag) (format "~a counts as typing" tag)))
  ;; the K branch must NOT be gated on it
  (check-false (regexp-match? #px"=== 'k'[^\n]*palTyping" k)
               "a held modifier works everywhere, including in a field"))

(test-case "the palette and the shell share ONE tab list"
  ;; The palette's first job is "jump to a tab", so a second copy of the list
  ;; would drift — and the one that drifts is the palette's, which would offer a
  ;; tab a feature switch has turned off or a permission does not allow.
  (check-equal? 1 (length (regexp-match* #px"'chat','agent','translate','search'" html))
                "the tab list is spelled exactly once")
  (check-true (string-contains? html "function visibleTabs()") "…in one function")
  (check-true (string-contains? html "const tabs=visibleTabs()") "the shell asks it")
  (check-true (string-contains? html "for (const tab of visibleTabs())") "…and so does the palette"))

(test-case "Esc falls through when the palette is closed"
  ;; Escape has meanings this console already relies on — leaving the editor's
  ;; focus mode is one. Taking it unconditionally would break them.
  (define k (fn-body "paletteKey"))
  (check-true (regexp-match? #px"(?s:Escape.*?return false)" k)
              "Esc is not swallowed when there is nothing open"))

(test-case "a repaint is AWAITED all the way down to the tab"
  ;; `renderTab()` paints a `…` placeholder and then awaits its view, so a
  ;; fire-and-forget call made `render()` resolve at exactly the moment the DOM
  ;; held the placeholder and nothing else — and `applyBrand` then resolved
  ;; before its own repaint. Every caller of both awaits them and then touches
  ;; the page, so each was racing a repaint it had started itself. It surfaced
  ;; as a CI-only failure in #210: demo-validate's second `doBrandSave()` found
  ;; `#brt` null. The window is one server round trip wide, which is why it had
  ;; never lost locally. This is `goTab`'s hazard on the product's side.
  (define r (fn-body "render"))
  (check-true (and r #t) "render exists")
  (check-true (string-contains? r "await renderTab()")
              "render awaits the tab it paints")
  (define ab (fn-body "applyBrand"))
  (check-true (and ab #t) "applyBrand exists")
  (check-true (string-contains? ab "await render()")
              "…and applyBrand awaits the repaint it triggers"))

;; ---- in-product help: one overlay, one POST, hidden when it cannot work (#183)

(test-case "the help overlay hooks the SAME delegated listener, after the palette's"
  ;; #182 established that a global shortcut goes through the one document
  ;; listener rather than adding a second. This is the second such shortcut, so
  ;; what matters is the ORDER: the palette owns Esc while ITS overlay is open
  ;; and `helpKey` claims Esc only while its own is, so two handlers both taking
  ;; Esc unconditionally is how one starts closing the other's overlay.
  (define base (file->string (build-path console-dir "01-base.js")))
  (check-true (string-contains? base "helpKey(ev)") "the help overlay hooks it")
  (define i (let ([m (regexp-match-positions #px"paletteKey\\(ev\\)" base)]) (and m (caar m))))
  (define j (let ([m (regexp-match-positions #px"helpKey\\(ev\\)" base)]) (and m (caar m))))
  (define el (let ([m (regexp-match-positions #px"closest\\('\\[data-h-" base)]) (and m (caar m))))
  (check-true (and i j (< i j)) "the palette's hook runs first")
  (check-true (and j el (< j el)) "…and both precede the element dispatch"))

(test-case "the help affordance is HIDDEN when help cannot answer"
  ;; A panel that explains itself only after you press it is worse than no panel,
  ;; and the field it reads (`S.me.help.reason`) is already fetched on every
  ;; render pass. `locale-empty` is deliberately NOT hidden: the corpus exists
  ;; and the answer arrives in another language, which is worth offering.
  (define b (fn-body "helpBlocked"))
  (check-true (and b #t) "helpBlocked exists")
  (check-true (string-contains? b "unconfigured") "no embedder hides it")
  (check-true (string-contains? b "'empty'") "an empty corpus hides it")
  (check-false (string-contains? b "locale-empty")
               "…and a corpus in another language does NOT, because it can still answer")
  (define shell (file->string (build-path console-dir "02-auth.js")))
  (check-true (string-contains? shell "helpBlocked()")
              "the header button is behind it")
  ;; the overlay lives in the static shell, like the palette's two
  (check-true (string-contains? html "id=\"helpbox\"")
              "the overlay is shell-resident, so a tab re-render cannot take it down mid-answer"))

(test-case "asking is ONE send, with the guard and the pending state as one flag"
  ;; #174's shape, which cost a double-billed model call the first time: the flag
  ;; IS the guard, nothing may await between the check and the set, and the
  ;; `finally` is what stops one network error leaving the button dead.
  (define f (fn-body "doHelpAsk"))
  (check-true (and f #t) "doHelpAsk exists")
  (check-true (string-contains? f "S.help.asking") "it has a flag")
  (define chk (let ([m (regexp-match-positions #px"S\\.help\\.asking\\) return" f)]) (and m (caar m))))
  (define set (let ([m (regexp-match-positions #px"S\\.help\\.asking = true" f)]) (and m (caar m))))
  (define aw  (let ([m (regexp-match-positions #px"await" f)]) (and m (caar m))))
  (check-true (and chk set (< chk set)) "the check precedes the set")
  (check-true (and set aw (< set aw))
              "and nothing awaits in between — two activations in one tick would both pass a guard that yields")
  (check-true (string-contains? f "finally") "the flag is cleared in a finally")
  ;; every label is a catalog key, which `doSearch` shipped English literals for
  ;; a year without (#178)
  (define body (file->string (build-path console-dir "17-help.js")))
  (check-false (regexp-match? #px"toast\\('[A-Za-z]" body)
               "no English literal in a user-facing string"))

;; ---- QVIZ: the queue's pictures (issue #184) ---------------------------------

(define qviz (file->string (build-path console-dir "18-queueviz.js")))
(define health (file->string (build-path console-dir "14-health.js")))

(test-case "the pictures are hand-drawn SVG, not a chart library"
  ;; QVIZ-2. `script-src 'self'` with no `'unsafe-inline'` since #110 r6 blocks a
  ;; CDN, and a vendored library is a third-party dependency for four shapes each
  ;; of which is a `<rect>`. The point of pinning it here is that the FAILURE
  ;; MODE of reaching for one is invisible in review and silent in CI: the
  ;; console-tests' own `src` assertion covers files, not a `<script>` the shell
  ;; might gain, and this says the drawing is ours.
  (check-true (and (regexp-match? #rx"<svg" qviz) #t) "the bar and the sparklines are SVG")
  (for ([lib (in-list '("chart.js" "Chart(" "d3." "plotly" "echarts" "import("))])
    (check-false (and (regexp-match? (regexp (regexp-quote lib)) qviz) #t)
                 (format "no ~a — the policy blocks it and the theme tokens make it unnecessary" lib)))
  ;; and the colours come from the theme rather than a second palette, so a
  ;; customer's branding reaches the picture for free (the integrator's rule)
  (check-true (and (regexp-match? #rx"var\\(--" qviz) #t) "it paints with the theme tokens"))

(test-case "nothing polls unless an operator asks, and the default is off"
  ;; QVIZ-6, and it is a security answer rather than a preference: the idle clock
  ;; counts from the last REQUEST (#38), so a screen that refreshed itself would
  ;; hold a session open for as long as the tab was left up — an idle timeout
  ;; disabled by something that looks like polish.
  (check-true (and (regexp-match? #rx"S\\.qvEvery\\|\\|0" qviz) #t)
              "the stored interval defaults to 0, which is off")
  (check-true (and (regexp-match? #rx"setInterval" qviz) #t) "the opt-in exists")
  ;; …and it stops itself when the operator leaves the tab, rather than leaving a
  ;; request loop running behind another screen
  (check-true (and (regexp-match? #rx"S\\.tab==='health'" qviz) #t))
  (check-true (and (regexp-match? #rx"clearInterval" qviz) #t))
  ;; the OTHER console modules still poll nothing but a live run
  (check-false (and (regexp-match? #rx"setInterval" health) #t)
               "the health screen itself must not acquire a timer of its own"))

(test-case "the Health screen composes, and the pictures join its ONE round"
  ;; The card is drawn ABOVE the two whose numbers it is summarising, and from
  ;; the SAME responses — two renderings of one set of figures is LIVE-IN's shape
  ;; and is what #179 was careful about in the first place.
  (check-true (and (regexp-match? #rx"queueVizCard\\(vr, fr\\)" health) #t))
  (check-true (and (regexp-match? #rx"/api/admin/queue/flow'\\+fleetQuery\\(\\)" health) #t)
              "the picture and the figures below it are over the same window")
  ;; a sixth SEQUENTIAL call is what made the Admin tab slow enough to notice
  (check-equal? (length (regexp-match* #rx"await Promise.all" health)) 1)
  (check-false (and (regexp-match? #rx"await api\\('/api/admin/queue/flow" health) #t)
               "it joins the round rather than awaiting on its own")
  ;; and the viz module must not be the file that boots the console (HEALTH-8:
  ;; a top-level render() in a file that sorts late is a ReferenceError only a
  ;; browser sees)
  (check-false (and (regexp-match? #px"(?m:^render\\(\\))" qviz) #t)))

(test-case "the trail opens in place, so it works on both screens that list jobs"
  ;; `queueCard` is rendered on Admin as well as on Health, so a trail that
  ;; rendered into a region only the Health screen has would be a button that
  ;; does nothing on the other tab — and nothing would fail.
  (define fleet (file->string (build-path console-dir "05-fleet.js")))
  (check-true (and (regexp-match? #rx"jobTrail\\(j\\.id, el\\)" fleet) #t) "the affordance is on the row")
  (check-true (and (regexp-match? #rx"insertBefore" qviz) #t) "and it opens under that row")
  (check-false (and (regexp-match? #rx"getElementById\\('qvtrail" qviz) #t)
               "not into a region one of the two screens lacks")
  ;; a second click closes it rather than stacking a second copy
  (check-true (and (regexp-match? #rx"qvtrailrow" qviz) #t))
  (check-true (and (regexp-match? #rx"\\.remove\\(\\)" qviz) #t)))

(test-case "every string the pictures show is in the catalogs"
  ;; `doSearch` shipped two English literals for a year in a console that is
  ;; otherwise entirely in the catalogs, so a Japanese operator was told "no
  ;; results" in English. This file is new, and the labels on a chart are exactly
  ;; the kind of text that gets typed in place.
  ;; `qvpath` lives on the queue ROW, which `05-fleet.js` draws — the affordance
  ;; has to be where the jobs are listed, on both screens that list them.
  (define qsrc (string-append qviz "\n" (file->string (build-path console-dir "05-fleet.js"))))
  (define keys (remove-duplicates (map cadr (regexp-match* #px"\\bt\\('(qv[a-z0-9_]+)'\\)" qsrc #:match-select values))))
  (check-true (> (length keys) 20) "it really is reading its labels from the catalog")
  (define en (file->string (build-path console-dir "../ui-strings.json")))
  (for ([k (in-list keys)])
    (check-true (and (regexp-match? (regexp (string-append "\"ui\\." (regexp-quote k) "\"")) en) #t)
                (format "ui.~a is missing from static/ui-strings.json" k)))
  ;; BOTH DIRECTIONS, which is what makes this catch a literal typed in place.
  ;; One direction cannot: replacing `t('qvflow')` with `'Flow'` simply removes
  ;; the key from the scan, and the case passes — the #110 r6 `src`-tags lesson,
  ;; where a file added but never loaded and a tag naming a missing file both
  ;; had to fail. So every `ui.qv*` the catalog ships must be USED here, and an
  ;; orphan says somebody hard-coded the string it was for.
  (define shipped
    (map cadr (regexp-match* #px"\"ui[.](qv[a-z0-9_]+)\"" en #:match-select values)))
  (check-equal? (remove* keys shipped) '()
                "a ui.qv* string nothing asks for means a label was typed in place"))

;; ---- the delegated-handler table is bounded (#185) --------------------------

(define base (file->string (build-path console-dir "01-base.js")))

(test-case "the handler table is SWEPT, in brackets that always close"
  ;; #185 measured what the old comment estimated: 120 render passes of the Admin
  ;; tab retained 14,963 closures, each closing over its row. Bounded, the same
  ;; 120 passes retain 128.
  (check-true (and (regexp-match? #rx"function hPassStart" base) #t))
  (check-true (and (regexp-match? #rx"function hPassEnd" base) #t))
  ;; THE BRACKET MUST CLOSE IN A `finally`, and this is the case that pins the
  ;; defect the first version shipped: both render functions return early —
  ;; superseded mid-flight, or on the sign-in screen — and a range left open
  ;; swallows every registration made after the pass, which swept the command
  ;; palette's own input two passes after it opened.
  (for ([f (in-list '("07-render.js" "13-kg.js"))])
    (define src (file->string (build-path console-dir f)))
    (check-true (and (regexp-match? #rx"hPassStart\\(\\)" src) #t) (format "~a opens a bracket" f))
    (check-true (and (regexp-match? #px"finally\\s*\\{\\s*hPassEnd\\(\\)" src) #t)
                (format "~a closes it in a finally" f))))

(test-case "a swept entry is a HOLE, never a splice"
  ;; The index IS an element's identity — it is sitting in a `data-h-click`
  ;; attribute in the DOM — so compacting the array would re-point every
  ;; attribute on screen at somebody else's closure. A hole reaches the
  ;; dispatcher's existing `typeof fn !== 'function'` guard and does nothing,
  ;; which is what a bad index has always done.
  (check-true (and (regexp-match? #rx"HANDLERS\\[i\\] = undefined" base) #t))
  (check-false (and (regexp-match? #px"HANDLERS[.]splice|HANDLERS[.]length *=" base) #t)
               "compacting or truncating would re-point every data-h-* attribute on screen")
  (check-true (and (regexp-match? #rx"typeof fn !== 'function'" base) #t)
              "and the guard that makes a hole harmless is still there"))

(test-case "the overlays register OUTSIDE the sweep, by name and not by timing"
  ;; The one risk the sweep takes on: `H()` is also called between passes. The
  ;; palette and the help overlay write their markup when they OPEN and stay on
  ;; screen while passes run behind them — which is exactly what #184's
  ;; auto-refresh does on a timer. `Hk()` says so at the call site, so an
  ;; overlay opened while a pass is awaiting its fetches is not caught by the
  ;; bracket either.
  (check-true (and (regexp-match? #rx"function Hk\\(fn\\)" base) #t))
  (check-true (and (regexp-match? #rx"H_KEPT" base) #t))
  (for ([f (in-list '("16-palette.js" "17-help.js"))])
    (define src (file->string (build-path console-dir f)))
    (check-true (> (length (regexp-match* #rx"\\$\\{Hk\\(" src)) 0)
                (format "~a registers with Hk" f))
    (check-equal? (length (regexp-match* #px"\\$\\{H\\(" src)) 0
                  (format "~a has no sweepable registration left" f)))
  ;; …and nothing ELSE uses Hk, or the bound it buys would drain away one
  ;; convenient exception at a time. A view that wants its handler kept is a
  ;; view that should not be re-rendering.
  (define others
    (for/list ([p (in-list script-files)]
               #:unless (member p '("01-base.js" "16-palette.js" "17-help.js"))
               #:when (regexp-match? #rx"Hk\\(" (console-code p)))
      p))
  (check-equal? others '() "Hk is for the shell-resident overlays only"))

(test-case "the SHELL is kept across passes, and freed when it is replaced"
  ;; THE BUG THIS PINS KILLED THE TAB BAR AFTER TWO CLICKS, and was reported
  ;; from outside: "once I click on a few of the tabs, none of the tabs stay
  ;; responsive". The sweep's premise is that the DOM on screen and the two
  ;; passes behind it are always live — true of a tab's markup, which
  ;; `renderTab()` replaces wholesale every pass, and FALSE of the shell, because
  ;; `go()` calls only `renderTab()` and one `appShell()` paint therefore stays
  ;; on screen across every later tab change. Its handlers sat inside
  ;; `render()`'s bracket, so after H_KEEP further passes the range was swept and
  ;; every tab button, logout, ⌘K and Ask went dead — silently, because a hole
  ;; reaches the dispatcher's `typeof fn !== 'function'` guard and returns.
  (check-true (and (regexp-match? #rx"function hShell" base) #t))
  ;; the shell paint goes THROUGH it — this is the call site that was the bug
  (define kg (file->string (build-path console-dir "13-kg.js")))
  (check-true (and (regexp-match? #px"innerHTML\\s*=\\s*hShell[(]appShell[)]" kg) #t)
              "render() must paint the shell through hShell, not call appShell() bare")
  (check-false (and (regexp-match? #px"innerHTML\\s*=\\s*appShell[(][)]" kg) #t)
               "a bare appShell() paint is the defect")
  ;; …and it is a SLOT, not a second Hk: the shell is repainted on every
  ;; `render()` (a language switch, a brand apply, a sign-in), so keeping each
  ;; paint for ever would leak a set per render with nothing freeing the shell it
  ;; replaced. The previous range is freed from H_KEPT in the same breath.
  (check-true (and (regexp-match? #rx"H_KEPT.delete" base) #t)
              "the shell it replaces must leave H_KEPT, or the bound drains away")
  ;; the shell is now the FIRST instance of a general mechanism: `cardSwap`
  ;; needed the same thing, because the un-swapped siblings of a partial update
  ;; outlive the pass that painted them exactly as the shell does. One slot per
  ;; key, holding at most one generation.
  (check-true (and (regexp-match? #rx"const H_SLOTS" base) #t))
  (check-true (and (regexp-match? #px"function hShell[^\n]*hKeepSlot[(]'shell'" base) #t)
              "hShell delegates to the slot rather than keeping its own range"))

(test-case "the Workers card reads the OBSERVED models, not the typed-in column"
  ;; Reported from outside: "why does only one model show up in the workers page,
  ;; and not for all workers, only for red5buntu?" Because there are TWO records
  ;; and the card read the wrong one. `executors.model` is set ONCE at create
  ;; from a value an operator typed and governs no matching;
  ;; `capabilities.models` is what the worker DECLARES on every claim, recorded
  ;; by `observe-capabilities!`, and is what `executor-can-run?` matches a job's
  ;; `requirements.model` against.
  ;;
  ;; FLEET-2 added the second for exactly this reason — "an aspirational record
  ;; cannot answer the question" — and this card went on rendering the field it
  ;; replaced, so a four-worker fleet showed one model and three dashes while all
  ;; four were declaring correctly on every poll.
  (define fl (file->string (build-path console-dir "05-fleet.js")))
  (check-true (and (regexp-match? #px"capabilities\\s*&&\\s*e[.]capabilities[.]models" fl) #t)
              "the pull row must read the observed capabilities")
  ;; …and the static column may only be a FALLBACK. A row that renders it
  ;; unconditionally is the defect, so the cell must go through the helper.
  (check-true (and (regexp-match? #px"<td>\\$\\{wkModels\\(e\\)\\}</td>" fl) #t)
              "the pull/push row renders the helper, not e.model directly")
  ;; the fallback is MARKED, because a value nobody has confirmed and one observed
  ;; on the last claim are different claims about the world (PULL-11e's rule)
  (check-true (and (regexp-match? #rx"wkmodelunconfirmed" fl) #t))
  ;; a PUSH backend is called by us, never claims, and has nothing to declare —
  ;; its own column IS the answer, so the helper must branch on the mode
  (check-true (and (regexp-match? #px"e[.]mode\\s*!==\\s*.pull." fl) #t)
              "a push backend keeps its configured model")
  ;; the declared list is joined AS DECLARED and never sorted: the first entry is
  ;; what the worker answers with when a job names no model
  (check-true (and (regexp-match? #px"models\\)[.]join|obs[.]join" fl) #t)))

(test-case "a refresh swaps ONE card and never re-renders the tab"
  ;; Reported from outside: "the queue on the admin page should stream in
  ;; updates, not full page refresh ... shouldn't reload the entire page."
  ;;
  ;; `renderTab()` paints a `…` placeholder BEFORE it awaits its view, so using
  ;; it as a refresh blanks and repaints the whole tab — and on Admin it also
  ;; re-fires the eight requests that tab opens with, to show twenty-five
  ;; different rows of one table. The jobs poll added one slice earlier had the
  ;; same defect: a 2s tick that flashed the entire screen.
  (define fl (file->string (build-path console-dir "05-fleet.js")))
  (define rv (file->string (build-path console-dir "08-reviews.js")))
  (check-true (and (regexp-match? #rx"async function cardSwap" base) #t))
  ;; A PARTIAL UPDATE MUST NOT BE A RENDER PASS, and the first version was one.
  ;; `cardSwap` opened a bracket, so every refresh counted as a pass — and the
  ;; UN-SWAPPED parts of the tab, painted by the tab render and left alone, were
  ;; swept two refreshes later. Reported from outside: "if I click on refresh, I
  ;; can no longer submit a chat from the jobs page". A live poll makes ONE click
  ;; enough, because the tick is the second pass. Reproduced in a harness: the
  ;; submit handler dies on refresh #2.
  (let ([body (car (regexp-match #px"async function cardSwap.*?\n[}]" base))])
    (check-false (and (regexp-match? #rx"hPassStart" body) #t)
                 "a card swap is NOT a render pass — that is the bug")
    (check-true (and (regexp-match? #rx"hKeepSlot" body) #t)
                "it keeps only what its own markup names")
    ;; the element is re-found after the await: the tab may have changed under it
    (check-true (>= (length (regexp-match* #rx"getElementById" body)) 2)))
  ;; the slot reads its indices from the MARKUP, not from a range of the table:
  ;; a render completing while a swap awaits its fetch would otherwise be caught
  ;; up in the range and wrongly kept — or freed on the next swap
  (check-true (and (regexp-match? #rx"function hIndicesIn" base) #t))
  (check-true (and (regexp-match? #rx"data-h-" base) #t))
  ;; ONE home for the delegated event list: the listener loop and the markup
  ;; scan must not drift, or a region's handlers are silently not kept
  (check-true (and (regexp-match? #rx"const H_EVENTS" base) #t))
  (check-true (and (regexp-match? #px"for [(]const evname of H_EVENTS[)]" base) #t)
              "the dispatcher installs from the same list the scan reads")
  ;; neither poller nor any pager control may reach for a tab render
  (for ([nm (in-list '("qRefresh" "jobsRefresh"))]
        [src (in-list (list fl rv))])
    (define body (car (regexp-match (pregexp (string-append "function " nm "\\(\\)\\s*\\{.*?\n\\}")) src)))
    (check-true (and (regexp-match? #rx"cardSwap" body) #t)
                (format "~a goes through cardSwap" nm))
    (check-false (and (regexp-match? #rx"renderTab" body) #t)
                 (format "~a must not re-render the tab" nm)))
  (check-false (and (regexp-match? #px"S\\.jobPoll===gen\\) renderTab" rv) #t)
               "the jobs poll must not re-render the tab")
  (check-false (and (regexp-match? #px"S\\.qPoll===gen[^;]*renderTab" fl) #t)
               "nor the queue tick")
  ;; a filter or a page change is the same rule
  (check-true (and (regexp-match? #px"function qSet[^\n]*qRefresh\\(\\)" fl) #t)
              "changing a filter swaps the card")
  (check-false (and (regexp-match? #px"function qSet[^\n]*renderTab" fl) #t)
               "…and does not re-render the tab")
  (check-true (and (regexp-match? #px"function qGo[^}]*qRefresh\\(\\)" fl) #t)
              "so does changing page"))

(test-case "linkable URLs: one seam writes the hash, and no credential is in it"
  ;; #230. Nothing in the console was linkable: no URL for a job, a run, a
  ;; document or a filtered queue page, a reload always landed on Chat, and Back
  ;; did nothing. HASH and not paths, because `server/routes.rkt` has four HTML
  ;; entry points and NO catch-all — `/jobs` would 404 rather than serve the
  ;; console, and adding a catch-all turns every typo into the console and has to
  ;; be reconciled with three `*path` bundle routes.
  (define rt (file->string (build-path console-dir "19-route.js")))
  (define rend (file->string (build-path console-dir "07-render.js")))
  (check-true (and (regexp-match? #rx"function routeFromState" rt) #t))
  (check-true (and (regexp-match? #rx"function applyRoute" rt) #t))
  ;; ONE SEAM. `renderTab()` is what every view change passes through — `go()`,
  ;; `wfOpen`, `repoOpenDetail`, `qSet`, `qGo` and the palette all end there — so
  ;; the URL is written in exactly one place and no call site had to learn about
  ;; the address bar. A second writer is how a view and its URL start disagreeing.
  (check-true (and (regexp-match? #rx"navigate[(][)];" rend) #t)
              "renderTab mirrors the URL")
  ;; …and the count is of CODE, not of prose: this file's own header says
  ;; `navigate()` three times, and an assertion that greps a literal must not run
  ;; against a comment mentioning it — the trap CLAUDE.md records twice already.
  (define callers
    (for/list ([f (in-list script-files)]
               #:unless (member f '("19-route.js"))
               #:when (regexp-match? #px"(?<![A-Za-z_.])navigate[(][)]" (console-code f)))
      f))
  (check-equal? callers '("07-render.js")
                "renderTab is the ONLY place outside the router that writes the URL")
  ;; a re-render with unchanged state must write nothing, or a live run's 1.5s
  ;; poll leaves a history entry per tick and Back needs a hundred presses
  (check-true (and (regexp-match? #px"location[.]hash === want[)] return" rt) #t)
              "an unchanged route writes nothing")
  ;; the first write REPLACES: booting must not leave an entry you press Back
  ;; through to leave the page
  (check-true (and (regexp-match? #rx"replaceState" rt) #t))
  (check-true (and (regexp-match? #rx"pushState" rt) #t))
  ;; an unreachable hash falls back rather than painting a tab that is not in the
  ;; bar — `visibleTabs()` is decided by permissions AND feature switches, and a
  ;; link may come from somebody who holds more than the reader does
  (check-true (and (regexp-match? #rx"visibleTabs[(][)][.]indexOf" rt) #t))
  ;; BOTH events: Back and Forward fire popstate, a typed hash fires hashchange
  (check-true (and (regexp-match? #rx"'popstate'" rt) #t))
  (check-true (and (regexp-match? #rx"'hashchange'" rt) #t))
  ;; NO CREDENTIAL AND NO UNSAVED TEXT, by construction rather than by review:
  ;; `S.newToken`/`S.wkToken` hold a token shown once, and a URL is pasted into
  ;; chat, logged by proxies and kept in history — which is why /activate already
  ;; strips its own. Unsaved editor text is out because a link promising content
  ;; that was never saved is a link that lies.
  (define state-reader
    (car (regexp-match #px"function routeFromState[(][)][{].*?\n[}]" rt)))
  (for ([forbidden (in-list '("newToken" "wkToken" "noteEdit" "docEdit" "token"))])
    (check-false (and (regexp-match? (regexp forbidden) state-reader) #t)
                 (format "routeFromState must not read S.~a" forbidden))))

(test-case "a button shares the form controls' box"
  ;; "On every page, there are some issues with buttons alignment with the
  ;; content. Buttons are staggered oddly." Measured across the console: 12 of 22
  ;; control rows were misaligned, the worst by 23px. `input,textarea,select`
  ;; carry `margin:4px 0 10px` and a 1px border; `.btn` had NEITHER, so a button
  ;; sat 10px below the field beside it and was 2px shorter. The transparent
  ;; border is what makes the heights match.
  (define css (file->string console-html))
  (check-true (and (regexp-match? #px"[.]btn[{][^}]*margin:4px 0 10px" css) #t)
              "a button carries the controls' vertical margin")
  (check-true (and (regexp-match? #px"[.]btn[{][^}]*border:1px solid transparent" css) #t)
              "…and a transparent border, or it is 2px short of an input")
  ;; a small button lives in a table cell or a pager, which set their own
  ;; spacing — and gains the control margin when it is really in a form row
  (check-true (and (regexp-match? #px"[.]row > [*] > [.]btn[.]sm" css) #t))
  (check-true (and (regexp-match? #rx"qpager" css) #t)
              "the pager opts out, or its own gap is doubled"))

(test-case "the queue pager is numbered, bounded and jumpable"
  (define fl (file->string (build-path console-dir "05-fleet.js")))
  (check-true (and (regexp-match? #rx"function qPager" fl) #t))
  ;; ONE home for the page size: `queueQuery` asks the server for it and the
  ;; pager computes the page count from it. Two literals would disagree the day
  ;; one changed, and the symptom is a pager offering a page the listing never
  ;; fills — LIVE-IN's shape.
  (check-true (and (regexp-match? #rx"const QPAGE" fl) #t))
  (check-true (and (regexp-match? #px"limit='\\+QPAGE" fl) #t)
              "the request uses the constant, not a second literal")
  (check-false (and (regexp-match? #px"limit=25" fl) #t) "…and no literal 25 is left in the query")
  ;; first and last are always reachable, and there is a jump box
  (check-true (and (regexp-match? #rx"qJump" fl) #t))
  (check-true (and (regexp-match? #rx"function qPages" fl) #t))
  ;; the ellipsis is NOT a control: a button whose destination a reader cannot
  ;; predict is worse than none
  (check-false (and (regexp-match? #px"data-h-click=\"[$][{]H[(][^\"]*…" fl) #t)
               "the ellipsis must not be clickable"))

(test-case "the jobs timestamp comes from the EPOCH, never from the text column"
  ;; `created_at` is TEXT `CURRENT_TIMESTAMP` and its format differs by dialect;
  ;; worse, `new Date("2026-11-01 05:15:17")` is read as LOCAL time by most
  ;; engines while the value is UTC, so a parsed timestamp is silently out by the
  ;; viewer's own offset with nothing to catch it. The epoch columns exist for
  ;; exactly this (0038/0041/0066, each of which records the trap).
  (define rv (file->string (build-path console-dir "08-reviews.js")))
  (check-true (and (regexp-match? #rx"created_epoch" rv) #t))
  (check-false (and (regexp-match? #px"new Date\\([^)]*created_at" rv) #t)
               "parsing the dialect-dependent text column is the defect")
  ;; …and the server must actually send it, or the column renders a dash forever
  (define sch (file->string scheduler-rkt))
  (check-true (and (regexp-match? #rx"'created_epoch" sch) #t)
              "JSELECT/row->job must project the epoch")
  ;; an in-process job says so IN WORDS. A bare dash with the explanation in a
  ;; `title` was the first version and was reported as the column not working:
  ;; a tooltip is invisible, and "–" under `worker` reads as missing data.
  (check-true (and (regexp-match? #rx"jobinprocshort" rv) #t))
  (check-true (and (regexp-match? #rx"jobunclaimedshort" rv) #t)))

(test-case "the pass brackets NEST, so an inner close is not the pass"
  ;; `render()` opens a bracket and then awaits `renderTab()`, which opens its
  ;; own. Undepth-counted, the inner `hPassEnd()` closed the OUTER range and the
  ;; outer `finally` became a no-op — so any registration made after
  ;; `await renderTab()` fell outside every bracket. Nothing is registered there
  ;; today; the counter is what stops that from being load-bearing.
  (check-true (and (regexp-match? #rx"H_DEPTH" base) #t))
  (check-true (and (regexp-match? #px"H_DEPTH\\s*>\\s*0[)]\\s*return" base) #t)
              "an inner bracket closing must return before the sweep runs"))

(test-case "api() answers a WRAPPER, and a reply has to be unwrapped before it is read"
  ;; `doHelpAsk` assigned the wrapper — {ok, status, json} — where the BODY
  ;; belongs, so `helpBody` read `reason`, `answer` and `citations` off an object
  ;; with none of them and the panel rendered the empty string for every
  ;; question ever asked. Reported from outside as "Help is broken, doesn't
  ;; respond to chat", with the server answering correctly throughout: probed in
  ;; process against the live corpus, "why do my jobs stay queued" came back
  ;; "your team has exceeded its AI budget" in 0.9 s.
  ;;
  ;; THE E2E GATE COULD NOT HAVE SEEN IT, which is the lesson rather than the
  ;; bug: §3e asserts the HIDDEN half, because a fresh install has no embedder
  ;; and no corpus, so the branch CI can reach was covered and the branch a
  ;; person meets was not. §3e2 now stubs `api` and drives the real `doHelpAsk`.
  ;; This case is the cheap guard beside it.
  (define help (console-code "17-help.js"))
  (check-true (and (regexp-match? #px"S\\.help\\.rep\\s*=\\s*r\\.json" help) #t)
              "the BODY is what gets stored, never the wrapper")
  (check-false (regexp-match? #px"S\\.help\\.rep\\s*=\\s*r\\s*;" help)
               "assigning the wrapper is the defect")
  ;; A REFUSAL HAS TO LAND SOMEWHERE TOO. The old code could not tell a 403 from
  ;; an answer — both became a wrapper with no `answer` — so a quota refusal was
  ;; silence as well.
  (check-true (and (regexp-match? #px"r\\.ok" help) #t) "the status has to be read")
  (check-true (and (regexp-match? #rx"toast" help) #t) "…and a failure says so"))

(test-case "#231: the Translate field grows, counts, and shows its clock"
  (define rv (console-code "07-render.js"))
  ;; the field was `rows="4"` and fixed, in the one place in this console where
  ;; people paste a document
  (check-true (and (regexp-match? #px"id=\"trsrc\"[^>]*class=\"grow\"" rv) #t)
              "the source field must grow")
  (check-true (and (regexp-match? #rx"growTA" rv) #t))
  ;; ONE home for the limit — the server's, reported on the read the tab already
  ;; makes — so the count in the browser cannot disagree with the rule that
  ;; refuses. A literal here would be LIVE-IN's shape.
  (check-true (and (regexp-match? #rx"max_chars" rv) #t))
  (check-false (regexp-match? #rx"7680" rv) "the limit must not be spelled in the console")
  ;; #174's shape, which this call never had: one send, the flag IS the guard
  ;; and the pending state, and a `finally` so one network error cannot leave it
  ;; dead.
  (check-true (and (regexp-match? #px"if\\s*\\(S\\.trBusy\\)\\s*return" rv) #t))
  (check-true (and (regexp-match? #rx"finally" rv) #t))
  ;; a refusal goes in the OUTPUT pane, not a toast that scrolls away in 2.6s —
  ;; #231's message is the several sentences the person needs to read
  (check-true (and (regexp-match? #px"out\\.textContent\\s*=\\s*\\(r\\.json" rv) #t)
              "the refusal has to be readable")
  ;; and the English literals the old version toasted are gone (doSearch's defect)
  (check-false (regexp-match? #px"toast\\('empty'\\)" rv)))

(test-case "the outcome figures are explained in the column HEADER"
  ;; Reported from outside: "what is the meaning of the numbers 73 ✓ 0 ✗ 0 ⧖ —
  ;; this needs a table header or something." #178 had given each figure its own
  ;; tooltip and put a legend under the window selector, and that was not
  ;; enough for the plain reason that it was in the wrong PLACE: a tooltip is
  ;; invisible until you suspect there is something to hover, and a muted line
  ;; above a table is not what somebody reading a cell looks at.
  (define fleet (console-code "05-fleet.js"))
  ;; the legend is in the `<th>` with the window, and the figures are the cell
  ;; below it
  (check-true (and (regexp-match? #px"<th[^>]*>[^<]*wkwindow[\\s\\S]{0,200}wklegend" fleet) #t)
              "the legend belongs in the header of the column it describes")
  ;; …and is NOT also printed above the table. The search card's lesson, where
  ;; the heading said "Search" three times on one screen.
  (check-equal? (length (regexp-match* #rx"wklegend" fleet)) 1
                "said once, in the header"))

(test-case "the chat and agent prompts count characters against the SERVER's limit"
  ;; Reported from outside: "on the translate screen and the chat screen, add a
  ;; character count to the chat window." #231 built it for Translate, where
  ;; past the limit the answer comes back WRONG rather than failing; a chat
  ;; prompt over the window is truncated oldest-first by the model server, which
  ;; drops the instruction and answers about what is left — the same failure,
  ;; so the same warning belongs beside the same kind of field.
  (define base (console-code "01-base.js"))
  (define tabs (console-code "03-tabs.js"))
  (define rv (console-code "07-render.js"))
  ;; ONE implementation, three fields. Two copies of the arithmetic is the drift
  ;; this console has paid for before (LIVE-IN's shape).
  (check-true (and (regexp-match? #px"function charCount\\(" base) #t)
              "the counter lives once, beside growTA")
  (check-equal? (length (regexp-match* #px"function charCountText\\(" (string-append base tabs rv))) 1
                "…and is spelled once in the whole console")
  (check-true (and (regexp-match? #rx"cpcount" tabs) #t) "the chat prompt has a count")
  (check-true (and (regexp-match? #rx"apcount" tabs) #t) "…and so does the agent prompt")
  ;; THE LIMIT IS THE SERVER'S, reported on the read each tab already makes, so
  ;; the number in the browser cannot disagree with the rule that refuses.
  (check-true (and (regexp-match? #rx"max_chars" tabs) #t))
  (check-false (regexp-match? #rx"7680" tabs) "the limit must not be spelled in the console")
  ;; a prefilled prompt is counted on arrival — both prompts ship with example
  ;; text, which a count-on-input handler never sees (growAll's own reason)
  (check-true (and (regexp-match? #rx"countAll\\(\\)" rv) #t)
              "counted after a render, as the fields are sized after a render"))

(test-case "a note can be READ, not only edited"
  ;; Reported from outside: "the notes view should have a view button, not just
  ;; edit." The list has rendered each body since #180, so what was missing is a
  ;; place to read ONE note — with the facts about it, and no editor and no
  ;; delete button under the cursor.
  (define tabs (console-code "03-tabs.js"))
  (check-true (and (regexp-match? #px"noteShow\\(" tabs) #t))
  (check-true (and (regexp-match? #px"function noteViewCard\\(" tabs) #t))
  (check-true (and (regexp-match? #px"t\\('view'\\)" tabs) #t) "the button says so in the catalogs")
  ;; VIEWING AND EDITING ARE ONE SLOT: opening either closes the other, or two
  ;; cards claim the top of the tab and a reader has to work out which is live.
  (check-true (and (regexp-match? #px"function noteEdit\\([^)]*\\)\\s*\\{[^}]*S\\.noteShow\\s*=\\s*null" tabs) #t)
              "editing closes the view")
  (check-true (and (regexp-match? #px"function noteShow\\([^)]*\\)\\s*\\{[^}]*S\\.noteEdit\\s*=\\s*null" tabs) #t)
              "…and viewing closes the editor")
  ;; THE TIMESTAMPS ARE NOT PARSED. `notes.created_at` is TEXT
  ;; `CURRENT_TIMESTAMP` and `new Date("2026-11-01 05:15:17")` is read as LOCAL
  ;; time by most engines while the value is UTC — silently out by the viewer's
  ;; own offset, with nothing to catch it (CARD-3's trap). This table has no
  ;; epoch columns, so the string is shown as stored and labelled.
  (check-false (regexp-match? #px"new Date\\(n\\.created_at" tabs)
               "a UTC string must not be parsed as local time")
  (check-true (and (regexp-match? #rx"UTC" tabs) #t) "…so it is labelled instead")
  ;; a tab change drops the view, beside the editor's own reset
  (check-true (and (regexp-match? #rx"S.noteShow=null" (console-code "02-auth.js")) #t)))

(test-case "HELP-23: with no citations to show, the panel shows what the answer was READ FROM"
  ;; Reported from outside as "ask the documentation is still broken". The panel
  ;; and the endpoint were both working: measured over ten real questions
  ;; against the live corpus, FOUR came back flagged while carrying a good
  ;; answer, because on this model `uncited` usually means the model answered
  ;; and did not bracket anything. So the reader met a correct answer under an
  ;; orange warning saying it was a refusal, and nothing under Sources at all.
  (define help (console-code "17-help.js"))
  (check-true (and (regexp-match? #px"rep\\.citations \\|\\| \\[\\]\\)\\.length && \\(rep\\.passages" help) #t)
              "the passages are shown whenever there are no citations, not only for no-model")
  (check-true (and (regexp-match? #px"t\\('helpread'\\)" help) #t)
              "…under a heading that says what they are, rather than claiming they are sources")
  ;; the citation carries its passage NUMBER, so a `[2]` in the prose resolves
  ;; to a line the reader can see
  (check-true (and (regexp-match? #rx"c.index" help) #t)))

(test-case "the reveal is ONE rule with two askers, and the run form is reachable"
  ;; "The workflow UI doesn't seem to populate anything you enter from a document
  ;; in the repository." Reported from outside, and the form was populated every
  ;; time: the e2e gate has asserted `object_id is prefilled` for as long as the
  ;; feature has existed, and it still passes. What was wrong is UX-1 again, in
  ;; the sibling surface — MEASURED at a 900px viewport, `#wfi_0` is painted at
  ;; y=1285 with `scrollY` 0, so the form sat 385px below the fold behind a table
  ;; of thirteen definitions and the click changed nothing anybody could see.
  ;;
  ;; What is pinned here is the ONE-HOME half. The scroll is the easy part; the
  ;; part that is easy to get wrong is WHEN NOT TO move, because both askers are
  ;; re-invoked for reasons that are not a fresh request — `repoOpenDetail` after
  ;; a visibility change, a share and a revoke, `wfSelect` on any re-render — and
  ;; a second copy of that condition is `executor-can-run?`'s drift. Whether it
  ;; actually lands on screen is a question about what the code COMPUTES, so it
  ;; is answered in a browser (demo-validate.mjs, §5) and not by grepping.
  (define base (console-code "01-base.js"))
  (define repo (console-code "09-repo.js"))
  (define flow (console-code "10-flow.js"))
  (check-true (and (regexp-match? #px"function revealEl\\(" base) #t)
              "the rule lives in 01-base.js")
  ;; …and NOWHERE else: one definition, and no second copy of the viewport test
  (check-equal? (length (for/list ([f (in-list script-files)]
                                   #:when (regexp-match? #px"function revealEl\\(" (console-code f)))
                          f))
                1 "revealEl is defined exactly once")
  (check-false (regexp-match? #px"scrollIntoView" repo)
               "repoRevealDetail delegates rather than carrying its own copy")
  (check-false (regexp-match? #px"scrollIntoView" flow)
               "…and so does the run form's")
  (check-true (and (regexp-match? #px"prefers-reduced-motion" base) #t)
              "the point is to arrive, not to glide")
  ;; it must not move a target that is already in view
  (check-true (and (regexp-match? #px"r\\.top >= 0 && r\\.top < \\(window\\.innerHeight" base) #t)
              "already in view means do nothing")
  ;; the form carries an id, or there is nothing to be taken to
  (check-true (and (regexp-match? #px"id=\"wfform\"" flow) #t))
  ;; BOTH askers, and both must AWAIT the render first: `revealEl` MEASURES the
  ;; element, and `renderTab` paints a `…` placeholder before it awaits its view.
  (for ([src (in-list (list repo flow))] [who (in-list '("repoRunWorkflow" "wfSelect"))])
    (check-true (and (regexp-match? #px"await renderTab\\(\\);\\s*revealEl\\('wfform'\\)" src) #t)
                (format "~a awaits the pass, then reveals" who))))

;; ---- a project is a key PREFIX (#239) ---------------------------------------

(test-case "the path navigator is spelled once and both tabs ask it"
  ;; ONE component, two tabs. The Repository files uploads into a path and the
  ;; Documents tab writes chapters into the same one, so a crumb trail drawn twice
  ;; would be two renderings of one answer — `executor-can-run?`'s drift, and
  ;; `visibleTabs()`'s own argument (PAL-5), where the wrong copy is the one
  ;; somebody is looking at.
  (define base* (console-code "01-base.js"))
  (define repo* (console-code "09-repo.js"))
  (define render* (console-code "07-render.js"))
  (check-true (and (regexp-match? #px"function pathNav\\(" base*) #t)
              "the component lives in the file both tabs load before their own")
  ;; it is DEFINED once across the whole console…
  (define defs
    (for*/sum ([f (in-list (sort (map path->string (directory-list console-dir)) string<?))]
               #:when (regexp-match? #px"[.]js$" f))
      (length (regexp-match* #px"function pathNav\\(" (console-code f)))))
  (check-equal? defs 1 "a second definition is how a crumb trail starts to drift")
  ;; …and ASKED by both, each with its own navigator, because each keeps its own
  ;; prefix in `S` and has its own paging to reset
  (check-true (and (regexp-match? #px"pathNav\\(r\\.json\\.folders, prefix, repoGo\\)" repo*) #t))
  (check-true (and (regexp-match? #px"pathNav\\(r\\.json\\.folders, prefix, docGo\\)" render*) #t))
  (check-true (and (regexp-match? #px"function repoGo\\(" repo*) #t))
  (check-true (and (regexp-match? #px"function docGo\\(" render*) #t))
  ;; THE FOLDERS ARE THE SERVER'S ANSWER, never a tree built from the page: a
  ;; listing is bounded and `can?`-filtered per row, so folders derived from the
  ;; keys on screen would show only what this page happened to reach — and could
  ;; offer one the caller may read nothing in.
  (check-false (and (regexp-match? #px"(repoKeys|objs)[^\n]*split\\('/'\\)" repo*) #t)
               "the folder strip is not derived from the keys on this page")
  ;; navigating RESETS the page: an offset is a position in the old window, so
  ;; carrying it over lands somebody in the middle of a folder they just opened
  (check-true (and (regexp-match? #px"function docGo\\(prefix\\)\\{[^}]*docOffset=0" render*) #t)
              "docGo clears the offset"))

(test-case "the two tabs file into the folder being viewed"
  (define repo* (console-code "09-repo.js"))
  (define render* (console-code "07-render.js"))
  ;; the upload key field and the document path field are both PREFILLED, or the
  ;; forms are the one place in the tab that ignores where you are standing
  (check-true (and (regexp-match? #px"id=\"rkey\"[^\n]*value=\"\\$\\{esc\\(prefix\\)\\}\"" repo*) #t))
  (check-true (and (regexp-match? #px"id=\"dk\"[^\n]*value=\"\\$\\{esc\\(prefix\\)\\}\"" render*) #t))
  ;; …and choosing a file APPENDS to that path rather than replacing it
  (check-true (and (regexp-match? #px"k\\.value=\\(k\\.value\\|\\|''\\)\\+f\\.name" repo*) #t)
              "the filename appends to the prefilled folder")
  ;; the create call carries it; `key` absent is what composes documents/<slug>
  (check-true (and (regexp-match? #px"key:val\\('dk'\\)" render*) #t))
  ;; `?immediate=1`, or opening a folder shows its whole subtree and looks
  ;; identical to the view above it
  (check-true (and (regexp-match? #px"immediate=1" repo*) #t)))

(test-case "every path string the two tabs show is in the catalogs"
  ;; `doSearch`'s lesson (#178) at a third surface, and these labels are exactly
  ;; the kind that gets typed in place.
  (define src (string-append (console-code "01-base.js") "\n"
                             (console-code "09-repo.js") "\n"
                             (console-code "07-render.js")))
  (define en (file->string (build-path console-dir "../ui-strings.json")))
  (for ([k (in-list '("allpaths" "foldercut" "nohereobjects" "dockeyhint" "docmovehint"))])
    (check-true (and (regexp-match? (regexp (string-append "t\\('" k "'\\)")) src) #t)
                (format "t('~a') is asked for" k))
    (check-true (and (regexp-match? (regexp (string-append "\"ui\\." k "\"")) en) #t)
                (format "ui.~a is in static/ui-strings.json" k))))
