import Foundation

/// Embedded static assets for the Clipx web frontend. Stored as inline
/// strings rather than bundled files so we don't have to fight with macOS
/// bundle path resolution.
///
/// Vanilla HTML/CSS/JS, no build step, no framework. Phone-first responsive
/// layout that also works on a laptop browser.
enum WebContent {
    static let indexHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
      <meta name="theme-color" content="#0a0a0a">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <title>Clipx</title>
      <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <!-- Pair gate — covers everything until a PIN is accepted. -->
      <div id="pair-gate" class="pair-gate hidden">
        <div class="pair-card">
          <h1>Pair with Clipx</h1>
          <p>Open the Mac app, go to Settings → Remote, and read the 6-digit PIN.</p>
          <input id="pair-input" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="off" placeholder="000000">
          <button id="pair-submit" class="primary">Pair</button>
          <div id="pair-error" class="error"></div>
        </div>
      </div>

      <header class="topbar">
        <h1>Clipx</h1>
        <input id="search" type="search" placeholder="Search sources, clips, notes…">
        <nav class="tabs">
          <button class="tab active" data-tab="sources">Sources</button>
          <button class="tab" data-tab="clips">Clips</button>
        </nav>
      </header>
      <main>
        <section id="sources-pane" class="pane active">
          <div class="status" id="sources-status">Loading…</div>
          <div id="sources-calendar"></div>
        </section>
        <section id="clips-pane" class="pane">
          <div class="status" id="clips-status">Loading…</div>
          <div class="grid" id="clips-grid"></div>
        </section>
        <section id="search-pane" class="pane">
          <h2 id="search-title">Search results</h2>
          <h3>Sources</h3>
          <div class="grid" id="search-sources-grid"><div class="empty">—</div></div>
          <h3>Clips</h3>
          <div class="grid" id="search-clips-grid"><div class="empty">—</div></div>
        </section>
        <section id="source-detail-pane" class="pane">
          <button class="back" id="source-detail-back">&larr; Back</button>
          <h2 id="source-detail-title"></h2>
          <div id="source-detail-meta" class="sub"></div>
          <button id="open-player" class="primary">Open player</button>
          <h3>Clips from this source</h3>
          <div class="grid" id="source-clips-grid"></div>
        </section>
      </main>

      <!-- Video player modal: <video> + scrubber + in/out + save -->
      <div id="player-modal" class="modal hidden">
        <div class="modal-head">
          <button id="player-close">&times;</button>
          <span id="player-title"></span>
        </div>
        <video id="player-video" playsinline controls preload="auto"></video>
        <div id="player-prep" class="prep hidden">
          <div class="spinner"></div>
          <div id="player-prep-text">Preparing…</div>
          <div id="player-prep-sub" class="prep-sub"></div>
        </div>
        <div class="player-controls">
          <div class="timeline">
            <div class="range" id="player-range"></div>
            <div class="playhead" id="player-playhead"></div>
          </div>
          <div class="player-buttons">
            <button id="btn-back-5">&laquo; 5s</button>
            <button id="btn-mark-in">Mark In (I)</button>
            <button id="btn-mark-out">Mark Out (O)</button>
            <button id="btn-fwd-5">5s &raquo;</button>
            <button id="btn-save" class="primary">Save Clip</button>
          </div>
          <div class="player-marks" id="player-marks">No marks set</div>
        </div>
      </div>

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
      --orange: #ff9550;
      --danger: #ff6760;
      --radius: 10px;
      --radius-sm: 6px;
    }
    * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; }
    .hidden { display: none !important; }
    /* Pair gate */
    .pair-gate { position: fixed; inset: 0; background: var(--bg); z-index: 100; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .pair-card { background: var(--panel); border: 1px solid #2a2a2a; border-radius: var(--radius); padding: 24px; max-width: 360px; width: 100%; text-align: center; }
    .pair-card h1 { margin: 0 0 12px; font-size: 20px; }
    .pair-card p { color: var(--muted); margin: 0 0 18px; font-size: 14px; line-height: 1.5; }
    .pair-card input { width: 100%; font-size: 32px; text-align: center; padding: 12px; background: var(--panel-2); border: 1px solid #333; color: var(--text); border-radius: var(--radius-sm); letter-spacing: 0.4em; font-family: ui-monospace, monospace; margin-bottom: 12px; }
    .pair-card input:focus { outline: 2px solid var(--accent); }
    .pair-card .primary { width: 100%; padding: 12px; background: var(--accent); color: white; border: 0; border-radius: var(--radius-sm); font-size: 16px; font-weight: 500; cursor: pointer; }
    .error { color: var(--danger); font-size: 13px; min-height: 1em; margin-top: 8px; }
    /* Topbar */
    .topbar { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 12px; padding: 12px 16px; background: var(--panel); border-bottom: 1px solid #2a2a2a; position: sticky; top: 0; z-index: 10; }
    .topbar h1 { margin: 0; font-size: 17px; letter-spacing: 0.2px; }
    .topbar input[type="search"] { padding: 8px 12px; background: var(--panel-2); border: 1px solid #2a2a2a; color: var(--text); border-radius: var(--radius-sm); font: inherit; min-width: 0; }
    .topbar input[type="search"]:focus { outline: 1px solid var(--accent); border-color: transparent; }
    @media (max-width: 540px) {
      .topbar { grid-template-columns: 1fr auto; }
      .topbar h1 { display: none; }
    }
    .tabs { display: flex; gap: 4px; }
    .tab { background: transparent; color: var(--muted); border: 0; padding: 8px 12px; border-radius: var(--radius-sm); font: inherit; cursor: pointer; }
    .tab.active { background: var(--accent-soft); color: var(--accent); }
    /* Layout */
    main { padding: 12px 14px 100px; max-width: 1280px; margin: 0 auto; }
    .pane { display: none; }
    .pane.active { display: block; }
    .status { color: var(--muted); padding: 12px 4px; font-size: 13px; }
    .empty { padding: 32px 16px; text-align: center; color: var(--muted); font-size: 13px; }
    .sub { font-size: 12px; color: var(--muted); margin: 4px 0 12px; }
    .back { background: transparent; color: var(--accent); border: 0; padding: 8px 0; font: inherit; cursor: pointer; margin-bottom: 8px; }
    h2 { margin: 4px 0 14px; font-size: 16px; font-weight: 600; }
    h3 { margin: 18px 0 8px; font-size: 13px; font-weight: 600; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
    .primary { background: var(--accent); color: white; border: 0; padding: 9px 16px; border-radius: var(--radius-sm); font: inherit; font-weight: 500; cursor: pointer; }
    .primary:active { transform: scale(0.98); }
    /* Cards & grid */
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 12px; }
    @media (min-width: 600px) { .grid { grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; } }
    .card { background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); overflow: hidden; display: flex; flex-direction: column; cursor: pointer; }
    .card:active { transform: scale(0.98); }
    .card .thumb { background: var(--panel-2); aspect-ratio: 16 / 9; position: relative; overflow: hidden; }
    .card .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    .card .thumb .badge { position: absolute; bottom: 6px; right: 6px; background: rgba(0,0,0,0.75); color: white; font-size: 11px; padding: 2px 6px; border-radius: 999px; font-variant-numeric: tabular-nums; }
    .card .thumb .badge.left { left: 6px; right: auto; }
    .card .meta { padding: 8px 10px; }
    .card .meta .name { font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card .meta .sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
    /* Calendar grouping */
    .month { margin-bottom: 18px; }
    .month-head { font-size: 14px; font-weight: 600; padding: 12px 4px 6px; position: sticky; top: 56px; background: var(--bg); }
    .day { margin-bottom: 12px; }
    .day-head { display: flex; align-items: baseline; gap: 8px; padding: 8px 4px; color: var(--muted); font-size: 12px; }
    /* Clip rows */
    .clip-row { display: flex; gap: 10px; padding: 10px; background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); align-items: center; }
    .clip-row .thumb { width: 96px; aspect-ratio: 16 / 9; flex-shrink: 0; border-radius: var(--radius-sm); overflow: hidden; background: var(--panel-2); }
    .clip-row .thumb img { width: 100%; height: 100%; object-fit: cover; }
    .clip-row .info { flex: 1; min-width: 0; }
    .clip-row .info .name { font-size: 14px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .clip-row .info .sub { font-size: 11px; color: var(--muted); margin-top: 2px; }
    .clip-row .rate { display: flex; gap: 3px; margin-top: 4px; }
    .clip-row .rate button { background: transparent; border: 0; color: #555; padding: 4px; font-size: 16px; cursor: pointer; line-height: 1; }
    .clip-row .rate button.filled { color: #ffcd3a; }
    /* Modal player */
    .modal { position: fixed; inset: 0; background: rgba(0,0,0,0.92); z-index: 50; display: flex; flex-direction: column; }
    .modal-head { display: flex; align-items: center; gap: 12px; padding: 12px 16px; }
    .modal-head button { background: transparent; color: white; border: 0; font-size: 26px; cursor: pointer; padding: 0; line-height: 1; }
    .modal-head span { font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1; }
    #player-video { width: 100%; flex: 1; min-height: 0; background: black; object-fit: contain; }
    .player-controls { background: var(--panel); padding: 12px 14px env(safe-area-inset-bottom); border-top: 1px solid #2a2a2a; }
    .timeline { position: relative; height: 24px; background: #2a2a2a; border-radius: 4px; margin-bottom: 12px; cursor: pointer; }
    .timeline .range { position: absolute; top: 0; bottom: 0; background: var(--accent-soft); border-left: 2px solid var(--accent); border-right: 2px solid var(--accent); pointer-events: none; }
    .timeline .playhead { position: absolute; top: -4px; bottom: -4px; width: 2px; background: var(--danger); pointer-events: none; }
    .player-buttons { display: grid; grid-template-columns: repeat(5, 1fr); gap: 6px; }
    .player-buttons button { padding: 12px 4px; background: var(--panel-2); color: var(--text); border: 1px solid #333; border-radius: var(--radius-sm); font: inherit; font-size: 13px; cursor: pointer; }
    .player-buttons button.primary { background: var(--accent); border-color: var(--accent); color: white; }
    .player-buttons button:active { transform: scale(0.97); }
    .player-marks { font-size: 12px; color: var(--muted); text-align: center; margin-top: 8px; font-variant-numeric: tabular-nums; }
    /* Proxy "preparing" overlay */
    .prep { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 12px; background: rgba(0,0,0,0.72); z-index: 5; text-align: center; padding: 24px; }
    .prep .spinner { width: 38px; height: 38px; border-radius: 50%; border: 3px solid rgba(255,255,255,0.18); border-top-color: var(--accent); animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    #player-prep-text { font-size: 15px; font-weight: 500; }
    .prep .prep-sub { font-size: 13px; color: var(--muted); font-variant-numeric: tabular-nums; }
    """

    static let appJS = """
    const $ = (sel) => document.querySelector(sel);
    const $$ = (sel) => Array.from(document.querySelectorAll(sel));

    // ----- Auth -----
    const TOKEN_KEY = 'clipxToken';
    let token = localStorage.getItem(TOKEN_KEY) || '';

    async function api(path, opts = {}) {
      const headers = Object.assign({}, opts.headers || {});
      if (token) headers['Authorization'] = `Bearer ${token}`;
      const res = await fetch(path, Object.assign({}, opts, { headers }));
      if (res.status === 401) {
        token = '';
        localStorage.removeItem(TOKEN_KEY);
        showPairGate();
        throw new Error('unauthorized');
      }
      if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('application/json')) return res.json();
      return res;
    }

    function showPairGate() { $('#pair-gate').classList.remove('hidden'); }
    function hidePairGate() { $('#pair-gate').classList.add('hidden'); }

    $('#pair-submit').addEventListener('click', pair);
    $('#pair-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') pair(); });

    async function pair() {
      const pin = $('#pair-input').value.trim();
      $('#pair-error').textContent = '';
      if (pin.length !== 6) {
        $('#pair-error').textContent = 'PIN should be 6 digits';
        return;
      }
      try {
        const res = await fetch('/api/pair', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ pin }),
        });
        if (!res.ok) {
          const body = await res.json().catch(() => ({ error: 'failed' }));
          $('#pair-error').textContent = body.error || 'Wrong PIN';
          return;
        }
        const body = await res.json();
        token = body.token;
        localStorage.setItem(TOKEN_KEY, token);
        hidePairGate();
        loadSources();
      } catch (e) {
        $('#pair-error').textContent = 'Network error: ' + e.message;
      }
    }

    // ----- Utilities -----
    function formatDuration(ms) {
      if (!ms || ms < 0) return '';
      const sec = Math.floor(ms / 1000);
      const h = Math.floor(sec / 3600);
      const m = Math.floor((sec % 3600) / 60);
      const s = sec % 60;
      if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}`;
      return `${m}:${String(s).padStart(2,'0')}`;
    }
    function formatMs(ms) {
      const sec = Math.floor(Math.max(0, ms) / 1000);
      const m = Math.floor(sec / 60), s = sec % 60;
      const cs = Math.floor((Math.max(0, ms) / 10) % 100);
      return `${String(m).padStart(2,'0')}:${String(s).padStart(2,'0')}.${String(cs).padStart(2,'0')}`;
    }
    function thumbURL(hash) { return hash ? `/api/thumb/${hash}.jpg` : ''; }

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
          <div class="name">${escapeHTML(src.name)}</div>
          <div class="sub">${src.fps ? Math.round(src.fps) + 'p' : ''}${src.online ? '' : ' · offline'}</div>
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
          <div class="name">${escapeHTML(clip.name || clip.sourceName)}</div>
          <div class="sub">${formatDuration(clip.durationMs)} · ${escapeHTML(clip.sourceName)}${clip.mood ? ' · ' + escapeHTML(clip.mood) : ''}</div>
          <div class="rate">${stars}</div>
        </div>
      `;
      row.querySelectorAll('.rate button').forEach(btn => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const rating = parseInt(btn.dataset.rating, 10);
          try {
            await api(`/api/clips/${clip.id}/rating`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ rating })
            });
            clip.rating = rating;
            row.querySelectorAll('.rate button').forEach((b, idx) => {
              b.classList.toggle('filled', idx < rating);
            });
          } catch (err) { alert('Rating failed: ' + err.message); }
        });
      });
      return row;
    }

    function escapeHTML(s) {
      return String(s || '').replace(/[&<>"]/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c]));
    }

    // ----- Calendar grouping -----
    function groupByCalendar(sources) {
      const buckets = new Map();
      const undated = [];
      for (const s of sources) {
        const t = s.createdAt || s.importedAt;
        if (!t) { undated.push(s); continue; }
        const date = new Date(t * 1000);
        const monthKey = `${date.getFullYear()}-${String(date.getMonth()+1).padStart(2,'0')}`;
        const dayKey = `${monthKey}-${String(date.getDate()).padStart(2,'0')}`;
        if (!buckets.has(monthKey)) buckets.set(monthKey, { date, days: new Map() });
        const month = buckets.get(monthKey);
        if (!month.days.has(dayKey)) month.days.set(dayKey, { date, sources: [] });
        month.days.get(dayKey).sources.push(s);
      }
      const sorted = [...buckets.entries()].sort(([a], [b]) => b.localeCompare(a))
        .map(([key, { date, days }]) => ({
          key, date,
          days: [...days.entries()].sort(([a], [b]) => b.localeCompare(a))
            .map(([k, v]) => ({ key: k, ...v }))
        }));
      if (undated.length) sorted.push({ key: 'unknown', date: null, days: [{ key: 'u', date: null, sources: undated }] });
      return sorted;
    }

    function renderCalendar(grouped) {
      const container = $('#sources-calendar');
      container.innerHTML = '';
      const monthFmt = new Intl.DateTimeFormat(undefined, { month: 'long', year: 'numeric' });
      const dayFmt = new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric' });
      for (const month of grouped) {
        const m = document.createElement('div');
        m.className = 'month';
        const head = document.createElement('div');
        head.className = 'month-head';
        head.textContent = month.date ? monthFmt.format(month.date) : 'No recording date';
        m.appendChild(head);
        for (const day of month.days) {
          const d = document.createElement('div');
          d.className = 'day';
          const dh = document.createElement('div');
          dh.className = 'day-head';
          dh.textContent = day.date ? dayFmt.format(day.date) : 'Unknown day';
          const count = document.createElement('span');
          count.textContent = `${day.sources.length} clip${day.sources.length === 1 ? '' : 's'}`;
          dh.appendChild(count);
          d.appendChild(dh);
          const grid = document.createElement('div');
          grid.className = 'grid';
          day.sources.forEach(s => grid.appendChild(sourceCard(s)));
          d.appendChild(grid);
          m.appendChild(d);
        }
        container.appendChild(m);
      }
    }

    // ----- Pane loaders -----
    async function loadSources() {
      const status = $('#sources-status');
      try {
        const sources = await api('/api/sources?limit=500');
        if (sources.length === 0) {
          status.textContent = 'No sources yet. Add a folder in the Mac app.';
          $('#sources-calendar').innerHTML = '';
          return;
        }
        status.textContent = `${sources.length} source${sources.length === 1 ? '' : 's'}`;
        renderCalendar(groupByCalendar(sources));
      } catch (e) {
        if (e.message !== 'unauthorized') status.textContent = 'Failed: ' + e.message;
      }
    }

    async function loadClips() {
      const grid = $('#clips-grid');
      const status = $('#clips-status');
      try {
        const clips = await api('/api/clips?limit=300');
        grid.innerHTML = '';
        if (clips.length === 0) {
          status.textContent = 'No clips yet. Mark some in the Mac app or in a source detail here.';
          return;
        }
        status.textContent = `${clips.length} clip${clips.length === 1 ? '' : 's'}`;
        clips.forEach(c => grid.appendChild(clipRow(c)));
      } catch (e) {
        if (e.message !== 'unauthorized') status.textContent = 'Failed: ' + e.message;
      }
    }

    let currentSource = null;
    async function openSourceDetail(src) {
      currentSource = src;
      // Warm the proxy in the background so it's likely ready by the time the
      // user taps "Open player" — fire-and-forget, ignore the result.
      api(`/api/sources/${src.id}/proxy-status`).catch(() => {});
      switchTab('source-detail-pane');
      $('#source-detail-title').textContent = src.name;
      $('#source-detail-meta').textContent = `${src.width || '?'}×${src.height || '?'} · ${src.fps ? Math.round(src.fps) + 'fps' : ''} · ${formatDuration(src.durationMs)}`;
      const grid = $('#source-clips-grid');
      grid.innerHTML = '<div class="empty">Loading clips…</div>';
      try {
        const clips = await api(`/api/sources/${src.id}/clips`);
        grid.innerHTML = '';
        if (clips.length === 0) {
          grid.innerHTML = '<div class="empty">No clips saved from this source yet.</div>';
          return;
        }
        clips.forEach(c => grid.appendChild(clipRow(c)));
      } catch (e) {
        if (e.message !== 'unauthorized') grid.innerHTML = '<div class="empty">Failed to load clips.</div>';
      }
    }

    $('#open-player').addEventListener('click', () => {
      if (currentSource) openPlayer(currentSource);
    });

    // ----- Search -----
    let searchTimer = null;
    $('#search').addEventListener('input', () => {
      clearTimeout(searchTimer);
      const q = $('#search').value.trim();
      if (!q) {
        if (document.querySelector('.tab[data-tab="sources"]').classList.contains('active')) {
          switchTab('sources-pane');
        }
        return;
      }
      searchTimer = setTimeout(() => runSearch(q), 220);
    });

    async function runSearch(q) {
      switchTab('search-pane');
      $('#search-title').textContent = `Results for "${escapeHTML(q)}"`;
      const sg = $('#search-sources-grid');
      const cg = $('#search-clips-grid');
      sg.innerHTML = '<div class="empty">Searching…</div>';
      cg.innerHTML = '';
      try {
        const res = await api(`/api/search?q=${encodeURIComponent(q)}`);
        sg.innerHTML = '';
        cg.innerHTML = '';
        if (!res.sources.length) sg.innerHTML = '<div class="empty">No sources.</div>';
        else res.sources.forEach(s => sg.appendChild(sourceCard(s)));
        if (!res.clips.length) cg.innerHTML = '<div class="empty">No clips.</div>';
        else res.clips.forEach(c => cg.appendChild(clipRow(c)));
      } catch (e) {
        if (e.message !== 'unauthorized') sg.innerHTML = '<div class="empty">Search failed.</div>';
      }
    }

    // ----- Player modal: stream + mark in/out + save -----
    let playerSource = null;
    let inMs = null, outMs = null;

    const sleep = (ms) => new Promise(r => setTimeout(r, ms));
    function showPrep(title, sub) {
      $('#player-prep-text').textContent = title;
      $('#player-prep-sub').textContent = sub || '';
      $('#player-prep').classList.remove('hidden');
    }
    function hidePrep() { $('#player-prep').classList.add('hidden'); }

    // The server streams a compressed proxy, not the raw source. The first time
    // a source is opened it has to be transcoded, so poll until it's ready.
    async function waitForProxy(id) {
      for (let i = 0; i < 900; i++) { // ~30 min ceiling at 2s/poll
        if ($('#player-modal').classList.contains('hidden')) return false;
        try {
          const s = await api(`/api/sources/${id}/proxy-status`);
          if (s.offline) { showPrep('Source drive is offline', 'Reconnect it on the Mac.'); return false; }
          if (s.ready) return true;
          showPrep('Preparing a smooth, compressed version…', (s.progress || 0) + '%');
        } catch (e) {
          if (e.message === 'unauthorized') return false;
          // transient network hiccup — keep polling
        }
        await sleep(2000);
      }
      showPrep('Still preparing — close and try again shortly.', '');
      return false;
    }

    async function openPlayer(src) {
      playerSource = src;
      inMs = null; outMs = null;
      updateMarksDisplay();
      $('#player-title').textContent = src.name;
      const video = $('#player-video');
      video.removeAttribute('src');
      video.load();
      $('#player-modal').classList.remove('hidden');
      showPrep('Preparing a smooth, compressed version…', '');
      requestAnimationFrame(updatePlayhead);

      const ready = await waitForProxy(src.id);
      // Bail if the user closed the player or opened a different source while
      // we were waiting.
      if (!ready || !playerSource || playerSource.id !== src.id) return;
      hidePrep();
      // Token in querystring as fallback — <video> can't set Authorization
      // headers; the server also accepts ?token= when Authorization is absent.
      video.src = `/api/sources/${src.id}/video?token=${encodeURIComponent(token)}`;
      video.load();
      video.play().catch(() => { /* autoplay may be blocked, that's ok */ });
    }

    function closePlayer() {
      const video = $('#player-video');
      video.pause();
      video.removeAttribute('src');
      video.load();
      hidePrep();
      $('#player-modal').classList.add('hidden');
      playerSource = null;
    }
    $('#player-close').addEventListener('click', closePlayer);

    function currentVideoMs() {
      const video = $('#player-video');
      return Math.floor(video.currentTime * 1000);
    }
    function durationMs() {
      const video = $('#player-video');
      return Math.floor((video.duration || 0) * 1000);
    }

    function updatePlayhead() {
      if (!playerSource) return;
      const total = durationMs();
      if (total > 0) {
        const ph = $('#player-playhead');
        ph.style.left = (currentVideoMs() / total * 100) + '%';
        const range = $('#player-range');
        if (inMs !== null) {
          const startPct = inMs / total * 100;
          const endPct = (outMs !== null ? outMs : currentVideoMs()) / total * 100;
          range.style.left = startPct + '%';
          range.style.width = Math.max(0, endPct - startPct) + '%';
          range.style.display = 'block';
        } else {
          range.style.display = 'none';
        }
      }
      requestAnimationFrame(updatePlayhead);
    }

    function updateMarksDisplay() {
      const el = $('#player-marks');
      if (inMs === null && outMs === null) {
        el.textContent = 'No marks set — tap Mark In to start';
      } else {
        const inLabel = inMs !== null ? formatMs(inMs) : '—';
        const outLabel = outMs !== null ? formatMs(outMs) : '—';
        const dur = (inMs !== null && outMs !== null && outMs > inMs) ? ' (' + formatMs(outMs - inMs) + ')' : '';
        el.textContent = `In ${inLabel}  →  Out ${outLabel}${dur}`;
      }
    }

    $('#btn-mark-in').addEventListener('click', () => {
      inMs = currentVideoMs();
      if (outMs !== null && outMs <= inMs) outMs = null;
      updateMarksDisplay();
    });
    $('#btn-mark-out').addEventListener('click', () => {
      outMs = currentVideoMs();
      if (inMs === null || outMs <= inMs) {
        alert('Mark In first, then move forward and Mark Out.');
        outMs = null;
      }
      updateMarksDisplay();
    });
    $('#btn-back-5').addEventListener('click', () => { $('#player-video').currentTime = Math.max(0, $('#player-video').currentTime - 5); });
    $('#btn-fwd-5').addEventListener('click', () => { $('#player-video').currentTime = Math.min(durationMs()/1000, $('#player-video').currentTime + 5); });
    $('#btn-save').addEventListener('click', async () => {
      if (inMs === null || outMs === null || outMs <= inMs) {
        alert('Mark in and out first.');
        return;
      }
      try {
        await api(`/api/sources/${playerSource.id}/clips`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ inMs, outMs }),
        });
        const dur = formatMs(outMs - inMs);
        $('#player-marks').textContent = `Saved ${dur} clip ✓`;
        inMs = null; outMs = null;
        // Refresh the clips list under the source detail.
        if (currentSource && currentSource.id === playerSource.id) openSourceDetail(currentSource);
      } catch (e) {
        alert('Save failed: ' + e.message);
      }
    });

    // Click timeline to seek.
    $('#player-range').parentElement.addEventListener('click', (e) => {
      const rect = e.currentTarget.getBoundingClientRect();
      const frac = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
      const video = $('#player-video');
      if (video.duration) video.currentTime = video.duration * frac;
    });

    // Keyboard shortcuts when player visible (laptop only realistically).
    document.addEventListener('keydown', (e) => {
      if ($('#player-modal').classList.contains('hidden')) return;
      if (e.target.tagName === 'INPUT') return;
      const video = $('#player-video');
      if (e.key === ' ') { e.preventDefault(); video.paused ? video.play() : video.pause(); }
      else if (e.key.toLowerCase() === 'i') $('#btn-mark-in').click();
      else if (e.key.toLowerCase() === 'o') $('#btn-mark-out').click();
      else if (e.key.toLowerCase() === 's') $('#btn-save').click();
      else if (e.key === 'j' || e.key === 'ArrowLeft') $('#btn-back-5').click();
      else if (e.key === 'l' || e.key === 'ArrowRight') $('#btn-fwd-5').click();
      else if (e.key === 'Escape') closePlayer();
    });

    // ----- Tabs -----
    function switchTab(paneID) {
      $$('.pane').forEach(p => p.classList.remove('active'));
      $(`#${paneID}`).classList.add('active');
      $$('.tab').forEach(t => t.classList.remove('active'));
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
    $('#source-detail-back').addEventListener('click', () => switchTab('sources-pane'));

    // ----- Boot -----
    if (!token) showPairGate();
    else loadSources();
    """
}
