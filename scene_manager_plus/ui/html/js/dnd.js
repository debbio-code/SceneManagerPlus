// Drag & drop multi-selezione in stile Photoshop, plain JS senza dipendenze.
// IMPORTANTE: usa mousedown/mousemove/mouseup invece del drag HTML5 nativo,
// perché CEF di SketchUp 2019 NON ridipinge il DOM mentre è in corso un drag
// nativo, quindi il drop-indicator (e qualsiasi altro update visivo) rimane
// invisibile fino a fine drag — inutilizzabile. Vedi anche CLAUDE.md.
//
// Espone window.SMDnd.attach(container, options) dove options = {
//   getSelected:  () => [scene_id...]
//   onDragSelect: (id) => void
//   onDrop:       (movingIds, dropInfo) => void
//                 dropInfo = { destFolderId: id|null, beforeId: id|null }
// }
window.SMDnd = (function () {
  var DRAG_THRESHOLD = 4;
  // Stato condiviso a livello modulo per esporre isDragging() ad app.js.
  // (Abbiamo una sola istanza di SMDnd nella finestra, quindi va bene.)
  var shared = { dragging: false, justDragged: false };

  function attach(container, opts) {
    var indicator    = null;
    var pending      = false;
    var movingIds    = [];
    var lastDropInfo = null;
    var startX = 0, startY = 0;
    var startRow = null;

    function ensureIndicator() {
      if (indicator && indicator.parentNode === document.body) return indicator;
      indicator = document.createElement('div');
      indicator.className = 'drop-indicator';
      indicator.style.position = 'fixed';
      indicator.style.height = '3px';
      indicator.style.marginTop = '-1px';
      indicator.style.background = '#4ea1ff';
      indicator.style.boxShadow = '0 0 4px #4ea1ff';
      indicator.style.zIndex = '99999';
      indicator.style.pointerEvents = 'none';
      indicator.style.display = 'none';
      document.body.appendChild(indicator);
      return indicator;
    }
    function hideIndicator() { if (indicator) indicator.style.display = 'none'; }

    function idOf(el) {
      return el.classList.contains('folder-row') ? el.dataset.folderId : el.dataset.id;
    }

    // Cerca il prossimo sibling dropTarget che condivide il contesto di `el`.
    // Contesto:
    //   - folder-row → root
    //   - scene-row[data-parent="root"] → root
    //   - scene-row[data-parent="<fid>"] → folder fid
    function nextInContext(el) {
      var ctx;
      if (el.classList.contains('folder-row')) ctx = 'root';
      else ctx = el.dataset.parent || 'root';
      var n = el.nextElementSibling;
      while (n) {
        if (n.classList.contains('folder-row')) {
          if (ctx === 'root') return n;
          return null; // uscito dalla cartella
        } else if (n.classList.contains('scene-row')) {
          var np = n.dataset.parent || 'root';
          if (np === ctx) return n;
          if (ctx !== 'root' && np === 'root') return null;
          if (ctx !== 'root' && np !== ctx)    return null;
        }
        n = n.nextElementSibling;
      }
      return null;
    }

    // Prima scena figlia di una cartella (cerca dopo il folder-row in DOM).
    function firstChildOfFolder(folderRow, fid) {
      var n = folderRow.nextElementSibling;
      while (n) {
        if (n.classList.contains('scene-row') && n.dataset.parent === fid) return n;
        if (n.classList.contains('folder-row')) return null;
        if (n.classList.contains('scene-row') && n.dataset.parent === 'root') return null;
        n = n.nextElementSibling;
      }
      return null;
    }

    // Calcola le info di drop dato Y. Ritorna:
    //   { destFolderId, beforeId, top, indent }
    function dropInfoAtY(y) {
      var items = container.querySelectorAll('.folder-row, .scene-row');
      for (var i = 0; i < items.length; i++) {
        var el = items[i];
        var r  = el.getBoundingClientRect();
        if (y < r.top || y > r.bottom) continue;
        var mid = r.top + r.height / 2;
        var before = y < mid;

        if (el.classList.contains('folder-row')) {
          var fid = el.dataset.folderId;
          if (before) {
            return { destFolderId: null, beforeId: fid, top: r.top, indent: 0 };
          }
          // metà inferiore del folder header → drop DENTRO la cartella.
          // Collassata: append in coda. Espansa: inserisci come prima scena.
          // Visivamente: rettangolo blu attorno all'header (no linea).
          var collapsed = el.classList.contains('collapsed');
          var beforeId  = null;
          if (!collapsed) {
            var first = firstChildOfFolder(el, fid);
            beforeId = first ? first.dataset.id : null;
          }
          return {
            destFolderId: fid,
            beforeId: beforeId,
            dropOnFolder: fid,
            top: r.bottom,
            indent: 28
          };
        }

        // scene-row
        var parent = el.dataset.parent === 'root' ? null : el.dataset.parent;
        var sid = el.dataset.id;
        if (before) {
          return {
            destFolderId: parent,
            beforeId: sid,
            top: r.top,
            indent: parent ? 28 : 0
          };
        } else {
          var nx2 = nextInContext(el);
          return {
            destFolderId: parent,
            beforeId: nx2 ? idOf(nx2) : null,
            top: r.bottom,
            indent: parent ? 28 : 0
          };
        }
      }
      // fuori da qualsiasi riga: append al root
      var all = container.querySelectorAll('.folder-row, .scene-row');
      var bottom = container.getBoundingClientRect().top;
      if (all.length) bottom = all[all.length - 1].getBoundingClientRect().bottom;
      return { destFolderId: null, beforeId: null, top: bottom, indent: 0 };
    }

    function beginDrag() {
      shared.dragging = true;
      if (startRow.classList.contains('folder-row')) {
        // trascinare una cartella → singolo item, nessun impatto su scene selection
        movingIds = [startRow.dataset.folderId];
      } else {
        var sel = opts.getSelected ? opts.getSelected() : [];
        var startId = startRow.dataset.id;
        if (sel.indexOf(startId) === -1) {
          if (typeof opts.onDragSelect === 'function') opts.onDragSelect(startId);
          sel = [startId];
        }
        movingIds = sel.slice();
      }
      var rows = container.querySelectorAll('.scene-row, .folder-row');
      rows.forEach(function (r) {
        if (movingIds.indexOf(idOf(r)) !== -1) r.classList.add('dragging');
      });
      document.body.style.cursor = 'grabbing';
    }

    function clearDropInto() {
      container.querySelectorAll('.folder-row.drop-into').forEach(function (el) {
        el.classList.remove('drop-into');
      });
    }

    function updateIndicator(y) {
      var info = dropInfoAtY(y);
      lastDropInfo = info;
      clearDropInto();
      if (info.dropOnFolder) {
        hideIndicator();
        var fr = container.querySelector('.folder-row[data-folder-id="' + info.dropOnFolder + '"]');
        if (fr) fr.classList.add('drop-into');
        return;
      }
      var cr = container.getBoundingClientRect();
      var ind = ensureIndicator();
      ind.style.display = 'block';
      ind.style.top   = info.top + 'px';
      ind.style.left  = (cr.left + info.indent) + 'px';
      ind.style.width = (cr.width - info.indent) + 'px';
    }

    function cleanup() {
      var hadDrag = shared.dragging;
      shared.dragging = false;
      pending  = false;
      movingIds = [];
      startRow = null;
      lastDropInfo = null;
      hideIndicator();
      clearDropInto();
      if (hadDrag) {
        container.querySelectorAll('.dragging').forEach(function (r) {
          r.classList.remove('dragging');
        });
        document.body.style.cursor = '';
        shared.justDragged = true;
        // Reset al prossimo tick — il click event fires subito dopo mouseup
        setTimeout(function () { shared.justDragged = false; }, 0);
      }
    }

    container.addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      // Ignora click sui controlli interni alla folder-row
      if (e.target.closest('.fbtn, .fswatch')) return;
      var row = e.target.closest('.scene-row, .folder-row');
      if (!row) return;
      startRow = row;
      startX = e.clientX;
      startY = e.clientY;
      pending = true;
    });

    document.addEventListener('mousemove', function (e) {
      if (!pending) return;
      if (!shared.dragging) {
        if (Math.abs(e.clientX - startX) > DRAG_THRESHOLD ||
            Math.abs(e.clientY - startY) > DRAG_THRESHOLD) {
          beginDrag();
        }
      }
      if (shared.dragging) {
        e.preventDefault();
        updateIndicator(e.clientY);
      }
    });

    document.addEventListener('mouseup', function (e) {
      if (!pending) return;
      if (shared.dragging) {
        var info = lastDropInfo || dropInfoAtY(e.clientY);
        // Evita di referenziare uno degli id che stiamo spostando come ancora
        if (info.beforeId && movingIds.indexOf(info.beforeId) !== -1) {
          info.beforeId = null;
        }
        opts.onDrop(movingIds, info);
      }
      cleanup();
    });

    // Sopprime il click successivo al drag (per non triggerare toggle cartella
    // o selezione scena)
    document.addEventListener('click', function (e) {
      if (shared.justDragged) {
        e.stopPropagation();
        e.preventDefault();
      }
    }, true);

    window.addEventListener('blur', cleanup);
  }

  return {
    attach: attach,
    isDragging: function () { return shared.dragging || shared.justDragged; }
  };
})();
