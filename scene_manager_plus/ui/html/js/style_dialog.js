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
    $('scope-note').textContent =
      'Applies to all scenes using this style (' + (state.scenes_count || 0) + '). ' +
      'To affect only one scene, duplicate the style in SU’s Window → Styles first.';
    $('footer-text').textContent = state.scenes_count + ' scene(s) use this style';
    populate(state.values);
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
    if (!el || !sw) return;
    var hex = normalizeHex(val) || '';
    // Solo se l'input non è in focus (l'utente potrebbe stare scrivendo)
    if (document.activeElement !== el) el.value = hex;
    sw.style.background = hex || '#000000';
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
    // Hex color
    ['BackgroundColor', 'SkyColor'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sw = $('sw-' + k);
      if (!el || !sw) return;
      el.addEventListener('input', function () {
        var hex = normalizeHex(el.value);
        if (hex) sw.style.background = hex;
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
          return;
        }
        el.value = hex;
        sw.style.background = hex;
        var c = {}; c[k] = hex; sendChanges(c);
      }
    });
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
