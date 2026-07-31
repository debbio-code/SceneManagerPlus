# Bug risolti — cronologia

Log dei bug concreti incontrati nello sviluppo, con sintomo / causa / fix.
Referenziato da `CLAUDE.md`. I pattern generalizzati di SU 2019 stanno in
`SU2019-LESSONS.md`.

---

## Fase 1

### `NameError: uninitialized constant SceneManagerPlus::UI::Command` al primo load

```
Error: #<NameError: uninitialized constant SceneManagerPlus::UI::Command>
.../scene_manager_plus/main.rb:10:in `<module:SceneManagerPlus>'
```

**Causa**: in `main.rb` riferivo `UI::Command`, `UI::Toolbar`, `UI.menu`
dentro `module SceneManagerPlus`. Ruby li risolveva come
`SceneManagerPlus::UI::Command` (perché esiste il sotto-modulo
`SceneManagerPlus::UI` definito in `ui/dialog.rb`), shadowando il top-level
`::UI` di SketchUp.

**Fix**: prefissare con `::` per forzare il lookup top-level:
```ruby
cmd = ::UI::Command.new(PLUGIN_NAME) { SceneManagerPlus::UI::Dialog.show }
::UI.menu('Plugins').add_item(cmd)
toolbar = ::UI::Toolbar.new(PLUGIN_NAME)
```

### Drop indicator invisibile durante il drag (CEF SU 2019)

**Sintomo:** Il `.drop-indicator` (linea blu di atterraggio del DnD) è
presente nel DOM (log lo conferma: parent corretto, dimensioni corrette,
`display: block`, top calcolato, z-index altissimo) ma **non si vede mai**
durante il drag — nemmeno una barra fucsia 8px appesa al `<body>` con
`position: fixed`.

**Causa:** CEF di SketchUp 2019 non ridipinge il DOM mentre è in corso un
drag HTML5 nativo. Tutti gli update visivi vengono congelati fino al
rilascio del mouse. Una `<div>` fissa creata *fuori* dal drag flow è invece
visibile normalmente — non è z-index/CSS/clipping.

**Fix:** Abbandonato il drag HTML5 nativo. `dnd.js` ora usa `mousedown` (su
row) + `mousemove`/`mouseup` (su `document`) con una soglia di 4px per
distinguere click da drag. Durante mousemove il DOM è aggiornato e
ridipinto normalmente, indicatore visibile.

### CEF carica vecchi JS/CSS dalla cache anche dopo edit

**Sintomo:** Modifico `dnd.js`, chiudo/riapro la finestra HtmlDialog, ma il
codice in esecuzione è ancora quello vecchio (log con marker `__SM_BUILD__`
non aggiornato).

**Fix:** `Dialog#prepare_index` genera a runtime un `index.cb.html` accanto
all'originale, riscrivendo i tag `<script src>` e `<link href>` con
`?v=<timestamp>`. CEF è obbligato a rileggere asset. Il temp file è
gitignored.

### `NoMethodError: undefined method 'use_camera' for Sketchup::Page`

I flag di `Sketchup::Page` (`use_camera`, `use_hidden`, ecc.) hanno **getter
con `?`** e **setter senza** (convenzione predicate Ruby/SU). `flags_hash`
faceva `page.send(:use_camera)` → NoMethodError.

**Fix**: nella costante `FLAG_KEYS` tenere i nomi *base* (per UI/JSON), e in
Ruby costruire `"#{k}?"` per leggere e `"#{k}="` per scrivere via `send`.

### `PAGE_USE_*` constants: nomi diversi per versione SU

`Sketchup::Page#update(mask)` accetta una bitmask di costanti `PAGE_USE_*`.
In SU 2019 alcune non esistono (es. `PAGE_USE_STYLE`, `PAGE_USE_AXES`).

**Fix**: in `update_from_view` uso un lookup difensivo
(`Object.const_defined?`) che prova più nomi e prende quello presente.
Mappatura completa in `SU2019-LESSONS.md`.

### Style non veniva salvato da `update_from_view` — due cause (2026-05)

**Causa 1 — bit sbagliato**. `use_style?` era piggybackato su
`PAGE_USE_RENDERING_OPTIONS` ("style fa parte di rendering"). In SU 2019
esiste invece il bit dedicato `PAGE_USE_SKETCHCS = 8` (verificato con
`tools/dump-page-use.rb`). Se l'utente aveva `use_style=true` e
`use_rendering_options=false`, il bit 2 non aggiornava lo style.

**Fix**: lookup difensivo `'PAGE_USE_STYLE', 'PAGE_USE_SKETCHCS',
'PAGE_USE_RENDERING_OPTIONS'`. Stesso pattern per `use_axes?` →
`'PAGE_USE_AXES', 'PAGE_USE_CAMERA'` (axes non ha bit dedicato in 2019).

**Causa 2 — modifiche pending allo stile non flushate**. `Page#update`
con `PAGE_USE_SKETCHCS` lega la scena allo stile corrente, ma NON sposta
le modifiche dell'utente dalla "dirty in-memory copy" allo stile salvato.
Il dialog nativo SU "Update Scene" mostra in questo caso "Warning -
Scenes and Styles" (Save as new / Update selected / Don't save).
`page.update` lo skippa silenziosamente → le modifiche allo stile si
perdono quando l'utente naviga via dalla scena.

**Fix**: in `update_from_view`, se `p.use_style?` e
`model.styles.active_style_changed`, mostriamo un `UI.messagebox`
3-button (YES/NO/CANCEL) equivalente:
- YES → `model.styles.update_selected_style`, poi `page.update(mask)`.
- NO → "Save as a new style" non è esposto dall'API Ruby di SU 2019
  (nessun `Style#save_as` / `Style#export`). Mostriamo un messaggio con
  le istruzioni manuali (browser Styles → "+") e abort.
- CANCEL → togliamo il bit `PAGE_USE_SKETCHCS` dal mask: gli altri
  property si aggiornano, lo stile resta com'era.

Script `tools/dump-styles-api.rb` per ispezionare quali metodi
`Sketchup::Styles` espone su una versione SU specifica.

### Nuova scena nasce con flag mancanti (2026-05)

`pages.add` rispetta i "Default Scene Properties" globali di SU (UI di
"Add Scene Options"). Se l'utente ha disattivato voci come "Style and Fog"
in quei default, la nuova scena nasceva con `use_style?=false` → SU non
salvava lo style su quella scena. Quindi un successivo `update_from_view`
non poteva ripristinarlo (use_style off = nessun bit attivato).

**Fix**: in `SceneModel.add_from_view`, dopo `pages.add`, forzare tutti
gli 8 `FLAG_KEYS` a `true` via setter. La nuova scena cattura sempre lo
state completo del viewport, indipendentemente dai default SU.

---

## Fase 2-3

### `dblclick` non scatta in CEF SU 2019 se render ricrea la row

`makeSceneRow` in `app.js` viene chiamata ad ogni `setState` → la
`<div.scene-row>` viene rimossa e ricreata. Tra primo e secondo click di un
dblclick, il target elemento non è più lo stesso → CEF non emette
`dblclick`.

**Tentativo fallito**: spostare il listener su `listEl` con event
delegation. Anche così non scatta affidabilmente.

**Soluzione adottata**: rilevamento manuale in `onRowClick` con timestamp
(`lastClickId` + `lastClickTs`, soglia 400ms, no modificatori). Se due
mousedown sulla stessa riga arrivano entro la soglia, triggeriamo
`SMBridge.openProperties(id)`.

---

## Fase 3-4 (Settings dialog)

### Valori 0 si ripristinavano sul default

**Sintomo**: in Settings > Logo, mettere "Offset X (px from right)" a 0 →
torna a 20. Stesso per `offset_y`, `opacity`, `width_pct`, e in generale
qualsiasi campo numerico con default ≠ 0.

**Causa**: in `readLogo()`/`readExport()`/`readForm()` usavo
`parseInt(x) || N` come fallback. 0 è falsy → `0 || 20 = 20`.

**Fix**: helper `toIntOr(v, fallback)` / `toFloatOr(v, fallback)` che
distingue empty/NaN da 0:
```js
function toIntOr(v, fallback) {
  if (v === '' || v == null) return fallback;
  var n = parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}
```

### Campi Naming si ripristinavano dopo blur

**Sintomo**: utente modifica un campo della sezione Naming (es. spunta
"Enable naming pattern", o digita in "Custom prefix"), poi clicca altrove
nel dialog → il campo torna al valore precedente.

**Causa**: Naming usava Save manuale (gli altri gruppi auto-save). Se
l'utente toccava Export/Logo, l'auto-save debounced (350ms) faceva
`push_state` → Ruby ri-pushava TUTTI i settings → `writeForm(naming)`
sovrascriveva la modifica non-ancora-salvata. Inoltre `writeForm` scriveva
direttamente nei campi senza `setIfNotFocused`.

**Fix**: 
1. `writeForm` ora usa `setIfNotFocused` (consistenza con `writeExport`/
   `writeLogo`).
2. Auto-save anche per Naming (rimosso bottone "Save", mantenuto "Rename
   scenes now" per l'apply action).

### Settings push_state riscrive campi in editing (originale)

Lo stesso problema dell'item precedente, prima fase di scoperta. Stessa
soluzione (`setIfNotFocused`) applicata a `writeExport`/`writeLogo` da
subito; l'estensione a `writeForm` è arrivata dopo, quando l'utente ha
segnalato lo stesso pattern sulla sezione Naming.

## Fase 4+ — UX polish

### Preview thumbnail "sparivano ogni tanto"

**Sintomo**: dopo un'operazione qualsiasi nel pannello (rename, reorder,
update from view, …) alcune o tutte le thumbnail scena diventavano
broken/vuote. Toggling thumbs off/on a volte le faceva tornare, altre
volte serviva rigenerare.

**Causa**: `state.preview_ts = Date.now()` veniva ribumpato a ogni
`setState`. L'`<img src="file:///.../X.png?t=newTs">` cambiava URL a
ogni render → CEF ri-richiedeva il PNG ogni volta, e la richiesta
ripetuta su `file://` con query string in CEF SU 2019 falliva
intermittentemente (filesystem race / quirk noto).

**Fix**: bumpare `preview_ts` solo quando (a) il set di chiavi della
mappa previews cambia, o (b) arriva il segnale `setPreviewProgress(null,
null)` di fine-rigenerazione (gestisce il caso "stessi uid, contenuto
nuovo"). Tra le altre operazioni l'URL resta identico, CEF tiene la
cache, niente fetch ripetuti.

### Doppio click apriva Properties senza nome scena

**Sintomo**: a volte (non sempre) il doppio click su una scena apriva il
dialog Properties con il titolo iniziale `—` invece del nome della scena.

**Causa**: c'erano DUE handler che chiamavano `openProperties(id)` —
rilevazione manuale del dblclick in `onRowClick` (necessaria perché CEF
non emette `dblclick` se la row viene ricreata tra i click) e un
listener `dblclick` su `listEl` aggiunto come "fallback". Il secondo
faceva chiamare `openProperties` di nuovo a millisecondi di distanza
dalla prima call. La seconda call trovava `@dialog.visible? === true` e
chiamava `execute_script("window.SMP && SMP.setState(...)")` PRIMA che
il JS di CEF fosse caricato → `window.SMP` undefined → il primo setState
si perdeva → il titolo restava al valore statico dell'HTML.

**Fix**: rimosso il listener `dblclick` su `listEl` (la rilevazione
manuale è sufficiente). Aggiunto un fallback in `SMP.setState`: se
arriva uno state vuoto e ne avevamo uno valido, ignora invece di
azzerare la UI.

### Click su una scena faceva saltare la lista in cima

**Sintomo**: con la finestra abbastanza corta da non mostrare tutte le
scene, cliccare su una qualsiasi scena scrollava la lista in cima.

**Causa**: `render()` fa `listEl.innerHTML = ''` per ricostruire la
lista — rimuovere tutti i figli azzera lo `scrollTop` del contenitore
(non c'è più nulla da scrollare). Quando re-appendevamo le row, la
scrollbar ricominciava da 0.

**Fix**: salvare `listEl.scrollTop` all'inizio di `render()` e
ripristinarlo dopo l'append. Generale per qualsiasi lista
re-renderizzata via innerHTML.

### Nuove scene perdevano i tag "Add visible tag"

**Sintomo**: creando una nuova scena (sia dal pannello nativo SU sia dal
bottone del plugin), i tag creati col plugin Layers Manager via "Add
visible tag" risultavano spenti, anche se a video erano accesi sulla
scena attiva.

**Causa**: `pages.add` snapshotta lo stato model-level dei layer, non
quello effettivo del viewport (che include gli override per-pagina della
scena attiva). I tag "Add visible tag" sono globalmente hidden e visibili
solo via override → SU li perde nello snapshot.

**Tentativo errato**: iterare `active.layers` e fare `set_visibility(layer,
!layer.visible?)`. In SU 2019 `page.layers` è la lista degli HIDDEN per
quella pagina (non degli "override generici"), quindi questa logica
accendeva tutti i layer-globalmente-hidden che la pagina intendeva
nascondere → risultato: nuova scena con tutti i layer ON tranne quelli
"Add visible tag" (caso peggiore del bug originale).

**Fix corretto**: per ogni `model.layers`, `new_page.set_visibility(layer,
!active.layers.include?(layer))`. Si replica la visibilità effettiva
calcolata dalla hidden-list. Vedi `SU2019-LESSONS.md` sezione
`Sketchup::Page#layers` per la spiegazione completa.

### Nuova scena da scena Match Photo: la foto spariva (2026-07-31)

**Sintomo**: creando una nuova scena dal plugin mentre era attiva una
scena Match Photo, la nuova nasceva senza foto di sfondo. Il plugin lo
"gestiva" con un messagebox che rinunciava e rimandava al menù nativo.

**Causa dichiarata (SBAGLIATA, durata mesi)**: si riteneva che SU avesse
*"due binari diversi"* per lo stesso comando — click manuale sul menù =
handler C++ con accesso al Match Photo, `send_action(21067)` = handler
"scripting-safe" che lo bypassa. Da lì la conclusione "limite
invalicabile dell'API".

**Causa reale**: solo `pages.add(name)` perde la foto. `send_action(21067)`
la conserva perfettamente. La falsa prova nasceva dal fatto che
**`send_action` è asincrono**: chi lo chiama e verifica subito dopo vede
il modello invariato e conclude che non abbia fatto nulla.

**Fix**: in `SceneModel.add_from_view`, ramo `is_mp` → `send_action`
(`add_from_view_native`) + catena `UI.start_timer` che attende la pagina
(`await_native_page`, diff su `page.object_id`) + `finalize_native_page`
per nome/flag/layer/uid in operazione `transparent`. Il messagebox di
rinuncia è stato rimosso; `add_from_view` ora accetta un blocco
`on_created` perché il ramo MP non può ritornare la Page.

**Verifica** (metodo da riusare per qualsiasi dubbio su Match Photo):
attivare un'altra scena, tornare sulla nuova, `view.write_image` e
confrontare i pixel con un render dell'originale → 0 differenze su 47.000
campioni. Le proprietà (`aspect_ratio`, `is_2d?`) NON sono una prova:
sono identiche anche sulle scene senza foto prodotte da `pages.add`.

**Da ricordare**: la teoria sbagliata era scritta in `CLAUDE.md` come
fatto acquisito, e per questo non è stata più rimessa in discussione. Una
misura negativa su un'API asincrona non è una prova.

---

## Potenziali bug aperti (osservati, non riproducibili in modo affidabile)

### Lentezza / freeze alla seconda immagine in batch export con watermark

**Sintomo**: l'export batch sembra completare la prima immagine
normalmente, poi alla seconda si imballa per molti secondi (utente ha
riportato 2 occorrenze; alla terza prova non è successo).

**Sospetto principale**: in `composite_bilinear!`, `base.colors` alloca
~`bw*bh` oggetti `Sketchup::Color` (a 4K = 8M oggetti). Sulla seconda
immagine il GC è ancora a smaltire quelli della prima → stall.

**Sospetto secondario**: `pages.selected_page = page` tra un export e
l'altro può triggerare refresh non documentati.

**Stato**: NON fixato perché non riproducibile in modo affidabile. Se si
ripresenta:
1. Aprire Ruby Console e cercare il punto di stall nei `puts`
2. Provare lo stesso batch con watermark disabilitato → se vola, è
   confermato il composite
3. Raccogliere: risoluzione export, numero scene, watermark on/off

Fix candidato (alto costo, da fare solo se confermato):
- Eliminare il primo pass copia-base via `base.colors` → usare `base.data`
  raw bytes se disponibile (ma formato/endian variano per build)
- Blendare solo nella bbox del logo senza copiare l'intera base
- Aggiungere `GC.start` esplicito tra un'immagine e l'altra (workaround
  rapido ma freeza UI 200-500ms)
