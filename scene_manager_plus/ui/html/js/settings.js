// Scene Manager+ — Settings dialog JS
(function () {
  'use strict';

  const SMS = {
    state: null,
    debounceTimer: null
  };
  window.SMS = SMS;

  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) {
      console.error('[SMS] call failed', name, e);
    }
  }

  function log(msg) { call('sm_settings_log', String(msg)); }

  // Coercion-helper: parseInt/parseFloat con `|| fallback` collassano 0 sul
  // fallback (0 è falsy). Per i numerici che ammettono 0 (offset, opacity 0%,
  // pad 0, ecc.) serve un check esplicito.
  function toIntOr(v, fallback) {
    if (v === '' || v == null) return fallback;
    var n = parseInt(v, 10);
    return Number.isFinite(n) ? n : fallback;
  }
  function toFloatOr(v, fallback) {
    if (v === '' || v == null) return fallback;
    var n = parseFloat(v);
    return Number.isFinite(n) ? n : fallback;
  }

  // ---- Values from form ----
  function readForm() {
    return {
      enabled: $('#naming-enabled').checked,
      prefix_mode: $('#prefix-mode').value,
      prefix_custom: $('#prefix-custom').value,
      pad: toIntOr($('#pad').value, 2),
      separator: $('#separator').value,
      include_scene_name: $('#include-scene-name').checked
    };
  }

  function writeForm(naming) {
    // Naming non ha auto-save (Save manuale): se un push_state arriva mentre
    // l'utente sta digitando — tipicamente perché l'auto-save Export/Logo
    // ha appena fatto un round-trip — NON dobbiamo sovrascrivere il campo
    // in editing, altrimenti il valore in-progress viene "ripristinato" al
    // contenuto persistito (vecchio).
    setIfNotFocused($('#naming-enabled'),     'checked', !!naming.enabled);
    setIfNotFocused($('#prefix-mode'),        'value',   naming.prefix_mode || 'skp_name');
    setIfNotFocused($('#prefix-custom'),      'value',   naming.prefix_custom || '');
    setIfNotFocused($('#pad'),                'value',   (naming.pad == null ? 2 : naming.pad));
    setIfNotFocused($('#separator'),          'value',   naming.separator || '_');
    setIfNotFocused($('#include-scene-name'), 'checked', !!naming.include_scene_name);
    updateConditionalRows();
    updatePatternString();
  }

  function $(sel) { return document.querySelector(sel); }

  function updateConditionalRows() {
    const mode = $('#prefix-mode').value;
    $('#row-prefix-custom').style.display = (mode === 'custom') ? '' : 'none';
  }

  function updatePatternString() {
    const f = readForm();
    const sep = f.separator || '';
    const prefix = f.prefix_mode === 'none' ? '' :
                   f.prefix_mode === 'custom' ? (f.prefix_custom || '<custom>') :
                   '<skp_name>';
    const pad = Math.max(0, Math.min(6, f.pad));
    const num = '1'.padStart(pad, '0');
    const parts = [];
    if (prefix) parts.push(prefix);
    parts.push(num);
    if (f.include_scene_name) parts.push('<scene_name>');
    $('#pattern-string').textContent = parts.join(sep);
  }

  function renderPreview(samples) {
    const ul = $('#preview-list');
    if (!samples || samples.length === 0) {
      ul.innerHTML = '<li class="empty">No scenes to preview.</li>';
      return;
    }
    ul.innerHTML = samples.map(s =>
      '<li>' +
        '<span class="old">' + escapeHtml(s.old) + '</span>' +
        '<span class="arrow">→</span>' +
        '<span class="new">' + escapeHtml(s.new) + '</span>' +
      '</li>'
    ).join('');
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function requestPreview() {
    clearTimeout(SMS.debounceTimer);
    SMS.debounceTimer = setTimeout(() => {
      call('sm_naming_preview', { values: readForm() });
    }, 120);
  }

  function setStatus(msg) {
    $('#apply-status').textContent = msg;
    if (msg) setTimeout(() => { $('#apply-status').textContent = ''; }, 3000);
  }

  function readExport() {
    return {
      width:       toIntOr($('#export-width').value, 1920),
      height:      toIntOr($('#export-height').value, 1080),
      format:      $('#export-format').value,
      antialias:   $('#export-antialias').checked,
      transparent: $('#export-transparent').checked,
      output_dir:  $('#output-dir').value,
      line_scale_multiplier: toFloatOr($('#export-line-scale').value, 1.0)
    };
  }
  function setIfNotFocused(el, prop, value) {
    if (!el || shouldSkipField(el)) return;
    el[prop] = value;
  }
  function writeExport(e) {
    setIfNotFocused($('#export-width'),       'value',   e.width   == null ? 1920 : e.width);
    setIfNotFocused($('#export-height'),      'value',   e.height  == null ? 1080 : e.height);
    setIfNotFocused($('#export-format'),      'value',   e.format  || 'png');
    setIfNotFocused($('#export-antialias'),   'checked', !!e.antialias);
    setIfNotFocused($('#export-transparent'), 'checked', !!e.transparent);
    setIfNotFocused($('#output-dir'),         'value',   e.output_dir || '');
    setIfNotFocused($('#export-line-scale'),  'value',   e.line_scale_multiplier == null ? 2 : e.line_scale_multiplier);
  }

  function readLogo() {
    return {
      enabled:     $('#logo-enabled').checked,
      use_default: $('#logo-use-default').checked,
      path:        $('#logo-path').value,
      width_pct:   toIntOr($('#logo-width-pct').value, 15),
      offset_x:    toIntOr($('#logo-offset-x').value, 20),
      offset_y:    toIntOr($('#logo-offset-y').value, 20),
      opacity:     toIntOr($('#logo-opacity').value, 100)
    };
  }
  function writeLogo(l, defaultLogoName) {
    setIfNotFocused($('#logo-enabled'),     'checked', !!l.enabled);
    setIfNotFocused($('#logo-use-default'), 'checked', l.use_default !== false);
    setIfNotFocused($('#logo-path'),        'value',   l.path || '');
    setIfNotFocused($('#logo-width-pct'),   'value',   (l.width_pct == null ? 15 : l.width_pct));
    setIfNotFocused($('#logo-offset-x'),    'value',   (l.offset_x == null ? 20 : l.offset_x));
    setIfNotFocused($('#logo-offset-y'),    'value',   (l.offset_y == null ? 20 : l.offset_y));
    setIfNotFocused($('#logo-opacity'),     'value',   (l.opacity  == null ? 100 : l.opacity));
    $('#logo-default-hint').textContent = defaultLogoName
      ? '(' + defaultLogoName + ')' : '(none bundled)';
    updateLogoPathRow();
  }
  function updateLogoPathRow() {
    $('#row-logo-path').style.display = $('#logo-use-default').checked ? 'none' : '';
  }

  // ---- Exposed callbacks from Ruby ----
  // Quando arriva uno state push da Ruby (es. dopo save) NON riscriviamo i
  // campi che l'utente sta editando: preserva input in-progress e impedisce
  // la perdita di valori non ancora salvati nei campi adiacenti.
  function shouldSkipField(el) {
    return el && document.activeElement === el;
  }

  SMS.setState = function (state) {
    SMS.state = state;
    const naming = (state.settings && state.settings.naming) || {};
    const exp    = (state.settings && state.settings.export) || {};
    const logo   = (state.settings && state.settings.logo)   || {};
    const ui     = (state.settings && state.settings.ui)     || {};
    writeForm(naming);
    writeExport(exp);
    writeLogo(logo, state.default_logo_name);
    writeUi(ui);
    requestPreview();
  };

  function readUi() {
    return {
      show_order_banner: $('#ui-show-order-banner').checked
    };
  }
  function writeUi(u) {
    setIfNotFocused($('#ui-show-order-banner'), 'checked', u.show_order_banner !== false);
  }
  function setUiStatus(msg) {
    const el = $('#ui-status');
    if (!el) return;
    el.textContent = msg;
    if (msg) setTimeout(() => { el.textContent = ''; }, 2500);
  }

  SMS.setOutputDir = function (path) { if (path) $('#output-dir').value = path; };
  SMS.setLogoPath  = function (path) { if (path) $('#logo-path').value  = path; };

  function setExportStatus(msg) {
    $('#export-status').textContent = msg;
    if (msg) setTimeout(() => { $('#export-status').textContent = ''; }, 2500);
  }
  function setLogoStatus(msg) {
    $('#logo-status').textContent = msg;
    if (msg) setTimeout(() => { $('#logo-status').textContent = ''; }, 2500);
  }

  SMS.setPreview = function (samples) {
    renderPreview(samples);
  };

  SMS.setApplyResult = function (count) {
    setStatus(count > 0 ? `Renamed ${count} scene${count === 1 ? '' : 's'}` : 'No scenes renamed');
  };

  // ---- Wire events ----
  function onChange() {
    updateConditionalRows();
    updatePatternString();
    requestPreview();
  }

  document.addEventListener('DOMContentLoaded', () => {
    // Naming form: auto-save (stesso pattern di Export/Logo). Prima usava
    // un Save manuale ma il flusso era inconsistente: il toggle del checkbox
    // "Enable" non persisteva, e un push_state collaterale (es. auto-save
    // Export/Logo durante editing) sovrascriveva i campi non ancora salvati.
    let namingSaveTimer = null;
    function saveNamingNow() {
      call('sm_settings_set', { group: 'naming', values: readForm() });
      setStatus('Saved');
    }
    function saveNamingDebounced() {
      clearTimeout(namingSaveTimer);
      namingSaveTimer = setTimeout(saveNamingNow, 350);
    }
    ['prefix-custom', 'pad', 'separator'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('input', () => { onChange(); saveNamingDebounced(); });
    });
    ['naming-enabled', 'prefix-mode', 'include-scene-name'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', () => { onChange(); saveNamingNow(); });
    });

    $('#btn-apply').addEventListener('click', () => {
      const msg = 'Rename ALL scenes using the current pattern?\n\n' +
                  'Use Ctrl+Z in SketchUp to revert.';
      if (!confirm(msg)) return;
      call('sm_naming_apply', { values: readForm() });
    });

    // Export form: auto-save su qualsiasi change (con piccolo debounce sui
    // campi testuali per non saturare il bridge mentre l'utente digita).
    let expSaveTimer = null;
    function saveExportNow() {
      call('sm_settings_set', { group: 'export', values: readExport() });
      setExportStatus('Saved');
    }
    function saveExportDebounced() {
      clearTimeout(expSaveTimer);
      expSaveTimer = setTimeout(saveExportNow, 350);
    }
    ['export-width', 'export-height', 'output-dir', 'export-line-scale'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('input', saveExportDebounced);
    });
    ['export-format', 'export-antialias', 'export-transparent'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveExportNow);
    });
    $('#btn-browse-output').addEventListener('click', () => {
      call('sm_pick_dir', { current: $('#output-dir').value });
    });

    // Logo form: stesso pattern auto-save.
    let logoSaveTimer = null;
    function saveLogoNow() {
      call('sm_settings_set', { group: 'logo', values: readLogo() });
      setLogoStatus('Saved');
    }
    function saveLogoDebounced() {
      clearTimeout(logoSaveTimer);
      logoSaveTimer = setTimeout(saveLogoNow, 350);
    }
    ['logo-path', 'logo-width-pct', 'logo-offset-x', 'logo-offset-y', 'logo-opacity'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('input', saveLogoDebounced);
    });
    ['logo-enabled', 'logo-use-default'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveLogoNow);
    });
    // UX: spuntare "Use default logo" attiva implicitamente il watermark.
    // Senza questo collegamento è facile aspettarsi il logo ma vederselo
    // mancare perché la master "Add watermark on export" è ancora off.
    $('#logo-use-default').addEventListener('change', () => {
      if ($('#logo-use-default').checked && !$('#logo-enabled').checked) {
        $('#logo-enabled').checked = true;
        saveLogoNow();
      }
    });
    $('#btn-browse-logo').addEventListener('click', () => {
      call('sm_pick_logo', { current: $('#logo-path').value });
    });
    $('#logo-use-default').addEventListener('change', updateLogoPathRow);

    // UI form: auto-save su change checkbox.
    function saveUiNow() {
      call('sm_settings_set', { group: 'ui', values: readUi() });
      setUiStatus('Saved');
    }
    const uiBanner = document.getElementById('ui-show-order-banner');
    if (uiBanner) uiBanner.addEventListener('change', saveUiNow);

    call('sm_settings_ready');
  });
})();
