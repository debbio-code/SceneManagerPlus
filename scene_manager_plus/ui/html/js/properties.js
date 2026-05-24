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

  // Mapping UI: label native SU + fusione use_style+use_rendering_options
  // in un unico "Style and Fog" (come nella UI nativa SU — 7 voci, non 8).
  var FLAG_UI = [
    { label: 'Camera Location',       keys: ['use_camera'] },
    { label: 'Hidden Geometry',       keys: ['use_hidden'] },
    { label: 'Visible Layers',        keys: ['use_hidden_layers'] },
    { label: 'Active Section Planes', keys: ['use_section_planes'] },
    { label: 'Style and Fog',         keys: ['use_style', 'use_rendering_options'] },
    { label: 'Shadow Settings',       keys: ['use_shadow_info'] },
    { label: 'Axes Location',         keys: ['use_axes'] },
  ];

  function renderFlags(flagKeys, flags) {
    const el = $('#prop-flags');
    // Filtra agli item che hanno almeno una key presente in flagKeys (defensive)
    const items = FLAG_UI.filter(item => item.keys.some(k => flagKeys.indexOf(k) !== -1));
    el.innerHTML = items.map(item => {
      // Checked se TUTTE le keys dell'item sono true (coerenza con SU nativo)
      const checked = item.keys.every(k => flags && flags[k]) ? 'checked' : '';
      const fsAttr = escapeHtml(JSON.stringify(item.keys));
      return '<label><input type="checkbox" data-flags="' + fsAttr + '" ' + checked + '>' +
             '<span>' + escapeHtml(item.label) + '</span></label>';
    }).join('');
    el.querySelectorAll('input[type=checkbox]').forEach(cb => {
      cb.addEventListener('change', commit);
    });
  }

  function readForm() {
    const flags = {};
    document.querySelectorAll('#prop-flags input[type=checkbox]').forEach(cb => {
      // data-flags è un JSON array: per item merged (es. Style and Fog)
      // propaga il valore a tutte le keys corrispondenti.
      var keys;
      try { keys = JSON.parse(cb.dataset.flags || '[]'); } catch (e) { keys = []; }
      keys.forEach(k => { flags[k] = cb.checked; });
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
    const s = state && state.scene;
    if (!s) {
      // Stato vuoto: può capitare se push_state arriva con @scene_id non
      // ancora risolto a una pagina, in race con apertura dialog. Se avevamo
      // uno stato valido prima, non sovrascriviamo i campi a vuoto. Se non
      // avevamo nulla, mostriamo "scene not found".
      if (SMP.state && SMP.state.scene) return;
      SMP.state = state;
      $('#scene-title').textContent = '(scene not found)';
      $('#prop-name').value = '';
      $('#prop-desc').value = '';
      $('#prop-flags').innerHTML = '';
      $('#btn-update-view').disabled = true;
      return;
    }
    SMP.state = state;
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

    // Right-click → menu di scelta singola property da aggiornare. Solo le
    // property attualmente checkate in "Properties to save" sono offerte:
    // coerente con l'intento "salva ciò che la scena dichiara di tracciare".
    $('#btn-update-view').addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const id = SMP.state && SMP.state.scene && SMP.state.scene.id;
      if (!id) return;
      const flags = SMP.state.scene.flags || {};
      const items = FLAG_UI.filter(item => item.keys.every(k => flags[k]));
      if (items.length === 0) {
        setStatus('No properties enabled');
        return;
      }
      showPartialMenu(e.clientX, e.clientY, items, (keys) => {
        call('sm_props_update_from_view', { id: id, flags: keys });
        setStatus('Captured ' + keys.length + ' property');
      });
    });

    call('sm_props_ready');
  });

  function showPartialMenu(x, y, items, onPick) {
    hidePartialMenu();
    const menu = document.createElement('div');
    menu.className = 'context-menu';
    menu.id = 'smp-ctx-menu';
    const header = document.createElement('div');
    header.className = 'ctx-header';
    header.textContent = 'Update only…';
    menu.appendChild(header);
    items.forEach(item => {
      const row = document.createElement('div');
      row.className = 'ctx-item';
      row.textContent = item.label;
      row.addEventListener('click', () => {
        hidePartialMenu();
        onPick(item.keys);
      });
      menu.appendChild(row);
    });
    document.body.appendChild(menu);
    const mw = menu.offsetWidth, mh = menu.offsetHeight;
    const vw = window.innerWidth, vh = window.innerHeight;
    if (x + mw > vw) x = Math.max(0, vw - mw - 2);
    if (y + mh > vh) y = Math.max(0, vh - mh - 2);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    setTimeout(() => {
      document.addEventListener('mousedown', onDocMouseDownClose, true);
      window.addEventListener('blur', hidePartialMenu);
    }, 0);
  }
  function hidePartialMenu() {
    const m = document.getElementById('smp-ctx-menu');
    if (m && m.parentNode) m.parentNode.removeChild(m);
    document.removeEventListener('mousedown', onDocMouseDownClose, true);
    window.removeEventListener('blur', hidePartialMenu);
  }
  function onDocMouseDownClose(e) {
    const m = document.getElementById('smp-ctx-menu');
    if (m && !m.contains(e.target)) hidePartialMenu();
  }
})();
