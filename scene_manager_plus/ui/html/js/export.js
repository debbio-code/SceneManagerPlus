// Scene Manager+ — Export dialog JS
(function () {
  'use strict';

  const SMX = { state: null };
  window.SMX = SMX;

  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) { console.error('[SMX] call failed', name, e); }
  }
  function $(s) { return document.querySelector(s); }
  function $$(s) { return Array.from(document.querySelectorAll(s)); }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
      .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  function renderFolders(folders) {
    const list = $('#folder-list');
    if (!folders || folders.length === 0) {
      list.innerHTML = '<p class="empty">No folders defined.</p>';
      return;
    }
    list.innerHTML = folders.map(f =>
      '<label>' +
        '<input type="checkbox" class="folder-check" value="' + escapeHtml(f.id) + '">' +
        '<span>' + escapeHtml(f.name) + '</span>' +
        '<span class="count">' + f.count + '</span>' +
      '</label>'
    ).join('');
  }

  function updateScopeUI() {
    const v = (document.querySelector('input[name="scope"]:checked') || {}).value;
    $('#folder-list').classList.toggle('hidden', v !== 'folders');
  }

  function renderSummary(s) {
    const settings = (s && s.settings) || {};
    const fmt = (settings.format || 'png').toUpperCase();
    const w = settings.width || 1920;
    const h = settings.height || 1080;
    const dir = settings.output_dir || '(auto: Immagini/ next to the .skp)';
    $('#out-summary').innerHTML =
      'Format: <code>' + escapeHtml(fmt) + '</code> &middot; ' +
      'Size: <code>' + w + '×' + h + '</code><br>' +
      'Folder: <code>' + escapeHtml(dir) + '</code>';
  }

  SMX.setState = function (state) {
    SMX.state = state;
    renderFolders(state.folders || []);
    renderSummary(state);

    const selCount = (state.selected || []).length;
    $('#count-selected').textContent = selCount ? '(' + selCount + ')' : '(none)';
    $('#rb-selected').disabled = !state.has_select;
    if (!state.has_select && document.querySelector('input[name="scope"]:checked').value === 'selected') {
      document.querySelector('input[name="scope"][value="all"]').checked = true;
    }
    updateScopeUI();
  };

  document.addEventListener('DOMContentLoaded', () => {
    $$('input[name="scope"]').forEach(el => el.addEventListener('change', updateScopeUI));

    $('#btn-cancel').addEventListener('click', () => call('sm_export_cancel'));

    $('#btn-export').addEventListener('click', () => {
      const scope = document.querySelector('input[name="scope"]:checked').value;
      const folder_ids = $$('.folder-check:checked').map(el => el.value);
      if (scope === 'folders' && folder_ids.length === 0) {
        alert('Select at least one folder.');
        return;
      }
      call('sm_export_run', { scope: scope, folder_ids: folder_ids });
    });

    call('sm_export_ready');
  });
})();
