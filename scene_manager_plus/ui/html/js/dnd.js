// Drag & drop multi-selezione in stile Photoshop, plain JS senza dipendenze.
// IMPORTANTE: usa mousedown/mousemove/mouseup invece del drag HTML5 nativo,
// perché CEF di SketchUp 2019 NON ridipinge il DOM mentre è in corso un drag
// nativo, quindi il drop-indicator (e qualsiasi altro update visivo) rimane
// invisibile fino a fine drag — inutilizzabile. Vedi anche CLAUDE.md.
//
// Espone window.SMDnd.attach(container, options) dove options = {
//   getRows:      () => [HTMLElement...]   // righe ordinate dalla UI
//   getSelected:  () => [id...]
//   onDragSelect: (id) => void              // chiamata se trascino una riga non selezionata
//   onDrop:       (movingIds, targetId|null) => void
// }
window.SMDnd = (function () {
  var DRAG_THRESHOLD = 4; // px prima di considerare il movimento un drag

  function attach(container, opts) {
    var indicator = null;
    var dragging  = false;
    var pending   = false;       // mousedown su una riga, ma soglia non ancora superata
    var movingIds = [];
    var startX = 0, startY = 0;
    var startRow = null;

    function ensureIndicator() {
      if (indicator && indicator.parentNode === document.body) return indicator;
      indicator = document.createElement('div');
      indicator.className = 'drop-indicator';
      // Position fixed su body: bypassa qualsiasi clipping/stacking
      // del container con overflow.
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

    function rowAtY(y) {
      var rows = opts.getRows();
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i].getBoundingClientRect();
        if (y >= r.top && y <= r.bottom) {
          var midpoint = r.top + r.height / 2;
          return { row: rows[i], index: i, before: y < midpoint };
        }
      }
      return null;
    }

    function beginDrag() {
      dragging = true;
      var sel = opts.getSelected();
      if (sel.indexOf(startRow.dataset.id) === -1) {
        if (typeof opts.onDragSelect === 'function') opts.onDragSelect(startRow.dataset.id);
        sel = [startRow.dataset.id];
      }
      movingIds = sel.slice();
      opts.getRows().forEach(function (r) {
        if (movingIds.indexOf(r.dataset.id) !== -1) r.classList.add('dragging');
      });
      document.body.style.cursor = 'grabbing';
    }

    function updateIndicator(y) {
      var hit = rowAtY(y);
      var top;
      if (hit) {
        var r = hit.row.getBoundingClientRect();
        top = hit.before ? r.top : r.bottom;
      } else {
        var rows = opts.getRows();
        var cr = container.getBoundingClientRect();
        top = rows.length === 0 ? cr.top : rows[rows.length - 1].getBoundingClientRect().bottom;
      }
      var cr2 = container.getBoundingClientRect();
      var ind = ensureIndicator();
      ind.style.display = 'block';
      ind.style.top   = top + 'px';
      ind.style.left  = cr2.left + 'px';
      ind.style.width = cr2.width + 'px';
    }

    function cleanup() {
      var hadDrag = dragging;
      dragging = false;
      pending  = false;
      movingIds = [];
      startRow = null;
      hideIndicator();
      if (hadDrag) {
        opts.getRows().forEach(function (r) { r.classList.remove('dragging'); });
        document.body.style.cursor = '';
      }
    }

    container.addEventListener('mousedown', function (e) {
      if (e.button !== 0) return;
      var row = e.target.closest('.scene-row');
      if (!row) return;
      startRow = row;
      startX = e.clientX;
      startY = e.clientY;
      pending = true;
      // niente preventDefault: lasciamo che app.js gestisca la selezione su mousedown
    });

    document.addEventListener('mousemove', function (e) {
      if (!pending) return;
      if (!dragging) {
        if (Math.abs(e.clientX - startX) > DRAG_THRESHOLD ||
            Math.abs(e.clientY - startY) > DRAG_THRESHOLD) {
          beginDrag();
        }
      }
      if (dragging) {
        e.preventDefault();
        updateIndicator(e.clientY);
      }
    });

    document.addEventListener('mouseup', function (e) {
      if (!pending) return;
      if (dragging) {
        var hit = rowAtY(e.clientY);
        var rows = opts.getRows();
        var targetId = null;
        if (hit) {
          if (hit.before) {
            targetId = hit.row.dataset.id;
          } else {
            var next = rows[hit.index + 1];
            targetId = next ? next.dataset.id : null;
          }
        }
        // se il target è uno di quelli in spostamento, salta avanti
        while (targetId && movingIds.indexOf(targetId) !== -1) {
          var idx = -1;
          for (var i = 0; i < rows.length; i++) if (rows[i].dataset.id === targetId) { idx = i; break; }
          var nx = rows[idx + 1];
          targetId = nx ? nx.dataset.id : null;
        }
        opts.onDrop(movingIds, targetId);
      }
      cleanup();
    });

    // se l'utente esce dalla finestra e rilascia altrove, blocchiamo lo stato
    window.addEventListener('blur', cleanup);
  }

  return { attach: attach };
})();
