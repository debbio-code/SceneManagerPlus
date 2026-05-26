window.__SM_BUILD__ = 'phaseC-style-mini-mgr';
window.SM = (function () {
  var state = { scenes: [], tree: [], folders: [], flag_keys: [], previews: {} };
  var lastPreviewSig = '';
  var lastPreviewTs  = 0;
  var selection = []; // array di scene id
  var activeId  = null; // id della scena attualmente visualizzata nel viewport
  var anchorId  = null; // ultimo id cliccato (per shift-range)
  var pendingCollapseId = null; // id su cui collassare la selezione se mouseup senza drag
  var lastClickId = null;
  var lastClickTs = 0;
  var DBLCLICK_MS = 400;
  var thumbsOn = false; // session-only toggle
  var listEl, statusEl;
  var sceneByIdMap = {};
  var styleByNameMap = {};

  function $(id) { return document.getElementById(id); }

  function escapeAttr(s) {
    return String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;');
  }

  // Nomi leggibili per le flag di memorizzazione scena — allineati alle
  // label native SU. use_style e use_rendering_options condividono lo stesso
  // nome ("Style and Fog") perché in SU 2019 la UI nativa li gestisce con
  // un unico checkbox.
  var FLAG_LABELS = {
    'use_camera':            'Camera Location',
    'use_hidden':            'Hidden Geometry',
    'use_hidden_layers':     'Visible Layers',
    'use_style':             'Style and Fog',
    'use_rendering_options': 'Style and Fog',
    'use_shadow_info':       'Shadow Settings',
    'use_axes':              'Axes Location',
    'use_section_planes':    'Active Section Planes',
  };

  // Costruisce il title del grip per la scena attiva.
  // allFlags=true → giallo, false → rosso con lista di cosa manca.
  // Deduplicazione: use_style e use_rendering_options hanno stesso label
  // → appaiono come un unico "Style and Fog" nel tooltip.
  function buildGripTitle(scene, allFlags) {
    if (!scene) return '';
    if (allFlags) return 'Active scene · All properties recorded';
    var missing = state.flag_keys.filter(function (k) { return !scene.flags[k]; });
    var seen = {};
    var lines = [];
    missing.forEach(function (k) {
      var label = FLAG_LABELS[k] || k;
      if (!seen[label]) { seen[label] = true; lines.push('– ' + label); }
    });
    return 'Active scene · Some properties not recorded:\n' + lines.join('\n');
  }

  // Lettera associata al nome stile (lookup in state.styles).
  // Restituisce '?' se lo stile non è mappato o lo state non è ancora arrivato.
  function letterForStyle(styleName) {
    if (!styleName || !state.styles) return '?';
    return styleByNameMap[styleName] ? styleByNameMap[styleName].letter : '?';
  }
  function colorForStyle(styleName) {
    if (!styleName || !state.styles) return null;
    var e = styleByNameMap[styleName];
    return e && e.color ? e.color : null;
  }
  // Calcola colore testo leggibile (nero/bianco) dato un bg hex.
  function readableTextColor(hex) {
    var s = String(hex || '').replace('#', '');
    if (!/^[0-9a-f]{6}$/i.test(s)) return null;
    var r = parseInt(s.substr(0,2),16), g = parseInt(s.substr(2,2),16), b = parseInt(s.substr(4,2),16);
    var lum = 0.299*r + 0.587*g + 0.114*b;
    return lum > 140 ? '#1a1a1a' : '#ffffff';
  }

  function setState(newState) {
    state = newState || state;
    if (!state.scenes) state.scenes = [];
    if (!state.tree)   state.tree   = [];
    if (!state.flag_keys) state.flag_keys = [];
    if (!state.previews) state.previews = {};
    if (!state.styles) state.styles = [];
    sceneByIdMap = {};
    state.scenes.forEach(function (s) { sceneByIdMap[s.id] = s; });
    styleByNameMap = {};
    state.styles.forEach(function (s) { styleByNameMap[s.name] = s; });
    if (state.active_id) activeId = state.active_id;
    // preview_ts viene usato come cache-buster nell'<img src>. Bumparlo a
    // ogni setState (cosa che facevamo prima) forzava CEF a ri-richiedere
    // ogni PNG dopo OGNI operazione (rename, reorder, update_from_view,
    // ecc.): la ri-richiesta a volte falliva e la preview spariva
    // "ogni tanto". Ora bumpiamo solo quando l'insieme dei PNG cambia
    // davvero (nuova generazione → cambia il set di chiavi). Così l'URL
    // dell'<img> resta stabile tra render e CEF tiene tutto in cache.
    var sig = Object.keys(state.previews).sort().join('|');
    if (sig !== lastPreviewSig) {
      lastPreviewTs  = Date.now();
      lastPreviewSig = sig;
    }
    state.preview_ts = lastPreviewTs;
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
    updateOrderBanner();
  }

  function updateOrderBanner() {
    var el = $('banner-order');
    if (!el) return;
    if (state.native_order_divergent) {
      el.classList.remove('hidden');
    } else {
      el.classList.add('hidden');
    }
  }

  function onBannerOrderClick() {
    alert(
      'SceneTabs order out of sync\n\n' +
      'The native SketchUp scene tabs are showing the scenes in creation order, ' +
      'which no longer matches the order in this plugin.\n\n' +
      'SketchUp 2019 does not expose an API to reorder native pages, so this ' +
      'mismatch cannot be fixed automatically. You can hide the native scene tabs ' +
      'via View → Animation → Scene Tabs (note: SU 2019 may forget this setting ' +
      'when reopening the file).'
    );
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
      // Generazione completata: forza il bump del cache-buster anche se il
      // set di uid è invariato (PNG riscritti con stesso nome ma contenuto
      // nuovo → senza questo, CEF servirebbe ancora la versione cached).
      lastPreviewTs  = Date.now();
      lastPreviewSig = '__force_' + lastPreviewTs;
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
      btn.innerHTML = '▶';
      btn.title = 'Click to apply pending changes to SketchUp' +
        (state.pending ? ' (' + state.pending + ' pending)' : '');
    } else {
      btn.classList.remove('active');
      btn.innerHTML = '⏸';
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
    var isActive = (scene.id === activeId);
    var allFlags = true;
    if (isActive) {
      allFlags = state.flag_keys.every(function (k) { return scene.flags[k] !== false; });
      row.classList.add(allFlags ? 'active' : 'active-warning');
    }
    var gripTitle = isActive ? buildGripTitle(scene, allFlags) : '';
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
    var included = scene.export_included !== false;
    var letter = letterForStyle(scene.style_name);
    var letterTitle = 'No style';
    if (scene.style_name) {
      // Mostra il nickname se c'è, indicando il nome nativo tra parentesi.
      var styleEntry = styleByNameMap[scene.style_name] || null;
      if (styleEntry && styleEntry.nick) {
        letterTitle = 'Style: ' + styleEntry.nick + ' (native: ' + scene.style_name + ')';
      } else {
        letterTitle = 'Style: ' + scene.style_name;
      }
    }
    var letterStyle = '';
    var letterColor = colorForStyle(scene.style_name);
    if (letterColor) {
      var txt = readableTextColor(letterColor) || '#cfd8e3';
      letterStyle = ' style="background:' + letterColor + ';color:' + txt + ';border-color:' + letterColor + '"';
    }
    // Colore per-scena: solo lo swatch a destra del nome viene colorato.
    // Vuoto = pattern a quadretti (CSS), pieno = inline background hex.
    var sceneColor = scene.color || null;
    var sceneSwatchStyle = sceneColor
      ? ' style="background:' + sceneColor + ';background-image:none"'
      : '';
    row.innerHTML =
      '<span class="grip" title="' + escapeAttr(gripTitle) + '">&#x2630;</span>' +
      '<span class="row-style-letter" title="' + escapeAttr(letterTitle) + '"' + letterStyle + '>' + letter + '</span>' +
      '<input type="checkbox" class="export-cb" title="Include in batch export (ignored when exporting only selected scenes)"' +
        (included ? ' checked' : '') + '>' +
      '<span class="idx">' + idx + '</span>' +
      thumbHtml +
      pendingDot +
      '<span class="name"></span>' +
      '<span class="row-scene-color" title="Scene color — click to pick, right-click to clear"' + sceneSwatchStyle + '></span>';
    row.querySelector('.name').textContent = scene.name;
    row.addEventListener('mousedown', function (e) { onRowClick(e, scene.id); });
    row.addEventListener('contextmenu', function (e) {
      e.preventDefault();
      if (selection.indexOf(scene.id) === -1) {
        selection = [scene.id];
        anchorId = scene.id;
        selectPageLocal(scene.id);
        render();
      }
      showContextMenu(e.clientX, e.clientY, scene.id);
    });
    return row;
  }

  // Scrolla la row al centro solo se non già completamente visibile.
  function scrollRowIntoCenter(id) {
    if (!listEl || !id) return;
    var row = listEl.querySelector('.scene-row[data-id="' + id + '"]');
    if (!row) return;
    var rRect = row.getBoundingClientRect();
    var lRect = listEl.getBoundingClientRect();
    if (rRect.top < lRect.top || rRect.bottom > lRect.bottom) {
      try { row.scrollIntoView({ block: 'center' }); } catch (e) {}
    }
  }

  // Context menu (tasto destro su scena)
  function hideContextMenu() {
    var m = document.getElementById('sm-ctx-menu');
    if (m) m.parentNode.removeChild(m);
    document.removeEventListener('mousedown', onDocMouseDownCloseMenu, true);
    window.removeEventListener('blur', hideContextMenu);
  }
  function onDocMouseDownCloseMenu(e) {
    var m = document.getElementById('sm-ctx-menu');
    if (m && !m.contains(e.target)) hideContextMenu();
  }
  // Picker stili: lista A nome / B nome / ... per riassegnare uno stile alla
  // scena cliccata. Stesso pattern di showContextMenu (dismiss via blur/click).
  function showStylePickerMenu(x, y, sceneId) {
    hideContextMenu();
    var styles = state.styles || [];
    var scene = sceneById(sceneId);
    var currentName = scene && scene.style_name;
    var menu = document.createElement('div');
    menu.className = 'context-menu style-picker-menu';
    menu.id = 'sm-ctx-menu';
    var header = document.createElement('div');
    header.className = 'ctx-header';
    header.textContent = 'Assign style';
    menu.appendChild(header);

    // Voce "+ Nuovo stile..." sempre in cima: alloca slot dal pool +
    // (opzionale) nickname + assegna alla scena di contesto.
    var newItem = document.createElement('div');
    newItem.className = 'ctx-item style-pick style-pick-new';
    newItem.innerHTML = '<span class="ctx-letter">+</span><span class="ctx-name">New style…</span>';
    newItem.addEventListener('click', function () {
      hideContextMenu();
      SMBridge.newStyle(sceneId);
    });
    menu.appendChild(newItem);

    if (styles.length > 0) {
      var sep = document.createElement('div');
      sep.className = 'ctx-sep';
      menu.appendChild(sep);
    }

    styles.forEach(function (s) {
      var item = document.createElement('div');
      item.className = 'ctx-item style-pick';
      if (s.name === currentName) item.classList.add('current');
      // Applica il colore custom solo se NON è lo stile correntemente attivo
      // per la scena (l'item .current ha già il giallo come segnale visivo).
      var letterStyleAttr = '';
      if (s.color && s.name !== currentName) {
        var txt = readableTextColor(s.color) || '#cfd8e3';
        letterStyleAttr = ' style="background:' + s.color + ';color:' + txt + ';border-color:' + s.color + '"';
      }
      var letterSpan = '<span class="ctx-letter"' + letterStyleAttr + '>' + s.letter + '</span>';
      item.innerHTML = letterSpan + '<span class="ctx-name"></span>';
      // Display: nickname se presente, altrimenti nome nativo.
      var label = s.display_name || s.name;
      item.querySelector('.ctx-name').textContent = label;
      // Tooltip mostra il nome nativo se diverso dal display.
      if (s.nick) item.title = 'Native: ' + s.name;
      item.addEventListener('click', function () {
        hideContextMenu();
        if (s.name !== currentName) {
          SMBridge.assignStyle(sceneId, s.name);
        }
      });
      menu.appendChild(item);
    });
    document.body.appendChild(menu);
    var mw = menu.offsetWidth, mh = menu.offsetHeight;
    var vw = window.innerWidth, vh = window.innerHeight;
    if (x + mw > vw) x = Math.max(0, vw - mw - 2);
    if (y + mh > vh) y = Math.max(0, vh - mh - 2);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    setTimeout(function () {
      document.addEventListener('mousedown', onDocMouseDownCloseMenu, true);
      window.addEventListener('blur', hideContextMenu);
    }, 0);
  }

  // Mapping identico a properties.js: stesso ordine, stessa fusione
  // use_style+use_rendering_options in 'Style and Fog'.
  var UPDATE_FLAG_UI = [
    { label: 'Camera Location',       keys: ['use_camera'] },
    { label: 'Hidden Geometry',       keys: ['use_hidden'] },
    { label: 'Visible Layers',        keys: ['use_hidden_layers'] },
    { label: 'Active Section Planes', keys: ['use_section_planes'] },
    { label: 'Style and Fog',         keys: ['use_style', 'use_rendering_options'] },
    { label: 'Shadow Settings',       keys: ['use_shadow_info'] },
    { label: 'Axes Location',         keys: ['use_axes'] }
  ];
  function item_all_flags_on(keys, scene) {
    return keys.every(function (k) { return scene && scene.flags && scene.flags[k]; });
  }

  var _flashUpdateTimer = null;
  function flashUpdateOk() {
    var btn = $('btn-update');
    if (!btn) return;
    btn.classList.add('flash-ok');
    if (_flashUpdateTimer) clearTimeout(_flashUpdateTimer);
    _flashUpdateTimer = setTimeout(function () {
      btn.classList.remove('flash-ok');
      _flashUpdateTimer = null;
    }, 2850);
  }

  function showUpdatePartialMenu(x, y, items, onPick) {
    hideContextMenu();
    var menu = document.createElement('div');
    menu.className = 'context-menu';
    menu.id = 'sm-ctx-menu';
    var header = document.createElement('div');
    header.className = 'ctx-header';
    header.textContent = 'Update only…';
    menu.appendChild(header);
    items.forEach(function (item) {
      var row = document.createElement('div');
      row.className = 'ctx-item';
      row.textContent = item.label;
      row.addEventListener('click', function () {
        hideContextMenu();
        onPick(item.keys);
      });
      menu.appendChild(row);
    });
    document.body.appendChild(menu);
    var mw = menu.offsetWidth, mh = menu.offsetHeight;
    var vw = window.innerWidth, vh = window.innerHeight;
    if (x + mw > vw) x = Math.max(0, vw - mw - 2);
    if (y + mh > vh) y = Math.max(0, vh - mh - 2);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    setTimeout(function () {
      document.addEventListener('mousedown', onDocMouseDownCloseMenu, true);
      window.addEventListener('blur', hideContextMenu);
    }, 0);
  }

  function showContextMenu(x, y, sceneId) {
    hideContextMenu();
    var menu = document.createElement('div');
    menu.className = 'context-menu';
    menu.id = 'sm-ctx-menu';
    var item = document.createElement('div');
    item.className = 'ctx-item';
    item.textContent = 'Rename';
    item.addEventListener('click', function () {
      hideContextMenu();
      startInlineRename(sceneId);
    });
    menu.appendChild(item);
    document.body.appendChild(menu);
    // Posiziona dentro la viewport
    var mw = menu.offsetWidth, mh = menu.offsetHeight;
    var vw = window.innerWidth, vh = window.innerHeight;
    if (x + mw > vw) x = Math.max(0, vw - mw - 2);
    if (y + mh > vh) y = Math.max(0, vh - mh - 2);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    setTimeout(function () {
      document.addEventListener('mousedown', onDocMouseDownCloseMenu, true);
      window.addEventListener('blur', hideContextMenu);
    }, 0);
  }

  // Rinomina inline dentro la row.
  function startInlineRename(id) {
    var row = listEl && listEl.querySelector('.scene-row[data-id="' + id + '"]');
    if (!row) return;
    var nameEl = row.querySelector('.name');
    if (!nameEl) return;
    var current = nameEl.textContent;
    nameEl.textContent = '';
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'rename-input';
    input.spellcheck = false;
    input.value = current;
    nameEl.appendChild(input);
    input.focus();
    input.select();
    var done = false;
    function commit() {
      if (done) return;
      done = true;
      var v = input.value.trim();
      if (v && v !== current) {
        SMBridge.updatePage({ id: id, name: v });
      } else {
        render();
      }
    }
    function cancel() {
      if (done) return;
      done = true;
      render();
    }
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter')      { e.preventDefault(); commit(); }
      else if (e.key === 'Escape'){ e.preventDefault(); cancel(); }
      e.stopPropagation();
    });
    input.addEventListener('blur', commit);
    input.addEventListener('mousedown', function (e) { e.stopPropagation(); });
    input.addEventListener('click',     function (e) { e.stopPropagation(); });
    input.addEventListener('dblclick',  function (e) { e.stopPropagation(); });
  }

  // Mappa parent->siblings (ordinati). 'root' = lista mista cartelle/scene root.
  function buildSiblingMap() {
    var map = { root: [] };
    state.tree.forEach(function (item) {
      map.root.push(item.id);
      if (item.kind === 'folder') {
        map[item.id] = item.scenes.map(function (s) { return s.id; });
      }
    });
    return map;
  }
  function findParentOf(id) {
    for (var i = 0; i < state.tree.length; i++) {
      var item = state.tree[i];
      if (item.id === id) return 'root';
      if (item.kind === 'folder') {
        for (var j = 0; j < item.scenes.length; j++) {
          if (item.scenes[j].id === id) return item.id;
        }
      }
    }
    return null;
  }

  // Sposta su/giù (delta = -1 o +1) la selezione di scene. Richiede che
  // tutte le scene selezionate stiano sotto lo stesso parent e siano
  // contigue nell'ordine dei sibling: altrimenti no-op (silenziosamente).
  function moveSelection(delta) {
    if (!selection.length) return;
    var sib = buildSiblingMap();
    var parents = {};
    selection.forEach(function (id) {
      var p = findParentOf(id);
      if (p == null) return;
      (parents[p] = parents[p] || []).push(id);
    });
    var pKeys = Object.keys(parents);
    if (pKeys.length !== 1) return;
    var parent = pKeys[0];
    var siblings = sib[parent] || [];
    var indices = parents[parent].map(function (id) { return siblings.indexOf(id); })
                                 .filter(function (i) { return i >= 0; })
                                 .sort(function (a, b) { return a - b; });
    if (!indices.length) return;
    var minI = indices[0], maxI = indices[indices.length - 1];
    if (maxI - minI + 1 !== indices.length) return; // non contigua
    var movingIds = siblings.slice(minI, maxI + 1);
    var beforeId;
    if (delta < 0) {
      if (minI === 0) return;
      beforeId = siblings[minI - 1];
    } else {
      if (maxI >= siblings.length - 1) return;
      var afterIdx = maxI + 2;
      beforeId = afterIdx < siblings.length ? siblings[afterIdx] : null;
    }
    SMBridge.reorder(movingIds, beforeId, parent === 'root' ? null : parent);
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
    // Preserva lo scroll: innerHTML='' rimuove i figli e di fatto azzera
    // lo scrollTop del contenitore. Senza questo, ogni selezione (che
    // chiama render()) faceva saltare la lista in cima se la finestra era
    // più corta del contenuto.
    var savedScroll = listEl.scrollTop;
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
    // Ripristina lo scroll dopo aver ricostruito il contenuto.
    listEl.scrollTop = savedScroll;
  }

  function indexOfId(id) {
    for (var i = 0; i < state.scenes.length; i++) {
      if (state.scenes[i].id === id) return i;
    }
    return -1;
  }

  function sceneById(id) {
    return sceneByIdMap[id] || null;
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
    // Se l'utente ha cliccato sulla checkbox export-cb, non toccare la selezione:
    // il click handler del listEl gestirà il bulk toggle.
    if (e.target && e.target.classList && e.target.classList.contains('export-cb')) {
      pendingCollapseId = null;
      return;
    }
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
        selectPageLocal(id);
        render();
        return;
      }
      selection = [id];
      anchorId = id;
      selectPageLocal(id);
    }
    render();
  }

  // Mouseup sul container: se c'è un collapse pending e non c'è stato drag,
  // collassa la selezione al solo id cliccato.
  function onContainerMouseUp(e) {
    if (pendingCollapseId === null) return;
    // Non collassare la selezione se il mouseup è su un export-cb: il click
    // handler gestirà il bulk toggle sulla selezione corrente.
    if (e.target && e.target.classList && e.target.classList.contains('export-cb')) {
      pendingCollapseId = null;
      return;
    }
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
    var bannerOrder = $('banner-order');
    if (bannerOrder) bannerOrder.addEventListener('click', onBannerOrderClick);
    var btnNewScene = $('btn-new-scene');
    if (btnNewScene) {
      btnNewScene.addEventListener('click', function () { SMBridge.newSceneFromView(); });
    }
    $('btn-new-folder').addEventListener('click', function () {
      var n = window.prompt('Folder name:', 'New folder');
      if (n && n.trim()) SMBridge.folderCreate(n.trim());
    });
    $('btn-update').addEventListener('click', function () {
      if (selection.length === 0) return;
      // Multi-update: itera. updateFromView in Ruby gestisce lo style-dirty
      // dialog per singola pagina; con N scene selezionate l'utente potrebbe
      // vedere il dialog più volte se più scene usano lo stesso stile dirty.
      selection.forEach(function (id) { SMBridge.updateFromView(id); });
      flashUpdateOk();
    });
    // Right-click → menu di scelta singola property da aggiornare. Il menu
    // mostra la UNIONE delle property checkate nelle scene selezionate;
    // l'update viene applicato solo alle scene che hanno quella property
    // attiva (resta coerente con "Properties to save" della singola scena).
    $('btn-update').addEventListener('contextmenu', function (e) {
      e.preventDefault();
      if (selection.length === 0) return;
      var scenes = selection.map(sceneById).filter(Boolean);
      if (scenes.length === 0) return;
      var items = UPDATE_FLAG_UI.filter(function (item) {
        return scenes.some(function (s) {
          return item.keys.every(function (k) { return s.flags && s.flags[k]; });
        });
      });
      if (items.length === 0) return;
      showUpdatePartialMenu(e.clientX, e.clientY, items, function (keys) {
        scenes.forEach(function (s) {
          if (item_all_flags_on(keys, s)) SMBridge.updateFromView(s.id, keys);
        });
        flashUpdateOk();
      });
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
    var btnSelectAll = $('btn-select-all');
    if (btnSelectAll) {
      // Ciclo: 0 = "all", 1 = "none", 2 = "invert original". Si resetta se
      // l'utente cambia selezione manualmente tra una pressione e l'altra.
      var saStep = 0;
      var saOriginal = null;
      var saLastApplied = null;
      function sigOf(arr) { return arr.slice().sort().join('|'); }
      btnSelectAll.addEventListener('click', function () {
        var order = visibleSceneOrder();
        if (order.length === 0) return;
        if (saLastApplied === null || sigOf(selection) !== saLastApplied) {
          saStep = 0;
          saOriginal = selection.slice();
        }
        if (saStep === 0) {
          selection = order.slice();
        } else if (saStep === 1) {
          selection = [];
        } else {
          var orig = saOriginal || [];
          selection = order.filter(function (id) { return orig.indexOf(id) === -1; });
        }
        anchorId = selection.length ? selection[0] : null;
        saLastApplied = sigOf(selection);
        saStep = (saStep + 1) % 3;
        render();
      });
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

    // NB: la rilevazione del doppio click avviene in onRowClick (manuale,
    // controllando lastClickId/lastClickTs). Niente listener `dblclick` qui:
    // un secondo handler causava openProperties() doppio e race su show_for
    // (talvolta il dialog si apriva senza nome scena perché push_state
    // arrivava prima che il JS fosse pronto, e la seconda chiamata trovava
    // @dialog.visible? === true ma window.SMP ancora undefined).

    // Lettera stile per riga:
    //   - mousedown: blocca selezione/drag così non triggera click sulla row
    //   - click sinistro: apre mini Style Manager per lo stile della scena
    //   - contextmenu (right-click): apre picker con tutti gli stili A,B,C...
    listEl.addEventListener('mousedown', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-style-letter')) return;
      e.stopPropagation();
      e.preventDefault();
    }, true);
    listEl.addEventListener('click', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-style-letter')) return;
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      var sc = sceneById(row.dataset.id);
      if (!sc) return;
      // style_name può essere vuoto su scene Match Photo (stile interno MP
      // non esposto coerentemente). Apriamo lo stesso: lato Ruby
      // StyleDialog.show_for risolve dal page.style dopo l'attivazione.
      SMBridge.openStyle(row.dataset.id, sc.style_name || '');
    });
    listEl.addEventListener('contextmenu', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-style-letter')) return;
      e.preventDefault();
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      var sc = sceneById(row.dataset.id);
      // MP scenes: tutte le voci del picker sono comunque bloccate (assign,
      // + New style…) perché la modifica via Ruby corrompe lo state MP.
      // Apriamo l'inspector Styles nativo, stesso principio di "Style and Fog
      // → Scenes panel" in Properties dialog.
      if (sc && sc.is_matchphoto) {
        SMBridge.openNativeStylesPanel(row.dataset.id);
        return;
      }
      showStylePickerMenu(e.clientX, e.clientY, row.dataset.id);
    }, true);

    // Scene color swatch: click sx → popup picker (live apply via Ruby).
    //                     right-click → clear.
    // mousedown stoppato così non triggera selezione/drag della row.
    listEl.addEventListener('mousedown', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-scene-color')) return;
      e.stopPropagation();
      e.preventDefault();
    }, true);
    listEl.addEventListener('click', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-scene-color')) return;
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      var id = row.dataset.id;
      var sc = sceneById(id);
      var current = (sc && sc.color) || '#4ea1ff';
      if (window.SMColorPopup) {
        // commitOnEnd: il colore scena non ha effetto sul viewport (solo
        // sullo swatch della row), quindi evitiamo le N write a SU durante
        // il drag — un solo set_attribute alla chiusura del popup.
        SMColorPopup.show(e.target, current, function (hex) {
          SMBridge.setSceneColor(id, hex);
        }, { allowNone: true, commitOnEnd: true });
      } else {
        var c = window.prompt('Scene color (hex, e.g. #4ea1ff):', current);
        if (c !== null) SMBridge.setSceneColor(id, c.trim());
      }
    });
    listEl.addEventListener('contextmenu', function (e) {
      if (!e.target.classList || !e.target.classList.contains('row-scene-color')) return;
      e.preventDefault();
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      SMBridge.setSceneColor(row.dataset.id, '');
    }, true);

    // Export-include checkbox: blocca selezione/drag, invia toggle a Ruby.
    // Se la row cliccata è dentro una selezione multipla, applica a tutte:
    // tutte incluse → tutte escluse; altrimenti (mixed/tutte escluse) →
    // tutte incluse. Anche al primo click di un set misto, tutte vengono
    // marcate.
    listEl.addEventListener('mousedown', function (e) {
      if (!e.target.classList || !e.target.classList.contains('export-cb')) return;
      e.stopPropagation();
    }, true);
    listEl.addEventListener('click', function (e) {
      if (!e.target.classList || !e.target.classList.contains('export-cb')) return;
      e.stopPropagation();
      var row = e.target.closest('.scene-row');
      if (!row || !row.dataset || !row.dataset.id) return;
      var id = row.dataset.id;
      var targetIds, newIncluded;
      if (selection.length > 1 && selection.indexOf(id) !== -1) {
        targetIds = selection.slice();
        var allIncluded = targetIds.every(function (sid) {
          var s = sceneById(sid);
          return s && s.export_included !== false;
        });
        newIncluded = !allIncluded;
      } else {
        targetIds = [id];
        // e.target.checked riflette già il nuovo stato (HTML toggle)
        newIncluded = e.target.checked;
      }
      // Annulla il toggle visivo immediato del browser: render() seguirà a
      // push_state e disegnerà lo stato reale per tutte le row coinvolte.
      // Senza questo, su selezione multipla la checkbox cliccata potrebbe
      // mostrare il toggle "browser-default" prima del re-render.
      e.target.checked = newIncluded;
      SMBridge.setExportIncluded(targetIds, newIncluded);
    });

    // PageUp/PageDown/Home/End: navigazione lungo l'ordine logico del plugin
    // (cartella aperta → in fila, cartella chiusa → saltata). Bind su document
    // così funziona ovunque il focus stia dentro la finestra. Si esce dal
    // gestore se l'utente sta digitando in un campo testuale.
    // ArrowUp / ArrowDown: sposta la selezione su/giù nell'ordine logico.
    // Funziona sia per scene a root sia per scene dentro la stessa cartella.
    // Selezione multipla supportata solo se contigua sotto lo stesso parent.
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
      var t = document.activeElement;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
      if (!selection.length) return;
      e.preventDefault();
      e.stopPropagation();
      moveSelection(e.key === 'ArrowDown' ? +1 : -1);
    });

    document.addEventListener('keydown', function (e) {
      var k = e.key;
      if (k !== 'PageUp' && k !== 'PageDown' && k !== 'Home' && k !== 'End') return;
      var t = document.activeElement;
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable)) return;
      var order = visibleSceneOrder();
      if (order.length === 0) return;
      var target = null;
      if (k === 'Home') {
        target = order[0];
      } else if (k === 'End') {
        target = order[order.length - 1];
      } else {
        // Se la scena attiva non è nell'ordine visibile (es. dentro cartella
        // chiusa), idx = -1 e cadiamo nel caso "fuori lista" per convenzione.
        var curId = selection[0];
        var idx = curId ? order.indexOf(curId) : -1;
        if (k === 'PageDown') {
          target = idx < 0 ? order[0] : order[Math.min(order.length - 1, idx + 1)];
        } else {
          target = idx < 0 ? order[order.length - 1] : order[Math.max(0, idx - 1)];
        }
      }
      if (!target) return;
      e.preventDefault();
      e.stopPropagation();
      selection = [target];
      anchorId = target;
      selectPageLocal(target);
      render();
      var row = listEl && listEl.querySelector('.scene-row[data-id="' + target + '"]');
      if (row && row.scrollIntoView) {
        try { row.scrollIntoView({ block: 'nearest' }); } catch (er) {}
      }
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

    // Refresh dello state quando la finestra principale riprende focus: copre
    // il caso "utente cambia flag via inspector Scenes nativo (es. Style and
    // Fog) e torna su SM+" — senza questo il grip (giallo/rosso) resta sullo
    // state vecchio. Pattern identico a quello della Properties dialog.
    //
    // Debounce 500ms: focus + visibilitychange spesso firano ravvicinati
    // sulla stessa interazione utente. push_state è read-only ma su modelli
    // pesanti con tante scene/stili costa comunque qualche ms — evitiamo
    // doppioni inutili.
    var lastRefresh = 0;
    function debouncedRefresh() {
      var now = Date.now();
      if (now - lastRefresh < 500) return;
      lastRefresh = now;
      SMBridge.refresh();
    }
    window.addEventListener('focus', debouncedRefresh);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) debouncedRefresh();
    });
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

  // Chiamato dai click/keynav locali: aggiorna activeId immediatamente
  // (no attesa del polling 250ms) e attiva la scena nel viewport.
  function selectPageLocal(id) {
    // In defer mode la scena nel viewport NON cambia, quindi nemmeno il
    // marker giallo deve seguire la selezione. Aggiorniamo activeId solo
    // quando attiviamo davvero la pagina.
    if (state.deferred) return;
    activeId = id;
    SMBridge.selectPage(id);
  }

  // Selezione "esterna" (es. dopo creazione nuova scena lato Ruby): porta la
  // fascia blu sul nuovo uid + ancora la selezione lì.
  function selectId(uid) {
    if (!uid) return;
    selection = [uid];
    anchorId = uid;
    render();
    scrollRowIntoCenter(uid);
  }

  function setActiveFromNative(uid) {
    if (!uid) return;
    if (activeId === uid) return;
    var prev = activeId;
    activeId = uid;
    updateActiveMarker(prev, uid);
  }

  function updateActiveMarker(prevId, nextId) {
    if (!listEl) return;
    if (prevId) {
      var prev = listEl.querySelector('.scene-row[data-id="' + prevId + '"]');
      if (prev) {
        prev.classList.remove('active');
        prev.classList.remove('active-warning');
        var pg = prev.querySelector('.grip');
        if (pg) pg.title = '';
      }
    }
    if (nextId) {
      var next = listEl.querySelector('.scene-row[data-id="' + nextId + '"]');
      if (next) {
        var sc = sceneByIdMap[nextId];
        var allFlags = !sc || state.flag_keys.every(function (k) { return sc.flags[k] !== false; });
        next.classList.add(allFlags ? 'active' : 'active-warning');
        var ng = next.querySelector('.grip');
        if (ng) ng.title = buildGripTitle(sc, allFlags);
      }
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
    setActiveFromNative: setActiveFromNative,
    selectId: selectId
  };
})();
