// Scene Manager+ — sezione "Print to scale" della scheda scena.
//
// La scala e' una proprieta' della scena, quindi si imposta qui insieme alle
// altre. Vive in un file suo e si aggancia a SMP.setState invece di stare
// dentro properties.js: quel file e' gia' lungo e questa sezione e' autonoma.
//
// Due regole che governano tutto quello che c'e' sotto:
//  1. i numeri (area coperta, pixel, memoria, spessore del tratto) li calcola
//     Ruby (Core::PrintScale.compute) e il JS li mostra e basta. La matematica
//     del foglio deve stare in UN posto solo: e' gia' costato un bug avere la
//     regola del prefisso duplicata fra Naming ed Exporter.
//  2. il commit NON e' live come nel resto del dialog: scrivere sulla pagina
//     puo' costare secondi sui modelli con AttributeObserver di plugin terzi,
//     quindi si salva solo con Apply. Anteprima gratis, scrittura a comando.
(function () {
  'use strict';

  var SMP = window.SMP;
  if (!SMP) return;

  function $(sel) { return document.querySelector(sel); }

  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) { console.error('[SMP] ps call failed', name, e); }
  }

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // chiave della cfg -> id del controllo.
  // `titleblock_mm` NON c'e' piu': l'altezza della fascia la calcola Ruby dalla
  // larghezza del foglio, per tenere al cartiglio le stesse proporzioni di
  // sempre. Resta nella cfg salvata (vedi readCfg) solo per compatibilita'.
  var FIELDS = {
    paper:         'ps-paper',
    orientation:   'ps-orient',
    scale_denom:   'ps-denom',
    dpi:           'ps-dpi',
    margin_mm:     'ps-margin',
    profile_mm:    'ps-profile',
    sheet_mode:    'ps-sheetmode',
    format:        'ps-format'
  };

  var psSaved   = null;   // cfg salvata nella scena (null = scena senza scala)
  var psLast    = null;   // ultimo payload ricevuto da Ruby
  var psListsIn = false;  // select gia' popolati
  var psTimer   = null;
  var bound     = false;

  function readCfg() {
    var cfg = {};
    Object.keys(FIELDS).forEach(function (k) {
      var el = document.getElementById(FIELDS[k]);
      if (el) cfg[k] = el.value;
    });
    // Campi che questa sezione non espone ma che vanno conservati, altrimenti
    // ogni Apply li azzererebbe.
    var base = (psLast && psLast.cfg) ? psLast.cfg : {};
    ['section_mm', 'antialias', 'titleblock_mm'].forEach(function (k) {
      if (base[k] !== undefined && base[k] !== null) cfg[k] = base[k];
    });
    return cfg;
  }

  // Confronto per VALORE, non per stringa: i campi sono testo ("50") e la cfg
  // salvata ha numeri (50.0). Senza normalizzare, Apply resterebbe acceso per
  // sempre anche senza modifiche.
  function sameAsSaved() {
    if (!psSaved) return false;
    var cur = readCfg();
    return Object.keys(FIELDS).every(function (k) {
      var a = cur[k], b = psSaved[k];
      var na = parseFloat(String(a).replace(',', '.'));
      var nb = parseFloat(String(b).replace(',', '.'));
      if (!isNaN(na) && !isNaN(nb)) return Math.abs(na - nb) < 1e-9;
      return String(a) === String(b);
    });
  }

  function markDirty() {
    var btn = $('#btn-ps-apply');
    if (!btn) return;
    var chk = $('#ps-enabled');
    var on = chk && chk.checked;
    btn.classList.toggle('is-dirty', !!on && !sameAsSaved());
  }

  function requestNumbers() {
    if (psTimer) clearTimeout(psTimer);
    psTimer = setTimeout(function () {
      psTimer = null;
      call('sm_props_ps_preview', { cfg: readCfg() });
    }, 200);
  }

  SMP.setScaleNumbers = function (nums) {
    try { renderReadout(nums); } catch (e) { console.error('[SMP] setScaleNumbers', e); }
  };

  function renderReadout(nums) {
    var box  = $('#ps-readout');
    var warn = $('#ps-warn');
    if (!box || !nums) return;

    var errs = nums.errors || [];
    if (errs.length) {
      box.innerHTML = '';
      if (warn) {
        warn.textContent = errs.join(' ');
        warn.className = 'ps-note is-error';
        warn.style.display = 'block';
      }
      return;
    }

    var rows = [
      ['Scale',    nums.scale,    ''],
      ['Sheet',    nums.sheet,    ''],
      ['Drawing',  nums.drawing,  ''],
      ['Covers',   nums.covers,   ''],
      ['Image',    nums.image,    ''],
      ['Memory',   nums.memory,   nums.heavy ? ' is-heavy' : ''],
      ['Thinnest', nums.thinnest, ''],
      ['Profiles', nums.profile,  ''],
      // La taratura sposta la scala del 4%: chi legge i numeri deve vedere
      // che e' attiva, altrimenti "Covers" sembra sbagliato.
      ['Printer',  nums.calib,    nums.calibrated ? ' is-calib' : '']
    ];
    box.innerHTML = rows.map(function (r) {
      var v = (r[1] === undefined || r[1] === null) ? '-' : r[1];
      return '<span class="ps-r-lbl">' + esc(r[0]) + '</span>' +
             '<span class="ps-r-val' + r[2] + '">' + esc(v) + '</span>';
    }).join('');

    var msg = [];
    if (nums.heavy) msg.push('This sheet needs a lot of memory: SketchUp may run out of it.');
    (nums.notes || []).forEach(function (n) { msg.push(n); });
    if (warn) {
      if (msg.length) {
        warn.textContent = msg.join(' ');
        warn.className = 'ps-note';
        warn.style.display = 'block';
      } else {
        warn.style.display = 'none';
      }
    }

    // Lo spessore del tratto piu' sottile e' la conseguenza meno intuitiva dei
    // DPI (gli spigoli ordinari sono sempre 1 px, quindi alzare i DPI assottiglia
    // la linea invece di ingrossarla): si mostra accanto al campo che lo decide.
    var th = $('#ps-thinnest');
    if (th) th.textContent = nums.thinnest ? ('thinnest line ' + nums.thinnest) : '';

    // Altezza della fascia cartiglio: calcolata, non scelta.
    var bd = $('#ps-band-ro');
    if (bd) bd.textContent = (nums.band === undefined || nums.band === null) ? '-' : nums.band;
  }

  function fillLists(ps) {
    if (psListsIn) return;
    psListsIn = true;

    var pap = $('#ps-paper');
    if (pap) {
      pap.innerHTML = (ps.papers || []).map(function (p) {
        return '<option value="' + esc(p) + '">' + esc(p) + '</option>';
      }).join('');
    }

    var pick = $('#ps-denom-pick');
    if (pick) {
      pick.innerHTML = '<option value="">common</option>' +
        (ps.scales || []).map(function (n) {
          return '<option value="' + esc(n) + '">1:' + esc(n) + '</option>';
        }).join('');
      pick.addEventListener('change', function () {
        if (!pick.value) return;
        var d = $('#ps-denom');
        if (d) { d.value = pick.value; onEdit(); }
        pick.value = '';
      });
    }
  }

  function onEdit() { markDirty(); requestNumbers(); }

  function renderPrintScale(ps) {
    var fs = $('#ps-fieldset');
    if (!fs) return;
    if (!ps) { fs.style.display = 'none'; return; }
    fs.style.display = '';
    psLast = ps;
    fillLists(ps);

    var chk = $('#ps-enabled');
    if (chk && document.activeElement !== chk) chk.checked = !!ps.enabled;

    // Non sovrascrivere il campo che l'utente sta compilando: stesso principio
    // del setIfNotFocused usato per Name/Description.
    Object.keys(FIELDS).forEach(function (k) {
      var el = document.getElementById(FIELDS[k]);
      if (!el || document.activeElement === el) return;
      var v = ps.cfg ? ps.cfg[k] : null;
      if (v === undefined || v === null) return;
      el.value = String(v);
    });

    psSaved = ps.enabled ? JSON.parse(JSON.stringify(ps.cfg || {})) : null;

    var ctr = $('#ps-controls');
    if (ctr) ctr.classList.toggle('ps-disabled', !ps.enabled);
    var pb = $('#btn-ps-print');
    if (pb) pb.disabled = !ps.enabled;
    var cb = $('#btn-ps-clear');
    if (cb) cb.disabled = !ps.enabled;

    // Il badge dice la verita' sull'inquadratura SALVATA nella scena, non su
    // quello che si vede adesso: "ok" significa "riaprendo questa scena sara'
    // gia' in scala".
    var badge = $('#ps-badge');
    if (badge) {
      if (ps.enabled && ps.badge) {
        badge.textContent = ps.badge.ok ?
          (ps.badge.label + ' - ' + ps.badge.sheet) :
          (ps.badge.label + ' - out of scale');
        badge.className = 'ps-badge ' + (ps.badge.ok ? 'is-ok' : 'is-off');
        badge.title = ps.badge.ok ?
          'The view saved in this scene is at this scale.' :
          ('Not at this scale: ' + (ps.badge.reason || '') +
           '. Press Apply to put it back and store it in the scene.');
      } else {
        badge.textContent = '';
        badge.className = 'ps-badge';
        badge.title = '';
      }
    }

    renderCalibration(ps.calibration);
    renderReadout(ps.numbers);
    markDirty();
  }

  // La taratura vive fuori dalla scena: e' della stampante, salvata per
  // computer. Il select NON viene ricostruito se ha il fuoco (stesso principio
  // del setIfNotFocused): un push_state a tendina aperta la chiuderebbe in
  // faccia all'utente.
  function renderCalibration(cal) {
    var sel = $('#ps-calib');
    if (!sel || !cal) return;
    var profs = cal.profiles || [];
    if (document.activeElement !== sel) {
      sel.innerHTML = '<option value="">No calibration (1:1)</option>' +
        profs.map(function (p) {
          return '<option value="' + esc(p.name) + '">' + esc(p.name) + '</option>';
        }).join('');
      sel.value = cal.active || '';
    }
    var del = $('#btn-ps-calib-del');
    if (del) del.disabled = !(cal.active || '');
    var actP = null;
    profs.forEach(function (p) { if (p.name === cal.active) actP = p; });

    var hint = $('#ps-calib-hint');
    if (hint) {
      hint.textContent = !actP ? 'sheets print at their nominal size' :
        (actP.use_y && actP.factor_y ?
          ('H ' + actP.factor.toFixed(4) + '  V ' + actP.factor_y.toFixed(4)) :
          ('factor ' + actP.factor.toFixed(4) + ' (' +
           ((actP.factor - 1) * 100).toFixed(2) + '%)'));
    }
    // Con un profilo attivo, la misura RAFFINA il fattore (il foglio che stai
    // misurando e' stato stampato con quel fattore). Senza, lo crea da zero.
    var lbl = $('#ps-calib-from');
    if (lbl) {
      lbl.textContent = actP ?
        'Measure the sheet you just printed: it refines the profile' :
        'Print a sheet, measure a known length, type both numbers';
    }
    // Si riporta solo il "should be" (e' la stessa lunghezza di riferimento a
    // ogni giro). Il "came out" resta VUOTO di proposito: il fattore ora si
    // compone con quello attivo, quindi ri-salvare una misura gia' usata lo
    // applicherebbe due volte.
    setIfFree('#ps-calib-exp',   actP && actP.expected);
    setIfFree('#ps-calib-exp-y', actP && actP.use_y && actP.expected_y);
    setIfFree('#ps-calib-got',   null);
    setIfFree('#ps-calib-got-y', null);

    var uy = $('#ps-calib-usey');
    if (uy && document.activeElement !== uy) uy.checked = !!(actP && actP.use_y);
    paintCalibY();
  }

  function setIfFree(sel, v) {
    var el = $(sel);
    if (!el || document.activeElement === el) return;
    el.value = v ? String(v) : '';
  }

  // Mostra/nasconde la riga della misura verticale e l'avviso che la spiega.
  // La spunta e' opt-in perche' la meta' orizzontale della correzione vive
  // nella risoluzione scritta nel file: se il programma di stampa la ignora
  // (o "adatta alla pagina") quella meta' non ha effetto.
  function paintCalibY() {
    var uy  = $('#ps-calib-usey');
    var box = document.querySelector('.ps-calib');
    var on  = !!(uy && uy.checked);
    if (box) box.classList.toggle('no-y', !on);
    var lblH = $('#ps-calib-axis-h');
    if (lblH) lblH.textContent = on ? 'horizontal' : '';
    var w = $('#ps-calib-warn');
    if (w) {
      w.textContent = on ?
        'the horizontal half only works if your printing software honours the DPI in the file' : '';
    }
  }

  var baseSetState = SMP.setState;
  SMP.setState = function (state) {
    baseSetState.call(SMP, state);
    try {
      renderPrintScale(state && state.scene ? state.scene.print_scale : null);
    } catch (e) { console.error('[SMP] renderPrintScale', e); }
  };

  function bind() {
    if (bound) return;
    bound = true;
    Object.keys(FIELDS).forEach(function (k) {
      var el = document.getElementById(FIELDS[k]);
      if (!el) return;
      // 'change' e non 'input': digitando "3000" un carattere per volta non
      // devono partire quattro anteprime.
      el.addEventListener('change', onEdit);
    });

    var chk = $('#ps-enabled');
    if (chk) {
      chk.addEventListener('change', function () {
        var ctr = $('#ps-controls');
        if (chk.checked) {
          if (ctr) ctr.classList.remove('ps-disabled');
          onEdit();
        } else {
          // Toglierla e' immediato: la scena torna a esportare come tutte le
          // altre. Rimetterla richiede Apply, perche' e' una scrittura.
          if (ctr) ctr.classList.add('ps-disabled');
          if (psSaved) call('sm_props_ps_clear', {});
        }
      });
    }

    var ap = $('#btn-ps-apply');
    if (ap) ap.addEventListener('click', function () { call('sm_props_ps_apply', { cfg: readCfg() }); });
    var pr = $('#btn-ps-print');
    if (pr) pr.addEventListener('click', function () { call('sm_props_ps_print', { cfg: readCfg() }); });
    var cl = $('#btn-ps-clear');
    if (cl) cl.addEventListener('click', function () { call('sm_props_ps_clear', {}); });

    var cs = $('#ps-calib');
    if (cs) cs.addEventListener('change', function () {
      call('sm_props_ps_calib_select', { name: cs.value });
    });
    var cd = $('#btn-ps-calib-del');
    if (cd) cd.addEventListener('click', function () {
      var s = $('#ps-calib');
      if (s && s.value) call('sm_props_ps_calib_delete', { name: s.value });
    });
    var uy = $('#ps-calib-usey');
    if (uy) uy.addEventListener('change', paintCalibY);

    var cv = $('#btn-ps-calib-save');
    if (cv) cv.addEventListener('click', function () {
      var e1 = $('#ps-calib-exp'),   e2 = $('#ps-calib-got'), s = $('#ps-calib');
      var y1 = $('#ps-calib-exp-y'), y2 = $('#ps-calib-got-y');
      var u  = $('#ps-calib-usey');
      call('sm_props_ps_calib_save', {
        name:       s ? s.value : '',
        expected:   e1 ? e1.value : '',
        measured:   e2 ? e2.value : '',
        use_y:      !!(u && u.checked),
        expected_y: y1 ? y1.value : '',
        measured_y: y2 ? y2.value : ''
      });
    });

    paintCalibY();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bind);
  } else {
    bind();
  }
})();
