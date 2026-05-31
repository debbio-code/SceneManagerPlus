// Mini Style Manager
window.SMS = (function () {
  var state = { style_name: null, scene_id: null, scenes_count: 0, values: {} };
  var listenersBound = false;

  function $(id) { return document.getElementById(id); }

  function call(name, data) {
    var payload = (data === undefined) ? '' : JSON.stringify(data);
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      try { window.sketchup[name](payload); }
      catch (e) { console.warn('SMS bridge failed: ' + name, e); }
    }
  }

  function logRuby(msg) { call('sm_style_log', String(msg)); }

  function normalizeHex(s) {
    if (!s) return null;
    s = String(s).trim().toLowerCase();
    if (s[0] !== '#') s = '#' + s;
    return /^#[0-9a-f]{6}$/.test(s) ? s : null;
  }

  // ColorPopup è ora il modulo condiviso color_popup.js (window.SMColorPopup):
  // include "Recenti" e bottone "None". Lasciamo qui la vecchia IIFE privata
  // come dead-code in caso si voglia rollback rapido, ma usiamo lo shared.
  var ColorPopup = window.SMColorPopup;
  var _ColorPopupLegacy = (function () {
    var popup, sbEl, sbMarker, hueEl, hueMarker, hexEl, previewEl, presetsEl;
    var hsv = { h: 0, s: 0, v: 0 };
    var onApply = null;
    var anchorEl = null;
    var ready = false;

    var PRESETS = [
      '#ffffff', '#dddddd', '#aaaaaa', '#777777', '#444444', '#000000', '#7a3e1d', '#3e1f0e',
      '#ff0000', '#ff8800', '#ffff00', '#88ff00', '#00ff44', '#00ddaa', '#00aaff', '#0044ff',
      '#4400ff', '#aa00ff', '#ff00aa', '#ff0044', '#88aaff', '#aaccdd', '#ccddee', '#e0e8f5'
    ];

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

      // Presets
      PRESETS.forEach(function (c) {
        var s = document.createElement('span');
        s.className = 'cp-preset';
        s.style.background = c;
        s.title = c;
        s.addEventListener('click', function () { setFromHex(c); });
        presetsEl.appendChild(s);
      });

      // SB drag (saturation × value)
      bindDrag(sbEl, function (e) {
        var r = sbEl.getBoundingClientRect();
        var x = Math.max(0, Math.min(r.width, e.clientX - r.left));
        var y = Math.max(0, Math.min(r.height, e.clientY - r.top));
        hsv.s = x / r.width;
        hsv.v = 1 - y / r.height;
        updateAll();
      });

      // Hue drag (vertical)
      bindDrag(hueEl, function (e) {
        var r = hueEl.getBoundingClientRect();
        var y = Math.max(0, Math.min(r.height, e.clientY - r.top));
        hsv.h = (y / r.height) * 360;
        if (hsv.h >= 360) hsv.h = 359.999;
        updateAll();
      });

      // Hex input typed → parse, update sliders
      hexEl.addEventListener('input', function () {
        var hex = normalizeHex(hexEl.value);
        if (hex) {
          var rgb = hexToRgb(hex);
          var nh = rgbToHsv(rgb.r, rgb.g, rgb.b);
          // Mantieni h se s/v sono 0 (per non perdere la posizione hue su grigi)
          if (nh.s > 0 || nh.v > 0) hsv.h = nh.h;
          hsv.s = nh.s;
          hsv.v = nh.v;
          updateAll(true); // skipHexUpdate = true (utente sta typing)
        }
      });

      // Outside click → close
      document.addEventListener('mousedown', function (e) {
        if (popup.classList.contains('hidden')) return;
        if (popup.contains(e.target)) return;
        if (anchorEl && anchorEl.contains(e.target)) return;
        hide();
      }, true);

      // Esc → close
      document.addEventListener('keydown', function (e) {
        if (popup.classList.contains('hidden')) return;
        if (e.key === 'Escape') hide();
      });

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
      // Background SB usa hue puro come base color
      sbEl.style.backgroundColor = hsvToHex(hsv.h, 1, 1);
      // Marker positions
      sbMarker.style.left = (hsv.s * 100) + '%';
      sbMarker.style.top  = ((1 - hsv.v) * 100) + '%';
      hueMarker.style.top = ((hsv.h / 360) * 100) + '%';
      previewEl.style.background = hex;
      if (!skipHexUpdate) hexEl.value = hex;
      // Live apply al caller (form + Ruby)
      if (onApply) onApply(hex);
    }

    function show(triggerEl, currentHex, applyFn) {
      init();
      if (!popup) return;
      anchorEl = triggerEl;
      onApply = applyFn;
      setFromHex(currentHex || '#ffffff');
      // Position
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
      anchorEl = null;
      onApply = null;
    }

    // ── HSV ↔ RGB ↔ Hex ────────────────────────────────────────────────
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

    return { show: show, hide: hide };
  })();

  // ═════════════════════════════════════════════════════════════════════
  // Style dialog principale
  // ═════════════════════════════════════════════════════════════════════
  function setState(newState) {
    state = newState || state;
    if (!state.values) state.values = {};
    if (!state.scenes_list) state.scenes_list = [];
    $('style-name').textContent = state.style_name || '—';
    // Nickname input: NON sovrascrivere se l'utente sta editando.
    var nickEl = $('style-nickname');
    if (nickEl && document.activeElement !== nickEl) {
      nickEl.value = state.nickname || '';
    }
    setBadgeColor(state.badge_color || '');
    $('scope-note').textContent =
      'Applies to all scenes using this style (' + (state.scenes_count || 0) + '). ' +
      'To affect only one scene, duplicate via SketchUp Window → Styles, then reassign.';
    $('footer-text').textContent = state.scenes_count + ' scene(s) use this style';
    populate(state.values);
  }

  function showScenesOverlay() {
    var overlay = $('scenes-overlay');
    var list    = $('scenes-overlay-list');
    if (!overlay || !list) return;
    list.innerHTML = '';
    var names = state.scenes_list || [];
    if (names.length === 0) {
      var empty = document.createElement('li');
      empty.textContent = '(no scenes)';
      empty.style.color = '#666';
      list.appendChild(empty);
    } else {
      names.forEach(function (name) {
        var li = document.createElement('li');
        li.textContent = name;
        list.appendChild(li);
      });
    }
    overlay.classList.remove('hidden');
  }

  function hideScenesOverlay() {
    var overlay = $('scenes-overlay');
    if (overlay) overlay.classList.add('hidden');
  }

  // Aggiorna swatch + input del Badge color senza scatenare commit.
  function setBadgeColor(hex) {
    var sw = $('sw-BadgeColor');
    var el = $('ctrl-BadgeColor');
    if (!sw || !el) return;
    var h = normalizeHex(hex);
    if (document.activeElement !== el) el.value = h || '';
    if (h) {
      sw.style.background = h;
      sw.classList.remove('swatch-empty');
    } else {
      sw.style.background = '';
      sw.classList.add('swatch-empty');
    }
  }

  function commitBadgeColor(hex) {
    var s = (hex == null ? '' : String(hex)).trim();
    var prev = state.badge_color || '';
    if (s !== '' && !normalizeHex(s)) return; // invalid → no-op
    if ((normalizeHex(s) || '') === prev) return;
    call('sm_style_set_color', { color: s });
  }

  // Commit del nickname: invia a Ruby. Vuoto = clear nickname.
  function commitNickname() {
    var el = $('style-nickname');
    if (!el) return;
    var v = el.value.trim();
    if ((v || null) === (state.nickname || null)) return;
    call('sm_style_set_nickname', { nickname: v });
  }

  // Imposta i controlli senza scatenare il change-handler che ri-invierebbe
  // l'edit a Ruby.
  function populate(vals) {
    setIntSelect('EdgeColorMode', vals.EdgeColorMode);
    setIntSelect('TransparencySort', vals.TransparencySort);
    setHex('BackgroundColor', vals.BackgroundColor);
    setHex('SkyColor', vals.SkyColor);
    setHex('HorizonColor', vals.HorizonColor);
    setBool('DrawHorizon', vals.DrawHorizon);
    setBool('ModelTransparency', vals.ModelTransparency);
    setBool('DrawHidden', vals.DrawHidden);
    setBool('DisplaySectionPlanes', vals.DisplaySectionPlanes);
    setBool('DisplaySectionCuts', vals.DisplaySectionCuts);
    setBool('DrawSilhouettes', vals.DrawSilhouettes);
    setBool('DisplaySketchAxes', vals.DisplaySketchAxes);
    setNum('ProfileWidth', vals.ProfileWidth);
    // Feedback visivo bottone "→ 1": evidenziato quando Profiles è ON e
    // ProfileWidth = 1 (= stato target che il bottone applicherebbe).
    var bpd = $('btn-profiles-default');
    if (bpd) {
      var alreadyAtTarget = (vals.DrawSilhouettes === true) &&
                            (Number(vals.ProfileWidth) === 1);
      bpd.classList.toggle('is-active', alreadyAtTarget);
      bpd.title = alreadyAtTarget
        ? 'Already at target (Profiles ON, width = 1)'
        : 'Turn Profiles ON and set width = 1';
    }
    if (!listenersBound) bindListeners();
  }

  function setNum(key, val) {
    var el = $('ctrl-' + key);
    var sl = $('slider-' + key);
    if (!el) return;
    if (val == null) {
      el.disabled = true; el.value = '';
      if (sl) { sl.disabled = true; sl.value = '0'; }
      return;
    }
    el.disabled = false;
    if (document.activeElement !== el) el.value = String(val);
    if (sl) {
      sl.disabled = false;
      if (document.activeElement !== sl) {
        // Slider è step intero; clampato al suo range. Non sovrascrivere
        // se l'utente sta draggando proprio quello slider.
        sl.value = String(Math.round(Number(val)));
      }
    }
  }

  function setIntSelect(key, val) {
    var el = $('ctrl-' + key);
    if (!el) return;
    var v = (val == null) ? '0' : String(val);
    if (el.value !== v) el.value = v;
  }
  function setBool(key, val) {
    var el = $('ctrl-' + key);
    if (!el) return;
    if (val == null) { el.disabled = true; el.checked = false; return; }
    el.disabled = false;
    el.checked = !!val;
  }
  function setHex(key, val) {
    var el = $('ctrl-' + key);
    var sw = $('sw-' + key);
    if (!el || !sw) return;
    var hex = normalizeHex(val) || '';
    if (document.activeElement !== el) el.value = hex;
    sw.style.background = hex || '#000000';
  }

  function sendChanges(changes) {
    call('sm_style_apply', { changes: changes });
  }

  function bindListeners() {
    // Select int
    ['EdgeColorMode', 'TransparencySort'].forEach(function (k) {
      var el = $('ctrl-' + k);
      if (!el) return;
      el.addEventListener('change', function () {
        var c = {}; c[k] = parseInt(el.value, 10); sendChanges(c);
      });
    });
    // Checkbox bool (Model axes = DisplaySketchAxes, RO stateful — niente più
    // toggle send_action: vedi style_dialog.rb)
    ['DrawHorizon', 'ModelTransparency', 'DrawHidden', 'DisplaySectionPlanes', 'DisplaySectionCuts', 'DrawSilhouettes', 'DisplaySketchAxes'].forEach(function (k) {
      var el = $('ctrl-' + k);
      if (!el) return;
      el.addEventListener('change', function () {
        var c = {}; c[k] = !!el.checked; sendChanges(c);
      });
    });
    // Input numerici (Profile width). Commit su change/blur, non su input:
    // evita un write per ogni keystroke/spinner-tick.
    ['ProfileWidth'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sl = $('slider-' + k);
      if (!el) return;
      function commit() {
        var raw = el.value;
        if (raw === '' || raw == null) {
          // ripristina valore corrente: non vogliamo scrivere NaN
          var cur = state.values && state.values[k];
          el.value = (cur == null ? '' : String(cur));
          if (sl && cur != null) sl.value = String(Math.round(Number(cur)));
          return;
        }
        var n = parseFloat(raw);
        if (isNaN(n)) {
          var cur2 = state.values && state.values[k];
          el.value = (cur2 == null ? '' : String(cur2));
          if (sl && cur2 != null) sl.value = String(Math.round(Number(cur2)));
          return;
        }
        if (sl) sl.value = String(Math.round(n));
        var c = {}; c[k] = n; sendChanges(c);
      }
      el.addEventListener('change', commit);
      el.addEventListener('blur', commit);
      el.addEventListener('input', function () {
        // Live-sync visivo dello slider mentre l'utente digita nel numero.
        // Niente commit a Ruby qui.
        var n = parseFloat(el.value);
        if (!isNaN(n) && sl) sl.value = String(Math.round(n));
      });
      el.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); el.blur(); }
        else if (e.key === 'Escape') {
          var cur = state.values && state.values[k];
          el.value = (cur == null ? '' : String(cur));
          if (sl && cur != null) sl.value = String(Math.round(Number(cur)));
          el.blur();
        }
      });

      // Slider (solo per fog): durante drag aggiorna soltanto il numero
      // accanto. Commit a Ruby solo al rilascio del mouse (event 'change'),
      // per non spammare write_attribute su modelli con observer terzo.
      if (sl) {
        sl.addEventListener('input', function () {
          // Live: sincronizza il numero accanto, nessun commit Ruby.
          el.value = sl.value;
        });
        sl.addEventListener('change', function () {
          var n = parseFloat(sl.value);
          if (isNaN(n)) return;
          el.value = String(n);
          var c = {}; c[k] = n; sendChanges(c);
        });
      }
    });
    // Bottone "Open native Styles panel" nell'header
    var btnNative = $('btn-open-native');
    if (btnNative) {
      btnNative.addEventListener('click', function () { call('sm_style_open_native'); });
    }
    // Bottone "Profiles → 1": atomico DrawSilhouettes=true + ProfileWidth=1
    var btnProfilesDefault = $('btn-profiles-default');
    if (btnProfilesDefault) {
      btnProfilesDefault.addEventListener('click', function () {
        call('sm_style_set_profiles_default');
      });
    }
    // Hex color: text input + swatch clickabile che apre il popup HSV custom.
    // (Niente più <input type="color">, broken in CEF SU 2019.)
    ['BackgroundColor', 'SkyColor', 'HorizonColor'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sw = $('sw-' + k);
      if (!el || !sw) return;

      // Swatch clickabile → apre popup picker
      sw.addEventListener('click', function () {
        var current = normalizeHex(state.values && state.values[k]) || '#ffffff';
        ColorPopup.show(sw, current, function (hex) {
          // Live apply ad ogni cambio nel popup
          el.value = hex;
          sw.style.background = hex;
          var c = {}; c[k] = hex; sendChanges(c);
        });
      });

      // Text input: anteprima live durante typing, commit su change/blur.
      el.addEventListener('input', function () {
        var hex = normalizeHex(el.value);
        if (hex) sw.style.background = hex;
      });
      el.addEventListener('change', commitHex);
      el.addEventListener('blur', commitHex);
      function commitHex() {
        var hex = normalizeHex(el.value);
        if (!hex) {
          var prev = normalizeHex(state.values && state.values[k]) || '';
          el.value = prev;
          sw.style.background = prev || '#000000';
          return;
        }
        el.value = hex;
        sw.style.background = hex;
        var c = {}; c[k] = hex; sendChanges(c);
      }
    });
    // Footer cliccabile → overlay HTML interno (no messagebox, no suono)
    var footerEl = $('footer-text');
    if (footerEl) {
      footerEl.addEventListener('click', function () {
        showScenesOverlay();
      });
    }
    var closeBtn = $('scenes-overlay-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', hideScenesOverlay);
    }
    // Click fuori dall'overlay-box → chiude
    var overlayEl = $('scenes-overlay');
    if (overlayEl) {
      overlayEl.addEventListener('mousedown', function (e) {
        if (e.target === overlayEl) hideScenesOverlay();
      });
    }
    // Nickname input: commit su Enter o blur. Esc = ripristina.
    var nickEl = $('style-nickname');
    if (nickEl) {
      nickEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); nickEl.blur(); }
        else if (e.key === 'Escape') {
          nickEl.value = state.nickname || '';
          nickEl.blur();
        }
      });
      nickEl.addEventListener('blur', commitNickname);
    }
    // Badge color: swatch apre il popup HSV; hex input + bottone clear.
    var bSw = $('sw-BadgeColor');
    var bEl = $('ctrl-BadgeColor');
    var bClr = $('btn-clear-badgecolor');
    if (bSw && bEl) {
      bSw.addEventListener('click', function () {
        var current = normalizeHex(state.badge_color) || '#cccccc';
        ColorPopup.show(bSw, current, function (hex) {
          bEl.value = hex;
          bSw.style.background = hex;
          bSw.classList.remove('swatch-empty');
          commitBadgeColor(hex);
        });
      });
      bEl.addEventListener('input', function () {
        var h = normalizeHex(bEl.value);
        if (h) { bSw.style.background = h; bSw.classList.remove('swatch-empty'); }
      });
      function commitFromInput() {
        var v = bEl.value.trim();
        if (v === '') { commitBadgeColor(''); return; }
        var h = normalizeHex(v);
        if (!h) { setBadgeColor(state.badge_color || ''); return; }
        bEl.value = h;
        commitBadgeColor(h);
      }
      bEl.addEventListener('change', commitFromInput);
      bEl.addEventListener('blur', commitFromInput);
      bEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); bEl.blur(); }
        else if (e.key === 'Escape') { setBadgeColor(state.badge_color || ''); bEl.blur(); }
      });
    }
    if (bClr) {
      bClr.addEventListener('click', function () { commitBadgeColor(''); });
    }
    listenersBound = true;
  }

  function init() {
    call('sm_style_ready');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  return { setState: setState };
})();
