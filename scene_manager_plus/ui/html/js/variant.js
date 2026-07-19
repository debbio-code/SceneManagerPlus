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
    renderOverrides();
  }

  function init() {
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
