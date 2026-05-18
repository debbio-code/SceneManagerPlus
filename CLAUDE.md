# Scene Manager+ — SketchUp 2019 Plugin

Plugin di gestione scene avanzata per SketchUp 2019, in stile "livelli Photoshop":
lista scene riordinabile, cartelle, batch export con watermark logo, naming pattern.

## Stato attuale: Fase 4 completata

Sviluppo in 4 fasi:

1. **Fase 1 — Scaffolding + finestra base con lista scene + selezione/DnD** ✅
2. **Fase 2 — Cartelle (logiche + DnD scene↔cartelle)** ✅
   - Sync ordine logico→pagine native SU **scartata di proposito** (vedi sotto)
3. **Fase 3 — Settings + naming pattern + Properties dialog** ✅
4. **Fase 4 — Batch export + watermark** ✅
   - `Core::Exporter` (asincrono, cancellabile)
   - Watermark via `Sketchup::ImageRep` — niente ChunkyPNG
   - Logo bundled in `scene_manager_plus/assets/default_logo.png`
   - Scope picker (All / Selected / Folders) in `ExportDialog`
   - Smart output dir: regola Immagini/Superate/NN accanto al `.skp`
   - Line Scale Multiplier (con fallback EdgeWidth/ProfileWidth per SU 2019)

Extra fuori-fase aggiunti in Fase 3:
- **Defer mode** (`Core::Buffer`): tutte le scritture vivono in RAM, un solo
  flush a SU. Bottone in toolbar, auto-flush alla chiusura.
- **Per-scene previews** (`Core::Previews`): PNG persistenti per-modello
  (`~/.scene_manager_plus/previews/<model_guid>/`). Generazione asincrona con
  progress bar.
- **Inline thumbnails** nella lista (toggle Thumbs).
- **Polling 250ms** per syncare in plugin la scena attivata da tab nativi SU.
- **Per-row ⟳** icona update-from-view (come "Update Scene" nativo).

## Decisioni di design

| Tema | Scelta |
|---|---|
| UI | `UI::HtmlDialog` (CEF, SU 2017+) — niente WebDialog legacy |
| Cartelle | Doppia modalità: solo logiche (default) + bottone "Sync to SketchUp" che applica l'ordine reale alle pagine |
| Formati export | PNG + JPG |
| Watermark | PNG: composizione via ChunkyPNG (pure Ruby, embedded in `vendor/`). JPG: fallback overlay 2D temporaneo nella scena, esportato e rimosso |
| Persistenza cartelle/ordine | Attributi sul `Sketchup.active_model` (vivono col file SKP) |
| Persistenza settings | `Sketchup.write_default` (per-utente, globale al PC) |
| Lingua UI | Inglese (UX standard) |
| Preview scene | NON implementata, per richiesta utente (no rallentamento refresh) |

## Struttura repo

```
scene_manager_plus.rb               # loader, registra l'extension
scene_manager_plus/
├── main.rb                         # entry point: menu + toolbar + comando
├── core/
│   ├── buffer.rb                   # Defer mode: stato globale edit in RAM + flush!
│   ├── scene_model.rb              # wrapper su Sketchup.active_model.pages
│   ├── folders.rb                  # cartelle logiche (schema + load/save)
│   ├── settings.rb                 # config persistente con defaults
│   ├── naming.rb                   # format/preview/apply_rename pattern
│   └── previews.rb                 # cache PNG anteprime per-modello persistente
└── ui/
    ├── dialog.rb                   # Main HtmlDialog + bridge + polling scene attiva
    ├── settings_dialog.rb          # Dialog Settings (pattern naming, ...)
    ├── properties_dialog.rb        # Dialog Properties singola scena (dblclick)
    └── html/
        ├── index.html              # finestra principale
        ├── settings.html           # finestra Settings
        ├── properties.html         # finestra Properties
        ├── css/{style,settings,properties}.css
        └── js/
            ├── bridge.js           # window.SMBridge → sketchup.<callback>
            ├── dnd.js              # drag&drop custom (no HTML5 native)
            ├── app.js              # logica lista, selezione, defer, thumbs
            ├── settings.js         # logica dialog Settings
            └── properties.js       # logica dialog Properties (live commit)
```

## Cosa funziona già (Fase 1 + 2)

**Fase 1**
- Finestra HtmlDialog tema scuro, ridimensionabile, posizione persistente
- Lista scene numerata con drag handle
- Selezione: click singolo, **Shift+click** range, **Ctrl+click** toggle
- DnD multi-selezione con drop indicator blu
- Click singolo sincronizza scena attiva nel viewport SU
- Pannello proprietà con name/description + tutti i flag nativi (`use_camera`,
  `use_hidden`, `use_hidden_layers`, `use_style`, `use_shadow_info`, `use_axes`,
  `use_section_planes`, `use_rendering_options`)
- Bottone **Update** = `page.update(mask)`, **Delete** con conferma

**Fase 2**
- Bottone **📁+ New folder** in toolbar (prompt nome)
- Header cartella: chevron espandi/collassa, swatch colore (prompt hex), nome,
  contatore scene, ✎ rinomina, ✕ elimina (visibili su hover)
- `logical_order` ora è una lista *mista*: scene uids al root + folder ids.
  Le scene dentro una cartella vivono in `folder.scene_ids`, non in `logical_order`.
- DnD esteso:
  - Scene root↔root, scene↔dentro cartella, cartelle↔root
  - Drop **sopra/sotto** una cartella → linea blu (root drop)
  - Drop **dentro** cartella (metà inferiore header) → rettangolo blu attorno
    all'header (background azzurro + bordo). Vale anche per cartelle **chiuse**
    (in quel caso appende in coda al loro contenuto).
  - Drop tra scene dentro una cartella → linea blu **indentata 28px**
- Selezione gruppo + drag = sposta tutto insieme (pattern file-explorer:
  clic su row già selezionato NON resetta la selezione finché non c'è mouseup
  senza drag; SMDnd.isDragging() esposto)
- Cancellazione cartella riporta le sue scene a root in coda
- Folder annidate NON supportate (folder_id_in_dest_folder filtrato lato Ruby)
- Bottoni Export / Settings presenti ma disabilitati (Fasi 3-4)

## Limite SU 2019 e scelta "ordine logico only"

`Sketchup::Pages` **non espone API pubblica per riordinare le pagine** in SU 2019.

**Soluzione adottata**: l'ordine vive solo come *ordine logico* in
`model.set_attribute('SceneManagerPlus', 'logical_order', [id, id, ...])`.
La lista è *mista* (uids di scene root + ids di cartelle). Le pagine native SU
restano nell'ordine di creazione — **e va bene così**: l'utente userà solo il
plugin per navigare scene, e l'export di Fase 4 leggerà direttamente dall'ordine
logico.

La "Sync to SketchUp" originariamente prevista è stata scartata perché sarebbe
stata destructive (cancella+ricrea pagine), rischiosa per lo stato per-pagina
(hidden geometry, layer states, section planes non sono facilmente preservabili
via API 2019), e non strettamente necessaria per il workflow dell'utente.

Ogni pagina riceve un `uid` stabile salvato come attributo `SceneManagerPlus/uid`,
così l'ordine logico e le cartelle sopravvivono a rinomine.

## Bridge Ruby ↔ JavaScript

JS chiama Ruby via `window.sketchup.<callback>(JSON.stringify(payload))`.
Ruby risponde via `dlg.execute_script("window.SM.setState(...)")` che
ri-renderizza tutta la lista (pattern unidirezionale, niente diff).

Callback registrate in `ui/dialog.rb`:

| Callback | Scopo |
|---|---|
| `sm_ready` | UI pronta, manda primo state |
| `sm_refresh` | force refresh state |
| `sm_reorder` | drop completato, riordina ordine logico |
| `sm_select_page` | attiva scena nel viewport |
| `sm_update_page` | salva name/desc/flags |
| `sm_update_from_view` | come bottone Update nativo |
| `sm_delete` | cancella scene selezionate |
| `sm_folder_create` | crea cartella vuota in coda al root |
| `sm_folder_update` | aggiorna name/color/expanded |
| `sm_folder_delete` | elimina (scene tornano a root in coda) |
| `sm_folder_toggle` | toggle expanded |
| `sm_log` | debug → `Ruby Console` |

Firma nuova `sm_reorder` (cambiata in Fase 2):
`{ ids: [], before_id: id|null, dest_folder_id: id|null }`. `dest_folder_id=null`
= root, altrimenti id cartella; `before_id=null` = append in coda.

## Installazione per test

Idealmente symlink/junction nella cartella Plugins di SU 2019 (PowerShell admin):

```powershell
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
New-Item -ItemType SymbolicLink -Path "$plug\scene_manager_plus.rb"  -Target "D:\Claude\SceneManager+\scene_manager_plus.rb"
New-Item -ItemType Junction     -Path "$plug\scene_manager_plus"     -Target "D:\Claude\SceneManager+\scene_manager_plus"
```

**Sulla macchina corrente i file sono copie reali** (non symlink/junction), quindi
dopo ogni modifica sincronizziamo con:

```powershell
$src = "D:\Claude\SceneManager+"
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
Remove-Item "$plug\scene_manager_plus" -Recurse -Force
Copy-Item "$src\scene_manager_plus.rb" "$plug\scene_manager_plus.rb" -Force
Copy-Item "$src\scene_manager_plus" "$plug\" -Recurse
```

⚠️ Trappola: `Copy-Item "$src\dir" "$plug\dir" -Recurse` quando `$plug\dir`
esiste annida `$plug\dir\dir\...`. Sempre rimuovere prima la destinazione.

Modifiche Ruby (.rb) → **riavvia SketchUp**.
Modifiche HTML/CSS/JS → basta chiudere+riaprire la finestra del plugin
(c'è il cache-bust su `index.html`).

Poi: SketchUp 2019 → menu **Plugins → Scene Manager+** (o icona toolbar).

## Lezioni Fase 4 (export + watermark)

### ⚠️ `Sketchup::ImageRep#set_data` su Windows: BGRA top-down, NON RGBA

Per 32 bpp, `set_data(w, h, 32, 0, buf)` su SU 2019 Windows si aspetta i byte
in ordine **BGRA** (DIB convention), NON RGBA. Sintomi se sbagli:
- Wood marrone diventa blu, e simmetricamente i blu diventano rossi (R↔B swap)
- Le righe NON vengono flippate (set_data legge top-down come io scrivo), quindi
  il logo non finisce capovolto a causa dei byte di base, MA…

Ordine corretto per ogni pixel:
```ruby
buf.setbyte(j,     c.blue)
buf.setbyte(j + 1, c.green)
buf.setbyte(j + 2, c.red)
buf.setbyte(j + 3, 255)
```

### ⚠️ `ImageRep#color_at_uv` usa convenzione OpenGL (v=0 in basso)

Se indicizzi top-down (riga 0 = top), devi flippare v:
```ruby
v = 1.0 - (dy + 0.5) / th.to_f
```
Altrimenti il logo finisce capovolto verticalmente nell'output (testo "ʇsɐıdǝp").

### ⚠️ `Sketchup.write_default` con stringhe JSON è inaffidabile in SU 2019

Salvare `'{"width":3840,"format":"jpg"}'` come singolo valore poteva non
persistere o ritornare valori vecchi alla lettura. **Schema robusto**: un
`write_default` per leaf, usando tipi nativi (Integer/Float/Boolean/String).
Vedi `Core::Settings#read_one`/`#write_one`. Chiave piatta `group.field`.

Pattern al read: booleani salvati con `write_default(..., true)` possono
ritornare come `1`/`0` in alcune build. Coercion difensiva:
```ruby
case default
when TrueClass, FalseClass
  return !!v if v.is_a?(TrueClass) || v.is_a?(FalseClass)
  return v.to_i != 0 if v.is_a?(Numeric)
end
```

### ⚠️ `PLUGIN_DIR` via Junction NON risale al repo

`File.expand_path('..', PLUGIN_DIR)` in deploy via Junction risale a
`%APPDATA%/.../Plugins/`, NON alla cartella di repo. **Bundle gli asset
DENTRO PLUGIN_DIR** (es. `scene_manager_plus/assets/`). Non usare `..`
per cercare risorse fuori dalla cartella plugin.

### ⚠️ `view.write_image(:scale_factor)` esiste solo in SU 2020+

Per Line Scale Multiplier su SU 2019 fallback: manipola
`model.rendering_options['EdgeWidth']` e `['ProfileWidth']` temporaneamente
prima del batch render, ripristina in `finish` (anche su cancel/errore).
Funziona solo se lo stile attivo ha edges/profili visibili.

### ⚠️ `view.write_image` per JPG apre la dialog "JPG Image Options"

Senza `compression:` esplicito. Sempre passare `compression: 0.9` (o altro)
per JPG così l'export è silent.

### ⚠️ Async step chain + multiple Save = on_done chiamato N volte

In un export asincrono (catena di `UI.start_timer`), serve:
1. `done_fired` (closure) per garantire chiamata singola a `on_done`
2. `stopped` flag per far ritornare immediatamente i timer già in coda
3. `@running` module-level per rifiutare export concorrenti

Senza queste guard, click multipli su Cancel o doppio click su Export
producevano N messagebox finali (uno per immagine in alcuni casi).

### ⚠️ Settings dialog con più Save buttons + push_state

`push_state` riscrive TUTTI i form da storage. Se l'utente modifica Export
ma clicca per errore il Save di Naming, le modifiche Export non salvate
vengono cancellate quando setState riscrive i campi. **Soluzioni adottate**:
1. **Auto-save** su input change per Export/Logo (debounce 350ms su testuali)
2. `setIfNotFocused` per non sovrascrivere il campo attualmente in editing
3. Niente più bottoni Save per Export/Logo (hint "Changes are saved automatically.")

Naming mantiene Save/Save & Rename perché ha semantica diversa (preview → apply).

### Smart output dir: Immagini / Superate / NN

Quando `export.output_dir` è vuoto:
- Caso A: `Immagini/` non esiste accanto al .skp → la crea, esporta lì
- Caso B: `Immagini/` esiste e ha file → crea `Superate/NN` con NN successivo
  (zero-padded 2 cifre), SPOSTA i file di `Immagini` lì, poi esporta in `Immagini`
- Caso C: `Immagini/` esiste vuota → esporta lì
- Se il .skp non è salvato → fallback al picker manuale

Le note di archivio entrano negli `errors` mostrati nel messagebox finale.

## Bug noti / risolti

### ✅ RISOLTO — `NameError: uninitialized constant SceneManagerPlus::UI::Command` (al primo load)

```
Error: #<NameError: uninitialized constant SceneManagerPlus::UI::Command>
.../scene_manager_plus/main.rb:10:in `<module:SceneManagerPlus>'
```

**Causa**: in `main.rb` riferivo `UI::Command`, `UI::Toolbar`, `UI.menu` dentro
`module SceneManagerPlus`. Ruby li risolveva come
`SceneManagerPlus::UI::Command` (perché esiste il sotto-modulo
`SceneManagerPlus::UI` definito in `ui/dialog.rb`), shadowando il top-level `::UI` di SketchUp.

**Fix**: prefissare con `::` per forzare il lookup top-level:

```ruby
cmd = ::UI::Command.new(PLUGIN_NAME) { SceneManagerPlus::UI::Dialog.show }
::UI.menu('Plugins').add_item(cmd)
toolbar = ::UI::Toolbar.new(PLUGIN_NAME)
```

Applicato. **Da verificare al riavvio di SU**.

### ✅ RISOLTO — Drop indicator invisibile durante il drag (CEF SU 2019)

**Sintomo:** Il `.drop-indicator` (linea blu di atterraggio del DnD) è presente
nel DOM (log lo conferma: parent corretto, dimensioni corrette, `display: block`,
top calcolato, z-index altissimo) ma **non si vede mai** durante il drag —
nemmeno una barra fucsia 8px appesa al `<body>` con `position: fixed`.

**Causa:** **CEF di SketchUp 2019 non ridipinge il DOM mentre è in corso un drag
HTML5 nativo** (`draggable=true` + `dragstart`/`dragover`/`drop`). Tutti gli
update visivi vengono congelati fino al rilascio del mouse → il drop-indicator
risulta inutilizzabile.

Una `<div>` fissa creata *fuori* dal drag flow è invece visibile normalmente,
quindi non è un problema di z-index/CSS/clipping: è proprio CEF che non
ridisegna durante il drag nativo.

**Fix:** Abbandonato il drag HTML5 nativo. `dnd.js` ora usa
`mousedown` (su row) + `mousemove`/`mouseup` (su `document`) con una soglia di
4px per distinguere click da drag. Durante mousemove il DOM è aggiornato e
**ridipinto normalmente**, indicatore visibile.

**Pattern:** In SU 2019 (e probabilmente in tutte le SU con CEF vecchia)
**evitare HTML5 native drag** per qualsiasi UI che debba dare feedback visivo
in tempo reale. Usare mouse/pointer events custom.

### ✅ RISOLTO — CEF carica vecchi JS/CSS dalla cache anche dopo edit

**Sintomo:** Modifico `dnd.js`, chiudo/riapro la finestra HtmlDialog, ma il
codice in esecuzione è ancora quello vecchio (log con marker `__SM_BUILD__`
non aggiornato).

**Fix:** `Dialog#prepare_index` genera a runtime un `index.cb.html` accanto
all'originale, riscrivendo i tag `<script src>` e `<link href>` con
`?v=<timestamp>`. CEF è obbligato a rileggere asset. Il temp file è gitignored.

### ✅ RISOLTO — `PAGE_USE_*` constants: nomi diversi per versione SU

`Sketchup::Page#update(mask)` accetta una bitmask di costanti top-level
`PAGE_USE_*`. **In SU 2019 i nomi differiscono dai docs SU recenti**.

Costanti che esistono in SU 2019: `PAGE_USE_CAMERA`,
`PAGE_USE_RENDERING_OPTIONS`, `PAGE_USE_SHADOWINFO`, `PAGE_USE_HIDDEN_LAYERS`,
`PAGE_USE_HIDDEN`, `PAGE_USE_SECTION_PLANES`, `PAGE_USE_ALL`.

Costanti che **NON esistono** in SU 2019: `PAGE_USE_STYLE`, `PAGE_USE_AXES`,
`PAGE_USE_HIDDEN_GEOMETRY`, `PAGE_USE_LAYER_VISIBILITY`,
`PAGE_USE_ACTIVE_SECTION_PLANES`.

Mappatura predicate → flag:
- `use_camera?` / `use_axes?` → CAMERA (gli assi seguono camera)
- `use_rendering_options?` / `use_style?` → RENDERING_OPTIONS (style è parte
  di rendering)
- `use_shadow_info?` → SHADOWINFO
- `use_hidden_layers?` → HIDDEN_LAYERS (o LAYER_VISIBILITY su SU recenti)
- `use_hidden?` → HIDDEN (o HIDDEN_GEOMETRY)
- `use_section_planes?` → SECTION_PLANES (o ACTIVE_SECTION_PLANES)

In `update_from_view` uso un lookup difensivo (`Object.const_defined?`) che
prova più nomi e prende quello presente. Vale anche `PAGE_USE_ALL`.

### ✅ RISOLTO — `NoMethodError: undefined method 'use_camera' for Sketchup::Page`

I flag di `Sketchup::Page` (`use_camera`, `use_hidden`, ecc.) hanno **getter con `?`**
e **setter senza** (convenzione predicate Ruby/SU). Non sono mai accessibili come
`page.use_camera` — fa esplodere il `flags_hash` se si fa `page.send(:use_camera)`.

```ruby
p.use_camera?           # => true/false   (getter, OK)
p.use_camera = true     # (setter, OK)
# p.use_camera          # ❌ NoMethodError
```

Vale per tutti i flag: `use_hidden?`, `use_hidden_layers?`, `use_style?`,
`use_shadow_info?`, `use_axes?`, `use_section_planes?`, `use_rendering_options?`.

Generalizzando: per qualsiasi predicate dell'API SU (`Entity#valid?`, `Group#locked?`,
`Drawingelement#visible?`, ecc.) ricordarsi del `?` quando si fa lookup dinamico via
`send`. La nostra costante `FLAG_KEYS` contiene i nomi *base* (per UI/JSON);
in Ruby costruiamo `"#{k}?"` per leggere e `"#{k}="` per scrivere.

### ✅ Completato in Fase 2-3

- UI cartelle collassabili con CRUD completo
- DnD scene↔cartelle e cartelle↔root
- Sync ordine logico → reale: **scartata** (utente non lo vuole, vedi sezione)
- Settings dialog + naming pattern + apply rename
- Properties dialog separato (dblclick → live commit)
- Defer mode (Core::Buffer)
- Previews persistenti + thumbnails inline + progress bar
- Sync scena attiva nativo → plugin (polling 250ms)
- ⟳ update-from-view per riga

### ⚠️ Da implementare in Fase 4

- Batch export PNG/JPG con naming pattern
- Watermark PNG via ChunkyPNG (embedded in `vendor/`)
- Watermark JPG fallback (overlay 2D temporaneo)
- Abilitazione delle sezioni Export e Logo nel Settings dialog (oggi disabled)

### ✅ RISOLTO — `dblclick` non scatta in CEF SU 2019 se render ricrea row

`makeSceneRow` in `app.js` viene chiamata ad ogni `setState` → la `<div.scene-row>`
viene rimossa e ricreata. Tra primo e secondo click di un dblclick, il target
elemento non è più lo stesso → CEF non emette `dblclick`.

**Tentativo fallito**: spostare il listener su `listEl` con event delegation.
Anche così non scatta affidabilmente.

**Soluzione adottata**: rilevamento manuale in `onRowClick` con timestamp
(`lastClickId` + `lastClickTs`, soglia 400ms, no modificatori). Se due
mousedown sulla stessa riga arrivano entro la soglia, triggeriamo
`SMBridge.openProperties(id)`.

### ⚠️ TRAPPOLA — `module_function` non rende il metodo respond_to-positive

```ruby
module Foo
  module_function
  def hello; "hi"; end
end
Foo.hello                # => "hi"   (OK, public module method)
Foo.respond_to?(:hello)  # => false  (perché module_function lo rende anche
                         #            private instance method)
```

Non usare `Module.respond_to?(:metodo_module_function)` per gating —
chiama direttamente. È un guard pattern che ho dovuto rimuovere da
SettingsDialog e PropertiesDialog quando il `Dialog.push_state` non veniva
chiamato.

### ⚠️ TRAPPOLA — `UI.start_timer(0, false)` da action_callback non affidabile

Tentativo di deferire `update_page` con `UI.start_timer(0, false) { ... }`
dentro una bridge callback: il timer non sempre fira in SU 2019.

Per progress bar previews uso una catena di timer `0.01s` (Previews.generate):
qui scatta. Forse il problema è `delay=0` esatto + callback context.
**Pattern sicuro**: delay >= 0.01, mai 0.

### ⚠️ TRAPPOLA — `Pages#add_frame_change_observer` non scatta sui tab clicks

In SU 2019 con scene transitions disabilitate (preferenze SU), il
`frame_change_observer` non emette `frameChange` quando l'utente clicca un
tab scena nativo. È pensato per le transizioni animate.

**Soluzione adottata**: polling `UI.start_timer(0.25, true)` che legge
`pages.selected_page` e confronta con `@last_active_uid`. Se cambia (e defer
è OFF), pusha `SM.setActiveFromNative(uid)` al dialog. Carico minimo.

Il polling viene attaccato in `Dialog.show` e fermato in `set_on_closed`.

### Pattern: intercettare click su sub-element prima di selezione/drag

Per il bottone ⟳ per-riga: la riga ha `mousedown` per selezione/drag (sia su
listener della row, sia via SMDnd attaccato a listEl).

```js
// CAPTURE phase: blocca prima che bubble raggiunga gli altri listener
listEl.addEventListener('mousedown', function (e) {
  if (!e.target.classList || !e.target.classList.contains('row-update')) return;
  e.stopPropagation();
  e.preventDefault();
}, true);
listEl.addEventListener('click', function (e) {
  if (!e.target.classList.contains('row-update')) return;
  e.stopPropagation();
  var row = e.target.closest('.scene-row');
  SMBridge.updateFromView(row.dataset.id);
});
```

Capture phase su listEl fira PRIMA degli handler bubble di SMDnd e dei row
mousedown listener. `stopPropagation` blocca tutto.

## Defer mode (Core::Buffer)

Quando attivo, le scritture vengono accumulate in RAM. Stato globale
(module-level var) in `core/buffer.rb`:

```ruby
@deferred       = bool
@page_edits     = { uid => { 'name'?, 'description'?, 'flags'? } }
@pending_delete = [uid, ...]
@folders        = lazy snapshot di Folders.all (mutato in place)
@order          = lazy snapshot di logical_order
@folders_dirty / @order_dirty = flag dirty
```

`SceneModel.update_page`, `delete_pages`, `set_logical_order` e
`Folders.all/save` controllano `Buffer.deferred?` e si comportano di
conseguenza. Display via `scene_hash` fa l'overlay degli edit; `tree` filtra
le pending-delete.

`Buffer.flush!` applica tutto in un'unica `model.start_operation`:
1) edit pagine, 2) erase pending-delete, 3) `Folders.write_raw`, 4)
`SceneModel.write_order_raw`. Singolo Ctrl+Z annulla tutto.

Eccezioni che restano immediate anche in defer mode:
- `select_page` (navigation) — bypassato lato JS (`if (!state.deferred)
  SMBridge.selectPage(id)`) e anche lato Ruby per sicurezza
- `update_from_view` (cattura viewport dipende dal qui-e-ora)

Auto-flush in `Dialog.set_on_closed`.

## Previews persistenti

`Core::Previews` salva PNG 480×300 in
`File.join(Dir.home, '.scene_manager_plus', 'previews', model_key, "#{uid}.png")`.

`model_key`: preferisce `Sketchup::Model#guid` (stabile per file SKP),
fallback hash MD5 del path.

Cache `@cache` in-memory ma idratata da disco via `refresh_from_disk!` al
prossimo `path_for`/`url_map`. Idempotente: se `model_key` non cambia non
rilegge.

Generazione asincrona: `generate(uids, on_progress:, on_done:)` usa catena
di `UI.start_timer(0.01, false)` per processare una scena per tick. Tra un
tick e l'altro CEF ridipinge la progress bar (importante: con delay 0
diretto, CEF non ridipinge → non vediamo progresso).

Salva e ripristina `pages.selected_page` e `view.camera` prima/dopo la
generazione.

## Sync scena attiva nativo → plugin

Polling 250ms in `Dialog#poll_active_scene`. Legge `pages.selected_page`,
confronta con `@last_active_uid`, se diverso esegue
`dlg.execute_script("SM.setActiveFromNative(uid)")`.

In defer mode il polling è no-op (la finestra è "isolata").

JS `setActiveFromNative` aggiorna `selection = [uid]`, render, e
`row.scrollIntoView({ block: 'nearest' })`. NIENTE bridge call back (no
infinite loop).

## Properties dialog (dblclick)

Live commit, niente Apply: name salva su Enter o blur, description su blur,
flag su change. `setState` da Ruby evita di sovrascrivere il campo se è
`document.activeElement` (no flicker durante digitazione).

`scene_payload` usa `SceneModel.scene_hash(p, uid)` che fa già l'overlay del
Buffer in defer mode, così il dialog mostra valori coerenti.

### Deploy locale (questa postazione)

- `%APPDATA%\SketchUp\SketchUp 2019\SketchUp\Plugins\scene_manager_plus` →
  **Junction** verso `C:\Claude\Sketchup Plugins\SceneManagerPlus\scene_manager_plus`.
  Gli edit ai sorgenti sono live (basta riavviare SU per ricaricare il Ruby).
- `scene_manager_plus.rb` (loader) è una **copia statica** — il symlink richiedeva
  admin, e questo file cambia raramente. Se lo modifichiamo, ricopiare manualmente.
- Icone: `clapboard.png` nel root del repo, copiato come
  `scene_manager_plus/ui/icons/scene_manager_{16,24}.png`.

## Modello dati cartelle (preview Fase 2)

```ruby
# salvato come JSON in model.attribute('SceneManagerPlus', 'folders')
[
  {
    "id": "f1", "name": "Sezioni", "color": "#4ea1ff",
    "expanded": true, "parent_id": null,
    "scene_ids": ["p123-abc", "p456-def"]
  },
  ...
]
```

Cartelle annidabili (`parent_id`). Scene non in nessuna cartella vivono al root.
L'ordine root è quello di `Core::SceneModel.logical_order`.

## Settings (preview Fase 3)

Vedi `core/settings.rb` per i defaults. Tre gruppi: `naming`, `export`, `logo`.
Pattern naming: `{prefix}{sep}{nnn}{sep}{scene_name}` con `prefix_mode` =
`skp_name` | `custom` | `none`.

## Note per future sessioni

- Lavoro condiviso tra postazioni → utente continuerà da un'altra macchina.
- Lingua di interazione con l'utente: **italiano**.
- L'utente preferisce sviluppo **per fasi con verifica intermedia**, non big-bang.
- Niente preview scene nel pannello (esplicita richiesta per performance).
- Watermark JPG: overlay 2D temporaneo confermato come fallback accettabile.
