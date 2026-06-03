import Foundation

/// Embedded static assets for the Clipx web frontend. Stored as inline
/// strings rather than bundled files so we don't have to fight with macOS
/// bundle path resolution for unsandboxed dev builds.
///
/// The frontend is intentionally tiny: vanilla HTML + CSS + JS, no build
/// step, no framework. Designed for phone-first but works on a laptop
/// browser too — the CSS uses a single fluid grid that responds to width.
enum WebContent {
    static let indexHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="theme-color" content="#0a0a0a">
      <title>Clipx</title>
      <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <header class="topbar">
        <h1>Clipx</h1>
        <nav class="tabs">
          <button class="tab active" data-tab="sources">Sources</button>
          <button class="tab" data-tab="clips">Clips</button>
        </nav>
      </header>
      <main>
        <section id="sources-pane" class="pane active">
          <div class="status" id="sources-status">Loading sources…</div>
          <div class="grid" id="sources-grid"></div>
        </section>
        <section id="clips-pane" class="pane">
          <div class="status" id="clips-status">Loading clips…</div>
          <div class="grid" id="clips-grid"></div>
        </section>
        <section id="source-detail-pane" class="pane">
          <button class="back" id="source-detail-back">&larr; Back to sources</button>
          <h2 id="source-detail-title"></h2>
          <div class="grid" id="source-clips-grid"></div>
        </section>
      </main>
      <script src="/app.js" defer></script>
    </body>
    </html>
    """

    static let appCSS = """
    :root {
      --bg: #0a0a0a;
      --panel: #161616;
      --panel-2: #1f1f1f;
      --text: #ededed;
      --muted: #9b9b9b;
      --accent: #4f8bff;
      --accent-soft: rgba(79, 139, 255, 0.16);
      --green: #57d97d;
      --radius: 10px;
      --radius-sm: 6px;
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; }
    .topbar { display: flex; align-items: center; gap: 16px; padding: 12px 16px env(safe-area-inset-bottom) 16px; background: var(--panel); border-bottom: 1px solid #2a2a2a; position: sticky; top: 0; z-index: 10; }
    .topbar h1 { margin: 0; font-size: 18px; letter-spacing: 0.2px; }
    .tabs { display: flex; gap: 4px; margin-left: auto; }
    .tab { background: transparent; color: var(--muted); border: 0; padding: 8px 12px; border-radius: var(--radius-sm); font: inherit; cursor: pointer; }
    .tab.active { background: var(--accent-soft); color: var(--accent); }
    main { padding: 12px 14px 80px; max-width: 1280px; margin: 0 auto; }
    .pane { display: none; }
    .pane.active { display: block; }
    .status { color: var(--muted); padding: 12px 4px; font-size: 13px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
      gap: 12px;
    }
    @media (min-width: 600px) {
      .grid { grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
    }
    .card { background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); overflow: hidden; display: flex; flex-direction: column; cursor: pointer; }
    .card:active { transform: scale(0.98); }
    .card .thumb { background: var(--panel-2); aspect-ratio: 16 / 9; position: relative; overflow: hidden; }
    .card .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .card .thumb .badge { position: absolute; bottom: 6px; right: 6px; background: rgba(0,0,0,0.75); color: white; font-size: 11px; padding: 2px 6px; border-radius: 999px; font-variant-numeric: tabular-nums; }
    .card .thumb .badge.left { left: 6px; right: auto; }
    .card .meta { padding: 8px 10px; }
    .card .meta .name { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card .meta .sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
    .card .stars { color: #ffcd3a; font-size: 11px; }
    .clip-row { display: flex; gap: 10px; padding: 10px; background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); align-items: center; }
    .clip-row .thumb { width: 96px; aspect-ratio: 16 / 9; flex-shrink: 0; border-radius: var(--radius-sm); overflow: hidden; background: var(--panel-2); }
    .clip-row .thumb img { width: 100%; height: 100%; object-fit: cover; }
    .clip-row .info { flex: 1; min-width: 0; }
    .clip-row .info .name { font-size: 14px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .clip-row .info .sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
    .clip-row .rate { display: flex; gap: 3px; margin-top: 4px; }
    .clip-row .rate button { background: transparent; border: 0; color: #555; padding: 4px; font-size: 16px; cursor: pointer; line-height: 1; }
    .clip-row .rate button.filled { color: #ffcd3a; }
    .back { background: transparent; color: var(--accent); border: 0; padding: 8px 0; font: inherit; cursor: pointer; margin-bottom: 8px; }
    h2 { margin: 4px 0 14px; font-size: 16px; font-weight: 600; }
    .empty { padding: 32px 16px; text-align: center; color: var(--muted); font-size: 13px; }
    """

    // Frontend behavior: tab switching, fetch+render, source-detail nav,
    // rating writes. Stays under ~150 lines.
    static let appJS = """
    const $ = (sel) => document.querySelector(sel);
    const $$ = (sel) => Array.from(document.querySelectorAll(sel));

    function formatDuration(ms) {
      if (!ms || ms < 0) return '';
      const sec = Math.floor(ms / 1000);
      const h = Math.floor(sec / 3600);
      const m = Math.floor((sec % 3600) / 60);
      const s = sec % 60;
      if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
      return `${m}:${String(s).padStart(2,'0')}`;
    }

    function relativeDate(unixSec) {
      if (!unixSec) return '';
      const ms = unixSec * 1000;
      const diff = Date.now() - ms;
      const day = 86400000;
      if (diff < day) return 'today';
      if (diff < 2 * day) return 'yesterday';
      if (diff < 7 * day) return `${Math.floor(diff / day)}d ago`;
      const d = new Date(ms);
      return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }

    async function fetchJSON(path) {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      return res.json();
    }

    function thumbURL(hash) {
      if (!hash) return '';
      return `/api/thumb/${hash}.jpg`;
    }

    function sourceCard(src) {
      const card = document.createElement('div');
      card.className = 'card';
      card.innerHTML = `
        <div class="thumb">
          ${src.hash ? `<img loading="lazy" src="${thumbURL(src.hash)}" onerror="this.style.display='none'">` : ''}
          ${src.durationMs ? `<span class="badge left">${formatDuration(src.durationMs)}</span>` : ''}
          ${src.width && src.height ? `<span class="badge">${src.width}×${src.height}</span>` : ''}
        </div>
        <div class="meta">
          <div class="name">${src.name}</div>
          <div class="sub">${relativeDate(src.createdAt || src.importedAt)}${src.fps ? ` · ${Math.round(src.fps)}p` : ''}${src.online ? '' : ' · offline'}</div>
        </div>
      `;
      card.addEventListener('click', () => openSourceDetail(src));
      return card;
    }

    function clipRow(clip) {
      const row = document.createElement('div');
      row.className = 'clip-row';
      const stars = [1,2,3,4,5].map(n => `<button data-rating="${n}" class="${n <= clip.rating ? 'filled' : ''}">★</button>`).join('');
      row.innerHTML = `
        <div class="thumb">${clip.sourceHash ? `<img loading="lazy" src="${thumbURL(clip.sourceHash)}" onerror="this.style.display='none'">` : ''}</div>
        <div class="info">
          <div class="name">${clip.name || clip.sourceName}</div>
          <div class="sub">${formatDuration(clip.durationMs)} · ${clip.sourceName}${clip.mood ? ' · ' + clip.mood : ''}</div>
          <div class="rate">${stars}</div>
        </div>
      `;
      row.querySelectorAll('.rate button').forEach(btn => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const rating = parseInt(btn.dataset.rating, 10);
          try {
            await fetch(`/api/clips/${clip.id}/rating`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ rating })
            });
            clip.rating = rating;
            row.querySelectorAll('.rate button').forEach((b, idx) => {
              b.classList.toggle('filled', idx < rating);
            });
          } catch (err) {
            alert('Rating failed: ' + err.message);
          }
        });
      });
      return row;
    }

    async function loadSources() {
      const grid = $('#sources-grid');
      const status = $('#sources-status');
      try {
        const sources = await fetchJSON('/api/sources?limit=200');
        grid.innerHTML = '';
        if (sources.length === 0) {
          status.textContent = 'No sources yet. Add a folder in the Mac app.';
          return;
        }
        status.textContent = `${sources.length} source${sources.length === 1 ? '' : 's'}`;
        sources.forEach(s => grid.appendChild(sourceCard(s)));
      } catch (e) {
        status.textContent = 'Failed: ' + e.message;
      }
    }

    async function loadClips() {
      const grid = $('#clips-grid');
      const status = $('#clips-status');
      try {
        const clips = await fetchJSON('/api/clips?limit=200');
        grid.innerHTML = '';
        if (clips.length === 0) {
          status.textContent = 'No clips yet. Mark some in the Mac app.';
          return;
        }
        status.textContent = `${clips.length} clip${clips.length === 1 ? '' : 's'}`;
        clips.forEach(c => grid.appendChild(clipRow(c)));
      } catch (e) {
        status.textContent = 'Failed: ' + e.message;
      }
    }

    async function openSourceDetail(src) {
      switchTab('source-detail-pane');
      $('#source-detail-title').textContent = src.name;
      const grid = $('#source-clips-grid');
      grid.innerHTML = '<div class="empty">Loading clips…</div>';
      try {
        const clips = await fetchJSON(`/api/sources/${src.id}/clips`);
        grid.innerHTML = '';
        if (clips.length === 0) {
          grid.innerHTML = '<div class="empty">No clips saved from this source yet.</div>';
          return;
        }
        clips.forEach(c => grid.appendChild(clipRow(c)));
      } catch (e) {
        grid.innerHTML = '<div class="empty">Failed to load clips.</div>';
      }
    }

    function switchTab(paneID) {
      $$('.pane').forEach(p => p.classList.remove('active'));
      $(`#${paneID}`).classList.add('active');
      $$('.tab').forEach(t => t.classList.remove('active'));
      // Tab buttons match data-tab to pane prefix; the detail pane is
      // standalone and doesn't light a tab.
      const tabName = paneID.replace('-pane', '');
      const tabBtn = $$(`.tab`).find(b => b.dataset.tab === tabName);
      if (tabBtn) tabBtn.classList.add('active');
    }

    $$('.tab').forEach(btn => {
      btn.addEventListener('click', () => {
        const pane = btn.dataset.tab + '-pane';
        switchTab(pane);
        if (pane === 'sources-pane') loadSources();
        else if (pane === 'clips-pane') loadClips();
      });
    });

    $('#source-detail-back').addEventListener('click', () => {
      switchTab('sources-pane');
    });

    loadSources();
    """
}
