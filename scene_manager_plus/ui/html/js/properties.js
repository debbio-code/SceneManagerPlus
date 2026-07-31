// Scene Manager+ — Properties dialog JS (live commit, no Apply button)
(function () {
  'use strict';

  const SMP = { state: null, applying: false };
  window.SMP = SMP;

  function $(sel) { return document.querySelector(sel); }
  function call(name, payload) {
    try {
      if (window.sketchup && typeof window.sketchup[name] === 'function') {
        window.sketchup[name](payload ? JSON.stringify(payload) : '');
      }
    } catch (e) { console.error('[SMP] call failed', name, e); }
  }
  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;');
  }

  // Mapping UI: label native SU + fusione use_style+use_rendering_options
  // in un unico "Style and Fog" (come nella UI nativa SU — 7 voci, non 8).
  var FLAG_UI = [
    { label: 'Camera Location',       keys: ['use_camera'] },
    { label: 'Hidden Geometry',       keys: ['use_hidden'] },
    { label: 'Visible Layers',        keys: ['use_hidden_layers'] },
    { label: 'Active Section Planes', keys: ['use_section_planes'] },
    { label: 'Style and Fog',         keys: ['use_style', 'use_rendering_options'] },
    { label: 'Shadow Settings',       keys: ['use_shadow_info'] },
    { label: 'Axes Location',         keys: ['use_axes'] },
  ];

  // === Anti "devo cliccare due volte" =======================================
  // Ogni push_state ricostruisce interi blocchi di DOM via innerHTML. Quando la
  // finestra non ha il fuoco, il primo mousedown la attiva -> parte
  // debouncedPropsRefresh -> Ruby risponde con setState -> il DOM viene
  // sostituito PRIMA del mouseup, e il browser non genera nessun `click`
  // (richiede mousedown e mouseup sullo stesso elemento). Risultato: il primo
  // click su un bottone "si perde", il secondo funziona.
  //
  // Rimedio: ridisegnare solo se i dati sono davvero cambiati. Le firme sono
  // il JSON del payload di quella sezione.
  var flagSig = null;
  var laySig  = null;

  function renderFlags(flagKeys, flags, isMatchPhoto) {
    const el = $('#prop-flags');
    var sig = JSON.stringify([flagKeys, flags, !!isMatchPhoto]);
    if (sig === flagSig && el.querySelector('input')) return;
    flagSig = sig;
    // Filtra agli item che hanno almeno una key presente in flagKeys (defensive)
    const items = FLAG_UI.filter(item => item.keys.some(k => flagKeys.indexOf(k) !== -1));
    el.innerHTML = items.map((item, idx) => {
      // Checked se TUTTE le keys dell'item sono true (coerenza con SU nativo)
      const checked = item.keys.every(k => flags && flags[k]) ? 'checked' : '';
      const fsAttr = escapeHtml(JSON.stringify(item.keys));
      // MP "Style and Fog" (use_style + use_rendering_options): scrivere questi
      // flag via Ruby setter su scena MP corrompe lo state interno → crash.
      // L'inspector Scenes nativo invece scrive via un pathway C++ "pulito" che
      // non corrompe nulla. Quindi: checkbox cliccabile, ma il click apre
      // l'inspector nativo invece di togglare via Ruby.
      const isStyleFog = item.keys.indexOf('use_style') !== -1;
      const isMPStyleFog = isMatchPhoto && isStyleFog;
      const title = isMPStyleFog
        ? ' title="Match Photo scene: click to open the native Scenes panel (the only safe way to set Style and Fog on MP scenes)."'
        : '';
      const labelClass = isMPStyleFog ? ' class="flag-mp-fog"' : '';
      const dataMp = isMPStyleFog ? ' data-mp-fog="1"' : '';
      return '<label' + labelClass + title + dataMp + '><input type="checkbox" data-flags="' + fsAttr + '" ' + checked + '>' +
             '<span>' + escapeHtml(item.label) + '</span></label>';
    }).join('');
    el.querySelectorAll('input[type=checkbox]').forEach(cb => {
      const label = cb.closest('label');
      if (label && label.dataset && label.dataset.mpFog === '1') {
        // Intercetta il click PRIMA che il checkbox cambi state (in capturing),
        // previene il toggle, e apre l'inspector Scenes nativo via Ruby.
        const handler = (e) => {
          e.preventDefault();
          e.stopPropagation();
          call('sm_props_open_scenes_panel', { id: SMP.state && SMP.state.scene ? SMP.state.scene.id : null });
        };
        label.addEventListener('click', handler, true);
      } else {
        cb.addEventListener('change', commit);
      }
    });
  }

  function readForm() {
    const flags = {};
    document.querySelectorAll('#prop-flags input[type=checkbox]').forEach(cb => {
      // data-flags è un JSON array: per item merged (es. Style and Fog)
      // propaga il valore a tutte le keys corrispondenti.
      var keys;
      try { keys = JSON.parse(cb.dataset.flags || '[]'); } catch (e) { keys = []; }
      keys.forEach(k => { flags[k] = cb.checked; });
    });
    return {
      id:          SMP.state && SMP.state.scene ? SMP.state.scene.id : null,
      name:        $('#prop-name').value,
      description: $('#prop-desc').value,
      flags:       flags
    };
  }

  function setStatus(msg, ms) {
    $('#status').textContent = msg;
    if (msg) setTimeout(() => { $('#status').textContent = ''; }, ms || 1500);
  }

  function commit() {
    if (SMP.applying) return;
    const data = readForm();
    if (!data.id) return;
    // Se name è vuoto, non inviarlo (SU non accetterebbe nome vuoto)
    if (!data.name || !data.name.trim()) {
      // ripristina dal state
      $('#prop-name').value = (SMP.state && SMP.state.scene) ? SMP.state.scene.name : '';
      setStatus('Name cannot be empty');
      return;
    }
    SMP.applying = true;
    call('sm_props_apply', data);
    setStatus('Saved');
    // applying si resetta in setState (push successivo)
    setTimeout(() => { SMP.applying = false; }, 200);
  }

  SMP.setState = function (state) {
    const s = state && state.scene;
    if (!s) {
      // Stato vuoto: può capitare se push_state arriva con @scene_id non
      // ancora risolto a una pagina, in race con apertura dialog. Se avevamo
      // uno stato valido prima, non sovrascriviamo i campi a vuoto. Se non
      // avevamo nulla, mostriamo "scene not found".
      if (SMP.state && SMP.state.scene) return;
      SMP.state = state;
      $('#scene-title').textContent = '(scene not found)';
      $('#prop-name').value = '';
      $('#prop-desc').value = '';
      $('#prop-flags').innerHTML = '';
      $('#btn-update-view').disabled = true;
      return;
    }
    SMP.state = state;
    $('#scene-title').textContent = s.name || '(unnamed)';
    // Non sovrascrivere il campo se l'utente sta digitando in quel momento
    const nameEl = $('#prop-name');
    const descEl = $('#prop-desc');
    if (document.activeElement !== nameEl) nameEl.value = s.name || '';
    if (document.activeElement !== descEl) descEl.value = s.description || '';
    renderFlags(state.flag_keys || [], s.flags || {}, !!s.is_matchphoto);
    $('#btn-update-view').disabled = false;
    renderPreview(state.preview_url);
    renderLayers(state);
    renderFog(s.fog || {}, !!s.is_active);
    // Esito di un'operazione Ruby che non merita un messagebox (es. quante
    // entita' sono finite sul layer).
    if (state.status) setStatus(state.status, 4000);
    SMP.applying = false;
  };

  // === Fog dual-range slider =================================================
  // Semantica (come il nativo SU Window → Fog):
  //  - L'asse del slider rappresenta la DISTANZA dalla camera (in unità
  //    modello, da 0 a un MAX dinamico = 2× bbox model diagonal).
  //  - I due thumb hanno labels FISSE "0%" e "100%" che si riferiscono alla
  //    DENSITÀ della nebbia in quel punto: "0%" = la nebbia INIZIA (densità
  //    0%, ancora trasparente), "100%" = la nebbia è OPACA (densità 100%).
  //  - Tra i due thumb, la densità interpola linearmente 0→100%.
  //  - I numeri sotto sono distanze fisiche in unità modello.
  var fogDragging = null;       // 'start' | 'end' | null
  var fogValues   = { start: 0, end: 0, display: false, active: false, max: 100, unit: 'in' };

  function valToPct(v) {
    var mx = fogValues.max > 0 ? fogValues.max : 1;
    var p = (v / mx) * 100;
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return p;
  }
  function pctToVal(p) {
    if (p < 0) p = 0;
    if (p > 100) p = 100;
    return (p / 100) * fogValues.max;
  }
  function pxToVal(clientX) {
    var dual = $('#fog-dual');
    if (!dual) return 0;
    var r = dual.getBoundingClientRect();
    var p = ((clientX - r.left) / r.width) * 100;
    return pctToVal(p);
  }
  function roundForDisplay(v) {
    // Granularità adattiva: per scene piccole 3 decimali, grandi 1 decimale.
    if (fogValues.max < 10)    return Math.round(v * 1000) / 1000;
    if (fogValues.max < 1000)  return Math.round(v * 10)   / 10;
    return Math.round(v);
  }

  // Vincolo: 0% (start) deve essere STRETTAMENTE minore di 100% (end).
  // Epsilon adattivo alla scala — su modello 1500 ~ 0.15, su modello 0.01
  // ~ 1e-6. Il thumb "in movimento" si ferma al limite, l'altro non viene
  // spinto via (stesso comportamento del nativo SU).
  function fogEpsilon() {
    return Math.max((fogValues.max || 100) / 10000, 1e-6);
  }
  function constrainStart(v) {
    if (v < 0) v = 0;
    var limit = fogValues.end - fogEpsilon();
    if (v > limit) v = limit;
    if (v < 0) v = 0;
    return v;
  }
  function constrainEnd(v) {
    if (v < 0) v = 0;
    var floor = fogValues.start + fogEpsilon();
    if (v < floor) v = floor;
    return v;
  }
  function setFogValue(which, v) {
    fogValues[which] = (which === 'start') ? constrainStart(v) : constrainEnd(v);
  }

  function renderFog(fog, isActive) {
    fogValues.display = !!fog.display;
    fogValues.start   = Number(fog.start != null ? fog.start : 0);
    fogValues.end     = Number(fog.end   != null ? fog.end   : 0);
    fogValues.max     = Number(fog.max   != null ? fog.max   : 100);
    fogValues.unit    = String(fog.unit_lbl || 'in');
    fogValues.active  = !!isActive;

    var cb = $('#fog-display');
    if (cb && document.activeElement !== cb) cb.checked = fogValues.display;

    var startNum = $('#fog-num-start');
    var endNum   = $('#fog-num-end');
    if (startNum && document.activeElement !== startNum) startNum.value = String(roundForDisplay(fogValues.start));
    if (endNum   && document.activeElement !== endNum)   endNum.value   = String(roundForDisplay(fogValues.end));

    var us = $('#fog-unit-start'); if (us) us.textContent = fogValues.unit;
    var ue = $('#fog-unit-end');   if (ue) ue.textContent = fogValues.unit;

    repositionFogThumbs();

    // Disable controls se la scena non è attiva: la fog è una rendering
    // option del modello, ha senso solo sulla scena nel viewport.
    var controls = $('#fog-controls');
    var note     = $('#fog-activate-note');
    if (controls) controls.classList.toggle('fog-disabled', !isActive);
    if (note)     note.style.display = isActive ? 'none' : 'flex';
    if (cb)       cb.disabled = !isActive;
  }

  function repositionFogThumbs() {
    var ts = $('#fog-thumb-start');
    var te = $('#fog-thumb-end');
    var fill = $('#fog-fill');
    if (!ts || !te || !fill) return;
    var ps = valToPct(fogValues.start);
    var pe = valToPct(fogValues.end);
    ts.style.left = ps + '%';
    te.style.left = pe + '%';
    var lo = Math.min(ps, pe), hi = Math.max(ps, pe);
    fill.style.left  = lo + '%';
    fill.style.width = (hi - lo) + '%';
    var startNum = $('#fog-num-start');
    var endNum   = $('#fog-num-end');
    if (startNum && document.activeElement !== startNum) startNum.value = String(roundForDisplay(fogValues.start));
    if (endNum   && document.activeElement !== endNum)   endNum.value   = String(roundForDisplay(fogValues.end));
  }

  function commitFog(partial) {
    if (!SMP.state || !SMP.state.scene) return;
    if (!fogValues.active) return; // safety: enabled solo su scena attiva
    var data = {
      id: SMP.state.scene.id,
      display: fogValues.display,
      start:   fogValues.start,
      end:     fogValues.end
    };
    if (partial) {
      // Permette commit parziali (es. solo "start" durante drag finale)
      Object.keys(partial).forEach(function (k) { data[k] = partial[k]; });
    }
    call('sm_props_fog_apply', data);
  }

  function bindFog() {
    var cb = $('#fog-display');
    if (cb) {
      cb.addEventListener('change', function () {
        fogValues.display = cb.checked;
        commitFog();
      });
    }

    // Dual-range slider: drag dei thumb
    ['start', 'end'].forEach(function (which) {
      var th = $('#fog-thumb-' + which);
      if (!th) return;
      th.addEventListener('mousedown', function (e) {
        if (!fogValues.active) return;
        e.preventDefault();
        fogDragging = which;
        document.addEventListener('mousemove', onFogMove);
        document.addEventListener('mouseup',   onFogUp);
      });
    });
    // Click sul track per teletrasportare il thumb più vicino
    var dual = $('#fog-dual');
    if (dual) {
      dual.addEventListener('mousedown', function (e) {
        if (!fogValues.active) return;
        if (e.target.classList && e.target.classList.contains('fog-thumb')) return;
        if (e.target.classList && e.target.classList.contains('fog-thumb-lbl')) return;
        var v = pxToVal(e.clientX);
        var dStart = Math.abs(v - fogValues.start);
        var dEnd   = Math.abs(v - fogValues.end);
        fogDragging = (dStart <= dEnd) ? 'start' : 'end';
        setFogValue(fogDragging, v);
        repositionFogThumbs();
        document.addEventListener('mousemove', onFogMove);
        document.addEventListener('mouseup',   onFogUp);
      });
    }

    // Input numerici 0% / 100%: commit su change/blur, sync visivo live.
    // Su commit applica il vincolo start < end e re-scrive il campo se è
    // stato clampato (feedback all'utente).
    [['start', 'fog-num-start'], ['end', 'fog-num-end']].forEach(function (pair) {
      var which = pair[0], id = pair[1];
      var el = document.getElementById(id);
      if (!el) return;
      function commit() {
        if (!fogValues.active) return;
        var n = parseFloat(el.value);
        if (isNaN(n)) { el.value = String(roundForDisplay(fogValues[which])); return; }
        setFogValue(which, n);
        el.value = String(roundForDisplay(fogValues[which]));
        repositionFogThumbs();
        commitFog();
      }
      el.addEventListener('input', function () {
        var n = parseFloat(el.value);
        // Durante typing NON clampiamo (l'utente potrebbe stare ancora
        // scrivendo i digit di un numero valido). Lo facciamo al commit.
        if (!isNaN(n)) {
          fogValues[which] = n;
          repositionFogThumbs();
        }
      });
      el.addEventListener('change', commit);
      el.addEventListener('blur', commit);
      el.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); el.blur(); }
        else if (e.key === 'Escape') {
          el.value = String(roundForDisplay(fogValues[which]));
          el.blur();
        }
      });
    });

    var actBtn = $('#btn-fog-activate');
    if (actBtn) {
      actBtn.addEventListener('click', function () {
        if (!SMP.state || !SMP.state.scene) return;
        call('sm_props_activate_scene', { id: SMP.state.scene.id });
      });
    }

    // Bottoni +/- grossi per gli input fog. Auto-repeat su hold: dopo 350ms
    // di pressione continua, ripete ogni 60ms. Modificatori:
    //   Shift = ×10 (passo largo, per scene grandi)
    //   Ctrl  = ÷10 (passo fine, per ritocchi precisi)
    document.querySelectorAll('.fog-step-btn').forEach(function (btn) {
      var which = btn.dataset.step;   // 'start' | 'end'
      var dir   = parseInt(btn.dataset.dir, 10); // +1 | -1
      var holdTimer = null;
      var repeatTimer = null;

      function baseStep() {
        // Granularità adattiva al MAX dinamico. Target: ~200 step utili sul
        // range completo (50cm su modello 100m, 0.05mm su modello 10mm).
        var mx = fogValues.max > 0 ? fogValues.max : 100;
        var s = mx / 200;
        // Arrotonda a "step rotondo" (es. 0.5, 1, 5, 10, 50...) per non avere
        // valori sgranati tipo 0.4723
        var mag = Math.pow(10, Math.floor(Math.log(s) / Math.LN10));
        var f = s / mag;
        var rounded = (f < 1.5) ? 1 : (f < 3.5) ? 2 : (f < 7.5) ? 5 : 10;
        return rounded * mag;
      }
      function applyStep(modShift, modCtrl) {
        if (!fogValues.active) return;
        var step = baseStep();
        if (modShift) step *= 10;
        if (modCtrl)  step /= 10;
        var next = (fogValues[which] || 0) + dir * step;
        setFogValue(which, next); // applica vincolo start < end + ≥ 0
        repositionFogThumbs();
      }

      btn.addEventListener('mousedown', function (e) {
        if (!fogValues.active) return;
        e.preventDefault();
        applyStep(e.shiftKey, e.ctrlKey || e.metaKey);
        // Hold → auto-repeat
        var shiftHeld = e.shiftKey;
        var ctrlHeld  = e.ctrlKey || e.metaKey;
        holdTimer = setTimeout(function () {
          repeatTimer = setInterval(function () {
            applyStep(shiftHeld, ctrlHeld);
          }, 60);
        }, 350);
      });
      function stopHold() {
        if (holdTimer)   { clearTimeout(holdTimer);   holdTimer = null; }
        if (repeatTimer) { clearInterval(repeatTimer); repeatTimer = null; commitFog(); }
        else             { commitFog(); }
      }
      btn.addEventListener('mouseup',   stopHold);
      btn.addEventListener('mouseleave', stopHold);
      btn.addEventListener('blur',       stopHold);
    });
  }

  function onFogMove(e) {
    if (!fogDragging) return;
    var v = pxToVal(e.clientX);
    setFogValue(fogDragging, v); // vincolo start < end applicato qui
    repositionFogThumbs();
  }
  function onFogUp() {
    document.removeEventListener('mousemove', onFogMove);
    document.removeEventListener('mouseup',   onFogUp);
    if (fogDragging) {
      commitFog(); // commit alla fine del drag, non durante
      fogDragging = null;
    }
  }

  // === Layers section ========================================================
  // Filtro della lista = PER-SCENA (solo i layer che questa scena non
  // nasconde). Tutte le operazioni = SUL MODELLO, come il pannello Layers
  // nativo di SU: valgono per ogni scena e la scena le cattura solo con
  // "Update from view". I due assi sono indipendenti, quindi togliere la
  // spunta non fa sparire la riga dalla lista.
  //
  // Selezione multipla con le regole di sempre: click = una riga, Shift+click =
  // intervallo dall'ancora, Ctrl+click = aggiungi/togli. Tasto destro sulla
  // lista per Select all / Invert selection / Clear selection.
  //
  // La selezione vive SOLO qui nel JS: cambiarla non chiama Ruby e non
  // ridisegna la lista (paintLaySel tocca la sola classe .is-sel), quindi resta
  // istantanea anche sui modelli con AttributeObserver di plugin terzi.
  var laySel      = [];     // nomi dei layer selezionati
  var layAnchor   = null;   // ancora dello Shift+click
  var layRenaming = null;   // nome del layer in rename inline

  function layCall(op, name, value) {
    var data = { op: op };
    if (name  !== undefined && name  !== null) data.name  = name;
    if (value !== undefined) data.value = value;
    call('sm_props_layer_op', data);
  }

  // Operazioni che si propagano alla selezione (visibilita', colore, line
  // style, delete, colori casuali): Ruby riceve la lista intera e la esegue in
  // una sola start_operation, quindi un solo Ctrl+Z la annulla.
  function layCallMany(op, names, value) {
    var data = { op: op, names: names, name: names[0] || '' };
    if (value !== undefined) data.value = value;
    call('sm_props_layer_op', data);
  }

  function laySelected(n) { return laySel.indexOf(n) !== -1; }

  // Bersagli di un controllo di riga: tutta la selezione se la riga ne fa
  // parte, altrimenti la sola riga.
  function layTargets(name) {
    return (laySelected(name) && laySel.length > 1) ? laySel.slice() : [name];
  }

  // I nomi delle righe nell'ordine in cui sono a schermo: e' l'ordine su cui
  // ragionano Shift+click e "Invert selection".
  function layOrder() {
    var out = [];
    var list = $('#lay-list');
    if (!list) return out;
    list.querySelectorAll('.lay-row').forEach(function (r) { out.push(r.dataset.name); });
    return out;
  }

  function paintLaySel() {
    var list = $('#lay-list');
    if (list) {
      list.querySelectorAll('.lay-row').forEach(function (r) {
        r.classList.toggle('is-sel', laySelected(r.dataset.name));
      });
    }
    syncLayerToolbar();
  }

  function setLaySel(names) {
    laySel = names.slice();
    paintLaySel();
  }

  // Controlli interattivi di una riga: un click qui sopra NON deve collassare
  // una selezione multipla, altrimenti la propagazione non avrebbe mai piu' di
  // un bersaglio.
  var ROW_CONTROLS = ['lay-vis', 'lay-sw', 'lay-dash', 'lay-cur', 'lay-info', 'lay-mv'];
  function isRowControl(el) {
    if (!el || !el.classList) return false;
    for (var i = 0; i < ROW_CONTROLS.length; i++) {
      if (el.classList.contains(ROW_CONTROLS[i])) return true;
    }
    return false;
  }

  function renderLayers(state) {
    var fs   = $('#layers-fieldset');
    var list = $('#lay-list');
    var note = $('#lay-note');
    var cnt  = $('#lay-count');
    if (!fs || !list) return;

    var p = (state && state.scene && state.scene.layers) || null;
    if (!p) {
      list.innerHTML = '<div class="lay-empty">Layers unavailable.</div>';
      laySig = null;
      if (note) note.textContent = '';
      if (cnt)  cnt.textContent = '';
      return;
    }

    // Vedi il commento su flagSig: niente re-render se il payload dei layer e'
    // identico, altrimenti un refresh su focus mangia il click in corso. Il
    // layer appena creato (focus_layer) forza comunque il giro completo, perche'
    // deve entrare in rename inline.
    var sig = JSON.stringify(p);
    if (sig === laySig && !(state && state.focus_layer) && list.querySelector('.lay-row')) {
      return;
    }
    laySig = sig;

    // Se l'utente sta rinominando, non ridisegnare: il push_state arriva anche
    // per motivi scollegati (fog, focus della finestra) e cancellerebbe l'input
    // a meta' digitazione. Stesso principio del setIfNotFocused sugli altri campi.
    var editing = document.querySelector('.lay-name-input');
    if (editing && document.activeElement === editing) return;

    var rows = p.layers || [];

    // Il payload e' cambiato: la selezione puo' contenere layer cancellati, o
    // usciti dalla lista perche' la scena li nasconde. Ripulirla qui evita che
    // "-" e i colori casuali restino abilitati su nomi che non esistono piu'.
    var present = {};
    rows.forEach(function (r) { present[r.name] = true; });
    laySel = laySel.filter(function (n) { return present[n]; });
    if (layAnchor && !present[layAnchor]) layAnchor = null;

    var supportsDash = !!p.supports_line_style;
    fs.classList.toggle('no-dash', !supportsDash);

    var dashOpts = '<option value="">Default</option>';
    (p.line_styles || []).forEach(function (n) {
      dashOpts += '<option value="' + escapeHtml(n) + '">' + escapeHtml(n) + '</option>';
    });

    if (rows.length === 0) {
      list.innerHTML = '<div class="lay-empty">This scene shows no layers.</div>';
    } else {
      list.innerHTML = rows.map(function (r) {
        var n     = r.name || '';
        var sel   = laySelected(n) ? ' is-sel' : '';
        // Layer elencato dalla scena ma spento nel modello: nome in grigio
        // corsivo. E' il "drift" fra stato scena e stato modello.
        var dim   = (r.visible === false) ? ' is-hiddenmodel' : '';
        var curOn = r.current ? ' is-on' : '';
        var col   = r.color || '';
        var swCls = col ? 'lay-sw' : 'lay-sw is-empty';
        // Il valore hex viaggia in data-hex: style.background rileggerebbe
        // "rgb(r, g, b)", che SMColorPopup non accetta.
        var swSty = ' data-hex="' + escapeHtml(col) + '"' +
                    (col ? ' style="background:' + escapeHtml(col) + '"' : '');
        var nameTitle = r.is_default
          ? 'Default layer: cannot be renamed or deleted'
          : 'Double-click to rename';
        var dash = supportsDash
          ? '<select class="lay-dash" title="Line style (dashes)">' + dashOpts + '</select>'
          : '<span></span>';
        return '<div class="lay-row' + sel + dim + '" data-name="' + escapeHtml(n) + '">' +
               '<button type="button" class="lay-cur' + curOn + '" title="Set as current layer"></button>' +
               '<input type="checkbox" class="lay-vis"' + (r.visible ? ' checked' : '') +
                 ' title="Visible in the model, exactly like the native Layers window. The scene captures it only with Update from view. With several rows selected, the change applies to all of them.">' +
               '<span class="lay-name" title="' + escapeHtml(nameTitle) + '">' + escapeHtml(n) + '</span>' +
               '<button type="button" class="lay-info" title="Show what is on this layer: groups, components, faces, edges, guides&hellip;">i</button>' +
               '<button type="button" class="lay-mv" title="Move the current model selection to this layer (like Entity Info: selected groups and components move as a whole)">&rarr;</button>' +
               '<button type="button" class="' + swCls + '"' + swSty +
                 ' title="Layer color. With several rows selected, the color applies to all of them."></button>' +
               dash +
               '</div>';
      }).join('');

      // I <select> non accettano il valore selezionato via attributo quando le
      // option sono generate a stringa: lo settiamo dopo l'inserimento nel DOM.
      var els = list.querySelectorAll('.lay-row');
      for (var i = 0; i < els.length; i++) {
        var sd = els[i].querySelector('.lay-dash');
        if (sd) sd.value = rows[i].line_style || '';
      }
    }

    bindLayerRows(rows);

    // "Color by layer" e' una rendering option del modello: il bottone e' un
    // toggle stateful, non un comando. Se la build non espone la chiave lo
    // nascondiamo del tutto invece di lasciare un bottone che non fa nulla.
    var cbl = $('#btn-lay-cbl');
    if (cbl) {
      var supported = p.supports_color_by_layer !== false;
      cbl.style.display = supported ? '' : 'none';
      cbl.classList.toggle('is-on', !!p.color_by_layer);
    }

    if (cnt) {
      cnt.textContent = rows.length + ' of ' + (p.total_count || rows.length) + ' layers';
    }
    if (note) {
      var msgs = [];
      if (p.scene_tracks === false) {
        msgs.push('This scene does not save layer visibility (Visible Layers is off), so every layer in the model is listed.');
      } else if (p.hidden_count > 0) {
        var names = (p.hidden_names || []).join(', ');
        msgs.push(p.hidden_count + ' layer(s) hidden by this scene are not listed: ' + names +
                  '. Turn them back on from the native Layers window, then Update from view.');
      }
      note.textContent = msgs.join(' ');
    }
  }

  function bindLayerRows(rows) {
    var list = $('#lay-list');
    if (!list) return;

    list.querySelectorAll('.lay-row').forEach(function (row) {
      var name = row.dataset.name;

      row.addEventListener('mousedown', function (e) {
        if (e.target.classList.contains('lay-name-input')) return;

        // Tasto destro: seleziona la riga solo se non fa gia' parte della
        // selezione. Altrimenti il menu contestuale lavorerebbe su una
        // selezione appena distrutta dal click che lo ha aperto.
        if (e.button === 2) {
          if (!laySelected(name)) { setLaySel([name]); layAnchor = name; }
          return;
        }

        if (e.shiftKey && layAnchor) {
          // preventDefault solo fuori dai controlli: su una checkbox
          // impedirebbe anche il toggle.
          if (!isRowControl(e.target)) e.preventDefault(); // niente selezione di testo
          var order = layOrder();
          var a = order.indexOf(layAnchor);
          var b = order.indexOf(name);
          if (a === -1) a = b;
          setLaySel(order.slice(Math.min(a, b), Math.max(a, b) + 1));
          return;
        }

        if (e.ctrlKey || e.metaKey) {
          var i = laySel.indexOf(name);
          if (i === -1) laySel.push(name); else laySel.splice(i, 1);
          layAnchor = name;
          paintLaySel();
          return;
        }

        layAnchor = name;
        // Click su un controllo di una riga gia' selezionata: la selezione
        // resta com'e' ed e' lei il bersaglio della propagazione.
        if (isRowControl(e.target) && laySelected(name)) return;
        setLaySel([name]);
      });

      var cur = row.querySelector('.lay-cur');
      if (cur) {
        cur.addEventListener('click', function (e) {
          e.stopPropagation();
          layCall('current', name);
        });
      }

      var vis = row.querySelector('.lay-vis');
      if (vis) {
        vis.addEventListener('change', function () {
          layCallMany('visible', layTargets(name), vis.checked);
        });
      }

      var info = row.querySelector('.lay-info');
      if (info) {
        info.addEventListener('click', function (e) {
          e.stopPropagation();
          layCall('info', name);
        });
      }

      // La selezione vive nel viewport, non nel dialog: nessun payload da
      // costruire qui, Ruby legge model.selection al volo.
      var mv = row.querySelector('.lay-mv');
      if (mv) {
        mv.addEventListener('click', function (e) {
          e.stopPropagation();
          layCall('assign_selection', name);
        });
      }

      var sw = row.querySelector('.lay-sw');
      if (sw) {
        sw.addEventListener('click', function (e) {
          e.stopPropagation();
          if (!window.SMColorPopup) return;
          var curHex = sw.dataset.hex || '';
          // commitOnEnd: il colore del layer si vede nel viewport solo con
          // "Color by layer" attivo, quindi non serve il live update e
          // risparmiamo una write a SU per ogni movimento del cursore.
          window.SMColorPopup.show(sw, curHex, function (hex) {
            if (!hex) return;
            layCallMany('color', layTargets(name), hex);
          }, { commitOnEnd: true });
        });
      }

      var dash = row.querySelector('.lay-dash');
      if (dash) {
        dash.addEventListener('change', function () {
          layCallMany('line_style', layTargets(name), dash.value);
        });
        dash.addEventListener('mousedown', function (e) { e.stopPropagation(); });
      }

      var nameEl = row.querySelector('.lay-name');
      if (nameEl) {
        var isDefault = false;
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].name === name) { isDefault = !!rows[i].is_default; break; }
        }
        if (!isDefault) {
          nameEl.addEventListener('dblclick', function (e) {
            e.stopPropagation();
            startLayerRename(row, name);
          });
        }
      }
    });

    syncLayerToolbar();

    // Il layer appena creato dal "+" entra subito in rename inline, come fa
    // il pannello nativo.
    var focus = SMP.state && SMP.state.focus_layer;
    if (focus) {
      SMP.state.focus_layer = null;
      // Scan invece di querySelector: dataset.name e' gia' de-escapato dal
      // browser, quindi funziona anche con nomi che contengono virgolette.
      var all = list.querySelectorAll('.lay-row');
      for (var j = 0; j < all.length; j++) {
        if (all[j].dataset.name === focus) {
          layAnchor = focus;
          setLaySel([focus]);
          startLayerRename(all[j], focus);
          break;
        }
      }
    }
  }

  function startLayerRename(row, name) {
    var nameEl = row.querySelector('.lay-name');
    if (!nameEl) return;
    layRenaming = name;
    var input = document.createElement('input');
    input.type = 'text';
    input.className = 'lay-name-input';
    input.value = name;
    input.spellcheck = false;
    nameEl.replaceWith(input);
    input.focus();
    input.select();

    var done = false;
    function finish(commit) {
      if (done) return;
      done = true;
      layRenaming = null;
      var v = input.value;
      // Blur esplicito PRIMA di chiamare Ruby: il push_state di risposta
      // arriva async e renderLayers salta il re-render se l'input di rename
      // ha ancora il focus (sul path Enter non lo perderebbe mai da solo).
      try { input.blur(); } catch (e) {}
      if (commit && v.trim() && v !== name) {
        // La selezione segue il nuovo nome, altrimenti dopo il re-render
        // nessuna riga combacia e i bottoni di gruppo tornerebbero disabilitati.
        var si = laySel.indexOf(name);
        if (si !== -1) laySel[si] = v.trim();
        if (layAnchor === name) layAnchor = v.trim();
        layCall('rename', name, v.trim());
      } else {
        // Nessuna modifica: ripristiniamo la riga senza disturbare Ruby.
        call('sm_props_ready');
      }
    }
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter')       { e.preventDefault(); finish(true); }
      else if (e.key === 'Escape') { e.preventDefault(); finish(false); }
    });
    input.addEventListener('blur', function () { finish(true); });
  }

  // I bottoni che lavorano sulla selezione sono disabilitati finche' non c'e'
  // una selezione: e' l'unico modo per dire che "-" e i colori casuali non
  // agiscono sull'intera lista.
  function syncLayerToolbar() {
    var n   = laySel.length;
    var del = $('#btn-lay-del');
    var rnd = $('#btn-lay-rand');
    if (del) {
      del.disabled = !n;
      del.title = n > 1 ? ('Delete the ' + n + ' selected layers')
                        : 'Delete the selected layer';
    }
    if (rnd) rnd.disabled = !n;
  }

  function bindLayers() {
    var add = $('#btn-lay-add');
    if (add) {
      add.addEventListener('click', function () { layCall('add'); });
    }
    // Layer visibile solo nella scena di questo dialog. Ruby lo aggancia a
    // @scene_id, non alla scena attiva: nessun id da passare da qui.
    var addHere = $('#btn-lay-add-here');
    if (addHere) {
      addHere.addEventListener('click', function () { layCall('add_scene_only'); });
    }
    var del = $('#btn-lay-del');
    if (del) {
      del.addEventListener('click', function () {
        if (!laySel.length) { setStatus('Select a layer first'); return; }
        var targets = laySel.slice();
        setLaySel([]);
        layCallMany('delete', targets);
      });
    }
    // Colore casuale diverso per ogni layer selezionato. Le tinte le sceglie
    // Ruby (distribuite sul cerchio cromatico, una sola operazione).
    var rnd = $('#btn-lay-rand');
    if (rnd) {
      rnd.addEventListener('click', function () {
        if (!laySel.length) { setStatus('Select one or more layers first'); return; }
        layCallMany('random_colors', laySel.slice());
      });
    }
    var purge = $('#btn-lay-purge');
    if (purge) {
      purge.addEventListener('click', function () { layCall('purge'); });
    }
    var cbl = $('#btn-lay-cbl');
    if (cbl) {
      cbl.addEventListener('click', function () {
        var on = cbl.classList.contains('is-on');
        // Feedback immediato: lo state vero riarriva col push_state.
        cbl.classList.toggle('is-on', !on);
        layCall('color_by_layer', null, !on);
      });
    }

    // Tasto destro sulla lista: comandi di selezione. Il menu e' agganciato al
    // contenitore, non alle righe, cosi' sopravvive ai re-render e funziona
    // anche sullo spazio vuoto sotto l'ultima riga.
    var list = $('#lay-list');
    if (list) {
      list.addEventListener('contextmenu', function (e) {
        e.preventDefault();
        var order = layOrder();
        if (!order.length) return;
        var inv = order.filter(function (n) { return !laySelected(n); });
        showCtxMenu(e.clientX, e.clientY, 'Selection', [
          { label: 'Select all (' + order.length + ')',
            onPick: function () { layAnchor = order[0]; setLaySel(order); } },
          { label: 'Invert selection (' + inv.length + ')',
            onPick: function () { layAnchor = inv.length ? inv[0] : null; setLaySel(inv); } },
          { label: 'Clear selection',
            onPick: function () { layAnchor = null; setLaySel([]); } }
        ]);
      });
    }

    syncLayerToolbar();
  }

  function renderPreview(url) {
    const box = $('#preview-box');
    if (!url) {
      box.innerHTML = '<div class="preview-empty">No preview generated.<br>Use the 🎬 Preview button in the main toolbar.</div>';
      return;
    }
    // Cache-buster sull'URL: lo stesso file PNG può essere riscritto, CEF
    // potrebbe servire la versione cached. ?t=<ts> forza il reload.
    const bust = (url.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now();
    box.innerHTML = '<img src="' + url + bust + '" alt="Scene preview">';
  }

  document.addEventListener('DOMContentLoaded', () => {
    // Commit su blur / change per i campi testuali
    $('#prop-name').addEventListener('change', commit);
    $('#prop-name').addEventListener('blur', commit);
    $('#prop-desc').addEventListener('change', commit);
    $('#prop-desc').addEventListener('blur', commit);

    // Enter sul nome → commit + blur
    $('#prop-name').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); e.target.blur(); }
    });
    // Ctrl+Enter sulla descrizione → commit + blur
    $('#prop-desc').addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
        e.preventDefault(); e.target.blur();
      }
    });

    $('#btn-update-view').addEventListener('click', () => {
      const id = SMP.state && SMP.state.scene && SMP.state.scene.id;
      if (!id) return;
      call('sm_props_update_from_view', { id: id });
      setStatus('Captured viewport');
    });

    // Refresh state quando la finestra Properties riprende focus: copre il caso
    // "utente apre l'inspector nativo (es. via 'Style and Fog ↗'), toggla un
    // flag lì, torna su Properties di SM+" — senza questo refresh il checkbox
    // mostrerebbe lo state vecchio. Debounce 500ms per evitare doppioni
    // focus+visibilitychange.
    var lastPropsRefresh = 0;
    function debouncedPropsRefresh() {
      var now = Date.now();
      if (now - lastPropsRefresh < 500) return;
      lastPropsRefresh = now;
      call('sm_props_ready');
    }
    window.addEventListener('focus', debouncedPropsRefresh);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) debouncedPropsRefresh();
    });

    // Right-click → menu di scelta singola property da aggiornare. Solo le
    // property attualmente checkate in "Properties to save" sono offerte:
    // coerente con l'intento "salva ciò che la scena dichiara di tracciare".
    $('#btn-update-view').addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const id = SMP.state && SMP.state.scene && SMP.state.scene.id;
      if (!id) return;
      const flags = SMP.state.scene.flags || {};
      const items = FLAG_UI.filter(item => item.keys.every(k => flags[k]));
      if (items.length === 0) {
        setStatus('No properties enabled');
        return;
      }
      showPartialMenu(e.clientX, e.clientY, items, (keys) => {
        call('sm_props_update_from_view', { id: id, flags: keys });
        setStatus('Captured ' + keys.length + ' property');
      });
    });

    bindFog();
    bindLayers();

    // Bottone "Open native Scenes panel" nell'header — riusa il callback
    // sm_props_open_scenes_panel già esistente (attiva la scena nel viewport
    // se non è attiva, poi UI.show_inspector('Scenes')).
    var btnOpenScenes = $('#btn-open-scenes-native');
    if (btnOpenScenes) {
      btnOpenScenes.addEventListener('click', function () {
        var id = SMP.state && SMP.state.scene ? SMP.state.scene.id : null;
        call('sm_props_open_scenes_panel', { id: id });
      });
    }

    call('sm_props_ready');
  });

  function showPartialMenu(x, y, items, onPick) {
    showCtxMenu(x, y, 'Update only…', items.map(function (item) {
      return { label: item.label, onPick: function () { onPick(item.keys); } };
    }));
  }

  // Menu contestuale generico: `entries` = [{ label, onPick }]. Ne vive uno
  // solo alla volta (#smp-ctx-menu), quindi aprirne uno chiude il precedente.
  function showCtxMenu(x, y, headerText, entries) {
    hidePartialMenu();
    const menu = document.createElement('div');
    menu.className = 'context-menu';
    menu.id = 'smp-ctx-menu';
    if (headerText) {
      const header = document.createElement('div');
      header.className = 'ctx-header';
      header.textContent = headerText;
      menu.appendChild(header);
    }
    entries.forEach(entry => {
      const row = document.createElement('div');
      row.className = 'ctx-item';
      row.textContent = entry.label;
      row.addEventListener('click', () => {
        hidePartialMenu();
        entry.onPick();
      });
      menu.appendChild(row);
    });
    document.body.appendChild(menu);
    const mw = menu.offsetWidth, mh = menu.offsetHeight;
    const vw = window.innerWidth, vh = window.innerHeight;
    if (x + mw > vw) x = Math.max(0, vw - mw - 2);
    if (y + mh > vh) y = Math.max(0, vh - mh - 2);
    menu.style.left = x + 'px';
    menu.style.top  = y + 'px';
    setTimeout(() => {
      document.addEventListener('mousedown', onDocMouseDownClose, true);
      window.addEventListener('blur', hidePartialMenu);
    }, 0);
  }
  function hidePartialMenu() {
    const m = document.getElementById('smp-ctx-menu');
    if (m && m.parentNode) m.parentNode.removeChild(m);
    document.removeEventListener('mousedown', onDocMouseDownClose, true);
    window.removeEventListener('blur', hidePartialMenu);
  }
  function onDocMouseDownClose(e) {
    const m = document.getElementById('smp-ctx-menu');
    if (m && !m.contains(e.target)) hidePartialMenu();
  }
})();
