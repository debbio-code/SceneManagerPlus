window.__SM_BUILD__ = 'phase2b-2';
window.SM = (function () {
  var state = { scenes: [], tree: [], folders: [], flag_keys: [] };
  var selection = []; // array di scene id
  var anchorId  = null; // ultimo id cliccato (per shift-range)
  var pendingCollapseId = null; // id su cui collassare la selezione se mouseup senza drag
  var listEl, propsEl, propsTitleEl, statusEl;

  function $(id) { return document.getElementById(id); }

  function setState(newState) {
    state = newState || state;
    if (!state.scenes) state.scenes = [];
    if (!state.tree)   state.tree   = [];
    if (!state.flag_keys) state.flag_keys = [];
    render();
    updateProps();
    var info = state.model_info || {};
    var statusBits = [state.scenes.length + ' scenes'];
    if (state.folders && state.folders.length) statusBits.push(state.folders.length + ' folders');
    if (info.title) statusBits.push(info.title);
    if (typeof info.pages_count === 'number' && info.pages_count !== state.scenes.length) {
      statusBits.push('(native: ' + info.pages_count + ')');
    }
    setStatus(statusBits.join(' · '));
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
    row.innerHTML =
      '<span class="grip">&#x2630;</span>' +
      '<span class="idx">' + idx + '</span>' +
      '<span class="name"></span>';
    row.querySelector('.name').textContent = scene.name;
    row.addEventListener('mousedown', function (e) { onRowClick(e, scene.id); });
    row.addEventListener('dblclick', function () { SMBridge.selectPage(scene.id); });
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
        SMBridge.selectPage(id);
        return;
      }
      selection = [id];
      anchorId = id;
      SMBridge.selectPage(id);
    }
    render();
    updateProps();
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
    updateProps();
  }

  function updateProps() {
    if (selection.length === 0) {
      propsEl.classList.add('collapsed');
      propsTitleEl.textContent = 'No selection';
      return;
    }
    if (selection.length > 1) {
      propsTitleEl.textContent = selection.length + ' scenes selected';
      propsEl.classList.add('collapsed');
      return;
    }
    var s = sceneById(selection[0]);
    if (!s) return;
    propsTitleEl.textContent = s.name;
    propsEl.classList.remove('collapsed');
    $('prop-name').value = s.name;
    $('prop-desc').value = s.description || '';
    var flagsEl = $('prop-flags');
    flagsEl.innerHTML = '';
    state.flag_keys.forEach(function (k) {
      var lbl = document.createElement('label');
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.dataset.flag = k;
      cb.checked = !!s.flags[k];
      lbl.appendChild(cb);
      lbl.appendChild(document.createTextNode(k.replace(/^use_/, '').replace(/_/g, ' ')));
      flagsEl.appendChild(lbl);
    });
  }

  function applyProps() {
    if (selection.length !== 1) return;
    var id = selection[0];
    var flags = {};
    document.querySelectorAll('#prop-flags input[type=checkbox]').forEach(function (cb) {
      flags[cb.dataset.flag] = cb.checked;
    });
    SMBridge.updatePage({
      id:          id,
      name:        $('prop-name').value,
      description: $('prop-desc').value,
      flags:       flags
    });
  }

  function init() {
    listEl        = $('scene-list');
    propsEl       = $('props');
    propsTitleEl  = $('props-title');
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
    $('prop-apply').addEventListener('click', applyProps);
    $('props-toggle').addEventListener('click', function () {
      propsEl.classList.toggle('collapsed');
    });
    $('props-header') && $('props-header').addEventListener('click', function (e) {
      if (e.target.tagName !== 'BUTTON') propsEl.classList.toggle('collapsed');
    });

    listEl.addEventListener('mouseup', onContainerMouseUp);

    SMDnd.attach(listEl, {
      getSelected:  function () { return selection.slice(); },
      onDragSelect: function (id) { selection = [id]; anchorId = id; render(); updateProps(); },
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

  return { setState: setState };
})();
