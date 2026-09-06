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
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <meta name="theme-color" content="#0a0a0a">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <title>Clipx</title>
      <link rel="stylesheet" href="/app.css">
    </head>
    <body>
      <!-- Pair gate — covers everything until a PIN is accepted. -->
      <dialog id="pair-gate" class="pair-gate hidden" aria-labelledby="pair-title">
        <div class="pair-card">
          <h1 id="pair-title">Pair with Clipx</h1>
          <p>Open the Mac app, go to Settings → Remote, and read the 6-digit PIN.</p>
          <label class="sr-only" for="pair-input">Six-digit pairing PIN</label>
          <input id="pair-input" inputmode="numeric" pattern="[0-9]*" maxlength="6" autocomplete="off" placeholder="000000">
          <button id="pair-submit" class="primary">Pair</button>
          <div id="pair-error" class="error" role="alert"></div>
        </div>
      </dialog>

      <header class="topbar">
        <h1>Clipx <span class="remote-label">Remote</span></h1>
        <label class="sr-only" for="search">Search your library</label>
        <input id="search" type="search" placeholder="Search sources, clips, notes…">
        <nav class="tabs" aria-label="Library views">
          <button class="tab active" data-tab="sources">Sources</button>
          <button class="tab" data-tab="clips">Clips</button>
        </nav>
      </header>
      <main>
        <section id="sources-pane" class="pane active">
          <div class="status" role="status" id="sources-status">Loading…</div>
          <div id="sources-calendar"></div>
          <button id="sources-more" class="load-more hidden">Load more sources</button>
        </section>
        <section id="clips-pane" class="pane">
          <div class="status" role="status" id="clips-status">Loading…</div>
          <div class="grid clip-grid" id="clips-grid"></div>
          <button id="clips-more" class="load-more hidden">Load more clips</button>
        </section>
        <section id="search-pane" class="pane">
          <h2 id="search-title">Search results</h2>
          <h3>Sources</h3>
          <div class="grid" id="search-sources-grid"><div class="empty">—</div></div>
          <h3>Clips</h3>
          <div class="grid clip-grid" id="search-clips-grid"><div class="empty">—</div></div>
          <button id="search-more" class="load-more hidden">Load more results</button>
        </section>
        <section id="source-detail-pane" class="pane">
          <button class="back" id="source-detail-back">&larr; Back</button>
          <h2 id="source-detail-title"></h2>
          <div id="source-detail-meta" class="sub"></div>
          <button id="open-player" class="primary">Open player</button>
          <h3>Clips from this source</h3>
          <div class="grid clip-grid" id="source-clips-grid"></div>
        </section>
      </main>

      <!-- Video player modal: <video> + scrubber + in/out + save -->
      <dialog id="player-modal" class="modal hidden" aria-labelledby="player-title">
        <div class="modal-head">
          <button id="player-close" aria-label="Close player">&times;</button>
          <span id="player-title"></span>
        </div>
        <div class="video-stage">
        <video id="player-video" playsinline controls preload="auto"></video>
        <div id="player-prep" class="prep hidden">
          <div class="spinner"></div>
          <div id="player-prep-text" role="status">Preparing…</div>
          <div id="player-prep-sub" class="prep-sub"></div>
          <button id="player-retry" class="primary hidden">Try again</button>
        </div>
        </div>
        <div class="player-controls">
          <div class="timeline" role="slider" tabindex="0" aria-label="Playback position" aria-valuemin="0" aria-valuemax="0" aria-valuenow="0">
            <div class="range" id="player-range"></div>
            <div class="playhead" id="player-playhead"></div>
          </div>
          <div class="player-buttons">
            <button disabled id="btn-back-5">&laquo; 5s</button>
            <button disabled id="btn-mark-in" title="Mark In (I)">Mark In</button>
            <button disabled id="btn-mark-out" title="Mark Out (O)">Mark Out</button>
            <button disabled id="btn-fwd-5">5s &raquo;</button>
            <button disabled id="btn-save" class="primary">Save Clip</button>
          </div>
          <div class="player-marks" id="player-marks" role="status">No marks set</div>
        </div>
      </dialog>

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
    .pair-gate { margin: 0; width: 100%; height: 100dvh; max-width: none; max-height: none; border: 0; color: var(--text); position: fixed; inset: 0; background: var(--bg); z-index: 100; display: flex; align-items: center; justify-content: center; padding: 24px; }
    .pair-card { background: var(--panel); border: 1px solid #2a2a2a; border-radius: var(--radius); padding: 24px; max-width: 360px; width: 100%; text-align: center; }
    .pair-card h1 { margin: 0 0 12px; font-size: 20px; }
    .pair-card p { color: var(--muted); margin: 0 0 18px; font-size: 14px; line-height: 1.5; }
    .pair-card input { width: 100%; font-size: 32px; text-align: center; padding: 12px; background: var(--panel-2); border: 1px solid #333; color: var(--text); border-radius: var(--radius-sm); letter-spacing: 0.4em; font-family: ui-monospace, monospace; margin-bottom: 12px; }
    .pair-card input:focus { outline: 2px solid var(--accent); }
    .pair-card .primary { width: 100%; padding: 12px; background: var(--accent); color: white; border: 0; border-radius: var(--radius-sm); font-size: 16px; font-weight: 500; cursor: pointer; }
    .error { color: var(--danger); font-size: 13px; min-height: 1em; margin-top: 8px; }
    /* Topbar */
    .topbar { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 12px; padding: max(12px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right)) 12px max(16px, env(safe-area-inset-left)); background: var(--panel); border-bottom: 1px solid #2a2a2a; position: sticky; top: 0; z-index: 10; }
    .remote-label { color: var(--muted); font-size: 12px; font-weight: 400; margin-left: 6px; }
    .topbar h1 { margin: 0; font-size: 17px; letter-spacing: 0.2px; }
    .topbar input[type="search"] { padding: 8px 12px; background: var(--panel-2); border: 1px solid #2a2a2a; color: var(--text); border-radius: var(--radius-sm); font: inherit; min-width: 0; }
    .topbar input[type="search"]:focus { outline: 1px solid var(--accent); border-color: transparent; }
    @media (max-width: 540px) {
      .topbar { grid-template-columns: 1fr auto; }
      .remote-label { color: var(--muted); font-size: 12px; font-weight: 400; margin-left: 6px; }
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
    .card { padding: 0; color: var(--text); font: inherit; text-align: left; background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); overflow: hidden; display: flex; flex-direction: column; cursor: pointer; }
    .card:hover { border-color: #454545; }
    .card:active { transform: scale(0.98); }
    .card .thumb { background: var(--panel-2); aspect-ratio: 16 / 9; position: relative; overflow: hidden; }
    .card .thumb img { width: 100%; height: 100%; object-fit: cover; display: block; }
    /* Hover-scrub sprite overlay. The strip is 10 frames laid side by side, so
       background-size: 1000% makes one frame exactly fill the 16/9 thumb;
       background-position-x then steps between frames. pointer-events: none so
       mousemove still hits .thumb (which carries the scrub listener). */
    .card .thumb .sprite { position: absolute; inset: 0; background-repeat: no-repeat; background-size: 1000% 100%; background-position: 0 0; opacity: 0; pointer-events: none; transition: opacity 0.12s ease; }
    .card .thumb .sprite.active { opacity: 1; }
    .card .thumb .badge { position: absolute; bottom: 6px; right: 6px; background: rgba(0,0,0,0.75); color: white; font-size: 11px; padding: 2px 6px; border-radius: 999px; font-variant-numeric: tabular-nums; }
    .card .thumb .badge.left { left: 6px; right: auto; }
    .card .meta { padding: 8px 10px; }
    .card .meta .name { display: block; font-size: 13px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .card .meta .sub { display: block; font-size: 11px; color: var(--muted); margin-top: 2px; }
    /* Calendar grouping */
    .month { margin-bottom: 18px; }
    .month-head { font-size: 14px; font-weight: 600; padding: 12px 4px 6px; position: sticky; top: var(--topbar-height, 64px); background: var(--bg); }
    .day { margin-bottom: 12px; }
    .day-head { display: flex; align-items: baseline; gap: 8px; padding: 8px 4px; color: var(--muted); font-size: 12px; }
    /* Clip rows */
    .clip-row { display: flex; gap: 10px; padding: 10px; background: var(--panel); border: 1px solid #232323; border-radius: var(--radius); align-items: center; }
    .clip-row .thumb { width: 88px; aspect-ratio: 16 / 9; flex-shrink: 0; border-radius: var(--radius-sm); overflow: hidden; background: var(--panel-2); }
    .clip-row .thumb img { width: 100%; height: 100%; object-fit: cover; }
    .clip-row .info { flex: 1; min-width: 0; }
    .clip-row .info .name { font-size: 14px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .clip-row .info .sub { margin-bottom: 0; font-size: 11px; color: var(--muted); margin-top: 2px; }
    .clip-row .rate { display: flex; gap: 3px; margin-top: 4px; }
    .clip-row .rate button { background: transparent; border: 0; color: #929292; min-width: 32px; min-height: 40px; padding: 5px; font-size: 18px; cursor: pointer; line-height: 1; }
    .clip-row .rate button.filled { color: #ffcd3a; }
    .clip-preview { position: relative; padding: 0; border: 0; color: white; font: inherit; cursor: pointer; }
    .preview-icon { position: absolute; top: 50%; left: 50%; translate: -50% -50%; display: grid; place-items: center; width: 28px; height: 28px; border-radius: 50%; background: rgba(0,0,0,.65); font-size: 12px; padding-left: 2px; }
    .clip-row .info { overflow: hidden; }
    /* Modal player */
    .modal { margin: 0; width: 100%; height: 100dvh; max-width: none; max-height: none; border: 0; padding: 0; color: var(--text); position: fixed; inset: 0; background: #080808; z-index: 50; display: flex; flex-direction: column; }
    .modal-head { flex-shrink: 0; display: flex; align-items: center; gap: 12px; padding: max(12px, env(safe-area-inset-top)) 16px 12px; }
    .modal-head button { background: transparent; color: white; border: 0; font-size: 26px; cursor: pointer; min-width: 44px; min-height: 44px; line-height: 1; }
    .modal-head span { font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; flex: 1; }
    .video-stage { position: relative; flex: 1; min-height: 0; display: flex; }
    #player-video { width: 100%; height: 100%; flex: 1; min-height: 0; background: black; object-fit: contain; }
    .player-controls { background: var(--panel); padding: 12px 14px max(12px, env(safe-area-inset-bottom)); flex-shrink: 0; border-top: 1px solid #2a2a2a; }
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
    .prep.terminal .spinner { display: none; }
    .prep .spinner { width: 38px; height: 38px; border-radius: 50%; border: 3px solid rgba(255,255,255,0.18); border-top-color: var(--accent); animation: spin 0.8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
    button:disabled { opacity: 0.5; cursor: default; }
    button:focus-visible, [tabindex]:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
    .load-more { display: block; margin: 24px auto; min-height: 44px; padding: 10px 20px; color: var(--text); background: var(--panel-2); border: 1px solid #333; border-radius: var(--radius-sm); font: inherit; }
    .clip-grid { grid-template-columns: repeat(auto-fill, minmax(min(100%, 320px), 1fr)); }
    @media (max-width: 390px) { .grid:not(.clip-grid) { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; } .player-buttons { grid-template-columns: repeat(4, 1fr); } #btn-save { grid-column: 1 / -1; } }
    @media (prefers-reduced-motion: reduce) { .prep .spinner { animation: none; } .sprite { transition: none !important; } }
    #player-prep-text { font-size: 15px; font-weight: 500; }
    .prep .prep-sub { font-size: 13px; color: var(--muted); font-variant-numeric: tabular-nums; }
    """

    static let appJS = """
    const $ = (sel) => document.querySelector(sel);
    const $$ = (sel) => Array.from(document.querySelectorAll(sel));

    // ----- Auth -----
    const TOKEN_KEY = 'clipxToken';
    let token = localStorage.getItem(TOKEN_KEY) || '';

    // Carry the session in a same-origin cookie so <video>/<img> requests
    // authenticate without putting the token in the URL. (#6)
    function setSessionCookie(t) {
      document.cookie = 'clipx_session=' + t + '; path=/; SameSite=Strict; max-age=' + (t ? 2592000 : 0);
    }

    async function api(path, opts = {}) {
      const headers = Object.assign({}, opts.headers || {});
      if (token) headers['Authorization'] = `Bearer ${token}`;
      const res = await fetch(path, Object.assign({}, opts, { headers }));
      if (res.status === 401) {
        token = '';
        localStorage.removeItem(TOKEN_KEY);
        setSessionCookie('');
        closePlayer();
        showPairGate();
        throw new Error('unauthorized');
      }
      if (!res.ok) {
        const body = await res.json().catch(() => null);
        throw new Error(body?.error || `${res.status} ${res.statusText}`);
      }
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('application/json')) return res.json();
      return res;
    }

    function showPairGate() { const gate = $('#pair-gate'); gate.classList.remove('hidden'); if (!gate.open) gate.showModal(); $('#pair-input').focus(); }
    function hidePairGate() { $('#pair-gate').close(); $('#pair-gate').classList.add('hidden'); }
    $('#pair-gate').addEventListener('cancel', e => e.preventDefault());

    $('#pair-submit').addEventListener('click', pair);
    $('#pair-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') pair(); });

    async function pair() {
      const pin = $('#pair-input').value.trim();
      $('#pair-error').textContent = '';
      if (!/^[0-9]{6}$/.test(pin)) {
        $('#pair-error').textContent = 'PIN should be 6 digits';
        return;
      }
      $('#pair-submit').disabled = true;
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
        setSessionCookie(token);
        hidePairGate();
        loadSources();
      } catch (e) {
        $('#pair-error').textContent = 'Could not reach the Mac. Check that both devices are on the same network.';
      } finally { $('#pair-submit').disabled = false; }
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
    function spriteURL(hash) { return hash ? `/api/sprite/${hash}.jpg` : ''; }

    // ----- Hover-scrub sprites -----
    // The server hands back a horizontal strip of SPRITE_FRAMES frames (240×135
    // each). Mapping the cursor's x-fraction to a frame index lets a card
    // preview the whole clip on hover. Sprites aren't pre-generated, so the
    // first request may 202 while the strip renders — we poll, then cache the
    // decoded blob URL per hash so subsequent hovers are instant.
    const SPRITE_FRAMES = 10;
    const spriteCache = new Map(); // hash -> { promise, controller, url }
    const SPRITE_CACHE_LIMIT = 48;
    function releaseSprite(hash) {
      const entry = spriteCache.get(hash);
      if (!entry) return;
      entry.controller.abort();
      if (entry.url) URL.revokeObjectURL(entry.url);
      spriteCache.delete(hash);
    }
    function clearSprites() { [...spriteCache.keys()].forEach(releaseSprite); }
    window.addEventListener('pagehide', clearSprites);

    function loadSprite(hash) {
      if (!hash) return Promise.resolve(null);
      if (spriteCache.has(hash)) {
        const entry = spriteCache.get(hash);
        spriteCache.delete(hash); spriteCache.set(hash, entry);
        return entry.promise;
      }
      while (spriteCache.size >= SPRITE_CACHE_LIMIT) releaseSprite(spriteCache.keys().next().value);
      const entry = { controller: new AbortController(), url: null, promise: null };
      entry.promise = (async () => {
        try {
          for (let i = 0; i < 40; i++) {
            const res = await fetch(spriteURL(hash), { signal: entry.controller.signal });
            if (res.status === 200) {
              const blob = await res.blob();
              if (entry.controller.signal.aborted) return null;
              entry.url = URL.createObjectURL(blob);
              return entry.url;
            }
            if (res.status !== 202) return null;
            await sleep(1500, entry.controller.signal);
          }
        } catch (_) { /* Retry is available on the next hover. */ }
        return null;
      })().then(url => {
        if (!url && spriteCache.get(hash) === entry) spriteCache.delete(hash);
        return url;
      });
      spriteCache.set(hash, entry);
      return entry.promise;
    }

    // Wire hover-scrub onto a card's .thumb (which must contain a .sprite div).
    function attachHoverScrub(thumbEl, hash) {
      if (!thumbEl) return;
      const spriteEl = thumbEl.querySelector('.sprite');
      if (!spriteEl) return;
      let ready = false, hovering = false, currentSpriteURL = null;
      thumbEl.addEventListener('mouseenter', () => {
        hovering = true;
        if (ready && spriteCache.get(hash)?.url === currentSpriteURL) return;
        ready = false;
        loadSprite(hash).then(objURL => {
          if (!objURL || !thumbEl.isConnected) return;
          spriteEl.style.backgroundImage = `url(${objURL})`;
          currentSpriteURL = objURL; ready = true;
          if (hovering) spriteEl.classList.add('active');
        });
      });
      thumbEl.addEventListener('mousemove', (e) => {
        if (!ready) return;
        const rect = thumbEl.getBoundingClientRect();
        if (rect.width <= 0) return;
        const frac = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const idx = Math.min(SPRITE_FRAMES - 1, Math.floor(frac * SPRITE_FRAMES));
        spriteEl.style.backgroundPositionX = (idx / (SPRITE_FRAMES - 1) * 100) + '%';
        spriteEl.classList.add('active');
      });
      thumbEl.addEventListener('mouseleave', () => {
        hovering = false;
        spriteEl.classList.remove('active');
      });
    }

    function sourceCard(src) {
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'card';
      card.setAttribute('aria-label', `Open ${src.name}`);
      card.innerHTML = `
        <span class="thumb">
          ${src.hash ? `<img alt="" loading="lazy" src="${thumbURL(src.hash)}" onerror="this.style.display='none'">` : ''}
          ${src.hash ? `<span class="sprite" aria-hidden="true"></span>` : ''}
          ${src.durationMs ? `<span class="badge left">${formatDuration(src.durationMs)}</span>` : ''}
          ${src.width && src.height ? `<span class="badge">${src.width}×${src.height}</span>` : ''}
        </span>
        <span class="meta">
          <span class="name">${escapeHTML(src.name)}</span>
          <span class="sub">${src.fps ? Math.round(src.fps) + 'p' : ''}${src.online ? '' : ' · offline'}</span>
        </span>
      `;
      if (src.hash) attachHoverScrub(card.querySelector('.thumb'), src.hash);
      card.addEventListener('click', () => openSourceDetail(src));
      return card;
    }

    function clipRow(clip) {
      const row = document.createElement('div');
      row.className = 'clip-row';
      const stars = [1,2,3,4,5].map(n => `<button data-rating="${n}" aria-label="Rate ${n} star${n === 1 ? '' : 's'}" aria-pressed="${n === clip.rating}" class="${n <= clip.rating ? 'filled' : ''}">★</button>`).join('');
      row.innerHTML = `
        <button class="thumb clip-preview" aria-label="Play ${escapeHTML(clip.name || clip.sourceName)}">${clip.sourceHash ? `<img alt="" loading="lazy" src="${thumbURL(clip.sourceHash)}" onerror="this.style.display='none'">` : ''}<span class="preview-icon" aria-hidden="true">▶</span></button>
        <div class="info">
          <div class="name">${escapeHTML(clip.name || clip.sourceName)}</div>
          <div class="sub">${formatDuration(clip.durationMs)} · ${escapeHTML(clip.sourceName)}${clip.mood ? ' · ' + escapeHTML(clip.mood) : ''}</div>
          <div class="rate" aria-label="Clip rating">${stars}</div>
        </div>
      `;
      row.querySelector('.clip-preview').addEventListener('click', async e => {
        const button = e.currentTarget, owner = ++clipOpenRequest, pane = activePane;
        button.disabled = true; button.setAttribute('aria-busy', 'true');
        button.querySelector('.preview-icon').textContent = '…';
        try {
          const src = await api(`/api/sources/${clip.sourceID}`);
          if (owner !== clipOpenRequest || activePane !== pane) return;
          openPlayer(src, false, clip);
        } catch (error) {
          if (owner === clipOpenRequest && activePane === pane) {
            let error = row.querySelector('.error');
            if (!error) { error = document.createElement('div'); error.className = 'error'; error.setAttribute('role', 'alert'); row.querySelector('.info').appendChild(error); }
            error.textContent = 'Could not open the clip. Try again.';
          }
          return;
        } finally {
          button.disabled = false; button.removeAttribute('aria-busy');
          button.querySelector('.preview-icon').textContent = '▶';
        }
      });
      row.querySelectorAll('.rate button').forEach(btn => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          if (row.dataset.saving) return;
          row.dataset.saving = 'true';
          const chosen = parseInt(btn.dataset.rating, 10);
          const rating = chosen === clip.rating ? 0 : chosen;
          row.querySelectorAll('.rate button').forEach(b => b.disabled = true);
          try {
            row.querySelector('.error')?.remove();
            await api(`/api/clips/${clip.id}/rating`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ rating })
            });
            clip.rating = rating;
            row.querySelectorAll('.rate button').forEach((b, idx) => {
              b.classList.toggle('filled', idx < rating);
              b.setAttribute('aria-pressed', String(idx + 1 === rating));
            });
          } catch (err) {
            let error = row.querySelector('.error');
            if (!error) { error = document.createElement('div'); error.className = 'error'; error.setAttribute('role', 'alert'); row.querySelector('.info').appendChild(error); }
            error.textContent = 'Rating could not be saved. Try again.';
          } finally {
            delete row.dataset.saving;
            row.querySelectorAll('.rate button').forEach(b => b.disabled = false);
          }
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
          count.textContent = `${day.sources.length} source${day.sources.length === 1 ? '' : 's'}`;
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

    // ----- Pane loaders and request ownership -----
    const PAGE_SIZE = 100;
    let activePane = 'sources-pane', paneBeforeSearch = 'sources-pane';
    let detailReturnPane = 'sources-pane', detailReturnFocus = null;
    let currentSource = null, detailRequest = 0, detailController = null, clipOpenRequest = 0;
    const lists = {
      sources: { items: [], offset: 0, more: true, request: 0, controller: null },
      clips: { items: [], offset: 0, more: true, request: 0, controller: null }
    };
    function mergeItems(old, rows) { return [...new Map([...old, ...rows].map(row => [row.id, row])).values()]; }
    async function loadList(kind, append = false) {
      const state = lists[kind], id = ++state.request;
      state.controller?.abort();
      state.controller = new AbortController();
      const offset = append ? state.offset : 0;
      const status = $(`#${kind}-status`), button = $(`#${kind}-more`);
      button.disabled = true;
      status.textContent = append ? `Loading more ${kind}…` : `Loading ${kind}…`;
      try {
        const rows = await api(`/api/${kind}?limit=${PAGE_SIZE}&offset=${offset}`, { signal: state.controller.signal });
        if (id !== state.request) return;
        state.items = mergeItems(append ? state.items : [], rows);
        state.offset = offset + rows.length;
        state.more = rows.length === PAGE_SIZE;
        status.textContent = state.items.length
          ? `${state.items.length} ${kind}${state.more ? ' · More available below' : ''}`
          : (kind === 'sources' ? 'No sources yet. Add a folder in the Mac app.' : 'No saved clips yet. Open a source and mark a range to save your first clip.');
        if (kind === 'sources') renderCalendar(groupByCalendar(state.items));
        else {
          const grid = $('#clips-grid'); grid.innerHTML = '';
          state.items.forEach(c => grid.appendChild(clipRow(c)));
        }
        button.classList.toggle('hidden', !state.more);
        button.textContent = `Load more ${kind}`;
      } catch (e) {
        if (id !== state.request || e.name === 'AbortError' || e.message === 'unauthorized') return;
        status.textContent = `Could not load ${kind}. Check the connection to your Mac and try again.`;
        button.classList.remove('hidden'); button.textContent = 'Try again';
      } finally { if (id === state.request) button.disabled = false; }
    }
    function loadSources(append = false) { return loadList('sources', append); }
    function loadClips(append = false) { return loadList('clips', append); }
    $('#sources-more').addEventListener('click', () => loadSources(true));
    $('#clips-more').addEventListener('click', () => loadClips(true));

    async function openSourceDetail(src, refresh = false) {
      const id = ++detailRequest;
      detailController?.abort(); detailController = new AbortController();
      if (!refresh && activePane !== 'source-detail-pane') { detailReturnPane = activePane; detailReturnFocus = document.activeElement; }
      currentSource = src;
      switchTab('source-detail-pane');
      $('#source-detail-title').textContent = src.name;
      $('#source-detail-meta').textContent = `${src.width || '?'}×${src.height || '?'} · ${src.fps ? Math.round(src.fps) + 'fps · ' : ''}${formatDuration(src.durationMs)}${src.speed !== 1 ? ' · ' + src.speed + '× playback' : ''}${src.online ? '' : ' · Offline'}`;
      const grid = $('#source-clips-grid');
      if (!refresh) grid.innerHTML = '<div class="empty">Loading clips…</div>';
      try {
        const clips = await api(`/api/sources/${src.id}/clips`, { signal: detailController.signal });
        if (id !== detailRequest || currentSource?.id !== src.id) return;
        grid.innerHTML = '';
        if (!clips.length) grid.innerHTML = '<div class="empty">No clips saved yet. Open the player to mark your first range.</div>';
        clips.forEach(c => grid.appendChild(clipRow(c)));
      } catch (e) {
        if (id === detailRequest && e.name !== 'AbortError' && e.message !== 'unauthorized') grid.innerHTML = '<div class="empty">Could not load clips. Reopen this source to try again.</div>';
      }
    }
    $('#open-player').addEventListener('click', () => { if (currentSource) openPlayer(currentSource); });

    // Clearing search restores the pane that owned it. Every input invalidates
    // previous requests immediately, including during the debounce interval.
    let searchTimer = null, searchRequest = 0, searchController = null;
    let searchOffset = 0, searchSources = [], searchClips = [];
    function cancelSearch() {
      clearTimeout(searchTimer); ++searchRequest; searchController?.abort();
    }
    $('#search').addEventListener('input', () => {
      cancelSearch();
      const q = $('#search').value.trim();
      if (!q) { switchTab(paneBeforeSearch); return; }
      if (activePane !== 'search-pane') paneBeforeSearch = activePane;
      switchTab('search-pane');
      const owner = searchRequest;
      searchTimer = setTimeout(() => runSearch(q, false, owner), 220);
    });

    async function runSearch(q, append = false, owner = searchRequest) {
      if (owner !== searchRequest || activePane !== 'search-pane') return;
      searchController?.abort();
      const controller = new AbortController(); searchController = controller;
      $('#search-title').textContent = `Results for "${q}"`;
      const sg = $('#search-sources-grid'), cg = $('#search-clips-grid'), button = $('#search-more');
      button.disabled = true;
      if (!append) {
        searchSources = []; searchClips = []; searchOffset = 0;
        sg.innerHTML = '<div class="empty">Searching…</div>'; cg.innerHTML = '';
        button.classList.add('hidden');
      }
      try {
        const res = await api(`/api/search?q=${encodeURIComponent(q)}&limit=${PAGE_SIZE}&offset=${searchOffset}`, { signal: controller.signal });
        if (owner !== searchRequest || q !== $('#search').value.trim() || activePane !== 'search-pane') return;
        searchOffset += PAGE_SIZE;
        searchSources = mergeItems(searchSources, res.sources); searchClips = mergeItems(searchClips, res.clips);
        sg.innerHTML = ''; cg.innerHTML = '';
        if (!searchSources.length) sg.innerHTML = '<div class="empty">No matching sources.</div>';
        else searchSources.forEach(s => sg.appendChild(sourceCard(s)));
        if (!searchClips.length) cg.innerHTML = '<div class="empty">No matching clips.</div>';
        else searchClips.forEach(c => cg.appendChild(clipRow(c)));
        button.classList.toggle('hidden', res.sources.length < PAGE_SIZE && res.clips.length < PAGE_SIZE);
        button.textContent = 'Load more results';
      } catch (e) {
        if (owner === searchRequest && activePane === 'search-pane' && e.name !== 'AbortError' && e.message !== 'unauthorized') {
          sg.innerHTML = '<div class="empty">Search could not be completed. Try again.</div>';
          button.classList.remove('hidden'); button.textContent = 'Try again';
        }
      } finally { if (owner === searchRequest && searchController === controller) button.disabled = false; }
    }
    $('#search-more').addEventListener('click', () => runSearch($('#search').value.trim(), true));

    // ----- Player modal: proxy playback with original source-time marks -----
    let playerSource = null, playerRequest = 0, playerController = null;
    let inMs = null, outMs = null, playerReady = false, savingClip = false;
    const markDrafts = new Map();
    const sleep = (ms, signal) => new Promise((resolve, reject) => {
      if (signal?.aborted) { reject(new DOMException('Aborted', 'AbortError')); return; }
      const abort = () => { clearTimeout(timer); reject(new DOMException('Aborted', 'AbortError')); };
      const timer = setTimeout(() => { signal?.removeEventListener('abort', abort); resolve(); }, ms);
      signal?.addEventListener('abort', abort, { once: true });
    });
    function showPrep(title, sub, terminal = false, retry = false) {
      $('#player-prep-text').textContent = title;
      $('#player-prep-sub').textContent = sub || '';
      $('#player-prep').classList.remove('hidden');
      $('#player-prep').classList.toggle('terminal', terminal);
      $('#player-retry').classList.toggle('hidden', !retry);
    }
    function hidePrep() { $('#player-prep').classList.add('hidden'); }
    function ownsPlayer(owner) { return owner === playerRequest && playerSource && !playerController.signal.aborted; }
    function setPlayerReady(ready) {
      playerReady = ready;
      ['btn-back-5','btn-mark-in','btn-mark-out','btn-fwd-5'].forEach(id => $('#' + id).disabled = !ready);
      $('#btn-save').disabled = !ready || savingClip || inMs === null || outMs === null || outMs <= inMs;
    }

    async function waitForProxy(id, owner, signal) {
      let failures = 0;
      for (let i = 0; i < 900; i++) {
        if (!ownsPlayer(owner)) return false;
        try {
          const state = await api(`/api/sources/${id}/proxy-status`, { signal });
          if (!ownsPlayer(owner)) return false;
          failures = 0;
          if (state.offline) { showPrep('Source is offline', 'Reconnect the source drive on your Mac, then try again.', true, true); return false; }
          if (state.error || state.state === 'failed' || state.state === 'cancelled') {
            showPrep('Could not prepare this video', state.error || 'Try again to restart preparation.', true, true); return false;
          }
          if (state.ready) return true;
          showPrep(state.state === 'queued' ? 'Waiting for another video to finish…' : 'Preparing this video…', state.state === 'queued' ? 'You can close the player while it prepares.' : `${state.progress || 0}% · You can close the player while it prepares.`);
        } catch (e) {
          if (!ownsPlayer(owner) || e.name === 'AbortError' || e.message === 'unauthorized') return false;
          if (++failures >= 3) { showPrep('Lost connection to your Mac', 'Check that Remote is enabled and both devices are on the same network.', true, true); return false; }
        }
        try { await sleep(2000, signal); } catch (_) { return false; }
      }
      if (ownsPlayer(owner)) showPrep('Preparation is taking too long', 'Try again, or check the video on your Mac.', true, true);
      return false;
    }

    async function openPlayer(src, retry = false, savedClip = null) {
      if (playerSource) markDrafts.set(playerSource.id, { inMs, outMs });
      playerController?.abort();
      const owner = ++playerRequest;
      playerController = new AbortController();
      const signal = playerController.signal;
      playerSource = src;
      ({ inMs = null, outMs = null } = markDrafts.get(src.id) || {});
      savingClip = false;
      setPlayerReady(false); updateMarksDisplay(); updatePlayhead();
      $('#player-title').textContent = src.name;
      const video = $('#player-video');
      video.pause(); video.removeAttribute('src'); video.load();
      const modal = $('#player-modal');
      modal.classList.remove('hidden');
      if (!modal.open) modal.showModal();
      showPrep('Preparing this video…', '');
      if (retry) {
        try { await api(`/api/sources/${src.id}/proxy-retry`, { method: 'POST', signal }); }
        catch (e) {
          if (ownsPlayer(owner)) showPrep('Could not restart preparation', 'Check the connection to your Mac and try again.', true, true);
          return;
        }
      }
      if (!(await waitForProxy(src.id, owner, signal)) || !ownsPlayer(owner)) return;
      video.addEventListener('loadedmetadata', () => {
        if (!ownsPlayer(owner)) return;
        try { video.playbackRate = Number.isFinite(src.speed) && src.speed > 0 ? src.speed : 1; }
        catch (_) { showPrep('This playback speed is unsupported', 'Choose a different speed for this source on the Mac.', true); return; }
        if (savedClip) video.currentTime = Math.max(0, savedClip.inMs / 1000);
        setPlayerReady(true); hidePrep(); updatePlayhead();
        video.play().catch(() => {});
      }, { once: true, signal });
      video.addEventListener('error', () => {
        if (!ownsPlayer(owner)) return;
        setPlayerReady(false);
        showPrep('Could not play this video', 'Try again, or check that the source plays on your Mac.', true, true);
      }, { once: true, signal });
      video.src = `/api/sources/${src.id}/video`;
      video.load();
    }

    function closePlayer() {
      if (playerSource) markDrafts.set(playerSource.id, { inMs, outMs });
      ++playerRequest; playerController?.abort();
      const video = $('#player-video');
      video.pause(); video.removeAttribute('src'); video.load();
      hidePrep();
      const modal = $('#player-modal');
      if (modal.open) modal.close();
      modal.classList.add('hidden');
      playerSource = null; setPlayerReady(false);
    }
    $('#player-close').addEventListener('click', closePlayer);
    $('#player-modal').addEventListener('cancel', e => { e.preventDefault(); closePlayer(); });
    $('#player-retry').addEventListener('click', () => { if (playerSource) openPlayer(playerSource, true); });

    function durationMs() {
      const seconds = $('#player-video').duration;
      const media = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds * 1000)) : 0;
      const source = playerSource?.durationMs;
      return source > 0 ? (media > 0 ? Math.min(source, media) : source) : media;
    }
    function currentVideoMs() {
      const seconds = $('#player-video').currentTime;
      return Number.isFinite(seconds) ? Math.min(durationMs(), Math.max(0, Math.floor(seconds * 1000))) : 0;
    }
    function updatePlayhead() {
      const total = durationMs(), current = currentVideoMs();
      $('#player-playhead').style.left = (total > 0 ? current / total * 100 : 0) + '%';
      const timeline = $('#player-range').parentElement;
      timeline.setAttribute('aria-valuemax', String(total));
      timeline.setAttribute('aria-valuenow', String(current));
      timeline.setAttribute('aria-valuetext', formatMs(current));
      const range = $('#player-range');
      range.style.display = inMs !== null && total > 0 ? 'block' : 'none';
      if (inMs !== null && total > 0) {
        range.style.left = (inMs / total * 100) + '%';
        range.style.width = (Math.max(0, (outMs ?? current) - inMs) / total * 100) + '%';
      }
    }
    ['timeupdate','seeking','loadedmetadata','durationchange'].forEach(event => $('#player-video').addEventListener(event, updatePlayhead));
    function updateMarksDisplay() {
      const el = $('#player-marks');
      if (inMs === null && outMs === null) el.textContent = 'Mark In, move forward, then Mark Out to save a clip.';
      else {
        const from = inMs !== null ? formatMs(inMs) : '—', to = outMs !== null ? formatMs(outMs) : '—';
        const duration = inMs !== null && outMs !== null && outMs > inMs ? ` · ${formatMs(outMs - inMs)} selected` : '';
        el.textContent = `In ${from} → Out ${to}${duration}`;
      }
      setPlayerReady(playerReady); updatePlayhead();
    }
    $('#btn-mark-in').addEventListener('click', () => {
      if (!playerReady) return;
      inMs = currentVideoMs(); if (outMs !== null && outMs <= inMs) outMs = null;
      updateMarksDisplay();
    });
    $('#btn-mark-out').addEventListener('click', () => {
      if (!playerReady) return;
      const mark = currentVideoMs();
      if (inMs === null || mark <= inMs) { $('#player-marks').textContent = 'Mark In first, then move forward before marking Out.'; return; }
      outMs = mark; updateMarksDisplay();
    });
    function seekBy(seconds) {
      if (playerReady) $('#player-video').currentTime = Math.min(durationMs() / 1000, Math.max(0, $('#player-video').currentTime + seconds));
    }
    $('#btn-back-5').addEventListener('click', () => seekBy(-5));
    $('#btn-fwd-5').addEventListener('click', () => seekBy(5));
    $('#btn-save').addEventListener('click', async () => {
      if (!playerSource || !playerReady || savingClip || inMs === null || outMs === null || outMs <= inMs) return;
      const source = playerSource, owner = playerRequest, savedIn = inMs, savedOut = outMs;
      savingClip = true; setPlayerReady(playerReady);
      try {
        await api(`/api/sources/${source.id}/clips`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ inMs: savedIn, outMs: savedOut })
        });
        const draft = markDrafts.get(source.id);
        if (draft?.inMs === savedIn && draft?.outMs === savedOut) markDrafts.delete(source.id);
        if (!ownsPlayer(owner)) return;
        if (inMs === savedIn && outMs === savedOut) { inMs = null; outMs = null; }
        updateMarksDisplay();
        $('#player-marks').textContent = `Saved ${formatMs(savedOut - savedIn)} clip`;
        if (currentSource?.id === source.id) openSourceDetail(currentSource, true);
      } catch (e) {
        if (ownsPlayer(owner)) $('#player-marks').textContent = 'Clip could not be saved. Your marks are kept; try again.';
      } finally {
        if (ownsPlayer(owner)) { savingClip = false; setPlayerReady(playerReady); }
      }
    });
    const timeline = $('#player-range').parentElement;
    timeline.addEventListener('click', e => {
      if (!playerReady) return;
      const rect = timeline.getBoundingClientRect();
      if (rect.width > 0) $('#player-video').currentTime = durationMs() / 1000 * Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    });
    timeline.addEventListener('keydown', e => {
      if (['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) {
        e.preventDefault(); e.stopPropagation();
        if (!playerReady) return;
        if (e.key === 'Home') $('#player-video').currentTime = 0;
        else if (e.key === 'End') $('#player-video').currentTime = durationMs() / 1000;
        else seekBy(e.key === 'ArrowLeft' ? -1 : 1);
      }
    });
    document.addEventListener('keydown', e => {
      if (!playerSource || e.target.closest('input, textarea, select, [contenteditable="true"]')) return;
      const key = e.key.toLowerCase();
      if (key === ' ' && e.target.tagName !== 'BUTTON') { e.preventDefault(); const video = $('#player-video'); if (playerReady) video.paused ? video.play().catch(() => {}) : video.pause(); }
      else if (key === 'i') $('#btn-mark-in').click();
      else if (key === 'o') $('#btn-mark-out').click();
      else if (key === 's') $('#btn-save').click();
      else if (key === 'j' || key === 'arrowleft') { e.preventDefault(); seekBy(-5); }
      else if (key === 'l' || key === 'arrowright') { e.preventDefault(); seekBy(5); }
    });

    // ----- Tabs -----
    function switchTab(paneID) {
      if (paneID !== 'search-pane') cancelSearch();
      if (paneID !== activePane) { clearSprites(); ++clipOpenRequest; }
      activePane = paneID;
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
        $('#search').value = ''; paneBeforeSearch = pane;
        switchTab(pane);
        if (pane === 'sources-pane') loadSources();
        else if (pane === 'clips-pane') loadClips();
      });
    });
    $('#source-detail-back').addEventListener('click', () => { switchTab(detailReturnPane); if (detailReturnFocus?.isConnected) detailReturnFocus.focus(); });

    new ResizeObserver(entries => document.documentElement.style.setProperty('--topbar-height', entries[0].target.getBoundingClientRect().height + 'px')).observe($('.topbar'));

    // ----- Boot -----
    if (!token) showPairGate();
    else { setSessionCookie(token); loadSources(); }
    """
}
