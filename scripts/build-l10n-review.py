#!/usr/bin/env python3
"""Build the Japanese localization review sheet.

Reads the two places Telemachus keeps user-facing Japanese —

    refimpl/racketmaximus/static/index.html    the console dictionary (const L)
    refimpl/racketmaximus/locales/{en,ja}.json  the server message catalogue
    refimpl/racketmaximus/domain/beta/beta.rkt  the shipped beta-funnel copy and
                                                its `i18n` overlay (read by
                                                evaluating the module, not by
                                                regex, so it cannot go stale)

— and emits a single self-contained HTML review form. It is generated from the
REAL sources on every run, so it cannot drift from what ships: change a string,
re-run this, and the row changes with it.

Reviewer notes live in NOTES below. They are the only hand-written content here;
everything else is read out of the source. A key in NOTES that no longer exists
is an error, not a silent no-op — a renamed string must not quietly lose its note.

    python3 scripts/build-l10n-review.py            # → build/l10n-ja-review.html
    python3 scripts/build-l10n-review.py -o out.html

This is a development tool, not shipped code, and not part of the Racket build.
"""

import argparse, html, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONSOLE = os.path.join(ROOT, "refimpl/racketmaximus/static/index.html")
LOCALES = os.path.join(ROOT, "refimpl/racketmaximus/locales")

# ---------------------------------------------------------------- extraction

def js_dict(blob, tag):
    """Pull one `tag:{...}` object literal out of the console's `const L`."""
    start = blob.index(tag + ":{")
    depth, i = 0, blob.index("{", start)
    for p in range(i, len(blob)):
        if blob[p] == "{":
            depth += 1
        elif blob[p] == "}":
            depth -= 1
            if depth == 0:
                return blob[i + 1:p]
    raise SystemExit(f"unbalanced braces in L.{tag}")


def js_pairs(body):
    """key -> value, plus the keys that were defined more than once."""
    out, order = {}, []
    for m in re.finditer(r"(\w+)\s*:\s*'((?:[^'\\]|\\.)*)'", body):
        k, v = m.group(1), m.group(2)
        # Decode ONLY the \uXXXX escapes. The old `v.encode().decode("unicode_escape")`
        # round-tripped UTF-8 bytes through latin-1, so every Japanese string that
        # also contained a \uXXXX escape (e.g. \u2014) reached the sheet as mojibake
        # -- and a reviewer was asked to approve it.
        v = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), v)
        v = v.replace("\\'", "'")
        out[k] = v
        order.append(k)
    dups = sorted({k for k in order if order.count(k) > 1})
    return out, dups


IMPL = os.path.join(ROOT, "refimpl/racketmaximus")


def beta_provider():
    """The registered onboarding provider, as JSON.

    Evaluated rather than parsed: the funnel copy is Racket data, and a regex over
    it would silently drift the first time someone reformats the literal. Needs
    the Nix dev shell (racket + PLTCOLLECTS); without it the funnel group is
    skipped with a warning rather than the whole sheet failing, because a sheet
    covering two of three sources still beats no sheet.
    """
    mod = os.path.join(IMPL, "domain/beta/beta.rkt").replace("\\", "/")
    expr = ('(require (file "%s") json)'
            '(write-json (hash-remove (active-onboarding) (quote judge-system)))' % mod)
    env = dict(os.environ, PLTCOLLECTS=os.path.join(IMPL, "pkgs") + ":")
    try:
        out = subprocess.run(["racket", "-e", expr], cwd=IMPL, env=env,
                             capture_output=True, timeout=180)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


# (english, japanese, key, note-key) rows for the shipped funnel copy
FUNNEL_SCALARS = ["title", "subtitle", "eyebrow", "cta", "footer"]


def funnel_rows(prov):
    over = (prov.get("i18n") or {}).get("ja") or {}
    rows = []
    for k in FUNNEL_SCALARS:
        if prov.get(k):
            rows.append(("funnel." + k, prov[k], over.get(k, "")))
    for i, d in enumerate(prov.get("details") or []):
        o = (over.get("details") or [])
        od = o[i] if i < len(o) else {}
        for part in ("heading", "body"):
            if d.get(part):
                rows.append(("funnel.details.%d.%s" % (i, part), d[part], od.get(part, "")))
    ofields = over.get("fields") or {}
    for f in prov.get("fields") or []:
        k = f.get("key")
        of = ofields.get(k) or {}
        if f.get("label"):
            rows.append(("funnel.field.%s" % k, f["label"], of.get("label", "")))
        if f.get("options"):
            # Options are localizable but often deliberately are NOT localized
            # (currency bands, numerals). Show them as one row so the reviewer
            # decides once per field rather than per option.
            rows.append(("funnel.field.%s.options" % k,
                         " · ".join(str(o) for o in f["options"]),
                         " · ".join(str(o) for o in (of.get("options") or []))))
    return rows


def read_sources():
    src = open(CONSOLE, encoding="utf-8").read()
    blob = src[src.index("const L = {"):]
    en, dup_en = js_pairs(js_dict(blob, "en"))
    ja, dup_ja = js_pairs(js_dict(blob, "ja"))
    if set(en) != set(ja):
        raise SystemExit(f"console dictionaries disagree: {set(en) ^ set(ja)}")
    men = json.load(open(os.path.join(LOCALES, "en.json"), encoding="utf-8"))["messages"]
    mja = json.load(open(os.path.join(LOCALES, "ja.json"), encoding="utf-8"))["messages"]
    return en, ja, sorted(set(dup_en) | set(dup_ja)), men, mja

# ------------------------------------------------------------------ grouping
# Every console key must land in exactly one group; the build asserts it, so a
# newly added string cannot slip through the review unnoticed.

GROUPS = [
    ("msg", "Server messages", "locales/ja.json",
     "The only strings the API itself returns, localized from <code>Accept-Language</code>. "
     "<b>An empty one is not a blank screen — it silently falls back to English</b>, so these "
     "outrank everything below.", None),

    ("nav", "Navigation &amp; global chrome", "static/index.html",
     "Tabs, section headers and the words that frame every other screen. Wrong register here "
     "is felt on every page.",
     "tagline chat agent notes team usage admin beta repository workflows documents jobs "
     "search features audit testing branding logout operator model"),

    ("act", "Common actions &amp; field labels", "static/index.html",
     "Buttons and column headings, reused across screens. These carry the house convention: "
     "bare nouns on controls, polite ~ました on the toast that follows.",
     "create save saved del deleted cancel close back refresh submit send share shared revoke "
     "revoked enable disable details download upload uploading uploaded copy copied link name "
     "status title body content key size updated source version started input output results "
     "recent file store objects visibility"),

    ("auth", "Sign-in, first run &amp; account", "static/index.html",
     "The first Japanese a new user ever reads, and the only screen an unauthenticated visitor sees.",
     "signin user pass code firstrun createop welcome setpw confirmpw activate chpw curpw newpw "
     "updpw teamsignin requestaccess"),

    ("chat", "Chat, agent &amp; tools", "static/index.html", None,
     "prompt reply tools tool"),

    ("tr", "Translation &amp; glossary", "static/index.html",
     "Worth extra care: a translation feature whose own UI reads awkwardly undercuts itself.",
     "translate sourcetext target translation glossary term addterm useglossary"),

    ("note", "Notes, documents &amp; visibility", "static/index.html",
     "Visibility wording is load-bearing — a reader who misjudges 「限定共有」 shares the wrong thing.",
     "newnote newdoc vis_team vis_private vis_shared visupdated sharewith sharedwith noshares "
     "noothers vishint"),

    ("repo", "Repository, uploads &amp; S3", "static/index.html",
     "The longest strings in the product, and the ones most likely to have drifted from their English.",
     "norepoobjects uploadhint newversion willversion versions s3keys s3created s3hint s3once "
     "s3off linkhint searchph"),

    ("wf", "Workflows, runs &amp; jobs", "static/index.html", None,
     "workflow definitions runwf runs viewrun steps stepsused nodefs noruns submitjob"),

    ("team", "Team, members, quotas &amp; tokens", "static/index.html", None,
     "members addmember role setquota dimension limit nolimit apitokens createtoken seed "
     "qualify reject"),

    ("brand", "Branding", "static/index.html", None,
     "brandinghint brandtitle brandtagline brandlogo brandclearlogo brandreset"),

    ("funnel", "Beta funnel \u2014 shipped copy", "domain/beta/beta.rkt",
     "The public sign-up page, and the only Japanese a prospect ever reads. This is "
     "an <code>i18n</code> overlay on the experience document, not a catalog: a "
     "deployment overrides it wholesale via <code>TELEMACHUS_ONBOARDING_FILE</code>, "
     "so treat these as OUR default copy rather than the last word. Field keys, "
     "types and <code>required</code> are never localized \u2014 only what is read.",
     None),

    ("loc", "Localization settings (Admin)", "static/index.html",
     "New in this sweep, and the only Japanese written after the review started — "
     "so it has had no native pass at all. The instance default and the switch that "
     "turns per-request negotiation off entirely.",
     "localization deflocale loctoggle lochint locoffhint locavail"),

    ("bx", "Beta funnel \u2014 chrome", "static/index.html",
     "Rendered by the console around the operator's copy: what a prospect sees while "
     "submitting, and after. New in this sweep.",
     "bxverifying bxthanks bxtouch bxrestart"),
]

# ------------------------------------------------------------------- notes
# flag: gap | short | term | punct | reg | dup   (None = no pre-flag, still needs a decision)

NOTES = {
 # --- server catalogue: all four blanks filled in this sweep ---------------
 "authz.bootstrap_done": ("fixed",
   "Was empty — first-run bootstrap answered in English whatever the "
   "<code>Accept-Language</code>. Written in this sweep; both placeholders kept."),
 "notes.saved": ("fixed", "Was empty. Written in this sweep."),
 "http.already_initialized": ("fixed",
   "Was empty. Written in this sweep. Seen by anyone who re-POSTs <code>/api/bootstrap</code>."),
 "inbox.summary": ("fixed",
   "Was empty, and the English is an ICU plural. Japanese has no grammatical plural, so this "
   "ships the <code>other</code> arm as a plain interpolation rather than translating the "
   "<code>one</code>/<code>other</code> machinery. Confirm 「件」 is the counter you want."),
 "authz.forbidden": ("fixed",
   "Was 「禁止されています: {perm}」, which reads as a prohibition notice rather than \"you lack "
   "this permission\". Now 「権限がありません：{perm}」, with a fullwidth colon to match the rest of "
   "the surface. <code>test/server-smoke.sh</code> was updated with it."),
 "http.unauthorized": (None,
   "Unchanged. Confirm the register suits a 401 the same user may hit repeatedly."),
 "greeting.hello": (None,
   "Unchanged. Confirm 「さん」 is right for an instance that may address a team, not a person."),

 # --- content restored -----------------------------------------------------
 "norepoobjects": ("fixed",
   "The Japanese had compressed the English format list to 「形式は自由です。」. The list is back — "
   "confirm 「、」 is the separator you want between the extensions."),
 "nodefs": ("fixed",
   "The Japanese stopped one clause early and lost \"otherwise POST a spec to /api/workflows\", "
   "leaving a Japanese operator no way to publish a workflow without a plugin. Restored."),

 # --- terminology ----------------------------------------------------------
 "revoked": ("fixed",
   "Was 「解除しました」 against a 「失効」 button — two verbs for one operation. Now 「失効しました」. "
   "If you would rather the pair be 無効化, both rows move together."),
 "revoke": (None, "Unchanged. Pairs with <code>revoked</code> above."),
 "repository": ("fixed",
   "Was 「ドキュメント保管」, an action where the English is a place. Now 「ドキュメント保管庫」. "
   "Plain 「リポジトリ」 is the other defensible choice — this is a top-level tab, so it sets the "
   "vocabulary for the whole section."),
 "stepsused": ("fixed", "Was 「ステップ使用」 (English word order). Now 「使用ステップ数」."),
 "dimension": ("fixed",
   "Was 「項目」 (\"item\"). Now 「指標」 — the column holds things like <code>ai.tokens.total</code>. "
   "「対象」 if you read it as the subject rather than the metric."),
 "source": (None,
   "Unchanged. Here 「ソース」 means where a workflow definition came from "
   "(<code>plugin:doc-indexer</code>), not source code. 「提供元」 if that reads clearer."),

 # --- register -------------------------------------------------------------
 "linkhint": ("fixed",
   "「あなたの」 → 「ご自身の」. Still worth a look: dropping the possessive entirely "
   "(「S3キーの権限で動作し…」) is the more usual Japanese UI register."),
 "vishint": ("reg",
   "NOT changed — this one is a judgment call. The English is second person (\"You set this "
   "because you uploaded it\"); the Japanese is third (「アップロードした本人が設定します」). Decide "
   "the house voice for hint text and it settles <code>vishint</code>, <code>uploadhint</code>, "
   "<code>linkhint</code> and <code>brandinghint</code> together."),
 "operator": (None,
   "Unchanged. The English is lowercase because it appears mid-sentence — check the Japanese is "
   "not being dropped where 「オペレーター」 needs a particle in front of it."),

 # --- punctuation ----------------------------------------------------------
 "noothers": ("fixed", "Added the sentence-final 。 to match its sibling <code>noshares</code>."),
 "saved": ("punct",
   "NOT changed. Toasts (「保存しました」, 「共有しました」, 「削除しました」) carry no 。 while full "
   "sentences elsewhere do. Defensible — decide it once here and the rest follow."),
 "tagline": ("punct",
   "NOT changed. Em dash (—) between clauses, in six strings (<code>tagline</code>, "
   "<code>firstrun</code>, <code>welcome</code>, <code>vis_team</code>, <code>vis_private</code>, "
   "<code>vis_shared</code>). Japanese UI more often reaches for 「：」 or 、. One decision, six rows."),
 "vis_team": ("punct", "See <code>tagline</code> — the em-dash question."),
 "vis_private": ("punct", "See <code>tagline</code> — the em-dash question."),
 "vis_shared": ("punct",
   "See <code>tagline</code>. Also confirm 「限定共有」 is unambiguous against 「共有」 used as a verb "
   "on the same screen."),

 # --- beta funnel: the server's own refusals -------------------------------
 "beta.not_ready": ("new", "Written in this sweep. Only seen before an instance has an operator."),
 "beta.rate_limited": ("new", "Written in this sweep."),
 "beta.challenge_expired": ("new", "Written in this sweep."),
 "beta.verify_failed": ("new", "Written in this sweep."),
 "beta.email_invalid": ("new",
   "Written in this sweep. Probably the most-read Japanese string in the whole product \u2014 "
   "it is what a mistyped address returns on the public form."),
 "beta.email_disposable": ("new",
   "Written in this sweep. Confirm the tone: this refuses a real person's real address."),
 "beta.field_required": ("new",
   "Written in this sweep. <code>{field}</code> is the field's own LOCALIZED label, so on a "
   "Japanese funnel this reads \u300c\u6cd5\u4eba\u756a\u53f7\u3092\u5165\u529b\u3057\u3066\u304f\u3060\u3055\u3044\u3002\u300d. Check the particle reads correctly "
   "after an arbitrary operator-authored label."),
 "beta.field_digits": ("new",
   "Written in this sweep. \u300c\u534a\u89d2\u6570\u5b57\u300d is explicit about full-width digits, which a "
   "Japanese IME will happily produce \u2014 confirm that is the behaviour you want to name."),
 "beta.field_too_short": ("new", "Written in this sweep. Carries a count, so check the counter word."),
 "beta.field_too_long": ("new", "Written in this sweep. Carries a count, so check the counter word."),
 "beta.duplicate": ("new", "Written in this sweep \u2014 a friendly refusal, not an error."),
 "beta.domain_cap": ("new", "Written in this sweep."),
 "beta.thanks": ("new",
   "Written in this sweep. Also returned to the HONEYPOT, which must be "
   "indistinguishable from a real success \u2014 so this string has to be identical "
   "in both paths, in every language."),

 # --- beta funnel: shipped copy --------------------------------------------
 "funnel.title": ("new", "Written in this sweep. The first line a Japanese prospect reads."),
 "funnel.subtitle": ("new", "Written in this sweep \u2014 the longest funnel string, worth reading aloud."),
 "funnel.eyebrow": ("new", "Written in this sweep."),
 "funnel.cta": ("new", "Written in this sweep. Matches the console's <code>requestaccess</code>."),
 "funnel.footer": ("new", "Written in this sweep."),
 "funnel.field.use_case": ("new",
   "Written in this sweep. The only funnel label that is a question \u2014 confirm the "
   "\u300c\uff1f\u300d and the level of politeness suit a first-contact form."),
 "funnel.field.revenue.options": (None,
   "Deliberately NOT translated: these are USD bands, and converting a currency is a "
   "commercial decision rather than a translation. Approve to confirm that, or supply "
   "\u5186 bands if the Japanese funnel should quote in yen."),
 "funnel.field.team_size.options": (None,
   "Deliberately NOT translated \u2014 numerals read the same. Approve to confirm."),

 # --- new strings, no native pass yet --------------------------------------
 "localization": ("new", "Written in this sweep. 「言語設定」 vs 「ローカライズ」 — your call."),
 "deflocale": ("new", "Written in this sweep."),
 "loctoggle": ("new", "Written in this sweep. A checkbox label, so it reads as a sentence on purpose."),
 "lochint": ("new", "Written in this sweep. The longest new string — worth reading aloud."),
 "locoffhint": ("new", "Written in this sweep."),
 "locavail": ("new", "Written in this sweep."),

 # --- confirmed good, still needs a decision -------------------------------
 "status": (None,
   "Was defined TWICE in both dictionaries (the second silently won). The duplicate is gone; the "
   "value 「状態」 is unchanged."),
 "searchph": (None, "Uses 、 and … correctly — the small things that mark hand-written Japanese."),
 "s3once": (None, "Direct and appropriately urgent."),
 "code": (None, "Fullwidth parens 「（有効な場合）」 — correct."),
 "brandinghint": (None, "「・」 for the list is right."),
 "key": (None, "The English column was renamed Path; 「パス」 matches."),
 "uploadhint": (None, "Complete against the English, and reads naturally."),
 "s3hint": (None, "Complete, and 「チームがバケットです」 lands the metaphor."),
}

FLAG_LABEL = {"gap": "empty", "short": "drops content", "term": "terminology",
              "punct": "punctuation", "reg": "register", "dup": "duplicate key",
              "fixed": "changed in this sweep", "new": "never reviewed"}

HOUSE = [
 ("Latin runs into Japanese with no space",
  "<code>チームAIプラットフォーム</code>, <code>2FAコード</code>, <code>S3アクセスキー</code>, "
  "<code>APIトークン</code> — consistent across all 143 strings. Confirm it as the rule."),
 ("Controls are bare nouns, results are polite",
  "<code>保存</code> / <code>削除</code> / <code>作成</code> on buttons; <code>保存しました</code> / "
  "<code>削除しました</code> in the toast that follows. Held consistently — confirm and keep."),
 ("Punctuation is already fullwidth",
  "No ASCII <code>:</code>, <code>(</code> or <code>,</code> survives anywhere in the console "
  "Japanese. The one ASCII colon left in the product is in <code>authz.forbidden</code>, below."),
 ("Every placeholder survives translation",
  "<code>{name}</code>, <code>{perm}</code>, <code>{m}</code> are all present in both languages. "
  "Nothing to fix — worth keeping true."),
]

# ------------------------------------------------------------------ rendering

def esc(s):
    return html.escape(s, quote=False)


def row(file, key, en, ja, note):
    flag, text = (note or (None, None))
    state = "gap" if (flag == "gap" or not ja.strip()) else "todo"
    pre = ""
    if flag:
        pre = f'<span class="flag f-{flag}">{FLAG_LABEL[flag]}</span>'
    body = f'<p class="note">{pre}{text}</p>' if text else (f'<p class="note">{pre}</p>' if pre else "")
    shown = esc(ja) if ja.strip() else "— empty —"
    empty = " is-empty" if not ja.strip() else ""
    return f"""<article class="row" data-key="{esc(key)}" data-file="{file}" data-state="{state}">
  <div class="stripe" aria-hidden="true"></div>
  <div class="main">
    <div class="src"><span class="en">{esc(en)}</span><code class="key">{esc(key)}</code></div>
    <p class="ja{empty}" lang="ja">{shown}</p>
    <p class="ja edited" lang="ja" hidden></p>
    {body}
    <div class="edit" hidden>
      <label for="t-{esc(key)}">Japanese as it should ship</label>
      <textarea id="t-{esc(key)}" lang="ja" rows="2">{esc(ja)}</textarea>
      <div class="edit-act">
        <button type="button" data-act="save">Save</button>
        <button type="button" data-act="cancel" class="ghost">Cancel</button>
      </div>
    </div>
  </div>
  <div class="act">
    <span class="pill" aria-hidden="true"></span>
    <button type="button" data-act="ok" aria-pressed="false">Approve</button>
    <button type="button" data-act="open" class="ghost">Rewrite</button>
    <button type="button" data-act="reset" class="ghost quiet">Reset</button>
  </div>
</article>"""


def build():
    en, ja, dups, men, mja = read_sources()
    prov = beta_provider()

    assigned, sections, total = set(), [], 0
    for gid, title, file, stand, keys in GROUPS:
        rows = []
        if gid == "msg":
            for k in men:
                rows.append(row("locales/ja.json", k, men[k]["text"],
                                mja.get(k, {}).get("text", ""), NOTES.get(k)))
        elif gid == "funnel":
            if prov is None:
                print("  ! skipping the funnel group: could not evaluate beta.rkt "
                      "(run inside `nix develop`)", file=sys.stderr)
            else:
                for k, en_s, ja_s in funnel_rows(prov):
                    rows.append(row("domain/beta/beta.rkt", k, en_s, ja_s, NOTES.get(k)))
        else:
            for k in keys.split():
                if k not in en:
                    raise SystemExit(f"group {gid}: no such console key {k!r}")
                if k in assigned:
                    raise SystemExit(f"key {k!r} assigned to two groups")
                assigned.add(k)
                rows.append(row("static/index.html", k, en[k], ja[k], NOTES.get(k)))
        total += len(rows)
        sections.append((gid, title, file, stand, rows))

    missed = sorted(set(en) - assigned)
    if missed:
        raise SystemExit("console keys in no group (add them to GROUPS): " + ", ".join(missed))
    # With no racket on PATH the funnel group is skipped (documented behaviour), so
    # its NOTES keys have nothing to match. Excluding them keeps the skip path a
    # skip instead of a hard exit on "keys that no longer exist".
    funnel_keys = ({k for k, _e, _j in funnel_rows(prov)} if prov
                   else {k for k in NOTES if k.startswith("funnel.")})
    stale = sorted(set(NOTES) - set(en) - set(men) - funnel_keys)
    if stale:
        raise SystemExit("NOTES refer to keys that no longer exist: " + ", ".join(stale))

    gaps = sum(1 for _, _, _, _, rs in sections for r in rs if 'data-state="gap"' in r)
    flagged = sum(1 for _, _, _, _, rs in sections for r in rs if 'class="flag' in r)

    jump = "".join(
        f'<a href="#{gid}">{title}<span>{len(rs)}</span></a>'
        for gid, title, _f, _s, rs in sections)

    secs = []
    for gid, title, file, stand, rows in sections:
        standp = f'<p class="stand">{stand}</p>' if stand else ""
        secs.append(f"""<section id="{gid}">
  <div class="shead">
    <h2>{title}</h2>
    <code class="file">{file}</code>
    <span class="count"><b data-done="{gid}">0</b>/{len(rows)}</span>
  </div>
  {standp}
  <div class="rows">{''.join(rows)}</div>
</section>""")

    house = "".join(f"<div><dt>{t}</dt><dd>{d}</dd></div>" for t, d in HOUSE)
    dupnote = (f'<p class="stand"><b>Source bug found while generating this sheet:</b> '
               f'the console dictionaries define <code>{", ".join(dups)}</code> twice. '
               f'See the row in <a href="#act">Common actions</a>.</p>' if dups else "")

    return TEMPLATE.format(total=total, gaps=gaps, flagged=flagged, jump=jump,
                           house=house, dupnote=dupnote, sections="".join(secs))


TEMPLATE = r"""<title>Japanese String Review</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Noto+Sans+JP:wght@400;500;700&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
:root {{
  --paper:#f7f6f3; --card:#fff; --sunk:#eeece7;
  --ink:#1a1a17; --ink-2:#57544d; --ink-3:#8a867d;
  --rule:#dcd8d0; --rule-2:#eae7e0;
  --accent:#7a4f24; --accent-soft:#f0e6da;
  --ok:#2f6b46; --ok-soft:#e3efe7;
  --edit:#3f5688; --edit-soft:#e6eaf3;
  --gap:#9c3a2c; --gap-soft:#f6e4e0;
  --shadow:0 1px 2px rgba(26,26,23,.05), 0 10px 26px -18px rgba(26,26,23,.35);
  --sans:"IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
  --mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
  --jp:"Noto Sans JP","Hiragino Sans","Hiragino Kaku Gothic ProN","Yu Gothic",Meiryo,sans-serif;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --paper:#16150f; --card:#1e1d16; --sunk:#262419;
    --ink:#eceade; --ink-2:#b6b1a1; --ink-3:#847f70;
    --rule:#33301f; --rule-2:#282619;
    --accent:#d09b62; --accent-soft:#2c2415;
    --ok:#79bd94; --ok-soft:#16281d;
    --edit:#93a6d6; --edit-soft:#1a1f2e;
    --gap:#e08b7c; --gap-soft:#2e1a16;
    --shadow:0 1px 2px rgba(0,0,0,.4), 0 10px 26px -18px rgba(0,0,0,.8);
  }}
}}
:root[data-theme="dark"] {{
  --paper:#16150f; --card:#1e1d16; --sunk:#262419;
  --ink:#eceade; --ink-2:#b6b1a1; --ink-3:#847f70;
  --rule:#33301f; --rule-2:#282619;
  --accent:#d09b62; --accent-soft:#2c2415;
  --ok:#79bd94; --ok-soft:#16281d;
  --edit:#93a6d6; --edit-soft:#1a1f2e;
  --gap:#e08b7c; --gap-soft:#2e1a16;
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 10px 26px -18px rgba(0,0,0,.8);
}}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--paper); color:var(--ink); font-family:var(--sans);
  font-size:15.5px; line-height:1.55; -webkit-font-smoothing:antialiased; }}
.wrap {{ max-width:64rem; margin:0 auto; padding:2.75rem 1.25rem 6rem; }}

.mast {{ border-bottom:2px solid var(--ink); padding-bottom:1.15rem; margin-bottom:1.4rem; }}
.eyebrow {{ font-family:var(--mono); font-size:.7rem; letter-spacing:.15em;
  text-transform:uppercase; color:var(--accent); margin-bottom:.55rem; }}
h1 {{ font-family:var(--jp); font-weight:700; font-size:clamp(1.85rem,4.4vw,2.7rem);
  line-height:1.12; letter-spacing:-.02em; text-wrap:balance; margin:0 0 .55rem; }}
.sub {{ color:var(--ink-2); max-width:48rem; margin:0; font-size:1rem; }}

.brief {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(190px,1fr)); gap:1px;
  background:var(--rule); border:1px solid var(--rule); border-radius:9px;
  overflow:hidden; margin:1.4rem 0 1.6rem; }}
.brief > div {{ background:var(--card); padding:.85rem 1rem; }}
.brief dt {{ font-family:var(--mono); font-size:.66rem; letter-spacing:.13em;
  text-transform:uppercase; color:var(--ink-3); margin-bottom:.3rem; }}
.brief dd {{ margin:0; font-size:.9rem; color:var(--ink); }}
.brief dd b {{ font-size:1.5rem; font-weight:600; font-variant-numeric:tabular-nums;
  display:block; line-height:1.1; }}
.brief .n-gap b {{ color:var(--gap); }}
.brief .n-flag b {{ color:var(--accent); }}

.how {{ background:var(--card); border:1px solid var(--rule); border-radius:9px;
  padding:1.05rem 1.2rem; margin-bottom:1.6rem; box-shadow:var(--shadow); }}
.how h3 {{ margin:0 0 .5rem; font-size:.95rem; }}
.how ol {{ margin:0; padding-left:1.15rem; color:var(--ink-2); font-size:.92rem; }}
.how li + li {{ margin-top:.3rem; }}
.how code {{ font-family:var(--mono); font-size:.85em; background:var(--sunk);
  padding:.08em .3em; border-radius:3px; }}

.house {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(250px,1fr)); gap:1px;
  background:var(--rule); border:1px solid var(--rule); border-radius:9px;
  overflow:hidden; margin-bottom:1.75rem; }}
.house > div {{ background:var(--card); padding:.85rem 1rem; }}
.house dt {{ font-weight:600; font-size:.88rem; margin-bottom:.25rem; }}
.house dd {{ margin:0; font-size:.86rem; color:var(--ink-2); }}

.rail {{ position:sticky; top:0; z-index:20; margin:0 -1.25rem 1.2rem; padding:.7rem 1.25rem;
  background:color-mix(in srgb, var(--paper) 90%, transparent); backdrop-filter:blur(9px);
  border-bottom:1px solid var(--rule); display:flex; align-items:center; gap:.9rem; flex-wrap:wrap; }}
.stat {{ font-family:var(--mono); font-size:.8rem; color:var(--ink-3);
  font-variant-numeric:tabular-nums; }}
.stat b {{ font-size:.95rem; color:var(--ink); }}
#nok b, #nok {{ color:var(--ok); }} #ned b, #ned {{ color:var(--edit); }}
.bar {{ flex:1; min-width:6rem; height:5px; background:var(--rule); border-radius:99px;
  overflow:hidden; display:flex; }}
.bar > i {{ display:block; height:100%; width:0; background:var(--ok); transition:width .25s ease; }}

button {{ font-family:var(--sans); font-size:.81rem; cursor:pointer; border-radius:6px;
  padding:.34rem .8rem; border:1px solid var(--accent); background:var(--accent); color:var(--card);
  font-weight:500; }}
:root[data-theme="dark"] button, :root:not([data-theme="light"]) button {{ color:var(--paper); }}
button:hover {{ filter:brightness(1.1); }}
button.ghost {{ background:none; color:var(--ink-2); border-color:var(--rule); }}
button.ghost:hover {{ color:var(--ink); border-color:var(--ink-3); }}
button.quiet {{ opacity:.55; }}
:focus-visible {{ outline:2px solid var(--accent); outline-offset:2px; border-radius:4px; }}

.jump {{ display:flex; flex-wrap:wrap; gap:.4rem; margin-bottom:2rem; }}
.jump a {{ display:inline-flex; align-items:center; gap:.4rem; font-size:.82rem;
  text-decoration:none; color:var(--ink-2); background:var(--card);
  border:1px solid var(--rule); border-radius:99px; padding:.25rem .7rem; }}
.jump a:hover {{ color:var(--accent); border-color:var(--accent); }}
.jump span {{ font-family:var(--mono); font-size:.72rem; color:var(--ink-3); }}

section {{ margin-bottom:2.5rem; scroll-margin-top:4rem; }}
.shead {{ display:flex; align-items:baseline; gap:.7rem; flex-wrap:wrap;
  border-bottom:1px solid var(--ink); padding-bottom:.45rem; margin-bottom:.7rem; }}
.shead h2 {{ margin:0; font-size:1.12rem; font-weight:600; }}
.shead .file {{ font-family:var(--mono); font-size:.72rem; color:var(--ink-3); }}
.shead .count {{ margin-left:auto; font-family:var(--mono); font-size:.78rem;
  color:var(--ink-3); font-variant-numeric:tabular-nums; }}
.stand {{ color:var(--ink-2); font-size:.9rem; margin:.2rem 0 .9rem; max-width:52rem; }}
.stand code, .note code {{ font-family:var(--mono); font-size:.85em; background:var(--sunk);
  padding:.08em .3em; border-radius:3px; }}
.rows {{ display:flex; flex-direction:column; gap:.55rem; }}

.row {{ display:grid; grid-template-columns:4px 1fr auto; gap:0; background:var(--card);
  border:1px solid var(--rule); border-radius:9px; overflow:hidden; box-shadow:var(--shadow); }}
@media (max-width:720px) {{ .row {{ grid-template-columns:4px 1fr; }} }}
.stripe {{ background:var(--rule-2); }}
.row[data-state="gap"] .stripe {{ background:var(--gap); }}
.row[data-state="ok"] .stripe {{ background:var(--ok); }}
.row[data-state="edit"] .stripe {{ background:var(--edit); }}
.main {{ padding:.75rem .95rem; min-width:0; }}
.src {{ display:flex; align-items:baseline; gap:.6rem; flex-wrap:wrap; margin-bottom:.3rem; }}
.src .en {{ font-size:.87rem; color:var(--ink-2); }}
.src .key {{ font-family:var(--mono); font-size:.7rem; color:var(--ink-3);
  background:var(--sunk); padding:.06em .35em; border-radius:3px; }}
.ja {{ font-family:var(--jp); font-size:1.06rem; line-height:1.7; margin:0;
  color:var(--ink); overflow-wrap:anywhere; }}
.ja.is-empty {{ color:var(--gap); font-family:var(--mono); font-size:.85rem; }}
.ja.edited {{ margin-top:.25rem; color:var(--edit); }}
.ja.edited::before {{ content:"→ "; font-family:var(--mono); font-size:.8rem; }}
.note {{ margin:.45rem 0 0; font-size:.85rem; color:var(--ink-2); background:var(--sunk);
  border-radius:6px; padding:.5rem .65rem; }}
.flag {{ display:inline-block; font-family:var(--mono); font-size:.63rem; letter-spacing:.08em;
  text-transform:uppercase; padding:.1em .4em; border-radius:3px; margin-right:.5rem;
  vertical-align:.08em; background:var(--accent-soft); color:var(--accent); }}
.flag.f-gap {{ background:var(--gap-soft); color:var(--gap); }}

.edit {{ margin-top:.6rem; }}
.edit label {{ display:block; font-size:.74rem; color:var(--ink-3); margin-bottom:.25rem;
  font-family:var(--mono); letter-spacing:.06em; text-transform:uppercase; }}
textarea {{ width:100%; font-family:var(--jp); font-size:1rem; line-height:1.6; padding:.5rem .6rem;
  border:1px solid var(--rule); border-radius:6px; background:var(--paper); color:var(--ink);
  resize:vertical; }}
.edit-act {{ display:flex; gap:.4rem; margin-top:.4rem; }}
.act {{ display:flex; flex-direction:column; align-items:stretch; gap:.3rem;
  padding:.75rem .8rem; border-left:1px solid var(--rule-2); min-width:8.5rem; }}
@media (max-width:720px) {{ .act {{ grid-column:2; border-left:none; border-top:1px solid var(--rule-2);
  flex-direction:row; flex-wrap:wrap; }} }}
.pill {{ font-family:var(--mono); font-size:.65rem; letter-spacing:.08em; text-transform:uppercase;
  text-align:center; padding:.12rem 0; border-radius:3px; color:var(--ink-3); }}
.pill::before {{ content:"unreviewed"; }}
.row[data-state="gap"] .pill {{ color:var(--gap); }}
.row[data-state="gap"] .pill::before {{ content:"untranslated"; }}
.row[data-state="ok"] .pill {{ color:var(--ok); background:var(--ok-soft); }}
.row[data-state="ok"] .pill::before {{ content:"approved"; }}
.row[data-state="edit"] .pill {{ color:var(--edit); background:var(--edit-soft); }}
.row[data-state="edit"] .pill::before {{ content:"rewritten"; }}

footer {{ margin-top:3rem; padding-top:1.2rem; border-top:1px solid var(--rule);
  font-size:.82rem; color:var(--ink-3); }}
footer code {{ font-family:var(--mono); }}
@media (prefers-reduced-motion:reduce) {{ * {{ transition:none !important; }} }}
</style>

<div class="wrap">
  <header class="mast">
    <div class="eyebrow">Telemachus · localization sweep</div>
    <h1>日本語 string review</h1>
    <p class="sub">Every Japanese string Telemachus ships, next to the English it came from.
      Approve the ones that read right, rewrite the ones that don't, then hit
      <b>Copy results</b> and hand the markdown back.</p>
  </header>

  <dl class="brief">
    <div><dt>Strings in scope</dt><dd><b>{total}</b>console + server catalogue</dd></div>
    <div class="n-gap"><dt>Untranslated</dt><dd><b>{gaps}</b>shipping English today</dd></div>
    <div class="n-flag"><dt>Pre-flagged</dt><dd><b>{flagged}</b>a specific question to settle</dd></div>
    <div><dt>Sources</dt><dd><b>2</b>the console dict + <code>locales/ja.json</code></dd></div>
  </dl>

  <div class="how">
    <h3>How to run this</h3>
    <ol>
      <li>Start with <b>Server messages</b> — those are the only strings the API itself returns, and an empty one ships English silently.</li>
      <li>Read the English on the left, the Japanese under it. <b>Approve</b> if it should ship as written; <b>Rewrite</b> to type what should ship instead.</li>
      <li>Rows carrying a coloured tag have a specific question in the note — those are the ones worth your attention first.</li>
      <li>Your work is saved in this browser as you go. <b>Copy results</b> emits a markdown table keyed by source file and string key, ready to apply.</li>
    </ol>
  </div>

  <dl class="house">{house}</dl>
  {dupnote}

  <div class="rail">
    <span class="stat"><b id="nok">0</b> approved</span>
    <span class="stat"><b id="ned">0</b> rewritten</span>
    <span class="stat"><b id="nleft">{total}</b> left</span>
    <span class="bar"><i id="fill"></i></span>
    <button type="button" id="only" class="ghost" aria-pressed="false">Unreviewed only</button>
    <button type="button" id="copy">Copy results</button>
    <button type="button" id="reset" class="ghost">Reset all</button>
  </div>

  <nav class="jump">{jump}</nav>

  {sections}

  <footer>
    Generated from <code>refimpl/racketmaximus/static/index.html</code> and
    <code>refimpl/racketmaximus/locales/*.json</code> by <code>scripts/build-l10n-review.py</code>.
    Re-run it after any string change — this sheet is never hand-edited.
  </footer>
</div>

<script>
(function () {{
  var KEY = 'tmx-l10n-ja-review-v1';
  var state = {{}};
  try {{ state = JSON.parse(localStorage.getItem(KEY)) || {{}}; }} catch (e) {{ state = {{}}; }}
  function save() {{ try {{ localStorage.setItem(KEY, JSON.stringify(state)); }} catch (e) {{}} }}

  var rows = Array.prototype.slice.call(document.querySelectorAll('.row'));

  function idOf(r) {{ return r.dataset.file + '#' + r.dataset.key; }}

  function apply(r) {{
    var s = state[idOf(r)];
    var ed = r.querySelector('.ja.edited');
    var ta = r.querySelector('textarea');
    if (s && s.t === 'edit') {{
      r.dataset.state = 'edit'; ed.textContent = s.v; ed.hidden = false;
      if (ta) {{ ta.value = s.v; }}
    }} else if (s && s.t === 'ok') {{
      r.dataset.state = 'ok'; ed.hidden = true;
    }} else {{
      r.dataset.state = r.dataset.initial; ed.hidden = true;
    }}
    r.querySelector('button[data-act="ok"]')
     .setAttribute('aria-pressed', String(!!s && s.t === 'ok'));
  }}

  function tally() {{
    var ok = 0, ed = 0, groups = {{}};
    rows.forEach(function (r) {{
      var g = r.closest('section').id;
      groups[g] = groups[g] || 0;
      var s = state[idOf(r)];
      if (s && s.t === 'ok') {{ ok++; groups[g]++; }}
      else if (s && s.t === 'edit') {{ ed++; groups[g]++; }}
    }});
    document.getElementById('nok').textContent = ok;
    document.getElementById('ned').textContent = ed;
    document.getElementById('nleft').textContent = rows.length - ok - ed;
    document.getElementById('fill').style.width =
      (rows.length ? ((ok + ed) / rows.length * 100) : 0) + '%';
    Object.keys(groups).forEach(function (g) {{
      var el = document.querySelector('[data-done="' + g + '"]');
      if (el) {{ el.textContent = groups[g]; }}
    }});
  }}

  rows.forEach(function (r) {{
    r.dataset.initial = r.dataset.state;
    r.addEventListener('click', function (ev) {{
      var b = ev.target.closest('button');
      if (!b) {{ return; }}
      var act = b.dataset.act, k = idOf(r), panel = r.querySelector('.edit');
      if (act === 'ok') {{ state[k] = {{ t: 'ok' }}; panel.hidden = true; }}
      else if (act === 'open') {{
        panel.hidden = !panel.hidden;
        if (!panel.hidden) {{ r.querySelector('textarea').focus(); }}
        return;
      }} else if (act === 'save') {{
        var v = r.querySelector('textarea').value.trim();
        if (v) {{ state[k] = {{ t: 'edit', v: v }}; }}
        panel.hidden = true;
      }} else if (act === 'cancel') {{ panel.hidden = true; return; }}
      else if (act === 'reset') {{ delete state[k]; panel.hidden = true; }}
      save(); apply(r); tally();
    }});
    apply(r);
  }});
  tally();

  document.getElementById('only').addEventListener('click', function (ev) {{
    var on = ev.target.getAttribute('aria-pressed') !== 'true';
    ev.target.setAttribute('aria-pressed', String(on));
    ev.target.textContent = on ? 'Show all' : 'Unreviewed only';
    rows.forEach(function (r) {{
      var s = state[idOf(r)];
      r.hidden = on && !!s && (s.t === 'ok' || s.t === 'edit');
    }});
    document.querySelectorAll('section').forEach(function (sec) {{
      var live = Array.prototype.slice.call(sec.querySelectorAll('.row'))
        .some(function (r) {{ return !r.hidden; }});
      sec.hidden = on && !live;
    }});
  }});

  document.getElementById('reset').addEventListener('click', function () {{
    if (!confirm('Clear every approval and rewrite on this page?')) {{ return; }}
    state = {{}}; save(); rows.forEach(apply); tally();
  }});

  document.getElementById('copy').addEventListener('click', function (ev) {{
    var out = ['# Japanese review results', '',
               'Legend: OK approve as-is · EDIT rewritten below · TODO not reviewed', ''];
    document.querySelectorAll('section').forEach(function (sec) {{
      out.push('## ' + sec.querySelector('h2').textContent.trim(), '');
      out.push('| status | file | key | English | ship |');
      out.push('|---|---|---|---|---|');
      sec.querySelectorAll('.row').forEach(function (r) {{
        var s = state[idOf(r)];
        var mark = s && s.t === 'ok' ? 'OK' : (s && s.t === 'edit' ? 'EDIT' : 'TODO');
        var ja = s && s.t === 'edit'
          ? s.v
          : r.querySelector('.ja:not(.edited)').textContent.trim();
        var bar = function (x) {{ return x.replace(/\|/g, '\\|'); }};
        out.push('| ' + mark + ' | ' + r.dataset.file + ' | `' + r.dataset.key + '` | ' +
                 bar(r.querySelector('.en').textContent.trim()) + ' | ' + bar(ja) + ' |');
      }});
      out.push('');
    }});
    var text = out.join('\n'), btn = ev.target;
    var done = function () {{
      btn.textContent = 'Copied';
      setTimeout(function () {{ btn.textContent = 'Copy results'; }}, 1600);
    }};
    if (navigator.clipboard && navigator.clipboard.writeText) {{
      navigator.clipboard.writeText(text).then(done, function () {{ fallback(text, done); }});
    }} else {{ fallback(text, done); }}
  }});

  function fallback(text, done) {{
    var ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try {{ document.execCommand('copy'); done(); }} catch (e) {{}}
    document.body.removeChild(ta);
  }}
}})();
</script>
"""

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default=os.path.join(ROOT, "build/l10n-ja-review.html"))
    a = ap.parse_args()
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    doc = build()
    open(a.out, "w", encoding="utf-8").write(doc)
    print(f"wrote {a.out} ({len(doc):,} bytes)")
