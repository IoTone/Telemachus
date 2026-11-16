// stay in sync with the admin-configured copy when present (optional)
Telemachus.beta.config().then(function (c) {
  if (!c) return;
  if (c.title) document.getElementById('title').textContent = c.title;
  if (c.subtitle) document.getElementById('lede').textContent = c.subtitle;
  if (c.eyebrow) document.getElementById('kicker').textContent = c.eyebrow;
}).catch(function () {});
// warm a challenge on load so the human fill-time gate passes
Telemachus.beta.challenge();
var form = document.getElementById('f'), msg = document.getElementById('msg'), btn = document.getElementById('btn');
form.addEventListener('submit', function (e) {
  e.preventDefault();
  msg.className = 'msg'; msg.textContent = 'Verifying you’re human…'; btn.disabled = true;
  Telemachus.beta.submit({
    name: document.getElementById('name').value,
    email: document.getElementById('email').value,
    company: document.getElementById('company').value,
    use_case: document.getElementById('use_case').value,
    _hp: document.getElementById('hp').value
  }).then(function (r) {
    if (r.ok) { form.querySelectorAll('input,textarea,button').forEach(function (el) { el.disabled = true; }); msg.textContent = r.message || 'Thanks — your request is in review.'; }
    else { btn.disabled = false; msg.className = 'msg err'; msg.textContent = r.error || 'Something went wrong.'; }
  });
});
