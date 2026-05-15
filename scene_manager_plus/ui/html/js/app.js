window.__SM_BUILD__ = 'dnd-mouse-1';
window.SM = (function () {
  var state = { scenes: [], folders: [], flag_keys: [] };
  var selection = []; // array di id
  var anchorId  = null; // ultimo id cliccato (per shift-range)
  var listEl, propsEl, propsTitleEl, statusEl;

  function $(id) { return document.getElementById(id); }

  function setState(newState) {
    state = newState || state;
    if (!state.scenes) state.scenes = [];
    if (!state.flag_keys) state.flag_keys = [];
    render();
    updateProps();
    var info = state.model_info || {};
    var statusBits = [state.scenes.length + ' scenes'];
    if (info.title) statusBits.push(info.title);
    if (typeof info.pages_count === 'number' && info.pages_count !== state.scenes.length) {
      statusBits.push('(native: ' + info.pages_count + ')');
    }
    setStatus(statusBits.join(' · '));
  }

  function setStatus(msg) { if (statusEl) statusEl.textContent = msg; }

  function render() {
    listEl.innerHTML = '';
    if (!state.scenes || state.scenes.length === 0) {
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
    state.scenes.forEach(function (s, i) {
      var row = document.createElement('div');
      row.className = 'scene-row';
      row.dataset.id = s.id;
      if (selection.indexOf(s.id) !== -1) row.classList.add('selected');
      row.innerHTML =
        '<span class="grip">&#x2630;</span>' +
        '<span class="idx">' + (i + 1) + '</span>' +
        '<span class="name"></span>';
      row.querySelector('.name').textContent = s.name;
      row.addEventListener('mousedown', function (e) { onRowClick(e, s.id); });
      row.addEventListener('dblclick', function () { SMBridge.selectPage(s.id); });
      listEl.appendChild(row);
    });
  }

  function getRows() {
    return Array.prototype.slice.call(listEl.querySelectorAll('.scene-row'));
  }

  function indexOfId(id) {
    for (var i = 0; i < state.scenes.length; i++) {
      if (state.scenes[i].id === id) return i;
    }
    return -1;
  }

  function onRowClick(e, id) {
    if (e.shiftKey && anchorId !== null) {
      var a = indexOfId(anchorId), b = indexOfId(id);
      if (a < 0 || b < 0) return;
      var lo = Math.min(a, b), hi = Math.max(a, b);
      selection = state.scenes.slice(lo, hi + 1).map(function (s) { return s.id; });
    } else if (e.ctrlKey || e.metaKey) {
      var pos = selection.indexOf(id);
      if (pos === -1) selection.push(id); else selection.splice(pos, 1);
      anchorId = id;
    } else {
      selection = [id];
      anchorId = id;
      // doppio scopo: singolo click attiva la scena in SU
      SMBridge.selectPage(id);
    }
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
    var s = state.scenes[indexOfId(selection[0])];
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

    SMDnd.attach(listEl, {
      getRows:      getRows,
      getSelected:  function () { return selection.slice(); },
      onDragSelect: function (id) { selection = [id]; anchorId = id; render(); updateProps(); },
      onDrop:       function (ids, targetId) { SMBridge.reorder(ids, targetId); }
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
