// Selettore colore condiviso di tutte le finestre (window.SMColorPopup).
// Dal 2026-10-24 e' lo stesso dei Componenti parametrici (selettore_colore.js
// in quel repo, chiesto da Nicola): in alto come il pannello Colori di
// SketchUp (menu Color wheel / HLS / HSB / RGB, campione, le due pipette, i
// cursori coi numeri), sotto i colori usati di recente, anteprima, codice e
// OK. Il riquadro si costruisce da solo alla prima apertura: le pagine
// includono solo questo file e css/color_popup.css. <input type="color"> non
// funziona nel CEF di SU 2019.
//
// API (la stessa del vecchio popup HSV, i chiamanti non sono cambiati):
//   SMColorPopup.show(triggerEl, currentHex, onApply, opts)
//     opts.title       testo in testa al riquadro
//     opts.allowNone   bottone "None": onApply('') e chiude
//     opts.commitOnEnd onApply una volta sola, alla chiusura, col colore
//                      finale (se e' stato toccato). Senza: a ogni ritocco,
//                      per l'anteprima dal vivo nel viewport
//     opts.onPreview   fn(hex), solo con commitOnEnd: a ogni ritocco
//   SMColorPopup.hide()    chiude = conferma (OK, Invio nel codice, Esc,
//                          clic fuori dal riquadro)
//   SMColorPopup.cancel()  chiude senza confermare niente
//   SMColorPopup.isOpen()
//   SMColorPopup.picked(hex, done, notice)  risposta delle pipette da Ruby
//     (core/color_pick.rb: callback sm_cp_model / sm_cp_screen / sm_cp_cancel,
//     che ogni finestra aggancia con ColorPick.register)
//   SMColorPopup.normalizeHex(s), SMColorPopup.pushRecent(hex)
// triggerEl non serve piu' (il riquadro sta al centro della finestra): resta
// nella firma per non toccare i chiamanti.
window.SMColorPopup = (function () {
  var MODES = [['wheel', 'Color wheel'], ['hls', 'HLS'], ['hsb', 'HSB'], ['rgb', 'RGB']];
  var MODE_KEY = 'sm_color_popup_mode';      // ultimo menu scelto
  var RECENT_KEY = 'sm_color_popup_recent';  // condivisi da tutte le finestre
  var RECENT_MAX = 8;
  var WHEEL = 128;   // diametro della ruota, px
  var GRACE = 500;   // ms dopo una pipetta in cui i clic qui non contano
  var NOTES = {
    model: '<b>Click an object in the model</b> to take the color it shows there ' +
      '(its face, otherwise its group or component). <b>Esc</b> cancels.',
    screen: 'Move the mouse <b>anywhere on the screen</b>, even outside SketchUp. ' +
      '<b>Click</b>, <b>Enter</b> or <b>Space</b> take the color, <b>Esc</b> cancels.' +
      '<br><span class="smcp-dim">The click also reaches the window underneath: ' +
      'over something delicate, confirm with Enter.</span>'
  };

  // --- conversioni: componenti 0-1, tinta 0-360, rgb 0-255 ------------------
  function sector(h, c, x) {
    h = ((h % 360) + 360) % 360;
    return h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] :
           h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  }
  function hsv2rgb(h, s, v) {
    var c = v * s, t = sector(h, c, c * (1 - Math.abs((h / 60) % 2 - 1))), m = v - c;
    return [(t[0] + m) * 255, (t[1] + m) * 255, (t[2] + m) * 255];
  }
  function hls2rgb(h, l, s) {
    var c = (1 - Math.abs(2 * l - 1)) * s, t = sector(h, c, c * (1 - Math.abs((h / 60) % 2 - 1))), m = l - c / 2;
    return [(t[0] + m) * 255, (t[1] + m) * 255, (t[2] + m) * 255];
  }
  // null = non definito (la tinta di un grigio, la saturazione del nero):
  // chi riceve tiene il valore che aveva
  function hue(r, g, b, mx, d) {
    if (d <= 1e-9) return null;
    var h = 60 * (mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4);
    return h < 0 ? h + 360 : h;
  }
  function rgb2hsv(c) {
    var r = c[0] / 255, g = c[1] / 255, b = c[2] / 255, mx = Math.max(r, g, b), d = mx - Math.min(r, g, b);
    return [hue(r, g, b, mx, d), mx > 1e-9 ? d / mx : null, mx];
  }
  function rgb2hls(c) {
    var r = c[0] / 255, g = c[1] / 255, b = c[2] / 255, mx = Math.max(r, g, b), mn = Math.min(r, g, b);
    var d = mx - mn, l = (mx + mn) / 2;
    return [hue(r, g, b, mx, d), (l > 1e-9 && l < 1 - 1e-9) ? d / (1 - Math.abs(2 * l - 1)) : null, l];
  }
  function normalizeHex(v) {
    var h = String(v || '').trim().replace(/^#?/, '#').toLowerCase();
    return /^#[0-9a-f]{6}$/.test(h) ? h : null;
  }
  function hexRgb(h) { return [1, 3, 5].map(function (i) { return parseInt(h.substr(i, 2), 16); }); }
  function rgbHex(c) {
    return '#' + c.map(function (n) {
      n = Math.max(0, Math.min(255, Math.round(n))).toString(16); return n.length < 2 ? '0' + n : n;
    }).join('');
  }
  function css(c) { return 'rgb(' + c.map(Math.round).join(',') + ')'; }
  function grad(stops) { return 'linear-gradient(to right,' + stops.map(css).join(',') + ')'; }
  var RAINBOW = 'linear-gradient(to right,#f00 0%,#ff0 16.7%,#0f0 33.3%,#0ff 50%,#00f 66.7%,#f0f 83.3%,#f00 100%)';

  // I tre modi coi cursori, nei valori che si vedono (H 0-360, il resto 0-100
  // o 0-255). La ruota usa la terna HSB: tinta e saturazione nel cerchio, la
  // luminosita' nel cursore sotto.
  var SPEC = {
    hls: {letters: 'HSL', max: [360, 100, 100],
      rgb: function (t) { return hls2rgb(t[0], t[2] / 100, t[1] / 100); },
      from: function (c) { var q = rgb2hls(c); return [q[0], q[1] === null ? null : q[1] * 100, q[2] * 100]; },
      bars: function (t) {
        var h = t[0], s = t[1] / 100, l = t[2] / 100;
        return [RAINBOW, grad([hls2rgb(h, l, 0), hls2rgb(h, l, 1)]),
                grad([[0, 0, 0], hls2rgb(h, 0.5, s), [255, 255, 255]])];
      }},
    hsb: {letters: 'HSB', max: [360, 100, 100],
      rgb: function (t) { return hsv2rgb(t[0], t[1] / 100, t[2] / 100); },
      from: function (c) { var q = rgb2hsv(c); return [q[0], q[1] === null ? null : q[1] * 100, q[2] * 100]; },
      bars: function (t) {
        var h = t[0], s = t[1] / 100, v = t[2] / 100;
        return [RAINBOW, grad([hsv2rgb(h, 0, v), hsv2rgb(h, 1, v)]), grad([[0, 0, 0], hsv2rgb(h, s, 1)])];
      }},
    rgb: {letters: 'RGB', max: [255, 255, 255],
      rgb: function (t) { return t.slice(); },
      from: function (c) { return c.slice(); },
      bars: function (t) {
        return [0, 1, 2].map(function (i) { var a = t.slice(), b = t.slice(); a[i] = 0; b[i] = 255; return grad([a, b]); });
      }}
  };

  // S.t = le terne dei tre modi, tenute insieme: quella che si sta muovendo
  // comanda, le altre si ricavano dal colore. S.hex resta il codice esatto
  // finche' non si tocca un cursore (recenti, codici scritti e pipette non si
  // spostano di 1/255 nel giro di conversioni).
  var S = {mode: 'hls', hex: '#808080', rgb: [128, 128, 128],
           t: {hls: [0, 0, 50], hsb: [0, 0, 50], rgb: [128, 128, 128]},
           drag: null, op: null, before: null, endAt: 0};
  var O = {};      // il selettore aperto: callback e opzioni di show()
  var D = null;    // gli elementi, costruiti alla prima apertura

  try { var m0 = localStorage.getItem(MODE_KEY); if (SPEC[m0] || m0 === 'wheel') S.mode = m0; } catch (e) {}

  // --- recenti ---------------------------------------------------------------
  var recentMem = [];   // se localStorage non c'e'
  function loadRecent() {
    try {
      var s = window.localStorage && window.localStorage.getItem(RECENT_KEY);
      if (s) {
        var arr = JSON.parse(s);
        if (Array.isArray(arr)) return arr.filter(normalizeHex).slice(0, RECENT_MAX);
      }
    } catch (e) {}
    return recentMem.slice();
  }
  function pushRecent(hex) {
    var h = normalizeHex(hex);
    if (!h) return;
    var arr = loadRecent(), i = arr.indexOf(h);
    if (i !== -1) arr.splice(i, 1);
    arr.unshift(h);
    if (arr.length > RECENT_MAX) arr.length = RECENT_MAX;
    recentMem = arr.slice();
    try { if (window.localStorage) window.localStorage.setItem(RECENT_KEY, JSON.stringify(arr)); } catch (e) {}
    drawRecent();
  }
  function drawRecent() {
    if (!D) return;
    var arr = loadRecent();
    D.recent.innerHTML = '';
    arr.forEach(function (h) {
      var sp = document.createElement('span');
      sp.title = h; sp.style.background = h;
      sp.addEventListener('click', function () { if (touch()) set(h); });
      D.recent.appendChild(sp);
    });
    D.recent.style.display = arr.length ? 'flex' : 'none';
  }

  // --- stato -----------------------------------------------------------------
  function fromRgb(skip) {
    for (var m in SPEC) {
      if (m === skip) continue;
      var n = SPEC[m].from(S.rgb), t = S.t[m];
      for (var i = 0; i < 3; i++) if (n[i] !== null) t[i] = n[i];
    }
  }
  function set(hex) {
    S.hex = hex; S.rgb = hexRgb(hex); fromRgb(null); draw(); notify();
  }
  function recalc(m) {
    S.rgb = SPEC[m].rgb(S.t[m]); S.hex = rgbHex(S.rgb); fromRgb(m); draw(); notify();
  }
  function adjust(m, i, v) {
    S.t[m][i] = Math.max(0, Math.min(SPEC[m].max[i], v)); recalc(m);
  }
  function invoke(fn, hex) {
    if (!fn) return;
    try { fn(hex); } catch (e) {}
  }
  function notify() {
    if (!O.open || O.silent) return;
    O.changed = true;
    if (O.commitOnEnd) invoke(O.onPreview, S.hex);
    else invoke(O.onApply, S.hex);
  }
  function channels() { return S.mode === 'wheel' ? [['hsb', 2]] : [[S.mode, 0], [S.mode, 1], [S.mode, 2]]; }

  // --- disegno ---------------------------------------------------------------
  function draw() {
    if (!D) return;
    D.sample.style.background = S.hex; D.prev.style.background = S.hex;
    if (document.activeElement !== D.hex) D.hex.value = S.hex;
    var wheel = S.mode === 'wheel', hsb = S.t.hsb, ch = channels();
    var bars = wheel ? [grad([[0, 0, 0], hsv2rgb(hsb[0], hsb[1] / 100, 1)])] : SPEC[S.mode].bars(S.t[S.mode]);
    D.wheel.style.display = wheel ? 'block' : 'none';
    D.rows.forEach(function (r, k) {
      var c = ch[k];
      r.el.style.display = c ? 'flex' : 'none';
      if (!c) return;
      var mx = SPEC[c[0]].max[c[1]], v = S.t[c[0]][c[1]];
      r.lab.textContent = wheel ? 'V' : SPEC[c[0]].letters.charAt(c[1]);
      r.bar.style.background = bars[k];
      r.cur.style.left = (v / mx * 100) + '%';
      r.num.max = mx;
      if (document.activeElement !== r.num) r.num.value = Math.round(v);
    });
    if (wheel) {
      var R = WHEEL / 2, a = hsb[0] * Math.PI / 180, d = hsb[1] / 100 * R;
      D.dot.style.left = (R + Math.cos(a) * d) + 'px';
      D.dot.style.top = (R - Math.sin(a) * d) + 'px';
      D.dark.style.opacity = 1 - hsb[2] / 100;
    }
    D.model.className = 'smcp-ico' + (S.op === 'model' ? ' on' : '');
    D.screen.className = 'smcp-ico' + (S.op === 'screen' ? ' on' : '');
  }
  function note(html) { D.note.innerHTML = html; D.note.style.display = html ? 'block' : 'none'; }

  // la ruota si disegna una volta sola, a luminosita' piena: il buio sopra la
  // scurisce col cursore V
  function drawWheel() {
    var n = WHEEL, R = n / 2, ctx = D.canvas.getContext('2d'), img = ctx.createImageData(n, n), p = img.data;
    for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) {
      var dx = x + 0.5 - R, dy = R - (y + 0.5), r = Math.sqrt(dx * dx + dy * dy), k = (y * n + x) * 4;
      if (r >= R) continue;
      var h = Math.atan2(dy, dx) * 180 / Math.PI, c = hsv2rgb(h < 0 ? h + 360 : h, Math.min(1, r / (R - 1)), 1);
      p[k] = c[0]; p[k + 1] = c[1]; p[k + 2] = c[2]; p[k + 3] = 255 * Math.min(1, R - r);
    }
    ctx.putImageData(img, 0, 0);
  }

  // --- pipette ---------------------------------------------------------------
  // Mentre lavora quella dallo schermo ogni clic e' una conferma (anche sopra
  // questo riquadro), e il clic arriva qui anche dopo: per un attimo non conta.
  function blocked() { return S.op === 'screen' || Date.now() - S.endAt < GRACE; }
  // un ritocco a mano mentre lavora la pipetta nel modello la spegne
  function touch() { if (blocked()) return false; if (S.op) cancelPick(); return true; }

  function pick(kind) {
    if (blocked()) return;
    if (S.op === kind) { cancelPick(); return; }
    if (S.op) cancelPick();
    var fn = 'sm_cp_' + kind;
    if (!(window.sketchup && window.sketchup[fn])) { note('Eyedroppers only work inside SketchUp.'); return; }
    // Il fuoco sul riquadro, non sul bottone: Invio e Spazio confermano la
    // pipetta dallo schermo, e sul bottone la farebbero ripartire.
    D.panel.focus();
    S.op = kind; S.before = S.hex;
    note(NOTES[kind]); draw();
    window.sketchup[fn]();
  }
  function finishPick(hex, notice) {
    S.op = null; S.endAt = Date.now();
    // annullata: com'era prima (anche nel viewport, se l'anteprima era dal vivo)
    if (!hex && S.before && S.before !== S.hex) set(S.before);
    note(notice || ''); draw();
  }
  function cancelPick() {
    if (!S.op) return;
    finishPick(null);
    if (window.sketchup && window.sketchup.sm_cp_cancel) window.sketchup.sm_cp_cancel();
  }
  // da Ruby: done=false mentre il mouse si muove, true alla fine ('' = annullata)
  function picked(hex, done, notice) {
    if (!S.op) return;
    var h = normalizeHex(hex);
    if (h) set(h);
    if (done) finishPick(h, notice);
  }

  // --- costruzione -----------------------------------------------------------
  var ICO_MODEL = '<svg viewBox="0 0 18 18" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" stroke-linecap="round">' +
    '<path d="M1.5 9.5 L6 7.3 L10.5 9.5 L10.5 14.5 L6 16.7 L1.5 14.5 Z M1.5 9.5 L6 11.7 L10.5 9.5 M6 11.7 V16.7"/>' +
    '<path d="M7.2 8.8 L12.6 3.4" stroke-width="2"/><path d="M11.3 2.1 L13.9 4.7"/>' +
    '<circle cx="14.6" cy="1.4" r="1.3" fill="currentColor" stroke="none"/></svg>';
  var ICO_SCREEN = '<svg viewBox="0 0 18 18" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" stroke-linecap="round">' +
    '<rect x="1.2" y="2" width="15.6" height="10.5" rx="1"/><path d="M5.5 16 H12.5 M9 12.5 V16"/>' +
    '<path d="M5.8 10 L10.4 5.4" stroke-width="1.8"/><path d="M9.3 4.3 L11.5 6.5"/>' +
    '<circle cx="12" cy="3.7" r="1.1" fill="currentColor" stroke="none"/></svg>';

  function row() {
    return '<div class="smcp-row"><span></span><div class="smcp-bar"><div class="smcp-cur"></div></div>' +
      '<input type="number" min="0" step="1"></div>';
  }

  function build() {
    var f = document.createElement('div');
    f.id = 'smcp';
    f.innerHTML = '<div id="smcpPanel" tabindex="-1"><div id="smcpTitle"></div>' +
      '<div class="smcp-head"><select id="smcpMode">' +
        MODES.map(function (m) { return '<option value="' + m[0] + '">' + m[1] + '</option>'; }).join('') +
      '</select><div id="smcpSample"></div>' +
      '<button type="button" class="smcp-ico" id="smcpModel" title="Take the color from an object in the model">' + ICO_MODEL + '</button>' +
      '<button type="button" class="smcp-ico" id="smcpScreen" title="Take the color from the screen">' + ICO_SCREEN + '</button></div>' +
      '<div id="smcpWheel"><canvas id="smcpCanvas" width="' + WHEEL + '" height="' + WHEEL + '"></canvas>' +
      '<div id="smcpDark"></div><div id="smcpDot"></div></div>' +
      row() + row() + row() +
      '<div id="smcpRecent" title="Recent colors"></div>' +
      '<div class="smcp-foot"><div id="smcpPrev"></div><input type="text" id="smcpHex" maxlength="7" spellcheck="false">' +
      '<button type="button" class="smcp-btn" id="smcpNone" title="No color">None</button>' +
      '<button type="button" class="smcp-btn smcp-ok" id="smcpOk" title="Confirm color (Enter)">OK</button></div>' +
      '<p id="smcpNote"></p></div>';
    document.body.appendChild(f);

    function $(id) { return document.getElementById(id); }
    D = {overlay: f, panel: $('smcpPanel'), title: $('smcpTitle'), mode: $('smcpMode'), sample: $('smcpSample'),
         model: $('smcpModel'), screen: $('smcpScreen'), wheel: $('smcpWheel'), canvas: $('smcpCanvas'),
         dark: $('smcpDark'), dot: $('smcpDot'), recent: $('smcpRecent'), prev: $('smcpPrev'),
         hex: $('smcpHex'), none: $('smcpNone'), ok: $('smcpOk'), note: $('smcpNote'), rows: []};
    Array.prototype.forEach.call(f.querySelectorAll('.smcp-row'), function (el, k) {
      var r = {el: el, lab: el.querySelector('span'), bar: el.querySelector('.smcp-bar'),
               cur: el.querySelector('.smcp-cur'), num: el.querySelector('input')};
      D.rows.push(r);
      r.bar.addEventListener('mousedown', function (e) {
        e.preventDefault();
        if (!touch()) return;
        S.drag = {row: k}; dragTo(e);
      });
      r.num.addEventListener('input', function () {
        var v = parseFloat(this.value), c = channels()[k];
        if (!c || isNaN(v) || !touch()) return;
        adjust(c[0], c[1], v);
      });
      r.num.addEventListener('blur', draw);
    });
    drawWheel();

    D.mode.value = S.mode;
    D.mode.addEventListener('change', function () {
      S.mode = this.value;
      try { localStorage.setItem(MODE_KEY, S.mode); } catch (e) {}
      draw();
    });
    D.wheel.addEventListener('mousedown', function (e) {
      e.preventDefault();
      if (!touch()) return;
      S.drag = {wheel: true}; dragTo(e);
    });
    D.model.addEventListener('click', function () { pick('model'); });
    D.screen.addEventListener('click', function () { pick('screen'); });
    D.hex.addEventListener('input', function () {
      var h = normalizeHex(this.value);
      if (h && !blocked()) { if (S.op) cancelPick(); set(h); }
    });
    D.hex.addEventListener('blur', draw);
    D.ok.addEventListener('click', function () { if (!blocked()) close(true); });
    D.none.addEventListener('click', function () {
      if (blocked()) return;
      O.none = true; close(true);
    });
    // Clic fuori dal riquadro = conferma, ma solo se anche il mousedown era
    // fuori: un cursore trascinato e lasciato sul fondo non deve chiudere.
    var downOut = false;
    f.addEventListener('mousedown', function (e) { downOut = (e.target === f); });
    f.addEventListener('click', function (e) {
      if (e.target === f && downOut && !blocked()) close(true);
    });
    // I tasti non escono dal riquadro: nella finestra principale le frecce
    // cambierebbero scena sotto il selettore aperto.
    f.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' || e.keyCode === 27) {
        e.preventDefault();
        if (S.op) cancelPick(); else if (!blocked()) close(true);
      } else if (e.key === 'Enter' && e.target === D.hex) {
        e.preventDefault();
        if (!blocked()) close(true);
      }
      e.stopPropagation();
    });
    document.addEventListener('keydown', function (e) {
      if (S.op && (e.key === 'Escape' || e.keyCode === 27)) cancelPick();
    });
    document.addEventListener('mousemove', function (e) {
      if (!S.drag) return;
      if (e.buttons === 0) { S.drag = null; return; }   // tasto lasciato fuori dalla finestra
      dragTo(e);
    });
    document.addEventListener('mouseup', function () { S.drag = null; });
  }

  function dragTo(e) {
    if (S.drag.wheel) {
      var b = D.wheel.getBoundingClientRect(), R = WHEEL / 2;
      var dx = e.clientX - b.left - R, dy = R - (e.clientY - b.top), h = Math.atan2(dy, dx) * 180 / Math.PI;
      S.t.hsb[0] = h < 0 ? h + 360 : h;
      S.t.hsb[1] = Math.min(1, Math.sqrt(dx * dx + dy * dy) / R) * 100;
      recalc('hsb');
      return;
    }
    var c = channels()[S.drag.row];
    if (!c) return;
    var r = D.rows[S.drag.row].bar.getBoundingClientRect();
    adjust(c[0], c[1], Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * SPEC[c[0]].max[c[1]]);
  }

  function show(triggerEl, currentHex, applyFn, opts) {
    if (!D) build();
    if (O.open) close(true);
    opts = opts || {};
    // Il colore iniziale si mette senza notify: aprire il selettore non deve
    // riscrivere il colore (era visibile su HorizonColor, dove il valore
    // mostrato differisce dal reale).
    O = {open: true, onApply: applyFn, commitOnEnd: !!opts.commitOnEnd,
         onPreview: typeof opts.onPreview === 'function' ? opts.onPreview : null,
         changed: false, none: false};
    D.title.textContent = opts.title || 'Color';
    D.none.style.display = opts.allowNone ? '' : 'none';
    drawRecent();
    var hex = normalizeHex(currentHex) || '#ffffff';
    S.hex = hex; S.rgb = hexRgb(hex); fromRgb(null);
    note('');
    D.overlay.style.display = 'flex';
    draw();
    D.panel.focus();
  }

  function close(commit) {
    if (!O.open) return;
    // cancel(): la pipetta si ferma senza rimandare il colore di prima a chi
    // ha aperto il selettore (cancel arriva quando la finestra e' gia' passata
    // a un altro stile o scena, e il colore finirebbe li').
    if (!commit) O.silent = true;
    if (S.op) cancelPick();
    D.overlay.style.display = 'none';
    var o = O;
    O = {};
    if (!commit) return;
    if (o.none) { invoke(o.onApply, ''); return; }
    if (!o.changed) return;
    if (o.commitOnEnd) invoke(o.onApply, S.hex);
    pushRecent(S.hex);
  }

  return {
    show: show,
    hide: function () { close(true); },
    cancel: function () { close(false); },
    isOpen: function () { return !!O.open; },
    picked: picked,
    normalizeHex: normalizeHex,
    pushRecent: pushRecent
  };
})();
