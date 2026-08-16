#lang racket/base

;; domain/beta/template.rkt — Tier-C custom HTML templates for the onboarding landing
;; (slice 44). An admin authors HTML with {{placeholders}} in the console; the server
;; SANITIZES it (strips scripts, event handlers, javascript: URIs, and structural/
;; active tags), substitutes escaped config values + a generated field set, and wraps
;; it with OUR trusted submission bootstrap. The result is rendered inside a
;; SANDBOXED, opaque-origin iframe (allow-scripts, NO allow-same-origin), so even a
;; sanitizer bypass runs isolated from our origin — it cannot read the operator's
;; token, cookies, or the parent DOM, only reach the already-public beta API (which
;; is CORS-enabled for this and rate-limited). Two independent defenses: sanitize +
;; sandbox. See docs/design/beta-onboarding-experience.md §5 (Tier C).

(require racket/string json)

(provide sanitize-template render-template template-page DEFAULT-TEMPLATE)

;; ---- sanitizer --------------------------------------------------------------
;; Regex-based, defense-in-depth (the sandbox is the primary guarantee). Removes
;; active content and structural tags that could escape the presentational intent.
(define (sanitize-template s)
  (let* ([s (regexp-replace* #px"(?i:<script\\b[^>]*>.*?</script\\s*>)" s "")]   ; <script>…</script>
         [s (regexp-replace* #px"(?i:<script\\b[^>]*/?>)" s "")]                  ; stray/self-closing script
         [s (regexp-replace* #px"(?i:</?(?:iframe|object|embed|applet|link|base|meta|frame|frameset)\\b[^>]*>)" s "")]
         [s (regexp-replace* #px"(?i:\\son[a-z]+\\s*=\\s*\"[^\"]*\")" s "")]      ; on…="…"
         [s (regexp-replace* #px"(?i:\\son[a-z]+\\s*=\\s*'[^']*')" s "")]         ; on…='…'
         [s (regexp-replace* #px"(?i:\\son[a-z]+\\s*=\\s*[^\\s>]+)" s "")]        ; on…=unquoted
         [s (regexp-replace* #px"(?i:\\s(?:action|formaction)\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+))" s "")]
         [s (regexp-replace* #px"(?i:(href|src)\\s*=\\s*\"\\s*javascript:[^\"]*\")" s "\\1=\"#\"")]
         [s (regexp-replace* #px"(?i:(href|src)\\s*=\\s*'\\s*javascript:[^']*')" s "\\1='#'")])
    s))

(define (esc s)
  (regexp-replaces (format "~a" s)
    '((#rx"&" "\\&amp;") (#rx"<" "\\&lt;") (#rx">" "\\&gt;") (#rx"\"" "\\&quot;"))))

;; generated, safe form inputs (name=<key>) + a hidden honeypot; the bootstrap reads them
(define (fields->html fields)
  (string-append
   (apply string-append
     (for/list ([f (in-list fields)])
       (define key (esc (hash-ref f 'key "")))
       (define label (esc (hash-ref f 'label "")))
       (define type (hash-ref f 'type "text"))
       (define req (if (hash-ref f 'required #f) " required" ""))
       (cond
         [(string=? type "textarea")
          (format "<p><label>~a</label><textarea name=\"~a\" rows=\"3\"~a></textarea></p>" label key req)]
         [(string=? type "select")
          (format "<p><label>~a</label><select name=\"~a\"~a><option value=\"\"></option>~a</select></p>"
                  label key req
                  (apply string-append (for/list ([o (in-list (hash-ref f 'options '()))]) (format "<option>~a</option>" (esc o)))))]
         [else
          (format "<p><label>~a</label><input name=\"~a\" type=\"~a\"~a></p>"
                  label key (if (member type '("email" "tel")) type "text") req)])))
   "<input name=\"_hp\" tabindex=\"-1\" autocomplete=\"off\" aria-hidden=\"true\" style=\"position:absolute;left:-9999px;width:1px;height:1px;opacity:0\">"))

;; substitute {{placeholders}} into the SANITIZED template with escaped values
(define (render-template tpl cfg)
  (define subs
    (hash "title"    (esc (hash-ref cfg 'title ""))
          "subtitle" (esc (hash-ref cfg 'subtitle ""))
          "eyebrow"  (esc (hash-ref cfg 'eyebrow ""))
          "logo"     (esc (hash-ref cfg 'logo "Telemachus"))
          "cta"      (esc (hash-ref cfg 'cta "Request access"))
          "footer"   (esc (hash-ref cfg 'footer ""))
          "fields"   (fields->html (hash-ref cfg 'fields '()))
          "message"  "<div data-beta-msg></div>"))
  (regexp-replace* #px"\\{\\{\\s*(\\w+)\\s*\\}\\}" (sanitize-template tpl)
                   (lambda (_ k) (hash-ref subs k ""))))

;; our trusted submission bootstrap — the ONLY script in the served page. Collects
;; [name] inputs, solves the PoW (FNV-1a, identical to antispam.rkt), posts to the
;; beta API (cross-origin from the sandboxed opaque origin → relies on CORS).
(define BOOTSTRAP #<<JS
(function(){
  function powhash(s){var h=2166136261>>>0;for(var i=0;i<s.length;i++){h=(h^s.charCodeAt(i))>>>0;h=Math.imul(h,16777619)>>>0;}return h>>>0;}
  function solve(n,d){var m=(d>=32)?0xFFFFFFFF:(((1<<d)>>>0)-1);for(var i=0;;i++){if((powhash(n+':'+i)&m)===0)return i;}}
  function msg(t,err){var e=document.querySelector('[data-beta-msg]');if(e){e.textContent=t;e.style.color=err?'#c0392b':'';}}
  function collect(){var o={},els=document.querySelectorAll('[name]');for(var i=0;i<els.length;i++){o[els[i].name]=els[i].value;}return o;}
  var cached=null;
  function warm(){return fetch('/api/beta/challenge').then(function(r){return r.json();}).then(function(c){cached=c;return c;}).catch(function(){return null;});}
  function submit(){
    msg('Verifying you\u2019re human\u2026');
    (cached?Promise.resolve(cached):warm()).then(function(ch){
      if(!ch||!ch.challenge){msg('Could not start \u2014 reload.',1);return;}
      var pow=solve(String(ch.challenge).split('.')[0],ch.difficulty);
      var body=collect();body[ch.honeypot||'_hp']=body[ch.honeypot||'_hp']||'';body.challenge=ch.challenge;body.pow=pow;
      cached=null;
      return fetch('/api/beta/signup',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}).then(function(r){return r.json().then(function(j){return {ok:r.ok,j:j};});}).then(function(x){
        if(x.ok){msg(x.j.message||'Thanks \u2014 your request is in review.');document.querySelectorAll('[name],[data-beta-submit]').forEach(function(el){el.disabled=true;});}
        else{msg((x.j&&x.j.error)||'Something went wrong.',1);warm();}
      });
    }).catch(function(){msg('Network error \u2014 please retry.',1);});
  }
  document.addEventListener('click',function(e){var t=e.target.closest&&e.target.closest('[data-beta-submit]');if(t){e.preventDefault();submit();}});
  document.addEventListener('submit',function(e){e.preventDefault();submit();});
  warm();   // issue the challenge at load so it ages past the min-fill-time gate
})();
JS
  )

;; the full HTML document served at /beta/template (rendered inside the sandbox)
(define (template-page cfg tpl)
  (string-append
   "<!doctype html><html><head><meta charset=\"utf-8\">"
   "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
   "<base target=\"_top\"></head><body>"
   (render-template tpl cfg)
   "<script>" BOOTSTRAP "</script></body></html>"))

(define DEFAULT-TEMPLATE #<<HTML
<style>
  body{margin:0;font:16px/1.6 ui-sans-serif,system-ui,sans-serif;background:#0f1117;color:#e6e8ee}
  .wrap{max-width:560px;margin:0 auto;padding:40px 22px}
  .eyebrow{letter-spacing:.16em;text-transform:uppercase;font-size:12px;color:#7c8cff;font-weight:700}
  h1{font-size:2rem;line-height:1.1;margin:.2em 0 .3em}
  p.lede{color:#9aa3b2}
  form{background:#171a23;border:1px solid #2a2f3d;border-radius:12px;padding:22px;margin-top:18px}
  label{display:block;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#9aa3b2;margin:0 0 4px}
  input,select,textarea{width:100%;box-sizing:border-box;background:#0f1117;border:1px solid #2a2f3d;color:#e6e8ee;border-radius:8px;padding:10px 12px;font:inherit}
  p{margin:0 0 12px}
  button{width:100%;margin-top:6px;background:#5a6cff;color:#fff;border:0;border-radius:8px;padding:12px;font-weight:800;font-size:15px;cursor:pointer}
  [data-beta-msg]{margin-top:10px;color:#9aa3b2;font-size:14px}
  footer{color:#6b7484;font-size:13px;margin-top:16px}
</style>
<div class="wrap">
  <div class="eyebrow">{{eyebrow}}</div>
  <h1>{{title}}</h1>
  <p class="lede">{{subtitle}}</p>
  <form>
    {{fields}}
    <button data-beta-submit>{{cta}}</button>
    {{message}}
  </form>
  <footer>{{footer}}</footer>
</div>
HTML
  )
