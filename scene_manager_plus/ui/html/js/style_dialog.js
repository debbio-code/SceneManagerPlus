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

  function setState(newState) {
    state = newState || state;
    if (!state.values) state.values = {};
    $('style-name').textContent = state.style_name || '—';
    // Nickname input: NON sovrascrivere se l'utente sta editando.
    var nickEl = $('style-nickname');
    if (nickEl && document.activeElement !== nickEl) {
      nickEl.value = state.nickname || '';
    }
    $('scope-note').textContent =
      'Applies to all scenes using this style (' + (state.scenes_count || 0) + '). ' +
      'To affect only one scene, duplicate the style in SU’s Window → Styles first.';
    $('footer-text').textContent = state.scenes_count + ' scene(s) use this style';
    populate(state.values);
  }

  // Commit del nickname: invia a Ruby. Vuoto = clear nickname.
  function commitNickname() {
    var el = $('style-nickname');
    if (!el) return;
    var v = el.value.trim();
    // Evita scritture inutili se non cambiato.
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
    setBool('DrawHorizon', vals.DrawHorizon);
    setBool('DrawHidden', vals.DrawHidden);
    setBool('DisplaySectionPlanes', vals.DisplaySectionPlanes);
    setBool('DisplaySectionCuts', vals.DisplaySectionCuts);
    if (!listenersBound) bindListeners();
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
    var pk = $('ctrl-' + key + '-picker');
    if (!el || !sw) return;
    var hex = normalizeHex(val) || '';
    // Solo se l'input non è in focus (l'utente potrebbe stare scrivendo)
    if (document.activeElement !== el) el.value = hex;
    sw.style.background = hex || '#000000';
    // CEF SU 2019: <input type="color"> accetta solo lowercase hex (normalizeHex
    // già lowercase). Salta sync se vuoto per non confondere il picker.
    if (pk && hex) pk.value = hex;
  }

  function normalizeHex(s) {
    if (!s) return null;
    s = String(s).trim().toLowerCase();
    if (s[0] !== '#') s = '#' + s;
    return /^#[0-9a-f]{6}$/.test(s) ? s : null;
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
    // Toggle button per Model Axes — fire-and-forget (no state in SU 2019 API)
    var btnAxes = $('ctrl-ToggleAxes');
    if (btnAxes) {
      btnAxes.addEventListener('click', function () { call('sm_style_toggle_axes'); });
    }
    // Checkbox bool
    ['DrawHorizon', 'DrawHidden', 'DisplaySectionPlanes', 'DisplaySectionCuts'].forEach(function (k) {
      var el = $('ctrl-' + k);
      if (!el) return;
      el.addEventListener('change', function () {
        var c = {}; c[k] = !!el.checked; sendChanges(c);
      });
    });
    // Hex color: tre controlli sincronizzati per ciascuna chiave —
    //   - <input type="color"> (picker nativo OS)
    //   - <input type="text"> hex (#aabbcc, lowercase)
    //   - swatch <span> (preview)
    // CEF SU 2019 quirks (vedi CLAUDE.md "Color picker"):
    //   - <input type="color"> accetta SOLO hex lowercase (normalizeHex già lo
    //     fa). #FFFFFF uppercase viene rifiutato silenziosamente.
    //   - L'event 'change' sul picker non sempre scatta affidabilmente; uso
    //     'input' che fire continuamente durante il drag della color wheel.
    ['BackgroundColor', 'SkyColor'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sw = $('sw-' + k);
      var pk = $('ctrl-' + k + '-picker');
      if (!el || !sw) return;

      // Picker nativo: ogni cambio (anche durante drag) propaga a hex + swatch + Ruby.
      if (pk) {
        pk.addEventListener('input', function () {
          var hex = normalizeHex(pk.value);
          if (!hex) return;
          el.value = hex;
          sw.style.background = hex;
          var c = {}; c[k] = hex; sendChanges(c);
        });
      }

      // Text input: anteprima live durante typing, commit su change/blur.
      el.addEventListener('input', function () {
        var hex = normalizeHex(el.value);
        if (hex) {
          sw.style.background = hex;
          if (pk) pk.value = hex;
        }
      });
      el.addEventListener('change', commitHex);
      el.addEventListener('blur', commitHex);
      function commitHex() {
        var hex = normalizeHex(el.value);
        if (!hex) {
          // Ripristina dallo state
          var prev = normalizeHex(state.values && state.values[k]) || '';
          el.value = prev;
          sw.style.background = prev || '#000000';
          if (pk && prev) pk.value = prev;
          return;
        }
        el.value = hex;
        sw.style.background = hex;
        if (pk) pk.value = hex;
        var c = {}; c[k] = hex; sendChanges(c);
      }
    });
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
