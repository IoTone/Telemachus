// The Notes tab's tidying lists: notes that are linked to no other note, and
// links whose target is not there. Both come from GET /api/notes/tidy, which
// resolves every link for the reader, so a colleague's private note is reported
// the way a missing one is.
//
// The card is opened and closed by a tab render, as the graph is: it is on
// screen in neither state, so there is nothing to swap, and the read then rides
// the tab's own round of requests. Closed, it costs no request.

function tidyOpen(){ S.tidyOpen = true; renderTab(); }
function tidyClose(){ S.tidyOpen = false; renderTab(); }

// one note, as a link that opens it in the view card
function tidyNoteLink(id, title){
  return `<a href="#" data-h-click="${H(() => { noteShow(id); return false; })}">${
    esc(title) || t('untitled')}</a>`;
}

function tidyCount(key, n){ return esc(tRaw(key).replace('{n}', n)); }

// "the first N" under a list the server cut short
function tidyMore(shown, total){
  return (typeof total === 'number' && total > shown)
    ? `<p class="muted" style="font-size:12px;margin:4px 0 0">${tidyCount('ntidymore', shown)}</p>`
    : '';
}

function noteTidyCard(T){
  const unlinked = T.unlinked || [];
  const broken = T.broken || [];
  const reason = r => r === 'ambiguous' ? t('ntidyambiguous') : t('ntidymissing');
  const unlinkedList = T.truncated
    ? ''
    : `<h4 style="margin:14px 0 4px">${tidyCount('ntidyunlinked', T.unlinked_total || 0)}</h4>
       <p class="muted" style="font-size:12px;margin:0 0 6px">${t('ntidyunlinkedhint')}</p>
       ${unlinked.length
          ? `<ul style="margin:0;padding-left:18px">${
              unlinked.map(n => `<li>${tidyNoteLink(n.note_id, n.title)}</li>`).join('')}</ul>`
          : `<p class="muted" style="margin:0">${t('ntidynone')}</p>`}
       ${tidyMore(unlinked.length, T.unlinked_total)}`;
  const brokenList =
    `<h4 style="margin:14px 0 4px">${tidyCount('ntidybroken', T.broken_total || 0)}</h4>
     <p class="muted" style="font-size:12px;margin:0 0 6px">${t('ntidybrokenhint')}</p>
     ${broken.length
        ? `<ul style="margin:0;padding-left:18px">${
            broken.map(b => `<li>${tidyNoteLink(b.note_id, b.title)}
              <span class="muted">&rarr;</span> <code>${esc(b.target)}</code>
              <span class="muted" style="font-size:12px">${reason(b.reason)}</span></li>`).join('')}</ul>`
        : `<p class="muted" style="margin:0">${t('ntidynone')}</p>`}
     ${tidyMore(broken.length, T.broken_total)}`;
  return `<div class="card" id="ntidy"><h3 style="margin-top:0">${t('ntidy')}</h3>
    <div class="row" style="gap:8px;align-items:flex-end">
      <div style="flex:1" class="muted">${t('ntidyhint')}</div>
      <div style="flex:0 0 auto"><button class="btn sm ghost"
        data-h-click="${H(() => tidyClose())}">${t('ntidyhide')}</button></div>
    </div>
    ${T.truncated ? `<p class="muted" style="font-size:12px">${t('ntidytrunc')}</p>` : ''}
    ${unlinkedList}${brokenList}</div>`;
}
