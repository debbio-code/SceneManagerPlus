// Scene Manager+ — Properties dialog JS (live commit, no Apply button)
(function () {
  'use strict';

  const SMP = { state: null, applying: false };
  window.SMP = SMP;

  function $(sel) { return document.querySelector(sel); }
  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) { console.error('[SMP] call failed', name, e); }
  }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;');
  }

  function renderFlags(flagKeys, flags) {
    const el = $('#prop-flags');
    el.innerHTML = flagKeys.map(k => {
      const checked = flags && flags[k] ? 'checked' : '';
      const label = k.replace(/^use_/, '').replace(/_/g, ' ');
      return '<label><input type="checkbox" data-flag="' + k + '" ' + checked + '>' +
             '<span>' + escapeHtml(label) + '</span></label>';
    }).join('');
    // listener live su ogni checkbox
    el.querySelectorAll('input[type=checkbox]').forEach(cb => {
      cb.addEventListener('change', commit);
    });
  }

  function readForm() {
    const flags = {};
    document.querySelectorAll('#prop-flags input[type=checkbox]').forEach(cb => {
      flags[cb.dataset.flag] = cb.checked;
    });
    return {
      id:          SMP.state && SMP.state.scene ? SMP.state.scene.id : null,
      name:        $('#prop-name').value,
      description: $('#prop-desc').value,
      flags:       flags
    };
  }

  function setStatus(msg) {
    $('#status').textContent = msg;
    if (msg) setTimeout(() => { $('#status').textContent = ''; }, 1500);
  }

  function commit() {
    if (SMP.applying) return;
    const data = readForm();
    if (!data.id) return;
    // Se name è vuoto, non inviarlo (SU non accetterebbe nome vuoto)
    if (!data.name || !data.name.trim()) {
      // ripristina dal state
      $('#prop-name').value = (SMP.state && SMP.state.scene) ? SMP.state.scene.name : '';
      setStatus('Name cannot be empty');
      return;
    }
    SMP.applying = true;
    call('sm_props_apply', data);
    setStatus('Saved');
    // applying si resetta in setState (push successivo)
    setTimeout(() => { SMP.applying = false; }, 200);
  }

  SMP.setState = function (state) {
    SMP.state = state;
    const s = state && state.scene;
    if (!s) {
      $('#scene-title').textContent = '(scene not found)';
      $('#prop-name').value = '';
      $('#prop-desc').value = '';
      $('#prop-flags').innerHTML = '';
      $('#btn-update-view').disabled = true;
      return;
    }
    $('#scene-title').textContent = s.name || '(unnamed)';
    // Non sovrascrivere il campo se l'utente sta digitando in quel momento
    const nameEl = $('#prop-name');
    const descEl = $('#prop-desc');
    if (document.activeElement !== nameEl) nameEl.value = s.name || '';
    if (document.activeElement !== descEl) descEl.value = s.description || '';
    renderFlags(state.flag_keys || [], s.flags || {});
    $('#btn-update-view').disabled = false;
    renderPreview(state.preview_url);
    SMP.applying = false;
  };

  function renderPreview(url) {
    const box = $('#preview-box');
    if (!url) {
      box.innerHTML = '<div class="preview-empty">No preview generated.<br>Use the 🎬 Preview button in the main toolbar.</div>';
      return;
    }
    // Cache-buster sull'URL: lo stesso file PNG può essere riscritto, CEF
    // potrebbe servire la versione cached. ?t=<ts> forza il reload.
    const bust = (url.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now();
    box.innerHTML = '<img src="' + url + bust + '" alt="Scene preview">';
  }

  document.addEventListener('DOMContentLoaded', () => {
    // Commit su blur / change per i campi testuali
    $('#prop-name').addEventListener('change', commit);
    $('#prop-name').addEventListener('blur', commit);
    $('#prop-desc').addEventListener('change', commit);
    $('#prop-desc').addEventListener('blur', commit);

    // Enter sul nome → commit + blur
    $('#prop-name').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); e.target.blur(); }
    });
    // Ctrl+Enter sulla descrizione → commit + blur
    $('#prop-desc').addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault(); e.target.blur();
      }
    });

    $('#btn-update-view').addEventListener('click', () => {
      const id = SMP.state && SMP.state.scene && SMP.state.scene.id;
      if (!id) return;
      call('sm_props_update_from_view', { id: id });
      setStatus('Captured viewport');
    });

    call('sm_props_ready');
  });
})();
