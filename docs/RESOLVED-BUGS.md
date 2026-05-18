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
