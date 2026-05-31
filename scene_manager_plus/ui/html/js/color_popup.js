// Shared color picker popup (HSV square + hue slider + presets).
// CEF di SU 2019 non supporta <input type="color">. Lo stesso popup vive
// anche in style_dialog.js (private IIFE) — qui è in window.SMColorPopup
// così index.html e altri dialog possono riutilizzarlo.
//
// HTML markup atteso nel DOM (id fissi):
//   #sm-color-popup, #cp-sb, #cp-sb-marker, #cp-hue, #cp-hue-marker,
//   #cp-hex, #cp-preview, #cp-presets
// CSS in css/color_popup.css.
//
// API:
//   SMColorPopup.show(triggerEl, currentHex, onApply, opts)
//     opts.allowNone = true → mostra anche un pulsante "Nessuno" che invoca
//                             onApply('') e chiude il popup.
//     opts.commitOnEnd = true → NON chiama onApply durante drag/typing; lo
//                               chiama una sola volta alla chiusura del popup
//                               con il colore finale. Usato per evitare write
//                               a SU su modelli con AttributeObserver lento.
//   SMColorPopup.hide()
//   SMColorPopup.pushRecent(hex) — chiamato automaticamente sui commit.
window.SMColorPopup = (function () {
  var popup, sbEl, sbMarker, hueEl, hueMarker, hexEl, previewEl, presetsEl;
  var recentRowEl, noneBtnEl;
  var hsv = { h: 0, s: 0, v: 0 };
  var onApply = null;
  var anchorEl = null;
  var ready = false;
  var allowNoneCurrent = false;
  var commitOnEndCurrent = false;
  var lastAppliedInSession = null;
  var pendingHex = null;

  var RECENT_KEY = 'sm_color_popup_recent';
  var RECENT_MAX = 5;
  var recentMem = []; // fallback in-memory se localStorage non c'è
  function loadRecent() {
    try {
      var s = window.localStorage && window.localStorage.getItem(RECENT_KEY);
      if (s) {
        var arr = JSON.parse(s);
        if (Array.isArray(arr)) return arr.filter(normalizeHex).slice(0, RECENT_MAX);
      }
    } catch (e) {}
    return recentMem.slice();
  }
  function saveRecent(arr) {
    recentMem = arr.slice();
    try {
      if (window.localStorage) window.localStorage.setItem(RECENT_KEY, JSON.stringify(arr));
    } catch (e) {}
  }
  function pushRecent(hex) {
    var h = normalizeHex(hex);
    if (!h) return;
    var arr = loadRecent();
    var i = arr.indexOf(h);
    if (i !== -1) arr.splice(i, 1);
    arr.unshift(h);
    if (arr.length > RECENT_MAX) arr.length = RECENT_MAX;
    saveRecent(arr);
    renderRecent();
  }
  function renderRecent() {
    if (!recentRowEl) return;
    recentRowEl.innerHTML = '';
    var arr = loadRecent();
    if (arr.length === 0) {
      recentRowEl.style.display = 'none';
      return;
    }
    recentRowEl.style.display = '';
    arr.forEach(function (c) {
      var s = document.createElement('span');
      s.className = 'cp-recent-swatch';
      s.style.background = c;
      s.title = c;
      s.addEventListener('click', function () { setFromHex(c); });
      recentRowEl.appendChild(s);
    });
  }

  var PRESETS = [
    '#ffffff', '#dddddd', '#aaaaaa', '#777777', '#444444', '#000000', '#7a3e1d', '#3e1f0e',
    '#ff0000', '#ff8800', '#ffff00', '#88ff00', '#00ff44', '#00ddaa', '#00aaff', '#0044ff',
    '#4400ff', '#aa00ff', '#ff00aa', '#ff0044', '#88aaff', '#aaccdd', '#ccddee', '#e0e8f5'
  ];

  function $(id) { return document.getElementById(id); }

  function normalizeHex(s) {
    if (!s) return null;
    s = String(s).trim().toLowerCase();
    if (s[0] !== '#') s = '#' + s;
    return /^#[0-9a-f]{6}$/.test(s) ? s : null;
  }

  function init() {
    if (ready) return;
    popup    = $('sm-color-popup');
    if (!popup) return;
    sbEl     = $('cp-sb');
    sbMarker = $('cp-sb-marker');
    hueEl    = $('cp-hue');
    hueMarker= $('cp-hue-marker');
    hexEl    = $('cp-hex');
    previewEl= $('cp-preview');
    presetsEl= $('cp-presets');
    recentRowEl = $('cp-recent');
    noneBtnEl   = $('cp-none');

    PRESETS.forEach(function (c) {
      var s = document.createElement('span');
      s.className = 'cp-preset';
      s.style.background = c;
      s.title = c;
      s.addEventListener('click', function () { setFromHex(c); });
      presetsEl.appendChild(s);
    });

    bindDrag(sbEl, function (e) {
      var r = sbEl.getBoundingClientRect();
      var x = Math.max(0, Math.min(r.width, e.clientX - r.left));
      var y = Math.max(0, Math.min(r.height, e.clientY - r.top));
      hsv.s = x / r.width;
      hsv.v = 1 - y / r.height;
      updateAll();
    });

    bindDrag(hueEl, function (e) {
      var r = hueEl.getBoundingClientRect();
      var y = Math.max(0, Math.min(r.height, e.clientY - r.top));
      hsv.h = (y / r.height) * 360;
      if (hsv.h >= 360) hsv.h = 359.999;
      updateAll();
    });

    // Enter / Esc nel campo hex → chiude il popup (= commit in modalità
    // commitOnEnd, no-op altrove perché il colore è già stato applicato).
    hexEl.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); hide(); }
      else if (e.key === 'Escape') { e.preventDefault(); hide(); }
    });

    hexEl.addEventListener('input', function () {
      var hex = normalizeHex(hexEl.value);
      if (hex) {
        var rgb = hexToRgb(hex);
        var nh = rgbToHsv(rgb.r, rgb.g, rgb.b);
        if (nh.s > 0 || nh.v > 0) hsv.h = nh.h;
        hsv.s = nh.s;
        hsv.v = nh.v;
        updateAll(true);
      }
    });

    document.addEventListener('mousedown', function (e) {
      if (popup.classList.contains('hidden')) return;
      if (popup.contains(e.target)) return;
      if (anchorEl && anchorEl.contains(e.target)) return;
      hide();
    }, true);

    document.addEventListener('keydown', function (e) {
      if (popup.classList.contains('hidden')) return;
      if (e.key === 'Escape') hide();
    });

    if (noneBtnEl) {
      noneBtnEl.addEventListener('click', function () {
        if (commitOnEndCurrent) {
          pendingHex = ''; // hide() committerà ''
        } else if (onApply) {
          onApply('');
        }
        hide();
      });
    }

    ready = true;
  }

  function bindDrag(el, fn) {
    el.addEventListener('mousedown', function (e) {
      e.preventDefault();
      fn(e);
      function move(ev) { fn(ev); }
      function up() {
        document.removeEventListener('mousemove', move);
        document.removeEventListener('mouseup', up);
      }
      document.addEventListener('mousemove', move);
      document.addEventListener('mouseup', up);
    });
  }

  function setFromHex(hex) {
    hex = normalizeHex(hex);
    if (!hex) return;
    var rgb = hexToRgb(hex);
    var nh = rgbToHsv(rgb.r, rgb.g, rgb.b);
    if (nh.s > 0 || nh.v > 0) hsv.h = nh.h;
    hsv.s = nh.s;
    hsv.v = nh.v;
    updateAll();
  }

  function updateAll(skipHexUpdate) {
    var hex = hsvToHex(hsv.h, hsv.s, hsv.v);
    sbEl.style.backgroundColor = hsvToHex(hsv.h, 1, 1);
    sbMarker.style.left = (hsv.s * 100) + '%';
    sbMarker.style.top  = ((1 - hsv.v) * 100) + '%';
    hueMarker.style.top = ((hsv.h / 360) * 100) + '%';
    previewEl.style.background = hex;
    if (!skipHexUpdate) hexEl.value = hex;
    lastAppliedInSession = hex;
    pendingHex = hex;
    if (onApply && !commitOnEndCurrent) onApply(hex);
  }

  function show(triggerEl, currentHex, applyFn, opts) {
    init();
    if (!popup) return;
    anchorEl = triggerEl;
    onApply = applyFn;
    allowNoneCurrent = !!(opts && opts.allowNone);
    commitOnEndCurrent = !!(opts && opts.commitOnEnd);
    if (noneBtnEl) noneBtnEl.style.display = allowNoneCurrent ? '' : 'none';
    lastAppliedInSession = null;
    pendingHex = null;
    renderRecent();
    // Set iniziale dei marker/preview dal colore corrente SENZA committare:
    // altrimenti aprire il popup riscriverebbe subito il colore (onApply in
    // updateAll). Era visibile su HorizonColor, dove il valore mostrato
    // (#ffffff sentinel) differisce dal reale e l'apertura lo sovrascriveva.
    var _savedApply = onApply;
    onApply = null;
    setFromHex(currentHex || '#ffffff');
    onApply = _savedApply;
    lastAppliedInSession = null; // setFromHex sopra non conta come commit utente
    pendingHex = null;
    var r = triggerEl.getBoundingClientRect();
    popup.classList.remove('hidden');
    var pw = popup.offsetWidth, ph = popup.offsetHeight;
    var x = r.left;
    var y = r.bottom + 4;
    var vw = window.innerWidth, vh = window.innerHeight;
    if (x + pw > vw) x = Math.max(4, vw - pw - 4);
    if (y + ph > vh) y = Math.max(4, r.top - ph - 4);
    popup.style.left = x + 'px';
    popup.style.top  = y + 'px';
  }

  function hide() {
    if (popup) popup.classList.add('hidden');
    // commitOnEnd: applichiamo una sola volta il colore finale alla chiusura,
    // evitando le N write durante drag/typing.
    if (commitOnEndCurrent && onApply && pendingHex !== null) {
      try { onApply(pendingHex); } catch (e) {}
    }
    if (lastAppliedInSession) pushRecent(lastAppliedInSession);
    lastAppliedInSession = null;
    pendingHex = null;
    commitOnEndCurrent = false;
    anchorEl = null;
    onApply = null;
  }

  function hexToRgb(hex) {
    hex = hex.replace('#', '');
    return {
      r: parseInt(hex.slice(0, 2), 16),
      g: parseInt(hex.slice(2, 4), 16),
      b: parseInt(hex.slice(4, 6), 16)
    };
  }
  function rgbToHex(r, g, b) {
    function h(x) { var s = Math.round(x).toString(16); return s.length === 1 ? '0' + s : s; }
    return '#' + h(r) + h(g) + h(b);
  }
  function rgbToHsv(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    var max = Math.max(r, g, b), min = Math.min(r, g, b);
    var d = max - min, s, h = 0, v = max;
    s = max === 0 ? 0 : d / max;
    if (max !== min) {
      if      (max === r) h = (g - b) / d + (g < b ? 6 : 0);
      else if (max === g) h = (b - r) / d + 2;
      else                h = (r - g) / d + 4;
      h *= 60;
    }
    return { h: h, s: s, v: v };
  }
  function hsvToRgb(h, s, v) {
    h /= 60;
    var i = Math.floor(h) % 6;
    var f = h - Math.floor(h);
    var p = v * (1 - s);
    var q = v * (1 - f * s);
    var t = v * (1 - (1 - f) * s);
    var r, g, b;
    switch (i) {
      case 0: r = v; g = t; b = p; break;
      case 1: r = q; g = v; b = p; break;
      case 2: r = p; g = v; b = t; break;
      case 3: r = p; g = q; b = v; break;
      case 4: r = t; g = p; b = v; break;
      case 5: r = v; g = p; b = q; break;
    }
    return { r: r * 255, g: g * 255, b: b * 255 };
  }
  function hsvToHex(h, s, v) {
    var rgb = hsvToRgb(h, s, v);
    return rgbToHex(rgb.r, rgb.g, rgb.b);
  }

  return {
    show: show,
    hide: hide,
    normalizeHex: normalizeHex,
    pushRecent: pushRecent
  };
})();
