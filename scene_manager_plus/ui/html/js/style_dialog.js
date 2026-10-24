// Mini Style Manager
window.SMS = (function () {
  var state = { style_name: null, scene_id: null, scenes_count: 0, values: {} };
  var listenersBound = false;

  function $(id) { return document.getElementById(id); }

  function call(name, data) {
    var payload = (data === undefined) ? '' : JSON.stringify(data);
    if (window.sketchup && typeof window.sketchup[name] === 'function') {
      try { window.sketchup[name](payload); }
      catch (e) { console.warn('SMS bridge failed: ' + name, e); }
    }
  }

  function logRuby(msg) { call('sm_style_log', String(msg)); }

  function normalizeHex(s) {
    if (!s) return null;
    s = String(s).trim().toLowerCase();
    if (s[0] !== '#') s = '#' + s;
    return /^#[0-9a-f]{6}$/.test(s) ? s : null;
  }

  // Selettore colore condiviso (js/color_popup.js, window.SMColorPopup).
  var ColorPopup = window.SMColorPopup;

  // ═════════════════════════════════════════════════════════════════════
  // Style dialog principale
  // ═════════════════════════════════════════════════════════════════════
  // Selettore stile dell'header. Le lettere sono le stesse della finestra
  // principale (stessa fonte lato Ruby), cosi' A resta A ovunque.
  // Le voci si ricostruiscono solo se l'elenco e' cambiato (ricostruirle a
  // tendina aperta la chiuderebbe di colpo); la voce scelta invece si
  // riallinea sempre. Prima c'era un "se ha il focus non toccare": ma dopo
  // una scelta il select tiene il focus anche quando si clicca nella
  // finestra principale (in CEF il blur non arriva), e da li' il selettore
  // restava fermo sullo stile della scena precedente a ogni cambio scena.
  var pickerKey = null;
  function renderStylePicker(styles, current) {
    var sel = $('style-pick');
    if (!sel) return;
    var found = styles.some(function (s) { return s.name === current; });
    // Stile non elencato (scene Match Photo con stile interno, o nessuno
    // stile): voce segnaposto, altrimenti il select mostrerebbe il primo
    // della lista facendo credere che sia quello in uso.
    var placeholder = found ? null : (current || '(no style)');
    var key = JSON.stringify([styles.map(function (s) { return [s.letter, s.name]; }), placeholder]);
    if (key !== pickerKey) {
      pickerKey = key;
      sel.innerHTML = '';
      if (placeholder !== null) {
        var ph = document.createElement('option');
        ph.value = '';
        ph.textContent = placeholder;
        sel.appendChild(ph);
      }
      styles.forEach(function (s) {
        var o = document.createElement('option');
        o.value = s.name;
        o.textContent = (s.letter ? s.letter + '   ' : '') + s.name;
        sel.appendChild(o);
      });
    }
    sel.value = found ? current : '';
  }

  // La finestra segue la scena attiva, quindi lo stile puo' cambiare sotto un
  // campo Name/Description con una modifica non ancora salvata (cursore
  // dentro, finestra disattivata da un clic sulla lista: in CEF il blur non
  // arriva). La modifica va allo stile per cui era stata scritta, mandata
  // esplicitamente col suo nome, prima che lo state cambi.
  function flushHeaderEdits(prev) {
    var oldName = prev.style_name || '';
    if (!oldName) return;
    var n = $('style-nickname');
    if (n && document.activeElement === n) {
      var v = n.value.trim();
      if (v && v !== oldName) call('sm_style_set_name', { name: v, style: oldName });
    }
    var d = $('style-description');
    if (d && document.activeElement === d && d.value !== (prev.description || '')) {
      call('sm_style_set_description', { description: d.value, style: oldName });
    }
  }

  function setState(newState) {
    var prev = state;
    var switching = !!(newState && prev && prev.style_name != null &&
                       newState.style_name !== prev.style_name);
    if (switching) {
      flushHeaderEdits(prev);
      // Selettore colore aperto sullo stile di prima: si chiude senza
      // confermare, e i ritocchi in coda non partono (andrebbero sul nuovo).
      if (ColorPopup && ColorPopup.isOpen()) ColorPopup.cancel();
      dropLive();
    }
    state = newState || state;
    if (!state.values) state.values = {};
    if (!state.scenes_list) state.scenes_list = [];
    if (switching) {
      // Campi riallineati allo stile nuovo PRIMA del blur: cosi' il
      // commit-on-blur li trova invariati e non manda niente.
      var nEl = $('style-nickname');
      if (nEl) { nEl.value = state.style_name || ''; nEl.blur(); }
      var dEl = $('style-description');
      if (dEl) { dEl.value = state.description || ''; dEl.blur(); }
    }
    renderStylePicker(state.styles || [], state.style_name || '');
    // Name input: NON sovrascrivere se l'utente sta editando.
    var nickEl = $('style-nickname');
    if (nickEl && document.activeElement !== nickEl) {
      nickEl.value = state.style_name || '';
    }
    var descEl = $('style-description');
    if (descEl && document.activeElement !== descEl) {
      descEl.value = state.description || '';
    }
    setBadgeColor(state.badge_color || '');
    $('scope-note').textContent =
      'Applies to all scenes using this style (' + (state.scenes_count || 0) + '). ' +
      'To affect only one scene, create a new style from the badge picker and assign it.';
    $('footer-text').textContent = state.scenes_count + ' scene(s) use this style';
    populate(state.values);
    populateMatchPhoto(state.match_photo, state.is_matchphoto);
  }

  // Match Photo: i valori NON arrivano dalle rendering options (l'API Ruby
  // non li espone) ma dai controlli del pannello Styles nativo, letti via
  // Win32. state.match_photo == null significa pannello non raggiungibile:
  // in quel caso disabilitiamo tutto invece di mostrare valori finti.
  function populateMatchPhoto(mp, isMatchPhoto) {
    // Fuori dalle scene Match Photo la sezione sparisce del tutto: i
    // controlli nativi esistono comunque, ma non farebbero niente.
    var sec = $('group-matchphoto');
    if (sec) sec.classList.toggle('hidden', !isMatchPhoto);
    if (!isMatchPhoto) return;
    var avail = !!mp;
    var note = $('mp-unavailable');
    if (note) note.classList.toggle('hidden', avail);
    // Ruby prima di leggere fa rinfrescare il pannello (vedi
    // Core::NativePanel.refresh_styles_panel!); se non ci e' riuscito i
    // valori letti possono essere vecchi e lo diciamo.
    var stale = $('mp-stale');
    if (stale) stale.classList.toggle('hidden', !(avail && mp.refreshed === false));
    ['foreground', 'background'].forEach(function (which) {
      var cb = $('ctrl-mp-' + which + '-on');
      var sl = $('slider-mp-' + which);
      var nu = $('ctrl-mp-' + which);
      if (!cb || !sl || !nu) return;
      var d = avail ? mp[which] : null;
      if (!d) {
        cb.disabled = true; sl.disabled = true; nu.disabled = true;
        cb.checked = false; nu.value = '';
        return;
      }
      cb.disabled = false;
      if (document.activeElement !== cb) cb.checked = !!d.on;
      // Rispecchiamo lo stato reale del controllo nativo: nel pannello SU
      // lo slider resta attivo anche a photo spenta.
      var en = d.enabled !== false;
      sl.disabled = !en; nu.disabled = !en;
      sl.min = String(d.min); sl.max = String(d.max);
      nu.min = String(d.min); nu.max = String(d.max);
      if (document.activeElement !== sl) sl.value = String(d.opacity);
      if (document.activeElement !== nu) nu.value = String(d.opacity);
    });
  }

  // Durante il drag mando a Ruby al massimo ogni MP_THROTTLE_MS: ogni invio
  // e' un messaggio Win32 al pannello nativo piu' un redraw del viewport,
  // quindi live si', ma non a raffica.
  var MP_THROTTLE_MS = 60;
  var mpTimer = null, mpPending = null;

  function scheduleMpApply(which, value) {
    mpPending = { which: which, value: parseInt(value, 10) };
    if (mpTimer) return;
    mpTimer = setTimeout(function () {
      mpTimer = null;
      if (mpPending) { call('sm_style_mp_opacity', mpPending); mpPending = null; }
    }, MP_THROTTLE_MS);
  }

  function cancelMpApply() {
    if (mpTimer) { clearTimeout(mpTimer); mpTimer = null; }
    mpPending = null;
  }

  function bindMatchPhoto() {
    ['foreground', 'background'].forEach(function (which) {
      var cb = $('ctrl-mp-' + which + '-on');
      var sl = $('slider-mp-' + which);
      var nu = $('ctrl-mp-' + which);

      if (cb) {
        cb.addEventListener('change', function () {
          call('sm_style_mp_enable', { which: which, on: !!cb.checked });
        });
      }

      if (sl) {
        sl.addEventListener('input', function () {
          if (nu) nu.value = sl.value;
          scheduleMpApply(which, sl.value);
        });
        // `final: true` = valore definitivo: Ruby committa lo stile solo qui,
        // non a ogni tick del drag (che passa da scheduleMpApply).
        sl.addEventListener('change', function () {
          cancelMpApply();
          call('sm_style_mp_opacity', { which: which, value: parseInt(sl.value, 10), final: true });
        });
      }

      if (nu) {
        var commitNum = function () {
          var n = parseInt(nu.value, 10);
          if (isNaN(n)) { nu.value = sl ? sl.value : ''; return; }
          if (n < 0) n = 0;
          if (n > 100) n = 100;
          nu.value = String(n);
          if (sl) sl.value = String(n);
          cancelMpApply();
          call('sm_style_mp_opacity', { which: which, value: n, final: true });
        };
        nu.addEventListener('change', commitNum);
        nu.addEventListener('blur', commitNum);
        nu.addEventListener('keydown', function (e) {
          if (e.key === 'Enter') { e.preventDefault(); nu.blur(); }
        });
      }
    });
  }

  function showScenesOverlay() {
    var overlay = $('scenes-overlay');
    var list    = $('scenes-overlay-list');
    if (!overlay || !list) return;
    list.innerHTML = '';
    var names = state.scenes_list || [];
    if (names.length === 0) {
      var empty = document.createElement('li');
      empty.textContent = '(no scenes)';
      empty.style.color = '#666';
      list.appendChild(empty);
    } else {
      names.forEach(function (name) {
        var li = document.createElement('li');
        li.textContent = name;
        list.appendChild(li);
      });
    }
    overlay.classList.remove('hidden');
  }

  function hideScenesOverlay() {
    var overlay = $('scenes-overlay');
    if (overlay) overlay.classList.add('hidden');
  }

  // Aggiorna swatch + input del Badge color senza scatenare commit.
  function setBadgeColor(hex) {
    var sw = $('sw-BadgeColor');
    var el = $('ctrl-BadgeColor');
    if (!sw || !el) return;
    var h = normalizeHex(hex);
    if (document.activeElement !== el) el.value = h || '';
    if (h) {
      sw.style.background = h;
      sw.classList.remove('swatch-empty');
    } else {
      sw.style.background = '';
      sw.classList.add('swatch-empty');
    }
  }

  function commitBadgeColor(hex) {
    var s = (hex == null ? '' : String(hex)).trim();
    var prev = state.badge_color || '';
    if (s !== '' && !normalizeHex(s)) return; // invalid → no-op
    if ((normalizeHex(s) || '') === prev) return;
    call('sm_style_set_color', { color: s });
  }

  // Commit del nome dello stile: rinomina lo stile NATIVO in SketchUp.
  // Ruby rifiuta vuoto e duplicati e ri-pusha lo stato, quindi qui non
  // serve validare: basta non inviare se nulla e' cambiato.
  function commitStyleName() {
    var el = $('style-nickname');
    if (!el) return;
    var v = el.value.trim();
    var cur = state.style_name || '';
    if (v === cur) return;
    call('sm_style_set_name', { name: v, style: cur });
  }

  function commitDescription() {
    var el = $('style-description');
    if (!el) return;
    var v = el.value;
    if (v === (state.description || '')) return;
    call('sm_style_set_description', { description: v, style: state.style_name || '' });
  }

  // Imposta i controlli senza scatenare il change-handler che ri-invierebbe
  // l'edit a Ruby.
  function populate(vals) {
    setIntSelect('EdgeColorMode', vals.EdgeColorMode);
    setIntSelect('TransparencySort', vals.TransparencySort);
    setHex('BackgroundColor', vals.BackgroundColor);
    setHex('SkyColor', vals.SkyColor);
    setHex('HorizonColor', vals.HorizonColor);
    setBool('DrawHorizon', vals.DrawHorizon);
    setBool('ModelTransparency', vals.ModelTransparency);
    setBool('DrawHidden', vals.DrawHidden);
    setBool('DisplaySectionPlanes', vals.DisplaySectionPlanes);
    setBool('DisplaySectionCuts', vals.DisplaySectionCuts);
    setBool('DrawSilhouettes', vals.DrawSilhouettes);
    setBool('DisplaySketchAxes', vals.DisplaySketchAxes);
    setNum('ProfileWidth', vals.ProfileWidth);
    // Feedback visivo bottone "→ 1": evidenziato quando Profiles è ON e
    // ProfileWidth = 1 (= stato target che il bottone applicherebbe).
    var bpd = $('btn-profiles-default');
    if (bpd) {
      var alreadyAtTarget = (vals.DrawSilhouettes === true) &&
                            (Number(vals.ProfileWidth) === 1);
      bpd.classList.toggle('is-active', alreadyAtTarget);
      bpd.title = alreadyAtTarget
        ? 'Already at target (Profiles ON, width = 1)'
        : 'Turn Profiles ON and set width = 1';
    }
    if (!listenersBound) bindListeners();
  }

  function setNum(key, val) {
    var el = $('ctrl-' + key);
    var sl = $('slider-' + key);
    if (!el) return;
    if (val == null) {
      el.disabled = true; el.value = '';
      if (sl) { sl.disabled = true; sl.value = '0'; }
      return;
    }
    el.disabled = false;
    if (document.activeElement !== el) el.value = String(val);
    if (sl) {
      sl.disabled = false;
      if (document.activeElement !== sl) {
        // Slider è step intero; clampato al suo range. Non sovrascrivere
        // se l'utente sta draggando proprio quello slider.
        sl.value = String(Math.round(Number(val)));
      }
    }
  }

  function setIntSelect(key, val) {
    var el = $('ctrl-' + key);
    if (!el) return;
    var v = (val == null) ? '0' : String(val);
    if (el.value !== v) el.value = v;
  }
  function setBool(key, val) {
    var el = $('ctrl-' + key);
    if (!el) return;
    if (val == null) { el.disabled = true; el.checked = false; return; }
    el.disabled = false;
    el.checked = !!val;
  }
  function setHex(key, val) {
    var el = $('ctrl-' + key);
    var sw = $('sw-' + key);
    if (!el || !sw) return;
    var hex = normalizeHex(val) || '';
    if (document.activeElement !== el) el.value = hex;
    sw.style.background = hex || '#000000';
  }

  function sendChanges(changes) {
    call('sm_style_apply', { changes: changes });
  }

  // Colori dal selettore, dal vivo: cursori, ruota e pipetta che scorre lo
  // schermo mandano decine di ritocchi al secondo, e ognuno e' una modifica
  // dello stile in SketchUp (con la sua voce nell'Undo). Ne parte al massimo
  // uno ogni LIVE_MS, e l'ultimo sempre.
  var LIVE_MS = 100;
  var liveTimer = null, liveQueue = null;
  function sendLive(changes) {
    liveQueue = liveQueue || {};
    for (var k in changes) liveQueue[k] = changes[k];
    if (!liveTimer) liveTick();
  }
  function liveTick() {
    liveTimer = null;
    if (!liveQueue) return;
    var c = liveQueue;
    liveQueue = null;
    sendChanges(c);
    liveTimer = setTimeout(liveTick, LIVE_MS);
  }
  // Cambio di stile sotto la finestra: i ritocchi in coda erano per lo stile
  // di prima, e Ruby li scriverebbe su quello nuovo.
  function dropLive() {
    if (liveTimer) { clearTimeout(liveTimer); liveTimer = null; }
    liveQueue = null;
  }
  var COLOR_TITLES = { BackgroundColor: 'Background color', SkyColor: 'Sky color', HorizonColor: 'Horizon color' };

  function bindListeners() {
    // Select int
    ['EdgeColorMode', 'TransparencySort'].forEach(function (k) {
      var el = $('ctrl-' + k);
      if (!el) return;
      el.addEventListener('change', function () {
        var c = {}; c[k] = parseInt(el.value, 10); sendChanges(c);
      });
    });
    // Checkbox bool (Model axes = DisplaySketchAxes, RO stateful — niente più
    // toggle send_action: vedi style_dialog.rb)
    ['DrawHorizon', 'ModelTransparency', 'DrawHidden', 'DisplaySectionPlanes', 'DisplaySectionCuts', 'DrawSilhouettes', 'DisplaySketchAxes'].forEach(function (k) {
      var el = $('ctrl-' + k);
      if (!el) return;
      el.addEventListener('change', function () {
        var c = {}; c[k] = !!el.checked; sendChanges(c);
      });
    });
    // Input numerici (Profile width). Commit su change/blur, non su input:
    // evita un write per ogni keystroke/spinner-tick.
    ['ProfileWidth'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sl = $('slider-' + k);
      if (!el) return;
      function commit() {
        var raw = el.value;
        if (raw === '' || raw == null) {
          // ripristina valore corrente: non vogliamo scrivere NaN
          var cur = state.values && state.values[k];
          el.value = (cur == null ? '' : String(cur));
          if (sl && cur != null) sl.value = String(Math.round(Number(cur)));
          return;
        }
        var n = parseFloat(raw);
        if (isNaN(n)) {
          var cur2 = state.values && state.values[k];
          el.value = (cur2 == null ? '' : String(cur2));
          if (sl && cur2 != null) sl.value = String(Math.round(Number(cur2)));
          return;
        }
        if (sl) sl.value = String(Math.round(n));
        var c = {}; c[k] = n; sendChanges(c);
      }
      el.addEventListener('change', commit);
      el.addEventListener('blur', commit);
      el.addEventListener('input', function () {
        // Live-sync visivo dello slider mentre l'utente digita nel numero.
        // Niente commit a Ruby qui.
        var n = parseFloat(el.value);
        if (!isNaN(n) && sl) sl.value = String(Math.round(n));
      });
      el.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); el.blur(); }
        else if (e.key === 'Escape') {
          var cur = state.values && state.values[k];
          el.value = (cur == null ? '' : String(cur));
          if (sl && cur != null) sl.value = String(Math.round(Number(cur)));
          el.blur();
        }
      });

      // Slider (solo per fog): durante drag aggiorna soltanto il numero
      // accanto. Commit a Ruby solo al rilascio del mouse (event 'change'),
      // per non spammare write_attribute su modelli con observer terzo.
      if (sl) {
        sl.addEventListener('input', function () {
          // Live: sincronizza il numero accanto, nessun commit Ruby.
          el.value = sl.value;
        });
        sl.addEventListener('change', function () {
          var n = parseFloat(sl.value);
          if (isNaN(n)) return;
          el.value = String(n);
          var c = {}; c[k] = n; sendChanges(c);
        });
      }
    });
    // Bottone "Open native Styles panel" nell'header
    var btnNative = $('btn-open-native');
    if (btnNative) {
      btnNative.addEventListener('click', function () { call('sm_style_open_native'); });
    }
    // Selettore stile: assegna alla scena di contesto e ci passa in edit.
    var pickEl = $('style-pick');
    if (pickEl) {
      pickEl.addEventListener('change', function () {
        var v = pickEl.value;
        // Via il focus: con il select ancora attivo, una freccia premuta
        // pensando di cambiare scena assegnerebbe lo stile successivo.
        pickEl.blur();
        if (!v || v === (state.style_name || '')) return;
        call('sm_style_pick', { name: v });
      });
    }
    // Purge: Ruby fa elenco + conferma + report.
    var btnPurge = $('btn-purge-styles');
    if (btnPurge) {
      btnPurge.addEventListener('click', function () { call('sm_style_purge'); });
    }
    // Bottone "Profiles → 1": atomico DrawSilhouettes=true + ProfileWidth=1
    var btnProfilesDefault = $('btn-profiles-default');
    if (btnProfilesDefault) {
      btnProfilesDefault.addEventListener('click', function () {
        call('sm_style_set_profiles_default');
      });
    }
    // Hex color: text input + swatch clickabile che apre il popup HSV custom.
    // (Niente più <input type="color">, broken in CEF SU 2019.)
    ['BackgroundColor', 'SkyColor', 'HorizonColor'].forEach(function (k) {
      var el = $('ctrl-' + k);
      var sw = $('sw-' + k);
      if (!el || !sw) return;

      // Swatch clickabile → apre popup picker
      sw.addEventListener('click', function () {
        var current = normalizeHex(state.values && state.values[k]) || '#ffffff';
        // Dal vivo: a ogni ritocco il viewport mostra il colore.
        ColorPopup.show(sw, current, function (hex) {
          el.value = hex;
          sw.style.background = hex;
          var c = {}; c[k] = hex; sendLive(c);
        }, { title: COLOR_TITLES[k] });
      });

      // Text input: anteprima live durante typing, commit su change/blur.
      el.addEventListener('input', function () {
        var hex = normalizeHex(el.value);
        if (hex) sw.style.background = hex;
      });
      el.addEventListener('change', commitHex);
      el.addEventListener('blur', commitHex);
      function commitHex() {
        var hex = normalizeHex(el.value);
        if (!hex) {
          var prev = normalizeHex(state.values && state.values[k]) || '';
          el.value = prev;
          sw.style.background = prev || '#000000';
          return;
        }
        el.value = hex;
        sw.style.background = hex;
        var c = {}; c[k] = hex; sendChanges(c);
      }
    });
    // Footer cliccabile → overlay HTML interno (no messagebox, no suono)
    var footerEl = $('footer-text');
    if (footerEl) {
      footerEl.addEventListener('click', function () {
        showScenesOverlay();
      });
    }
    var closeBtn = $('scenes-overlay-close');
    if (closeBtn) {
      closeBtn.addEventListener('click', hideScenesOverlay);
    }
    // Click fuori dall'overlay-box → chiude
    var overlayEl = $('scenes-overlay');
    if (overlayEl) {
      overlayEl.addEventListener('mousedown', function (e) {
        if (e.target === overlayEl) hideScenesOverlay();
      });
    }
    // Name input: commit su Enter o blur. Esc = ripristina.
    var nickEl = $('style-nickname');
    if (nickEl) {
      nickEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); nickEl.blur(); }
        else if (e.key === 'Escape') {
          nickEl.value = state.style_name || '';
          nickEl.blur();
        }
      });
      nickEl.addEventListener('blur', commitStyleName);
    }
    // Description input: stesso pattern.
    var descEl = $('style-description');
    if (descEl) {
      descEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); descEl.blur(); }
        else if (e.key === 'Escape') {
          descEl.value = state.description || '';
          descEl.blur();
        }
      });
      descEl.addEventListener('blur', commitDescription);
    }
    // Badge color: swatch apre il popup HSV; hex input + bottone clear.
    var bSw = $('sw-BadgeColor');
    var bEl = $('ctrl-BadgeColor');
    var bClr = $('btn-clear-badgecolor');
    if (bSw && bEl) {
      bSw.addEventListener('click', function () {
        var current = normalizeHex(state.badge_color) || '#cccccc';
        // Il colore del badge non si vede nel viewport: una sola scrittura,
        // alla chiusura (e' un attributo del modello, ~5s sui file con
        // observer di plugin terzi). Intanto cambia solo il campione.
        ColorPopup.show(bSw, current, function (hex) {
          commitBadgeColor(hex);
        }, {
          title: 'Badge color',
          allowNone: true,
          commitOnEnd: true,
          onPreview: function (hex) {
            bEl.value = hex;
            bSw.style.background = hex;
            bSw.classList.remove('swatch-empty');
          }
        });
      });
      bEl.addEventListener('input', function () {
        var h = normalizeHex(bEl.value);
        if (h) { bSw.style.background = h; bSw.classList.remove('swatch-empty'); }
      });
      function commitFromInput() {
        var v = bEl.value.trim();
        if (v === '') { commitBadgeColor(''); return; }
        var h = normalizeHex(v);
        if (!h) { setBadgeColor(state.badge_color || ''); return; }
        bEl.value = h;
        commitBadgeColor(h);
      }
      bEl.addEventListener('change', commitFromInput);
      bEl.addEventListener('blur', commitFromInput);
      bEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter') { e.preventDefault(); bEl.blur(); }
        else if (e.key === 'Escape') { setBadgeColor(state.badge_color || ''); bEl.blur(); }
      });
    }
    if (bClr) {
      bClr.addEventListener('click', function () { commitBadgeColor(''); });
    }
    bindMatchPhoto();
    listenersBound = true;
  }

  function init() {
    call('sm_style_ready');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

  return { setState: setState };
})();
