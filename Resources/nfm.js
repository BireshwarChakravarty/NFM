/*
 * NFM page bridge.
 *
 * Injected into every netflix.com page at document start. It is the only
 * code that touches Netflix's DOM or its internal player, so when Netflix
 * changes something, this is the file to fix.
 *
 * Native → page:  window.__nfm.run(command, argument)
 *                 window.__nfm.configure(settings)
 *                 window.__nfm.setFullscreen(bool)
 * Page → native:  webkit.messageHandlers.nfm.postMessage({ type, ... })
 */
(() => {
  'use strict';
  if (window.__nfm) return;

  // ---------------------------------------------------------------- utils --

  const post = (type, payload) => {
    try {
      window.webkit.messageHandlers.nfm.postMessage(Object.assign({ type }, payload || {}));
    } catch (_) { /* not inside the app */ }
  };

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const firstMatch = (selectors) => {
    for (const s of selectors) {
      const el = $(s);
      if (el && isVisible(el)) return el;
    }
    return null;
  };
  const isVisible = (el) => {
    if (!el || !el.isConnected) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const isWatchPage = () => location.pathname.startsWith('/watch');

  // ------------------------------------------------------- stream formats --
  //
  // Record the formats Netflix actually streams (e.g. 'audio/mp4; codecs="mp4a.40.5"'
  // = HE-AAC stereo) for Audio Diagnostics.

  const streamFormats = [];
  const recordFormat = (type) => {
    streamFormats.push(String(type));
    if (streamFormats.length > 12) streamFormats.shift();
  };
  for (const Source of [window.MediaSource, window.ManagedMediaSource]) {
    if (!Source || !Source.prototype || !Source.prototype.addSourceBuffer) continue;
    const original = Source.prototype.addSourceBuffer;
    Source.prototype.addSourceBuffer = function (type) {
      recordFormat(type);
      return original.apply(this, arguments);
    };
  }

  // ------------------------------------------------------------- settings --

  const settings = {
    autoSkipIntro: true,
    autoSkipRecap: true,
    autoNextEpisode: false,
    dismissStillWatching: true,
    autoProfile: '',          // profile name to pick on the profile gate, '' = off
    videoFill: 'fit',         // 'fit' | 'fill'
    rememberSpeed: false,
    subtitleScale: 1,         // 1 = Netflix's own size
  };
  let desiredRate = 1;

  // --------------------------------------------------------------- styles --

  const CSS = `
    /* Leave room for the macOS traffic lights while windowed. */
    html.nfm-inset:not(.nfm-fullscreen) .pinning-header .main-header,
    html.nfm-inset:not(.nfm-fullscreen) .main-header {
      padding-left: max(4%, 84px) !important;
    }
    html.nfm-inset:not(.nfm-fullscreen) [data-uia="control-nav-back"] {
      margin-top: 16px !important;
    }
    /* Fill mode: crop letterboxing (great for 21:9 films on a MacBook). */
    html.nfm-fill video { object-fit: cover !important; }
    /* Subtitle size: scale Netflix's subtitle block around its bottom centre,
       so lines stay where Netflix puts them, just smaller or larger. */
    html.nfm-subs .player-timedtext > * {
      transform: scale(var(--nfm-sub-scale, 1)) !important;
      transform-origin: 50% 100% !important;
    }
    /* In the mini player the native overlay owns the mouse; keep it clean. */
    html.nfm-mini, html.nfm-mini * { cursor: default !important; }
    html.nfm-mini .watch-video--bottom-controls-container,
    html.nfm-mini [data-uia="controls-standard"],
    html.nfm-mini [data-uia="control-nav-back"],
    html.nfm-mini [data-uia="video-title"] { opacity: 0 !important; pointer-events: none !important; }
    /* TV mode: focus ring, no footer, no scrollbars, cursor hidden while using keys. */
    #nfm-tv-ring {
      position: fixed; left: 0; top: 0; width: 0; height: 0; opacity: 0;
      pointer-events: none; z-index: 2147483647; border-radius: 10px;
      border: 3px solid rgba(255,255,255,.95);
      box-shadow: 0 0 0 6px rgba(255,255,255,.16), 0 0 34px 6px rgba(255,255,255,.22), 0 18px 46px rgba(0,0,0,.65);
      transition: transform .16s cubic-bezier(.2,.8,.2,1), width .16s cubic-bezier(.2,.8,.2,1),
                  height .16s cubic-bezier(.2,.8,.2,1), opacity .2s ease;
    }
    html:not(.nfm-tv) #nfm-tv-ring { display: none !important; }
    html.nfm-tv .member-footer, html.nfm-tv footer { display: none !important; }
    html.nfm-tv::-webkit-scrollbar, html.nfm-tv ::-webkit-scrollbar { display: none !important; }
    html.nfm-tv.nfm-tv-keys, html.nfm-tv.nfm-tv-keys * { cursor: none !important; }
    /* Dark, unobtrusive scrollbars. */
    ::-webkit-scrollbar { width: 10px; height: 10px; background: transparent; }
    ::-webkit-scrollbar-thumb { background: rgba(255,255,255,.18); border-radius: 5px; border: 2px solid transparent; background-clip: padding-box; }
    ::-webkit-scrollbar-thumb:hover { background-color: rgba(255,255,255,.32); }
  `;

  const installStyle = () => {
    if (document.getElementById('nfm-style')) return;
    const style = document.createElement('style');
    style.id = 'nfm-style';
    style.textContent = CSS;
    (document.head || document.documentElement).appendChild(style);
  };

  const applyClasses = () => {
    const html = document.documentElement;
    if (!html) return;
    html.classList.toggle('nfm-fill', settings.videoFill === 'fill');
    const subs = Number(settings.subtitleScale) || 1;
    html.classList.toggle('nfm-subs', subs !== 1);
    html.style.setProperty('--nfm-sub-scale', String(subs));
    html.classList.add('nfm-inset'); // leave room for the traffic lights
  };

  // ------------------------------------------------------- netflix player --

  // Netflix's internal (cadmium) player. Seeking must go through it: setting
  // video.currentTime directly makes the player bail out with error M7375.
  const cadmium = () => {
    try {
      const api = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
      const ids = api.getAllPlayerSessionIds() || [];
      const id = ids.find((i) => String(i).startsWith('watch')) || ids[0];
      return id ? api.getVideoPlayerBySessionId(id) : null;
    } catch (_) {
      return null;
    }
  };

  const video = () => {
    const vids = $$('video');
    if (vids.length <= 1) return vids[0] || null;
    // Prefer the biggest one that has media (billboard trailers are smaller).
    return vids
      .filter((v) => v.readyState > 0)
      .sort((a, b) => (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight))[0] || vids[0];
  };

  const currentTime = () => {
    const p = cadmium();
    if (p && typeof p.getCurrentTime === 'function') return p.getCurrentTime() / 1000;
    const v = video();
    return v ? v.currentTime : 0;
  };

  const duration = () => {
    const p = cadmium();
    if (p && typeof p.getDuration === 'function') return p.getDuration() / 1000;
    const v = video();
    return v && isFinite(v.duration) ? v.duration : 0;
  };

  const isPlaying = () => {
    const v = video();
    return !!v && !v.paused && !v.ended && v.readyState > 2;
  };

  const play = () => {
    const p = cadmium();
    if (p) p.play(); else { const v = video(); if (v) v.play(); }
  };

  const pause = () => {
    const p = cadmium();
    if (p) p.pause(); else { const v = video(); if (v) v.pause(); }
  };

  const seekTo = (seconds) => {
    const p = cadmium();
    if (!p) return false;
    const d = duration();
    const t = Math.max(0, d > 0 ? Math.min(seconds, d - 1) : seconds);
    p.seek(Math.round(t * 1000));
    return true;
  };

  const getVolume = () => {
    const p = cadmium();
    if (p && typeof p.getVolume === 'function') return p.getVolume();
    const v = video();
    return v ? v.volume : 1;
  };

  const setVolume = (value) => {
    const vol = Math.max(0, Math.min(1, value));
    const p = cadmium();
    if (p && typeof p.setVolume === 'function') {
      p.setVolume(vol);
      if (vol > 0 && p.isMuted && p.isMuted()) p.setMuted(false);
    } else {
      const v = video();
      if (v) { v.volume = vol; if (vol > 0) v.muted = false; }
    }
    return vol;
  };

  const isMuted = () => {
    const p = cadmium();
    if (p && typeof p.isMuted === 'function') return p.isMuted();
    const v = video();
    return v ? v.muted : false;
  };

  const setMuted = (muted) => {
    const p = cadmium();
    if (p && typeof p.setMuted === 'function') p.setMuted(muted);
    else { const v = video(); if (v) v.muted = muted; }
  };

  const setRate = (rate) => {
    desiredRate = Math.max(0.25, Math.min(3, rate));
    const v = video();
    if (v) v.playbackRate = desiredRate;
    return desiredRate;
  };

  // ----------------------------------------------------------- metadata --

  let titleCache = { key: '', title: '', subtitle: '' };

  const movieId = () => {
    const m = location.pathname.match(/\/watch\/(\d+)/);
    return m ? m[1] : '';
  };

  // Depth-limited search of Netflix's player metadata for a title string.
  const metadataTitle = () => {
    try {
      const state = window.netflix.appContext.state.playerApp.getState();
      const md = state && state.videoPlayer && state.videoPlayer.videoMetadata;
      const entry = md && md[movieId()];
      if (!entry) return null;
      const seen = new Set();
      const walk = (obj, depth) => {
        if (!obj || typeof obj !== 'object' || depth > 5 || seen.has(obj)) return null;
        seen.add(obj);
        if (typeof obj.title === 'string' && obj.title && (obj.type === 'show' || obj.type === 'movie')) {
          return obj.title;
        }
        for (const key of Object.keys(obj)) {
          const found = walk(obj[key], depth + 1);
          if (found) return found;
        }
        return null;
      };
      return walk(entry, 0);
    } catch (_) {
      return null;
    }
  };

  const readTitle = () => {
    const key = movieId();
    if (titleCache.key !== key) titleCache = { key, title: '', subtitle: '' };

    const el = $('[data-uia="video-title"]');
    if (el) {
      const heading = $('h4', el);
      const spans = $$('span', el).map((s) => s.textContent.trim()).filter(Boolean);
      if (heading) {
        titleCache.title = heading.textContent.trim();
        titleCache.subtitle = spans.join(' · ');
      } else if (el.textContent.trim()) {
        titleCache.title = el.textContent.trim();
        titleCache.subtitle = '';
      }
    }
    if (!titleCache.title) titleCache.title = metadataTitle() || '';
    return titleCache;
  };

  // -------------------------------------------------------------- state --

  let lastReport = 0;
  let reportTimer = null;

  const report = () => {
    reportTimer = null;
    lastReport = Date.now();
    const v = video();
    const watching = isWatchPage();
    const t = watching ? readTitle() : { title: '', subtitle: '' };
    post('state', {
      url: location.href,
      watching,
      hasVideo: watching && !!v,
      playing: watching && isPlaying(),
      time: watching ? currentTime() : 0,
      duration: watching ? duration() : 0,
      rate: v ? v.playbackRate : 1,
      volume: watching ? getVolume() : 1,
      muted: watching ? isMuted() : false,
      videoWidth: v ? v.videoWidth : 0,
      videoHeight: v ? v.videoHeight : 0,
      title: t.title,
      subtitle: t.subtitle,
    });
  };

  // Coalesce bursts of events; never report more than ~4x a second.
  const scheduleReport = (urgent) => {
    if (reportTimer) return;
    const wait = urgent ? 30 : Math.max(0, 250 - (Date.now() - lastReport));
    reportTimer = setTimeout(report, wait);
  };

  const MEDIA_EVENTS = ['play', 'playing', 'pause', 'ended', 'ratechange', 'loadedmetadata',
    'volumechange', 'seeked', 'emptied', 'durationchange'];
  MEDIA_EVENTS.forEach((name) => {
    // Media events don't bubble, but capture-phase listeners on the document still see them.
    document.addEventListener(name, (e) => {
      if (!(e.target instanceof HTMLVideoElement)) return;
      if (isWatchPage() && e.target === video()) {
        if (name === 'ratechange') {
          // Follow speed changes made anywhere, including Netflix's own speed menu.
          desiredRate = e.target.playbackRate;
        } else if ((name === 'playing' || name === 'loadedmetadata') && e.target.playbackRate !== desiredRate) {
          // A new stream starts at 1x; keep the chosen speed.
          e.target.playbackRate = desiredRate;
        }
      }
      scheduleReport(name !== 'volumechange');
    }, true);
  });

  let lastTick = 0;
  document.addEventListener('timeupdate', (e) => {
    if (!(e.target instanceof HTMLVideoElement)) return;
    const now = Date.now();
    if (now - lastTick > 1000) { lastTick = now; scheduleReport(false); }
  }, true);

  // ------------------------------------------------------------ routing --

  let lastPath = location.pathname;
  const onRoute = () => {
    if (location.pathname === lastPath) return;
    const wasWatching = lastPath.startsWith('/watch');
    lastPath = location.pathname;
    if (!settings.rememberSpeed && !(wasWatching && isWatchPage())) desiredRate = 1;
    if (isWatchPage() && desiredRate !== 1) setTimeout(() => setRate(desiredRate), 1500);
    idle = false;
    post('route', { url: location.href, watching: isWatchPage() });
    scheduleReport(true);
  };
  for (const fn of ['pushState', 'replaceState']) {
    const original = history[fn];
    history[fn] = function () {
      const result = original.apply(this, arguments);
      setTimeout(onRoute, 0);
      return result;
    };
  }
  window.addEventListener('popstate', () => setTimeout(onRoute, 0));

  // ----------------------------------------------------- auto actions --

  const SKIP_INTRO = ['[data-uia="player-skip-intro"]'];
  const SKIP_RECAP = ['[data-uia="player-skip-recap"]', '[data-uia="player-skip-preplay"]'];
  const NEXT_EPISODE = ['[data-uia="next-episode-seamless-button"]',
    '[data-uia="next-episode-seamless-button-draining"]'];
  const STILL_WATCHING = ['[data-uia="interrupt-autoplay-continue"]'];
  const NEXT_CONTROL = ['[data-uia="control-next"]'];

  const clicked = new WeakSet();
  const press = (el, kind) => {
    if (!el || clicked.has(el)) return false;
    clicked.add(el);
    el.click();
    post('autoAction', { kind });
    return true;
  };

  const autoActions = () => {
    if (!isWatchPage()) return;
    if (settings.autoSkipIntro) press(firstMatch(SKIP_INTRO), 'intro');
    if (settings.autoSkipRecap) press(firstMatch(SKIP_RECAP), 'recap');
    if (settings.autoNextEpisode) press(firstMatch(NEXT_EPISODE), 'credits');
    if (settings.dismissStillWatching) press(firstMatch(STILL_WATCHING), 'stillWatching');
  };

  // ---------------------------------------------------- profile gate --

  const PROFILE_LINKS = ['[data-uia="action-select-profile+primary"]', 'a.profile-link', '.choose-profile .profile-link'];

  const profileLinks = () => {
    const links = new Set();
    PROFILE_LINKS.forEach((s) => $$(s).forEach((el) => links.add(el)));
    return Array.from(links).filter(isVisible);
  };

  const profileName = (el) => {
    const nameEl = $('.profile-name', el) || $('[data-uia="profile-name-text"]', el);
    return ((nameEl && nameEl.textContent) || el.getAttribute('aria-label') || el.textContent || '').trim();
  };

  let profileAutoDone = false;
  const autoProfile = () => {
    if (!settings.autoProfile || profileAutoDone) return;
    const links = profileLinks();
    if (!links.length) return;
    const target = links.find((el) => profileName(el) === settings.autoProfile);
    if (!target) return;
    profileAutoDone = true;
    target.click();
    post('profileAutoSelected', { name: settings.autoProfile });
  };

  document.addEventListener('click', (e) => {
    const link = e.isTrusted && e.target instanceof Element &&
      e.target.closest(PROFILE_LINKS.join(','));
    if (link) post('profileChosen', { name: profileName(link) });
  }, true);

  // ------------------------------------------------------ dom observer --

  let observeQueued = false;
  const onMutations = () => {
    if (observeQueued) return;
    observeQueued = true;
    setTimeout(() => {
      observeQueued = false;
      installStyle();
      autoActions();
      autoProfile();
      if (isWatchPage() && !titleCache.title) readTitle();
    }, 120);
  };
  const startObserver = () => {
    new MutationObserver(onMutations).observe(document.documentElement, { childList: true, subtree: true });
    installStyle();
    applyClasses();
    onMutations();
  };

  // --------------------------------------------- fullscreen polyfill --
  //
  // WebKit's element fullscreen would open a separate window. The app keeps
  // element fullscreen off and maps the Fullscreen API onto native window
  // fullscreen instead, so the page, overlays and HUD stay in one window.

  let nativeFullscreen = false;
  const fsElement = () => (nativeFullscreen ? document.documentElement : null);
  const defineGetter = (obj, name, getter) => {
    try { Object.defineProperty(obj, name, { configurable: true, get: getter }); } catch (_) {}
  };
  defineGetter(Document.prototype, 'fullscreenEnabled', () => true);
  defineGetter(Document.prototype, 'webkitFullscreenEnabled', () => true);
  defineGetter(Document.prototype, 'fullscreenElement', fsElement);
  defineGetter(Document.prototype, 'webkitFullscreenElement', fsElement);
  defineGetter(Document.prototype, 'webkitCurrentFullScreenElement', fsElement);
  defineGetter(Document.prototype, 'webkitIsFullScreen', () => nativeFullscreen);
  defineGetter(Document.prototype, 'fullscreen', () => nativeFullscreen);

  const requestFS = function () { post('fullscreen', { enter: true }); return Promise.resolve(); };
  const exitFS = function () { post('fullscreen', { enter: false }); return Promise.resolve(); };
  Element.prototype.requestFullscreen = requestFS;
  Element.prototype.webkitRequestFullscreen = requestFS;
  Element.prototype.webkitRequestFullScreen = requestFS;
  Document.prototype.exitFullscreen = exitFS;
  Document.prototype.webkitExitFullscreen = exitFS;
  Document.prototype.webkitCancelFullScreen = exitFS;

  // ------------------------------------------- title bar & idle chrome --

  const INTERACTIVE = 'a,button,input,textarea,select,label,[role="button"],[role="link"],' +
    '[role="menu"],[role="menuitem"],[role="tab"],[tabindex],[contenteditable="true"]';
  const TITLEBAR_HEIGHT = 30;

  document.addEventListener('mousedown', (e) => {
    if (nativeFullscreen || e.button !== 0 || e.clientY > TITLEBAR_HEIGHT) return;
    const target = e.target instanceof Element ? e.target : null;
    if (target && target.closest(INTERACTIVE)) return;
    if (e.detail === 2) post('titlebarDoubleClick');
    else post('dragWindow');
  }, true);

  let idle = false;
  let idleTimer = null;
  const markActive = () => {
    if (idle) { idle = false; post('idle', { idle: false }); }
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (isWatchPage() && isPlaying()) { idle = true; post('idle', { idle: true }); }
    }, 2500);
  };
  document.addEventListener('mousemove', markActive, true);
  document.addEventListener('keydown', markActive, true);

  // ---------------------------------------------- picture in picture --

  const togglePiP = () => {
    const v = video();
    if (!v) return 'no-video';
    v.removeAttribute('disablePictureInPicture');
    v.disablePictureInPicture = false;
    if (typeof v.webkitSetPresentationMode === 'function' &&
        (!v.webkitSupportsPresentationMode || v.webkitSupportsPresentationMode('picture-in-picture'))) {
      const next = v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture';
      v.webkitSetPresentationMode(next);
      return next;
    }
    if (document.pictureInPictureElement) { document.exitPictureInPicture(); return 'inline'; }
    if (v.requestPictureInPicture) { v.requestPictureInPicture().catch(() => {}); return 'picture-in-picture'; }
    return 'unsupported';
  };

  // ------------------------------------------------------------ TV mode --
  //
  // A lean-back layer over Netflix's site: arrow keys (or a game controller,
  // via native code) move a highlight between titles, Enter selects, Esc goes
  // back. The highlight is our own element; Netflix's DOM is never re-styled
  // beyond hiding the footer.

  const TV_TARGETS = 'a[href], button, [role="button"], [role="link"], [tabindex="0"]';
  const MODAL = '.previewModal--wrapper, [data-uia="previewModal--wrapper"], [role="dialog"]';
  const MODAL_CLOSE = ['[data-uia="previewModal-closebtn"]', '.previewModal-close', '[role="dialog"] [aria-label="close"]'];
  const ROW = '.lolomoRow, [class*="lolomoRow"], .rowContainer, .row-with-x-columns';
  const ROW_NEXT = '.handleNext, [class*="handleNext"]';
  const ROW_PREV = '.handlePrev, [class*="handlePrev"]';

  const tv = {
    on: false,
    current: null,
    ring: null,
    syncTimer: null,
    busy: false,
  };

  const rectOf = (el) => el.getBoundingClientRect();
  const centerOf = (r) => ({ x: r.left + r.width / 2, y: r.top + r.height / 2 });
  const overlap = (a1, a2, b1, b2) => Math.max(0, Math.min(a2, b2) - Math.max(a1, b1));

  const openModal = () => $$(MODAL).find(isVisible) || null;

  const tvCandidates = () => {
    const scope = openModal() || document;
    const vw = window.innerWidth;
    return $$(TV_TARGETS, scope).filter((el) => {
      if (el.id === 'nfm-tv-ring' || el.closest('[aria-hidden="true"]')) return false;
      if (el.disabled) return false;
      const r = rectOf(el);
      if (r.width < 18 || r.height < 14) return false;
      // Cards scrolled sideways out of a row are not reachable until the row pages.
      if (r.right < 4 || r.left > vw - 4) return false;
      const style = getComputedStyle(el);
      return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity) > 0.05;
    });
  };

  const ensureRing = () => {
    if (tv.ring && tv.ring.isConnected) return tv.ring;
    const ring = document.createElement('div');
    ring.id = 'nfm-tv-ring';
    (document.body || document.documentElement).appendChild(ring);
    tv.ring = ring;
    return ring;
  };

  const syncRing = () => {
    if (!tv.on) return;
    const ring = ensureRing();
    const el = tv.current;
    if (!el || !el.isConnected || isWatchPage()) { ring.style.opacity = '0'; return; }
    const r = rectOf(el);
    const pad = 4;
    ring.style.opacity = '1';
    ring.style.transform = `translate(${r.left - pad}px, ${r.top - pad}px)`;
    ring.style.width = `${r.width + pad * 2}px`;
    ring.style.height = `${r.height + pad * 2}px`;
  };

  const setCurrent = (el, scroll) => {
    tv.current = el;
    if (el && scroll) {
      const r = rectOf(el);
      const margin = window.innerHeight * 0.22;
      if (r.top < margin || r.bottom > window.innerHeight - margin) {
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
      }
    }
    syncRing();
  };

  const pickInitial = () => {
    const modal = openModal();
    const preferred = modal
      ? $('[data-uia="play-button"], button[aria-label*="Play" i]', modal)
      : $('[data-uia="play-button"]');
    if (preferred && isVisible(preferred)) return preferred;
    const visible = tvCandidates().filter((el) => {
      const r = rectOf(el);
      return r.top >= 0 && r.bottom <= window.innerHeight;
    });
    const pool = visible.length ? visible : tvCandidates();
    // Prefer artwork (title cards) over small header links.
    pool.sort((a, b) => {
      const ra = rectOf(a), rb = rectOf(b);
      const big = (r) => (r.width * r.height > 9000 ? 0 : 1);
      return big(ra) - big(rb) || ra.top - rb.top || ra.left - rb.left;
    });
    return pool[0] || null;
  };

  const best = (from, dir, sameLineOnly) => {
    const f = rectOf(from);
    const fc = centerOf(f);
    let winner = null;
    let winnerScore = Infinity;
    for (const el of tvCandidates()) {
      if (el === from || el.contains(from) || from.contains(el)) continue;
      const r = rectOf(el);
      const c = centerOf(r);
      let primary, secondary, lineOverlap;
      if (dir === 'right' || dir === 'left') {
        if (dir === 'right' ? c.x <= fc.x + 2 : c.x >= fc.x - 2) continue;
        primary = dir === 'right' ? r.left - f.right : f.left - r.right;
        secondary = Math.abs(c.y - fc.y);
        lineOverlap = overlap(f.top, f.bottom, r.top, r.bottom);
      } else {
        if (dir === 'down' ? c.y <= fc.y + 2 : c.y >= fc.y - 2) continue;
        primary = dir === 'down' ? r.top - f.bottom : f.top - r.bottom;
        secondary = Math.abs(c.x - fc.x);
        lineOverlap = overlap(f.left, f.right, r.left, r.right);
      }
      if (sameLineOnly && lineOverlap <= 0) continue;
      const score = Math.max(0, primary) + secondary * (lineOverlap > 0 ? 0.4 : 2.5);
      if (score < winnerScore) { winnerScore = score; winner = el; }
    }
    return winner;
  };

  // At the end of a visible row: page the row, then land on its first new card.
  const pageRow = (from, dir) => {
    const row = from.closest(ROW);
    const handle = row && $(dir === 'right' ? ROW_NEXT : ROW_PREV, row);
    if (!handle) return false;
    tv.busy = true;
    handle.click();
    setTimeout(() => {
      tv.busy = false;
      const inRow = tvCandidates().filter((el) => row.contains(el));
      inRow.sort((a, b) => rectOf(a).left - rectOf(b).left);
      const next = dir === 'right' ? inRow[0] : inRow[inRow.length - 1];
      if (next) setCurrent(next, false);
    }, 750);
    return true;
  };

  const tvMove = (dir) => {
    if (tv.busy || isWatchPage()) return false;
    document.documentElement.classList.add('nfm-tv-keys');
    const from = tv.current && tv.current.isConnected ? tv.current : null;
    if (!from) { setCurrent(pickInitial(), true); return true; }
    const horizontal = dir === 'left' || dir === 'right';
    const next = best(from, dir, horizontal);
    if (next) { setCurrent(next, true); return true; }
    if (horizontal && pageRow(from, dir)) return true;
    if (!horizontal && dir === 'up' && !openModal()) {
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }
    return false;
  };

  const tvSelect = () => {
    if (isWatchPage()) return false;
    const el = tv.current && tv.current.isConnected ? tv.current : null;
    if (!el) { setCurrent(pickInitial(), true); return false; }
    el.click();
    // Whatever opens (a details panel, a new page) gets a fresh starting point.
    setTimeout(() => { if (!tv.current || !tv.current.isConnected || openModal()) setCurrent(pickInitial(), true); }, 700);
    return true;
  };

  const tvBack = () => {
    const modal = openModal();
    if (modal) {
      const close = firstMatch(MODAL_CLOSE);
      if (close) close.click();
      else document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
      setTimeout(() => setCurrent(pickInitial(), true), 500);
      return 'closed';
    }
    if (history.length > 1 && !/^\/browse\/?$/.test(location.pathname)) {
      history.back();
      return 'back';
    }
    return 'root';
  };

  const setTV = (on) => {
    tv.on = !!on;
    const html = document.documentElement;
    html.classList.toggle('nfm-tv', tv.on);
    clearInterval(tv.syncTimer);
    if (tv.on) {
      ensureRing();
      tv.syncTimer = setInterval(syncRing, 200);
      if (!tv.current || !tv.current.isConnected) setTimeout(() => setCurrent(pickInitial(), false), 300);
      else syncRing();
    } else {
      html.classList.remove('nfm-tv-keys');
      if (tv.ring) tv.ring.style.opacity = '0';
    }
    return tv.on;
  };

  const editable = (el) => el instanceof Element &&
    (el.closest('input, textarea, select, [contenteditable="true"]') !== null);

  window.addEventListener('keydown', (e) => {
    if (!tv.on || e.metaKey || e.ctrlKey || e.altKey || editable(e.target)) return;
    const watching = isWatchPage();
    let handled = false;
    if (!watching) {
      const dirs = { ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down' };
      if (dirs[e.key]) { tvMove(dirs[e.key]); handled = true; }
      else if (e.key === 'Enter' || e.key === ' ') { tvSelect(); handled = true; }
    }
    if (e.key === 'Escape' || e.key === 'Backspace') {
      if (watching) history.back(); else tvBack();
      handled = true;
    }
    if (handled) { e.preventDefault(); e.stopImmediatePropagation(); }
  }, true);

  window.addEventListener('scroll', () => { if (tv.on) syncRing(); }, { passive: true, capture: true });
  window.addEventListener('resize', () => { if (tv.on) syncRing(); });
  document.addEventListener('mousemove', () => document.documentElement.classList.remove('nfm-tv-keys'), true);
  document.addEventListener('mouseover', (e) => {
    if (!tv.on || isWatchPage() || !(e.target instanceof Element)) return;
    const target = e.target.closest(TV_TARGETS);
    if (target && tvCandidates().includes(target)) setCurrent(target, false);
  }, true);

  // --------------------------------------------------------- commands --

  const clickFirst = (selectors) => {
    const el = firstMatch(selectors);
    if (!el) return false;
    el.click();
    return true;
  };

  const commands = {
    play() { play(); return true; },
    pause() { pause(); return true; },
    seekBy(sec) { return seekTo(currentTime() + Number(sec || 0)); },
    seekTo(sec) { return seekTo(Number(sec || 0)); },
    volumeBy(delta) {
      if (isMuted()) setMuted(false);
      return setVolume(getVolume() + Number(delta || 0));
    },
    toggleMute() { const m = !isMuted(); setMuted(m); return m; },
    setRate(rate) { return setRate(Number(rate) || 1); },
    rateBy(delta) {
      const steps = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];
      const cur = desiredRate;
      const idx = steps.reduce((best, s, i) => (Math.abs(s - cur) < Math.abs(steps[best] - cur) ? i : best), 0);
      const next = steps[Math.max(0, Math.min(steps.length - 1, idx + (delta > 0 ? 1 : -1)))];
      return setRate(next);
    },
    skip() {
      if (clickFirst(SKIP_INTRO)) return 'intro';
      if (clickFirst(SKIP_RECAP)) return 'recap';
      if (clickFirst(NEXT_EPISODE)) return 'credits';
      return '';
    },
    nextEpisode() { return clickFirst(NEXT_EPISODE) || clickFirst(NEXT_CONTROL); },
    togglePiP() { return togglePiP(); },
    setMini(on) { document.documentElement.classList.toggle('nfm-mini', !!on); return !!on; },
    state() { report(); return true; },
    setTV(on) { return setTV(on); },
    audioInfo() {
      const v = video();
      const p = cadmium();
      const plain = (obj) => {
        const out = {};
        if (!obj || typeof obj !== 'object') return out;
        let n = 0;
        for (const key in obj) {
          const value = obj[key];
          const t = typeof value;
          if ((t === 'string' || t === 'number' || t === 'boolean') && n++ < 24) out[key] = value;
        }
        return out;
      };
      const call = (name) => {
        try { return p && typeof p[name] === 'function' ? p[name]() : undefined; } catch (_) { return undefined; }
      };
      const info = {
        watching: isWatchPage(),
        playing: isPlaying(),
        netflixVolume: call('getVolume'),
        netflixMuted: call('isMuted'),
        elementVolume: v ? v.volume : null,
        elementMuted: v ? v.muted : null,
        formats: streamFormats.slice(),
      };
      const track = call('getAudioTrack');
      if (track) info.audioTrack = plain(track);
      return info;
    },
    tvMove(dir) { return tvMove(String(dir)); },
    tvSelect() { return tvSelect(); },
    tvBack() { return tvBack(); },
  };

  // ------------------------------------------------------------ public --

  window.__nfm = Object.freeze({
    run(name, arg) {
      const fn = commands[name];
      if (!fn) return null;
      try { const result = fn(arg); scheduleReport(true); return result; } catch (err) { return String(err); }
    },
    configure(next) {
      Object.assign(settings, next || {});
      if (settings.autoProfileArmed === false) profileAutoDone = true;
      applyClasses();
      onMutations();
      return true;
    },
    setFullscreen(on) {
      if (nativeFullscreen === !!on) return;
      nativeFullscreen = !!on;
      document.documentElement.classList.toggle('nfm-fullscreen', nativeFullscreen);
      document.dispatchEvent(new Event('fullscreenchange'));
      document.dispatchEvent(new Event('webkitfullscreenchange'));
    },
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startObserver, { once: true });
  } else {
    startObserver();
  }
  post('ready', { url: location.href });
})();
