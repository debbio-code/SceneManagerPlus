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
    setIfNotFocused($('#prefix-mode'),        'value',   naming.prefix_mode || 'skp_first_word');
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
                   f.prefix_mode === 'skp_first_word' ? '<skp_first_word>' :
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
    const naming  = (state.settings && state.settings.naming)         || {};
    const exp     = (state.settings && state.settings.export)         || {};
    const preview = (state.settings && state.settings.preview)        || {};
    const logo    = (state.settings && state.settings.logo)           || {};
    const label   = (state.settings && state.settings.filename_label) || {};
    const tb      = (state.settings && state.settings.titleblock)     || {};
    const ui      = (state.settings && state.settings.ui)             || {};
    writeForm(naming);
    writeExport(exp);
    writePreview(preview);
    writeLogo(logo, state.default_logo_name);
    writeLabel(label);
    writeTitleblock(tb);
    writeUi(ui);
    // Debug-on-startup: flag globale (non nel gruppo 'ui'), arriva al
    // top-level dello state.
    setIfNotFocused($('#ui-debug-on-open'), 'checked', !!state.debug_mode_on_open);
    requestPreview();
  };

  function readPreview() {
    return {
      line_scale_multiplier: toFloatOr($('#preview-line-scale').value, 1.0)
    };
  }
  function writePreview(p) {
    setIfNotFocused($('#preview-line-scale'), 'value',
      p.line_scale_multiplier == null ? 1 : p.line_scale_multiplier);
  }

  function normalizeHex(s) {
    if (!s) return '#ffffff';
    var v = String(s).trim().toLowerCase();
    if (v[0] !== '#') v = '#' + v;
    // espande #abc → #aabbcc
    if (/^#[0-9a-f]{3}$/.test(v)) {
      v = '#' + v[1] + v[1] + v[2] + v[2] + v[3] + v[3];
    }
    if (!/^#[0-9a-f]{6}$/.test(v)) return '#ffffff';
    return v;
  }
  function syncColorSwatch() {
    var v = normalizeHex($('#label-color').value);
    var sw = $('#label-color-swatch');
    if (sw) sw.style.background = v;
  }
  function readLabel() {
    return {
      enabled:     $('#label-enabled').checked,
      font_family: $('#label-font-family').value || 'Arial',
      font_size:   toIntOr($('#label-font-size').value, 28),
      bold:        $('#label-bold').checked,
      color:       normalizeHex($('#label-color').value),
      offset_x:    toIntOr($('#label-offset-x').value, 20),
      offset_y:    toIntOr($('#label-offset-y').value, 20),
      opacity:     toIntOr($('#label-opacity').value, 100)
    };
  }
  function writeLabel(l) {
    setIfNotFocused($('#label-enabled'),     'checked', !!l.enabled);
    setIfNotFocused($('#label-font-family'), 'value',   l.font_family || 'Arial');
    setIfNotFocused($('#label-font-size'),   'value',   (l.font_size == null ? 28 : l.font_size));
    setIfNotFocused($('#label-bold'),        'checked', !!l.bold);
    setIfNotFocused($('#label-color'),       'value',   normalizeHex(l.color));
    setIfNotFocused($('#label-offset-x'),    'value',   (l.offset_x == null ? 20 : l.offset_x));
    setIfNotFocused($('#label-offset-y'),    'value',   (l.offset_y == null ? 20 : l.offset_y));
    setIfNotFocused($('#label-opacity'),     'value',   (l.opacity  == null ? 100 : l.opacity));
    syncColorSwatch();
  }
  function setLabelStatus(msg) {
    const el = $('#label-status');
    if (!el) return;
    el.textContent = msg;
    if (msg) setTimeout(() => { el.textContent = ''; }, 2500);
  }

  function readTitleblock() {
    return {
      enabled:        $('#tb-enabled').checked,
      height_px:      toIntOr($('#tb-height').value, 120),
      font_family:    $('#tb-font-family').value || 'Century Gothic',
      project_by:     $('#tb-project-by').value || 'Arch. Nicola Debiasi',
      designer:       $('#tb-designer').value,
      project_phase:  $('#tb-project-phase').value || 'Definitivo',
      date_override:  $('#tb-date-override').value || '',
      white_margin_px: toIntOr($('#tb-white-margin').value, 2)
    };
  }
  function writeTitleblock(t) {
    setIfNotFocused($('#tb-enabled'),        'checked', !!t.enabled);
    setIfNotFocused($('#tb-height'),         'value',   (t.height_px == null ? 120 : t.height_px));
    setIfNotFocused($('#tb-font-family'),    'value',   t.font_family || 'Century Gothic');
    setIfNotFocused($('#tb-project-by'),     'value',   t.project_by || 'Arch. Nicola Debiasi');
    setIfNotFocused($('#tb-designer'),       'value',   (t.designer == null ? 'Arch. Nicola Debiasi' : t.designer));
    setIfNotFocused($('#tb-project-phase'),  'value',   t.project_phase || 'Definitivo');
    setIfNotFocused($('#tb-date-override'),  'value',   t.date_override || '');
    setIfNotFocused($('#tb-white-margin'),   'value',   (t.white_margin_px == null ? 2 : t.white_margin_px));
  }
  function setTbStatus(msg) {
    const el = $('#tb-status');
    if (!el) return;
    el.textContent = msg;
    if (msg) setTimeout(() => { el.textContent = ''; }, 2500);
  }

  function readUi() {
    return {
      show_order_banner:       $('#ui-show-order-banner').checked,
      hide_scene_tabs_on_open: $('#ui-hide-scene-tabs-on-open').checked
    };
  }
  function writeUi(u) {
    setIfNotFocused($('#ui-show-order-banner'), 'checked', u.show_order_banner !== false);
    setIfNotFocused($('#ui-hide-scene-tabs-on-open'), 'checked', !!u.hide_scene_tabs_on_open);
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

  function setDebugStatus(msg) {
    const el = $('#debug-status');
    if (!el) return;
    el.textContent = msg || '';
  }
  SMS.setDebugResult = function (msg) {
    setDebugStatus(msg || 'Done');
  };

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
    // 'input' → solo preview live; 'change' (blur/Enter) → save.
    // Save on input scatena set_attribute ogni cifra; su modelli pesanti
    // (con observer di terzi su attribute change) ogni write costa ~5s.
    // Spostare il save su blur evita freeze a metà digitazione.
    ['prefix-custom', 'pad', 'separator'].forEach(id => {
      const el = document.getElementById(id);
      if (el) {
        el.addEventListener('input', onChange);
        el.addEventListener('change', saveNamingNow);
      }
    });
    ['naming-enabled', 'prefix-mode', 'include-scene-name'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', () => { onChange(); saveNamingNow(); });
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
      if (el) el.addEventListener('change', saveExportNow);
    });

    // Preview line scale: auto-save indipendente (gruppo 'preview').
    let prevSaveTimer = null;
    function savePreviewNow() {
      call('sm_settings_set', { group: 'preview', values: readPreview() });
      setExportStatus('Saved');
    }
    function savePreviewDebounced() {
      clearTimeout(prevSaveTimer);
      prevSaveTimer = setTimeout(savePreviewNow, 350);
    }
    const prevLs = document.getElementById('preview-line-scale');
    if (prevLs) prevLs.addEventListener('change', savePreviewNow);
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
      if (el) el.addEventListener('change', saveLogoNow);
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

    // Filename label form: stesso pattern auto-save (debounce su testo/numeri,
    // immediato su checkbox e color).
    let labelSaveTimer = null;
    function saveLabelNow() {
      call('sm_settings_set', { group: 'filename_label', values: readLabel() });
      setLabelStatus('Saved');
    }
    function saveLabelDebounced() {
      clearTimeout(labelSaveTimer);
      labelSaveTimer = setTimeout(saveLabelNow, 350);
    }
    ['label-font-family', 'label-font-size', 'label-offset-x', 'label-offset-y', 'label-opacity'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveLabelNow);
    });
    ['label-enabled', 'label-bold'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveLabelNow);
    });
    // Color: input testuale (CEF 2019 ha <input type=color> instabile).
    // - 'input' aggiorna swatch in tempo reale e fa autosave debounced.
    // - 'blur'/'change' normalizza il valore (es. 'fff' → '#ffffff').
    const labelColor = document.getElementById('label-color');
    if (labelColor) {
      // input: solo update swatch live (niente save → no freeze a metà typing)
      labelColor.addEventListener('input', syncColorSwatch);
      labelColor.addEventListener('change', () => {
        labelColor.value = normalizeHex(labelColor.value);
        syncColorSwatch();
        saveLabelNow();
      });
      labelColor.addEventListener('blur', () => {
        labelColor.value = normalizeHex(labelColor.value);
        syncColorSwatch();
      });
    }
    // Preset buttons: click → set value + save immediato
    document.querySelectorAll('.color-preset').forEach(btn => {
      btn.addEventListener('click', () => {
        const c = btn.getAttribute('data-color');
        if (!c || !labelColor) return;
        labelColor.value = c;
        syncColorSwatch();
        saveLabelNow();
      });
    });

    // Titleblock form: stesso pattern auto-save.
    let tbSaveTimer = null;
    function saveTbNow() {
      call('sm_settings_set', { group: 'titleblock', values: readTitleblock() });
      setTbStatus('Saved');
    }
    function saveTbDebounced() {
      clearTimeout(tbSaveTimer);
      tbSaveTimer = setTimeout(saveTbNow, 350);
    }
    ['tb-height', 'tb-font-family', 'tb-date-override', 'tb-white-margin'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveTbNow);
    });
    ['tb-enabled', 'tb-project-by', 'tb-designer', 'tb-project-phase'].forEach(id => {
      const el = document.getElementById(id);
      if (el) el.addEventListener('change', saveTbNow);
    });

    // UI form: auto-save su change checkbox.
    function saveUiNow() {
      call('sm_settings_set', { group: 'ui', values: readUi() });
      setUiStatus('Saved');
    }
    const uiBanner = document.getElementById('ui-show-order-banner');
    if (uiBanner) uiBanner.addEventListener('change', saveUiNow);
    const uiHideTabs = document.getElementById('ui-hide-scene-tabs-on-open');
    if (uiHideTabs) uiHideTabs.addEventListener('change', saveUiNow);

    // Styles: purge unused styles. UI a senso unico (Ruby fa il
    // confirmation messagebox + purge_unused + cleanup metadata).
    const purgeBtn = document.getElementById('btn-purge-unused-styles');
    if (purgeBtn) {
      purgeBtn.addEventListener('click', () => {
        call('sm_settings_purge_unused_styles');
      });
    }

    // Migrazione dei nomi stile legacy. Anche qui Ruby fa conferma + report.
    const migrateBtn = document.getElementById('btn-migrate-style-names');
    if (migrateBtn) {
      migrateBtn.addEventListener('click', () => {
        call('sm_settings_migrate_style_names');
      });
    }

    // Debugging mode on startup: checkbox persistente (flag globale).
    // Toggle-on attiva subito (Ruby apre console + MCP e riporta via
    // SMS.setDebugResult); toggle-off persiste solo per i prossimi avvii.
    const debugChk = document.getElementById('ui-debug-on-open');
    if (debugChk) {
      debugChk.addEventListener('change', () => {
        if (debugChk.checked) setDebugStatus('Starting…');
        call('sm_settings_debug_on_open', { enabled: debugChk.checked });
      });
    }

    call('sm_settings_ready');
  });
})();
