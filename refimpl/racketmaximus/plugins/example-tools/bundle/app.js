// The token the console signed in with; the bundle and the API route below
// are served by the same origin and both require it.
const token = localStorage.getItem('tmx_token');
document.getElementById('go').onclick = async () => {
  const text = document.getElementById('t').value;
  const r = await fetch('/api/x/example-tools/word-count?text=' + encodeURIComponent(text),
                        { headers: { Authorization: 'Bearer ' + token } });
  const j = await r.json();
  document.getElementById('out').textContent =
    r.ok ? `${j.words} words, ${j.chars} characters` : (j.error || 'failed');
};
