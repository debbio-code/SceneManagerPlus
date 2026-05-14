// Drag & drop multi-selezione in stile Photoshop, plain JS senza dipendenze.
// Espone window.SMDnd.attach(container, options) dove options = {
//   getRows:      () => [HTMLElement...]   // righe ordinate dalla UI
//   getSelected:  () => [id...]
//   onDrop:       (movingIds, targetId|null) => void
// }
window.SMDnd = (function () {
  function attach(container, opts) {
    var indicator = null;
    var dragging  = false;
    var movingIds = [];

    function clearIndicator() {
      if (indicator && indicator.parentNode) indicator.parentNode.removeChild(indicator);
      indicator = null;
    }

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

    container.addEventListener('dragstart', function (e) {
      var row = e.target.closest('.scene-row');
      if (!row) return;
      var sel = opts.getSelected();
      // se la riga trascinata non è selezionata, diventa unica selezione
      if (sel.indexOf(row.dataset.id) === -1) {
        if (typeof opts.onDragSelect === 'function') opts.onDragSelect(row.dataset.id);
        sel = [row.dataset.id];
      }
      movingIds = sel.slice();
      dragging = true;
      try { e.dataTransfer.setData('text/plain', movingIds.join(',')); } catch (_) {}
      e.dataTransfer.effectAllowed = 'move';
      // ghost: nascondi le altre selezionate
      opts.getRows().forEach(function (r) {
        if (movingIds.indexOf(r.dataset.id) !== -1) r.classList.add('dragging');
      });
    });

    container.addEventListener('dragover', function (e) {
      if (!dragging) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      var hit = rowAtY(e.clientY);
      clearIndicator();
      indicator = document.createElement('div');
      indicator.className = 'drop-indicator';
      var contRect = container.getBoundingClientRect();
      var top;
      if (hit) {
        var r = hit.row.getBoundingClientRect();
        top = (hit.before ? r.top : r.bottom) - contRect.top + container.scrollTop;
      } else {
        // sotto l'ultima riga
        var rows = opts.getRows();
        if (rows.length === 0) {
          top = 0;
        } else {
          var last = rows[rows.length - 1].getBoundingClientRect();
          top = last.bottom - contRect.top + container.scrollTop;
        }
      }
      indicator.style.top = top + 'px';
      container.appendChild(indicator);
    });

    container.addEventListener('drop', function (e) {
      if (!dragging) return;
      e.preventDefault();
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
      // se il target è uno di quelli che si stanno spostando, salta in avanti
      while (targetId && movingIds.indexOf(targetId) !== -1) {
        var idx = -1;
        for (var i = 0; i < rows.length; i++) if (rows[i].dataset.id === targetId) { idx = i; break; }
        var nx = rows[idx + 1];
        targetId = nx ? nx.dataset.id : null;
      }
      opts.onDrop(movingIds, targetId);
      cleanup();
    });

    container.addEventListener('dragend', cleanup);

    function cleanup() {
      dragging = false;
      movingIds = [];
      clearIndicator();
      opts.getRows().forEach(function (r) { r.classList.remove('dragging'); });
    }
  }

  return { attach: attach };
})();
