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

  // ---- Values from form ----
  function readForm() {
    return {
      enabled: $('#naming-enabled').checked,
      prefix_mode: $('#prefix-mode').value,
      prefix_custom: $('#prefix-custom').value,
      pad: parseInt($('#pad').value, 10) || 0,
      separator: $('#separator').value,
      include_scene_name: $('#include-scene-name').checked
    };
  }

  function writeForm(naming) {
    $('#naming-enabled').checked = !!naming.enabled;
    $('#prefix-mode').value = naming.prefix_mode || 'skp_name';
    $('#prefix-custom').value = naming.prefix_custom || '';
    $('#pad').value = (naming.pad == null ? 2 : naming.pad);
    $('#separator').value = naming.separator || '_';
    $('#include-scene-name').checked = !!naming.include_scene_name;
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

  // ---- Exposed callbacks from Ruby ----
  SMS.setState = function (state) {
    SMS.state = state;
    const naming = (state.settings && state.settings.naming) || {};
    writeForm(naming);
    requestPreview();
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
    ['naming-enabled', 'prefix-mode', 'prefix-custom', 'pad',
     'separator', 'include-scene-name'].forEach(id => {
      const el = document.getElementById(id);
      if (!el) return;
      el.addEventListener('input', onChange);
      el.addEventListener('change', onChange);
    });

    $('#btn-save').addEventListener('click', () => {
      call('sm_settings_set', { group: 'naming', values: readForm() });
      setStatus('Saved');
    });

    $('#btn-apply').addEventListener('click', () => {
      const msg = 'Rename ALL scenes using the current pattern?\n\n' +
                  'Use Ctrl+Z in SketchUp to revert.';
      if (!confirm(msg)) return;
      call('sm_naming_apply', { values: readForm() });
    });

    call('sm_settings_ready');
  });
})();
