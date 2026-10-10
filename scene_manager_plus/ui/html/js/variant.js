// Logica del dialog "Color variant" (Fase V2).
// NB: mantenere le stringhe in ASCII puro (trappola smart-quotes, vedi CLAUDE.md).
window.SMV = (function () {
  'use strict';

  var state = null;
  var NONE_VALUE = '__none__';

  function $(id) { return document.getElementById(id); }

  function call(name, data) {
    var payload = (data === undefined) ? '' : JSON.stringify(data);
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      try { window.sketchup[name](payload); } catch (err) { /* noop */ }
    }
  }

  function setStatus(msg) {
    var el = $('status');
    if (el) el.textContent = msg || '-';
  }

  function matLabel(name) {
    return name === null || name === undefined ? '(no material)' : name;
  }

  // Costruisce le <option> per un select di materiali. selected puo' essere
  // string | null (null = "(remove material)").
  function fillMatSelect(sel, materials, selected, includeNone) {
    while (sel.firstChild) sel.removeChild(sel.firstChild);
    if (includeNone) {
      var optNone = document.createElement('option');
      optNone.value = NONE_VALUE;
      optNone.textContent = '(remove material)';
      sel.appendChild(optNone);
    }
    materials.forEach(function (name) {
      var opt = document.createElement('option');
      opt.value = name;
      opt.textContent = name;
      sel.appendChild(opt);
    });
    if (selected === null) {
      sel.value = NONE_VALUE;
    } else if (selected !== undefined && materials.indexOf(selected) !== -1) {
      sel.value = selected;
    } else if (selected !== undefined && selected !== null) {
      // Materiale referenziato dall'override ma non piu' presente nel
      // modello (rinominato/purgato): mostra una option disabilitata
      // esplicita invece di ripiegare silenziosamente sulla prima voce.
      var optMissing = document.createElement('option');
      optMissing.value = '__missing__';
      optMissing.textContent = 'missing: ' + selected;
      optMissing.disabled = true;
      sel.insertBefore(optMissing, sel.firstChild);
      sel.value = '__missing__';
    }
  }

  // ---------------------------------------------------------------
  // Override di materiale: [base] nome -> [in questa scena] [copia] [x]
  // Le righe arrivano da Ruby (state.mat_rows): i materiali che la scena
  // gia' cambia + quelli usati dalla selezione nel viewport.
  // ---------------------------------------------------------------

  // Anteprima mentre si trascina nel selettore: al massimo una chiamata a
  // Ruby ogni PREVIEW_MS (ognuna e' un'operazione su SketchUp).
  var PREVIEW_MS = 120;
  var pvTimer = null;
  var pvLast = null;

  function sendPreview(name, hex) {
    pvLast = { name: name, color: hex };
    if (pvTimer) return;
    pvTimer = setTimeout(function () {
      pvTimer = null;
      if (pvLast) { call('sm_variant_mat_preview', pvLast); pvLast = null; }
    }, PREVIEW_MS);
  }

  function dropPreview() {
    if (pvTimer) { clearTimeout(pvTimer); pvTimer = null; }
    pvLast = null;
  }

  function pickColor(sw, row) {
    if (!window.SMColorPopup) return;
    var start = row.color || row.base || '#ffffff';
    window.SMColorPopup.show(sw, start, function (hex) {
      // chiusura del selettore = conferma (una sola scrittura sulla scena)
      dropPreview();
      call('sm_variant_mat_set', { name: row.name, color: hex });
    }, {
      commitOnEnd: true,
      onPreview: function (hex) {
        sw.classList.remove('empty');
        sw.textContent = '';
        sw.style.background = hex;
        sendPreview(row.name, hex);
      }
    });
  }

  // <select> stretto che fa da bottone: la prima voce e' l'etichetta, le
  // altre i materiali. Scelto uno, chiama fn e torna sull'etichetta.
  function pickSelect(cls, label, title, names, fn) {
    var sel = document.createElement('select');
    sel.className = 'mat-pick ' + cls;
    sel.title = title;
    var first = document.createElement('option');
    first.value = '';
    first.textContent = label;
    sel.appendChild(first);
    names.forEach(function (n) {
      var opt = document.createElement('option');
      opt.value = n;
      opt.textContent = n;
      sel.appendChild(opt);
    });
    sel.addEventListener('change', function () {
      var v = sel.value;
      sel.value = '';
      if (v) fn(v);
    });
    return sel;
  }

  function renderMaterials() {
    var list = $('mat-list');
    while (list.firstChild) list.removeChild(list.firstChild);
    var rows = (state && state.mat_rows) || [];
    var active = !!(state && state.is_active);
    var nSet = rows.filter(function (r) { return !!r.color; }).length;
    $('mat-count').textContent = nSet ? '(' + nSet + ')' : '';
    $('mat-empty').classList.toggle('hidden', rows.length > 0);
    $('mat-truncated').classList.toggle('hidden', !(state && state.mat_truncated));
    // dove si puo' spostare un override rimasto su un materiale non piu' in
    // uso: i materiali della selezione che non ne hanno ancora uno
    var targets = rows.filter(function (r) {
      return r.in_sel && !r.color && !r.textured && !r.missing;
    }).map(function (r) { return r.name; });

    rows.forEach(function (r) {
      var stale = !!(r.color && (r.missing || r.unused));
      var locked = !active || r.missing || r.textured;
      var row = document.createElement('div');
      row.className = 'mat-row' + (r.color ? ' set' : '') + (stale ? ' off' : '');

      var base = document.createElement('span');
      base.className = 'mat-sw';
      if (r.base) base.style.background = r.base;
      base.title = r.base ? 'Base color ' + r.base : 'Material not in the model';
      row.appendChild(base);

      var name = document.createElement('span');
      name.className = 'mat-name';
      name.textContent = r.name;
      name.title = r.name;
      row.appendChild(name);

      var tagText = r.missing ? 'missing' : (r.textured ? 'texture' : (r.unused ? 'not in use' : ''));
      if (tagText) {
        var tag = document.createElement('span');
        tag.className = 'mat-tag';
        tag.textContent = tagText;
        tag.title = r.missing ? 'This material is no longer in the model.'
          : (r.textured ? 'Materials with a texture are not supported yet.'
            : 'Nothing in the model uses this material any more.');
        row.appendChild(tag);
      }

      if (stale && active && targets.length) {
        row.appendChild(pickSelect('mat-move', 'move to', 'Move this override to another material', targets, function (to) {
          call('sm_variant_mat_move', { from: r.name, to: to });
        }));
      }

      var arrow = document.createElement('span');
      arrow.className = 'ov-arrow';
      arrow.textContent = '→';
      row.appendChild(arrow);

      var sw = document.createElement('span');
      sw.className = 'mat-sw mat-sw-var' + (r.color ? '' : ' empty') + (locked ? ' locked' : '');
      if (r.color) sw.style.background = r.color; else sw.textContent = '+';
      sw.title = !active ? 'Activate the scene first'
        : (r.textured ? 'Materials with a texture are not supported yet'
          : (r.color ? 'In this scene: ' + r.color + ' - click to change' : 'Click to choose a color for this scene'));
      if (!locked) sw.addEventListener('click', function () { pickColor(sw, r); });
      row.appendChild(sw);

      // Le due caselle in fondo ci sono sempre, anche vuote: cosi' i
      // quadratini restano in colonna.
      var copySlot = document.createElement('span');
      copySlot.className = 'mat-slot';
      if (!locked) {
        var others = (state.materials || []).filter(function (n) { return n !== r.name; });
        // largo quanto la freccina: l'etichetta si legge solo a tendina aperta
        copySlot.appendChild(pickSelect('mat-copy', 'copy the color of...', 'Copy the color of another material', others, function (from) {
          call('sm_variant_mat_copy', { name: r.name, from: from });
        }));
      }
      row.appendChild(copySlot);

      var rmSlot = document.createElement('span');
      rmSlot.className = 'mat-slot';
      if (r.color) {
        var rm = document.createElement('button');
        rm.className = 'ov-remove';
        rm.textContent = '✕';
        rm.title = 'Remove (back to the base color)';
        rm.addEventListener('click', function () {
          call('sm_variant_mat_remove', { name: r.name });
        });
        rmSlot.appendChild(rm);
      }
      row.appendChild(rmSlot);

      list.appendChild(row);
    });
  }

  function renderOverrides() {
    var list = $('ov-list');
    var empty = $('ov-empty');
    var count = $('ov-count');
    while (list.firstChild) list.removeChild(list.firstChild);
    var ovs = (state && state.overrides) || [];
    count.textContent = ovs.length ? '(' + ovs.length + ')' : '';
    empty.classList.toggle('hidden', ovs.length > 0);
    // "Clean missing" visibile solo se ci sono override orfani
    var anyMissing = ovs.some(function (o) { return !o.found; });
    $('btn-clean').classList.toggle('hidden', !anyMissing);
    ovs.forEach(function (o) {
      var row = document.createElement('div');
      row.className = 'ov-row' + (o.found ? '' : ' missing');

      var kind = document.createElement('span');
      kind.className = 'ov-kind';
      kind.textContent = o.kind;
      kind.title = 'pid ' + o.pid + ' - click to select in viewport';
      kind.addEventListener('click', function () {
        if (o.found) call('sm_variant_pick', { pid: o.pid });
      });
      row.appendChild(kind);

      var base = document.createElement('span');
      base.className = 'ov-base';
      base.textContent = matLabel(o.base);
      base.title = 'Base material: ' + matLabel(o.base);
      row.appendChild(base);

      var arrow = document.createElement('span');
      arrow.className = 'ov-arrow';
      arrow.textContent = '→';
      row.appendChild(arrow);

      var sel = document.createElement('select');
      sel.className = 'ov-mat';
      fillMatSelect(sel, state.materials || [], o.mat, true);
      sel.addEventListener('change', function () {
        var v = sel.value === NONE_VALUE ? null : sel.value;
        call('sm_variant_set_mat', { pid: o.pid, mat: v });
      });
      row.appendChild(sel);

      var rm = document.createElement('button');
      rm.className = 'ov-remove';
      rm.textContent = '✕';
      rm.title = 'Remove override (restore base material)';
      rm.addEventListener('click', function () {
        call('sm_variant_remove', { pid: o.pid });
      });
      row.appendChild(rm);

      list.appendChild(row);
    });
  }

  function setState(s) {
    state = s;
    $('scene-name').textContent = s.scene_name || '-';
    $('inactive-banner').classList.toggle('hidden', !!s.is_active);
    // Non ricostruire il dropdown Assign se l'utente lo sta usando
    var matSel = $('mat-select');
    if (document.activeElement !== matSel) {
      var prev = matSel.value;
      fillMatSelect(matSel, s.materials || [], undefined, true);
      // preserva la scelta precedente se ancora valida
      if (prev) {
        var opts = Array.prototype.map.call(matSel.options, function (op) { return op.value; });
        if (opts.indexOf(prev) !== -1) matSel.value = prev;
      }
    }
    renderMaterials();
    renderOverrides();
  }

  function init() {
    // Un errore JS qui dentro non si vede da nessuna parte: lo si manda
    // alla Ruby Console.
    window.onerror = function (msg, src, line) {
      call('sm_variant_log', 'JS error: ' + msg + ' @' + line);
    };
    $('btn-assign').addEventListener('click', function () {
      var v = $('mat-select').value;
      call('sm_variant_assign', { mat: v === NONE_VALUE ? null : v });
    });
    $('btn-clear').addEventListener('click', function () {
      call('sm_variant_clear');
    });
    $('btn-clean').addEventListener('click', function () {
      call('sm_variant_clean_missing');
    });
    $('btn-activate').addEventListener('click', function () {
      call('sm_variant_activate');
    });
    call('sm_variant_ready');
  }

  document.addEventListener('DOMContentLoaded', init);

  return { setState: setState, setStatus: setStatus };
})();
