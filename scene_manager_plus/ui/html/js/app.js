window.__SM_BUILD__ = 'phase2b-2';
window.SM = (function () {
  var state = { scenes: [], tree: [], folders: [], flag_keys: [], previews: {} };
  var selection = []; // array di scene id
  var anchorId  = null; // ultimo id cliccato (per shift-range)
  var pendingCollapseId = null; // id su cui collassare la selezione se mouseup senza drag
  var lastClickId = null;
  var lastClickTs = 0;
  var DBLCLICK_MS = 400;
  var thumbsOn = false; // session-only toggle
  var listEl, statusEl;

  function $(id) { return document.getElementById(id); }

  function setState(newState) {
    state = newState || state;
    if (!state.scenes) state.scenes = [];
    if (!state.tree)   state.tree   = [];
    if (!state.flag_keys) state.flag_keys = [];
    if (!state.previews) state.previews = {};
    state.preview_ts = Date.now();
    render();
    var info = state.model_info || {};
    var statusBits = [state.scenes.length + ' scenes'];
    if (state.folders && state.folders.length) statusBits.push(state.folders.length + ' folders');
    if (info.title) statusBits.push(info.title);
    if (typeof info.pages_count === 'number' && info.pages_count !== state.scenes.length) {
      statusBits.push('(native: ' + info.pages_count + ')');
    }
    if (state.deferred) {
      statusBits.push('DEFER (' + (state.pending || 0) + ' pending)');
    }
    setStatus(statusBits.join(' · '));
    updateDeferButton();
  }

  // Chiamato da Ruby durante la generazione previews.
  // done=null,total=null  → fine, nascondi
  // done=N, total=-1      → indeterminato (non sappiamo quante)
  // done=N, total=M       → progress N/M
  function setPreviewProgress(done, total) {
    var bar = $('progress');
    var fill = $('progress-fill');
    var txt = $('progress-text');
    if (!bar) return;
    if (done === null || done === undefined) {
      bar.classList.add('hidden');
      fill.classList.remove('indeterminate');
      fill.style.width = '0%';
      return;
    }
    bar.classList.remove('hidden');
    if (total === -1) {
      fill.classList.add('indeterminate');
      fill.style.width = '';
      txt.textContent = 'Generating previews… (' + done + ')';
    } else {
      fill.classList.remove('indeterminate');
      var pct = total > 0 ? Math.round((done / total) * 100) : 0;
      fill.style.width = pct + '%';
      txt.textContent = 'Generating previews… ' + done + '/' + total;
    }
  }

  function updateThumbsButton() {
    var btn = $('btn-thumbs');
    if (!btn) return;
    if (thumbsOn) btn.classList.add('active'); else btn.classList.remove('active');
    if (listEl) {
      if (thumbsOn) listEl.classList.add('with-thumbs');
      else          listEl.classList.remove('with-thumbs');
    }
  }

  function updateDeferButton() {
    var btn = $('btn-defer');
    if (!btn) return;
    if (state.deferred) {
      btn.classList.add('active');
      btn.innerHTML = '▶ Apply' + (state.pending ? ' (' + state.pending + ')' : '');
      btn.title = 'Click to apply pending changes to SketchUp';
    } else {
      btn.classList.remove('active');
      btn.innerHTML = '⏸ Defer';
      btn.title = 'Defer mode: stage changes in memory, click again to flush all to SketchUp';
    }
  }

  function setStatus(msg) { if (statusEl) statusEl.textContent = msg; }

  // Costruisce una scene-row. parent = 'root' o folder_id.
  function makeSceneRow(scene, idx, parent) {
    var row = document.createElement('div');
    row.className = 'scene-row';
    row.dataset.id = scene.id;
    row.dataset.parent = parent;
    if (parent !== 'root') row.classList.add('in-folder');
    if (selection.indexOf(scene.id) !== -1) row.classList.add('selected');
    var pendingDot = scene.pending ? '<span class="pending-dot" title="Pending edits"></span>' : '';
    var previewUrl = state.previews && state.previews[scene.id];
    var thumbHtml;
    if (previewUrl) {
      // cache-bust per evitare immagine vecchia cached da CEF
      var sep = previewUrl.indexOf('?') === -1 ? '?' : '&';
      thumbHtml = '<img class="thumb" src="' + previewUrl + sep + 't=' + (state.preview_ts || '') + '" alt="">';
    } else {
      thumbHtml = '<div class="thumb-empty">no preview</div>';
    }
    row.innerHTML =
      '<span class="grip">&#x2630;</span>' +
      '<span class="row-update" title="Update scene from view">&#x27F3;</span>' +
      '<span class="idx">' + idx + '</span>' +
      thumbHtml +
      pendingDot +
      '<span class="name"></span>';
    row.querySelector('.name').textContent = scene.name;
    row.addEventListener('mousedown', function (e) { onRowClick(e, scene.id); });
    return row;
  }

  function makeFolderHeader(folder) {
    var hdr = document.createElement('div');
    hdr.className = 'folder-row' + (folder.expanded ? '' : ' collapsed');
    hdr.dataset.folderId = folder.id;
    var color = folder.color || '#4ea1ff';
    hdr.innerHTML =
      '<span class="fchev">' + (folder.expanded ? '▾' : '▸') + '</span>' +
      '<span class="fswatch" title="Change color"></span>' +
      '<span class="fname"></span>' +
      '<span class="fcount">' + folder.scenes.length + '</span>' +
      '<button class="fbtn fbtn-rename" title="Rename">✎</button>' +
      '<button class="fbtn fbtn-delete" title="Delete folder">✕</button>';
    hdr.querySelector('.fname').textContent = folder.name || '(unnamed)';
    hdr.querySelector('.fswatch').style.background = color;
    // Click chevron / row body → toggle
    hdr.addEventListener('click', function (e) {
      if (e.target.closest('.fbtn') || e.target.classList.contains('fswatch')) return;
      SMBridge.folderToggle(folder.id);
    });
    hdr.querySelector('.fswatch').addEventListener('click', function (e) {
      e.stopPropagation();
      var c = window.prompt('Color (hex, e.g. #4ea1ff):', color);
      if (c) SMBridge.folderUpdate({ id: folder.id, color: c });
    });
    hdr.querySelector('.fbtn-rename').addEventListener('click', function (e) {
      e.stopPropagation();
      var n = window.prompt('Folder name:', folder.name || '');
      if (n && n.trim()) SMBridge.folderUpdate({ id: folder.id, name: n.trim() });
    });
    hdr.querySelector('.fbtn-delete').addEventListener('click', function (e) {
      e.stopPropagation();
      if (window.confirm('Delete folder "' + (folder.name || '') + '"? Scenes will go back to root.')) {
        SMBridge.folderDelete(folder.id);
      }
    });
    return hdr;
  }

  function render() {
    listEl.innerHTML = '';
    if (!state.tree || state.tree.length === 0) {
      var info = state.model_info || {};
      var empty = document.createElement('div');
      empty.className = 'empty-state';
      if (info.pages_count > 0) {
        empty.textContent = 'No scenes in logical order, but the model has ' +
          info.pages_count + ' native pages.\nTry Refresh.';
      } else if (info.title === '') {
        empty.textContent = 'No model open (or untitled).\nOpen a .skp file with scenes.';
      } else {
        empty.textContent = 'No scenes in this model.\nCreate a scene in SketchUp, then Refresh.';
      }
      listEl.appendChild(empty);
      return;
    }
    var counter = 0;
    state.tree.forEach(function (item) {
      if (item.kind === 'folder') {
        listEl.appendChild(makeFolderHeader(item));
        if (item.expanded) {
          item.scenes.forEach(function (s) {
            counter++;
            listEl.appendChild(makeSceneRow(s, counter, item.id));
          });
        }
      } else if (item.kind === 'scene') {
        counter++;
        listEl.appendChild(makeSceneRow(item, counter, 'root'));
      }
    });
  }

  function indexOfId(id) {
    for (var i = 0; i < state.scenes.length; i++) {
      if (state.scenes[i].id === id) return i;
    }
    return -1;
  }

  function sceneById(id) {
    for (var i = 0; i < state.scenes.length; i++) {
      if (state.scenes[i].id === id) return state.scenes[i];
    }
    return null;
  }

  // Ordine visivo lineare delle scene (per shift-range), seguendo l'albero
  // ed escludendo le scene dentro cartelle collassate.
  function visibleSceneOrder() {
    var arr = [];
    state.tree.forEach(function (item) {
      if (item.kind === 'folder') {
        if (item.expanded) item.scenes.forEach(function (s) { arr.push(s.id); });
      } else if (item.kind === 'scene') {
        arr.push(item.id);
      }
    });
    return arr;
  }

  function onRowClick(e, id) {
    pendingCollapseId = null;
    // Manual dblclick detection: CEF in SU 2019 può non emettere dblclick
    // dopo che render() ricrea le row tra un click e l'altro.
    var now = Date.now();
    if (lastClickId === id && (now - lastClickTs) < DBLCLICK_MS &&
        !e.shiftKey && !e.ctrlKey && !e.metaKey) {
      lastClickId = null;
      lastClickTs = 0;
      SMBridge.openProperties(id);
      return;
    }
    lastClickId = id;
    lastClickTs = now;
    if (e.shiftKey && anchorId !== null) {
      var order = visibleSceneOrder();
      var a = order.indexOf(anchorId), b = order.indexOf(id);
      if (a < 0 || b < 0) return;
      var lo = Math.min(a, b), hi = Math.max(a, b);
      selection = order.slice(lo, hi + 1);
    } else if (e.ctrlKey || e.metaKey) {
      var pos = selection.indexOf(id);
      if (pos === -1) selection.push(id); else selection.splice(pos, 1);
      anchorId = id;
    } else {
      // Se il row è già nella selezione: NON resettare il gruppo.
      // Tieni la selezione viva per consentire drag-del-gruppo. Se mouseup
      // arriva senza drag, collassiamo a singolo (stile file-explorer).
      if (selection.indexOf(id) !== -1 && selection.length > 1) {
        pendingCollapseId = id;
        anchorId = id;
        if (!state.deferred) SMBridge.selectPage(id);
        return;
      }
      selection = [id];
      anchorId = id;
      if (!state.deferred) SMBridge.selectPage(id);
    }
    render();
  }

  // Mouseup sul container: se c'è un collapse pending e non c'è stato drag,
  // collassa la selezione al solo id cliccato.
  function onContainerMouseUp(e) {
    if (pendingCollapseId === null) return;
    if (window.SMDnd && SMDnd.isDragging && SMDnd.isDragging()) {
      pendingCollapseId = null;
      return;
    }
    var id = pendingCollapseId;
    pendingCollapseId = null;
    selection = [id];
    anchorId = id;
    render();
  }

  function init() {
    listEl        = $('scene-list');
    statusEl      = $('status');

    $('btn-refresh').addEventListener('click', function () { SMBridge.refresh(); });
    $('btn-new-folder').addEventListener('click', function () {
      var n = window.prompt('Folder name:', 'New folder');
      if (n && n.trim()) SMBridge.folderCreate(n.trim());
    });
    $('btn-update').addEventListener('click', function () {
      if (selection.length === 1) SMBridge.updateFromView(selection[0]);
    });
    $('btn-delete').addEventListener('click', function () {
      if (selection.length === 0) return;
      if (confirm('Delete ' + selection.length + ' scene(s)?')) {
        SMBridge.deleteScenes(selection);
        selection = [];
      }
    });
    var btnDefer = $('btn-defer');
    if (btnDefer) {
      btnDefer.addEventListener('click', function () { SMBridge.deferToggle(); });
    }
    var btnThumbs = $('btn-thumbs');
    if (btnThumbs) {
      btnThumbs.addEventListener('click', function () {
        thumbsOn = !thumbsOn;
        updateThumbsButton();
      });
    }
    var btnPreviews = $('btn-previews');
    if (btnPreviews) {
      btnPreviews.addEventListener('click', function () {
        // selezione vuota → tutte le scene; selezione presente → solo quelle
        var ids = selection.slice();
        var msg = ids.length === 0
          ? 'Generate previews for ALL scenes? This may take a while.'
          : 'Generate previews for ' + ids.length + ' selected scene(s)?';
        if (!confirm(msg)) return;
        setStatus('Generating previews…');
        SMBridge.generatePreviews(ids);
      });
    }
    var btnExport = $('btn-export');
    if (btnExport) {
      btnExport.addEventListener('click', function () {
        SMBridge.openExport(selection.slice());
      });
    }
    var btnCancelExp = $('btn-cancel-export');
    if (btnCancelExp) {
      btnCancelExp.addEventListener('click', function () {
        btnCancelExp.disabled = true;
        SMBridge.cancelExport();
      });
    }
    var btnSettings = $('btn-settings');
    if (btnSettings) {
      btnSettings.addEventListener('click', function () {
        try { window.sketchup && window.sketchup.sm_open_settings && window.sketchup.sm_open_settings(''); }
        catch (e) { console.error('open settings failed', e); }
      });
    }
    listEl.addEventListener('mouseup', onContainerMouseUp);

    // Dblclick via delegation: render() ricrea le row, quindi un listener sul row
    // non viene preservato tra primo e secondo click. Il listEl invece è stabile.
    listEl.addEventListener('dblclick', function (e) {
      var row = e.target.closest && e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      SMBridge.openProperties(row.dataset.id);
    });

    // Click sull'icona "update scene" per riga (delegation, capture):
    // ferma propagazione così non triggera selezione né drag.
    listEl.addEventListener('mousedown', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-update')) return;
      e.stopPropagation();
      e.preventDefault();
    }, true);
    listEl.addEventListener('click', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-update')) return;
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      SMBridge.updateFromView(row.dataset.id);
    });

    SMDnd.attach(listEl, {
      getSelected:  function () { return selection.slice(); },
      onDragSelect: function (id) { selection = [id]; anchorId = id; render(); },
      onDrop:       function (ids, info) {
        SMBridge.reorder(ids, info.beforeId, info.destFolderId);
      }
    });

    if (SMBridge && SMBridge.log) SMBridge.log('JS build=' + window.__SM_BUILD__);
    SMBridge.ready();
  }

  function safeInit() {
    try { init(); }
    catch (err) {
      var el = document.getElementById('scene-list');
      if (el) {
        el.innerHTML = '';
        var box = document.createElement('div');
        box.className = 'empty-state error';
        box.textContent = 'JS init error:\n' + (err && err.stack || err);
        el.appendChild(box);
      }
      if (window.SMBridge && SMBridge.log) SMBridge.log('init error: ' + err);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', safeInit);
  } else {
    safeInit();
  }

  function setActiveFromNative(uid) {
    if (!uid) return;
    // Solo cambio di selezione UI: NIENTE bridge call back.
    selection = [uid];
    anchorId  = uid;
    render();
    // Scrolla la riga in vista
    var row = listEl && listEl.querySelector('.scene-row[data-id="' + uid + '"]');
    if (row && row.scrollIntoView) {
      try { row.scrollIntoView({ block: 'nearest' }); } catch (e) {}
    }
  }

  function setExportProgress(done, total, name) {
    var bar = $('progress');
    var fill = $('progress-fill');
    var txt = $('progress-text');
    var cancel = $('btn-cancel-export');
    if (!bar) return;
    if (done === null || done === undefined) {
      bar.classList.add('hidden');
      fill.classList.remove('indeterminate');
      fill.style.width = '0%';
      if (cancel) { cancel.classList.add('hidden'); cancel.disabled = false; }
      return;
    }
    bar.classList.remove('hidden');
    fill.classList.remove('indeterminate');
    if (cancel) { cancel.classList.remove('hidden'); cancel.disabled = false; }
    var pct = (total && total > 0) ? Math.round((done / total) * 100) : 0;
    fill.style.width = pct + '%';
    txt.textContent = 'Exporting… ' + done + '/' + total + (name ? '  ' + name : '');
  }

  return {
    setState: setState,
    setPreviewProgress: setPreviewProgress,
    setExportProgress: setExportProgress,
    setActiveFromNative: setActiveFromNative
  };
})();
