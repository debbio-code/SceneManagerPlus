# Scene Manager+ — SketchUp 2019 Plugin

Plugin di gestione scene avanzata per SketchUp 2019, in stile "livelli Photoshop":
lista scene riordinabile, cartelle, batch export con watermark logo, naming pattern.

## Stato attuale: Fase 4 completata

Sviluppo in 4 fasi:

1. **Fase 1 — Scaffolding + finestra base con lista scene + selezione/DnD** ✅
2. **Fase 2 — Cartelle (logiche + DnD scene↔cartelle)** ✅
3. **Fase 3 — Settings + naming pattern + Properties dialog** ✅
4. **Fase 4 — Batch export + watermark** ✅

Feature aggiunte fuori-fase (Fase 3):
- **Defer mode** (`Core::Buffer`): tutte le scritture vivono in RAM, un solo
  flush a SU. Bottone in toolbar, auto-flush alla chiusura.
- **Per-scene previews** (`Core::Previews`): PNG persistenti per-modello
  (`~/.scene_manager_plus/previews/<model_guid>/`). Generazione asincrona con
  progress bar.
- **Inline thumbnails** nella lista (toggle Thumbs).
- **Polling 250ms** per syncare in plugin la scena attivata da tab nativi SU.

Feature aggiunte post-Fase 4:
- **Style letter badge** per-row al posto di ⟳: mostra A,B,C... (alfabetico
  su tutti gli stili del modello). Click sx → mini Style Manager; click dx →
  picker per riassegnare lo stile. Vedi "Style management" più in basso.
- **Update from view in toolbar**: l'icona ⟳ è stata spostata dalla row al
  bottone `btn-update` della toolbar, ora opera sulla selezione (anche
  multipla). La row ha solo la lettera stile, non più due trigger di update.

## Documentazione di supporto

- **`docs/SU2019-LESSONS.md`** — Gotcha e pattern di SU 2019 (BGRA pixel
  order, CEF cache, `PAGE_USE_*` per versione, `module_function`, ecc.).
  Consultare quando si tocca composite/export, CEF/HtmlDialog, predicate
  API, settings UI.
- **`docs/RESOLVED-BUGS.md`** — Cronologia bug risolti con sintomo/causa/
  fix. Consultare se un problema "suona familiare", o per capire perché un
  pattern strano nel codice è strano.

## Decisioni di design

| Tema | Scelta |
|---|---|
| UI | `UI::HtmlDialog` (CEF, SU 2017+) — niente WebDialog legacy |
| Stile finestra principale | `STYLE_UTILITY` (palette sempre sopra viewport, posizione+dimensione persistite affidabilmente — `STYLE_DIALOG` non salva la posizione su SU 2019). Auto-riaprire all'avvio se era aperta (flag `main_dialog_open` via `write_default`, ri-show con timer 0.5s dopo `file_loaded`). Settings/Properties restano `STYLE_DIALOG` (sono modali-ish). |
| Navigazione tastiera | `PageUp`/`PageDown`/`Home`/`End` scorrono la selezione lungo l'ordine logico visibile (cartelle chiuse saltate). `ArrowUp`/`ArrowDown` invece **spostano** la selezione (singola o multi-contigua sotto lo stesso parent) nell'ordine logico. Non c'è modo pulito in SU 2019 di hijacker i tasti globalmente, quindi fuori dal plugin resta il comportamento nativo. |
| Nuova scena da vista | Icona toolbar (📷+) → `SceneModel.add_from_view`. Replica gli override di visibilità layer della pagina attiva (vedi sotto, "Add visible tag"). **Forza tutti gli 8 `FLAG_KEYS` (use_camera, use_style, ecc.) a `true`** dopo `pages.add`, così la nuova scena cattura sempre lo state completo del viewport — `pages.add` da solo rispetta i "Default Scene Properties" globali di SU e se l'utente li ha personalizzati (es. Style/Fog OFF) la scena nascerebbe monca. Scelta UX: il flusso del plugin è "scatta foto completa", non "rispetta i miei default SU". |
| Update da view (`⟳`) | `SceneModel.update_from_view(id)` costruisce una bitmask `PAGE_USE_*` con lookup difensivo (vedi `docs/SU2019-LESSONS.md`). Per `use_style?` tenta `PAGE_USE_STYLE` → `PAGE_USE_SKETCHCS` → `PAGE_USE_RENDERING_OPTIONS` (fallback piggyback). Per `use_axes?` tenta `PAGE_USE_AXES` → `PAGE_USE_CAMERA`. Script `tools/dump-page-use.rb` per verificare i nomi delle costanti effettivamente esposte dalla SU in uso. **Se lo stile attivo è dirty** (`styles.active_style_changed`), mostra un `UI.messagebox` 3-button YES/NO/CANCEL equivalente al "Warning - Scenes and Styles" nativo: YES → `update_selected_style` poi page.update; NO → mostra istruzioni per "Save as new" via browser (l'API Ruby SU 2019 non lo espone) e abort; CANCEL → toglie il bit style dal mask, salva il resto. Senza questo dialog le modifiche pending allo stile si perdono silenziosamente: `page.update(PAGE_USE_SKETCHCS)` lega la scena allo stile ma non lo flusha. UI: il trigger ⟳ vive nella toolbar (`btn-update`), opera su selezione (anche multipla con loop client-side). Niente più icona update per-row: quello slot è occupato dal badge lettera stile. |
| Style letter badge | Sostituisce la vecchia ⟳ per-row. Mostra A,B,C... derivato da `SceneModel.styles_map` (ordine alfabetico su `model.styles.map(&:name)`, **tutti** gli stili, anche orfani). Per-scena `scene.style_name` da `page.style.name`. JS lookup via `letterForStyle()` → '?' se manca. Render solo (zero interazione di update): click sx apre mini Style Manager, click dx apre picker riassegna. |
| Style assignment (click dx lettera) | `SceneModel.assign_style(uid, name)` attiva la target page, fa `styles.selected_style = X`, forza `use_style/use_rendering_options = true`, `page.update(STYLE_BIT \| RO_BIT)`, ripristina la scena attiva precedente. Tutto in una `start_operation` (1 Ctrl+Z). Immediato anche in defer mode (operazione viewport-dipendente, analoga a `update_from_view`). Side-effect noto: se lo stile precedente era dirty, le pending si perdono (come comportamento native SU). |
| Mini Style Manager (click sx lettera) | `UI::StyleDialog` (`STYLE_DIALOG`) con 3 gruppi: **Edges** (`EdgeColorMode` 0/1/2 = All same/By material/By axis — è il colore *delle linee*, non delle facce; `TransparencySort` 0/1/2); **Background** (`BackgroundColor`, `DrawHorizon` on/off, `SkyColor`); **Display** (`DrawHidden`, Model axes toggle, `DisplaySectionPlanes`, `DisplaySectionCuts`). Edit live → `rendering_options[k] = v` + `styles.update_selected_style` per committare al persistente. All'apertura, la scena di contesto viene attivata nel viewport per feedback live. **Scope sempre = "all scenes using this style"**: niente "only this scene" perché l'API Ruby SU 2019 non espone `style.name=` né `Styles#add_style` da memoria, quindi clonare programmaticamente uno stile non è fattibile pulitamente. Banner nel dialog spiega il workaround manuale: duplicare lo stile in Window → Styles nativo, poi riassegnare via right-click su lettera. **Model Axes è bottone Toggle**, non checkbox: SU 2019 non espone state né setter per il display degli assi nemmeno via `RenderingOption` né via `model.options` (verificato enumerando ogni provider/chiave). Implementato via `Sketchup.send_action(axes_cmd_id)` con `WIN_AXES_CMD_ID = 10522` su Windows (override `Sketchup.write_default('SceneManagerPlus', 'axes_cmd_id', N)`); Mac selector `'showHideAxes:'`. |
| Rinomina inline | Right-click su scena → context menu → "Rename" → input nella row, Enter = commit, Esc/blur-senza-modifiche = annulla. |
| Selezione vs scena attiva | Due stati **distinti** nel JS: `selection` (array, barra azzurra, può essere multipla) e `activeId` (singolo, marker giallo sul `.grip`, = scena effettivamente nel viewport). `push_state` invia `active_id` dal `pages.selected_page` di Ruby. `setActiveFromNative` (polling 250ms) aggiorna SOLO `activeId`, mai la selezione (prima la collassava all'uid, e ogni cambio tab nativo distruggeva la multi-selezione). Helper `selectPageLocal(id)` per i click/keynav: in **defer mode è no-op** (la scena nel viewport non cambia → il giallo non deve seguire la selezione), altrimenti setta `activeId` e chiama `SMBridge.selectPage` per feedback immediato senza attendere il polling. **Ordine obbligatorio nei handler keynav (PageUp/Down/Home/End) e click**: `selectPageLocal(id)` PRIMA di `render()`, perché `selectPageLocal` muta `activeId` ma non re-renderizza; se invertito, il marker giallo resta sulla scena precedente fino al successivo `push_state` (lag di 1 step). |
| Preview thumbnail | 300×150 (stesso aspect ratio dell'export finale). Durante batch generation: transizioni scena disabilitate, antialias off, yield a CEF batched ogni ~total/25 scene. Cache-buster `?t=` bumpato solo a cambio set chiavi o fine-generazione, non a ogni `setState`. |
| Cartelle | Solo logiche (ordine in `model.attribute`), no sync alle pagine native (vedi sotto) |
| Formati export | PNG + JPG |
| Watermark | Composizione via `Sketchup::ImageRep` (PNG + JPG unificati). ChunkyPNG scartato, niente `vendor/`. Logo bundled in `scene_manager_plus/assets/default_logo.png` |
| Persistenza cartelle/ordine | Attributi sul `Sketchup.active_model` (vivono col file SKP) |
| Persistenza settings | `Sketchup.write_default` per-leaf (vedi `SU2019-LESSONS.md`) |
| Lingua UI | Inglese (UX standard) |
| Preview scene | NON implementata nel pannello, per richiesta utente (no rallentamento refresh). Esiste come thumbnails inline opzionali. |
| Export-include per-scena | Checkbox in row (tra ⟳ e idx). Flag persistente come page attribute `SceneManagerPlus/export_included` (default true). Filtra solo scope `'all'` in `Exporter.collect_targets`; scope `selected` e `folders` lo ignorano per design. Click su checkbox di scena in multi-selezione → bulk: target = `!tutte_incluse` (mixed→tutte; all-on→all-off). Singola `start_operation` per il bulk = un Ctrl+Z. **Numerazione `{nnn}` / "Tavola nr." mantiene i buchi** (es. escludendo la 3 i numeri sono 1,2,4,5): l'index resta la posizione 1-based in `Naming.ordered_scene_pairs` (ordine logico globale), non un counter sui soli target — la posizione tavola resta stabile a prescindere dall'inclusione. |

## Struttura repo

```
scene_manager_plus.rb               # loader, registra l'extension
scene_manager_plus/
├── main.rb                         # entry point: menu + toolbar + comando
├── assets/default_logo.png         # logo bundled per watermark
├── assets/styles/                  # pool slot_NN.style bundled (vedi sez. "Style pool + nickname")
├── assets/titleblock/              # asset bundlati per il cartiglio
│   ├── company.txt                 # 4 righe dati aziendali
│   └── logo.jpg                    # logo aziendale per il cartiglio
├── core/
│   ├── buffer.rb                   # Defer mode: stato globale edit in RAM + flush!
│   ├── exporter.rb                 # Batch export PNG/JPG + watermark + titleblock via ImageRep
│   ├── folders.rb                  # cartelle logiche (schema + load/save)
│   ├── naming.rb                   # format/preview/apply_rename pattern
│   ├── previews.rb                 # cache PNG anteprime per-modello persistente
│   ├── scene_model.rb              # wrapper su Sketchup.active_model.pages
│   ├── settings.rb                 # config persistente con defaults
│   ├── styles.rb                   # pool slot + nickname per-modello
│   ├── text_render.rb              # PowerShell+System.Drawing per filename label
│   └── titleblock.rb               # PowerShell+System.Drawing per cartiglio
└── ui/
    ├── dialog.rb                   # Main HtmlDialog + bridge + polling scene attiva
    ├── export_dialog.rb            # Dialog Export (scope picker + progress)
    ├── properties_dialog.rb        # Dialog Properties singola scena (dblclick)
    ├── settings_dialog.rb          # Dialog Settings (naming + export + logo)
    ├── style_dialog.rb             # Mini Style Manager (click lettera badge)
    └── html/
        ├── index.html              # finestra principale
        ├── export.html             # finestra Export
        ├── properties.html         # finestra Properties
        ├── settings.html           # finestra Settings
        ├── style.html              # finestra Mini Style Manager
        ├── css/{style,export,properties,settings,style_dialog}.css
        └── js/
            ├── app.js              # logica lista, selezione, defer, thumbs
            ├── bridge.js           # window.SMBridge → sketchup.<callback>
            ├── dnd.js              # drag&drop custom (no HTML5 native)
            ├── export.js           # logica dialog Export
            ├── properties.js      # logica dialog Properties (live commit)
            ├── settings.js         # logica dialog Settings
            └── style_dialog.js     # logica Mini Style Manager (window.SMS)
```

## Limite SU 2019 e scelta "ordine logico only"

`Sketchup::Pages` **non espone API pubblica per riordinare le pagine** in SU 2019.

**Soluzione adottata**: l'ordine vive solo come *ordine logico* in
`model.set_attribute('SceneManagerPlus', 'logical_order', [id, id, ...])`.
La lista è *mista* (uids di scene root + ids di cartelle). Le pagine native SU
restano nell'ordine di creazione — **e va bene così**: l'utente usa solo il
plugin per navigare scene, e l'export legge dall'ordine logico.

La "Sync to SketchUp" originariamente prevista è stata scartata: sarebbe
stata destructive (cancella+ricrea pagine), rischiosa per lo stato per-pagina
(hidden geometry, layer states, section planes non sono facilmente preservabili
via API 2019), e non strettamente necessaria per il workflow dell'utente.

Ogni pagina riceve un `uid` stabile salvato come attributo `SceneManagerPlus/uid`,
così l'ordine logico e le cartelle sopravvivono a rinomine.

## Compatibilità con "Add visible tag" del plugin Layers Manager

Il plugin Layers Manager espone "Add visible tag" — un tag visibile solo
nella scena attiva, ottenuto creando il layer globalmente hidden e
aggiungendolo alla hidden-list (`page.layers`) di tutte le altre pagine
esistenti. `Sketchup::Pages#add` di SU snapshotta solo la visibilità a
livello modello, quindi questi tag spariscono dalle nuove scene.

`SceneModel.add_from_view` risolve questo: cattura `selected_page` prima
di `pages.add`, poi per ogni `model.layers` chiama
`new_page.set_visibility(layer, !active.layers.include?(layer))` —
allinea la visibilità *effettiva* della nuova scena a quella che il
viewport sta renderizzando. Vedi `docs/SU2019-LESSONS.md` (sezione
"Sketchup::Page#layers in SU 2019") per la semantica esatta — è
controintuitiva (è la lista degli hidden, non degli "override").

Se in futuro aggiungiamo altri punti che creano scene da view (es.
"Duplicate scene"), riusare la stessa logica.

## `state.scenes` vs `state.tree` — due payload da tenere allineati

In `push_state` (`ui/dialog.rb`) il JS riceve due rappresentazioni delle
scene: `state.scenes` (flat list, da `SceneModel.list_ordered`) e
`state.tree` (albero misto folder+scene, da `SceneModel.tree`, che internamente
usa `scene_hash`). Il render legge dal tree; lookup come `sceneById(id)` in
`app.js` leggono invece da `state.scenes`.

**Trappola**: i due builder devono includere gli stessi campi che il JS
consulta. Già successo con `export_included`: il bulk toggle in
multi-selezione confrontava `state.scenes[i].export_included !== false` e
con il campo mancante il check restituiva sempre `true` (undefined !== false),
quindi `allIncluded` era sempre true e il toggle poteva solo escludere, mai
re-includere. Fix: tenere `list_ordered` allineato a `scene_hash` su tutti i
campi che il JS può leggere via `sceneById` (oggi: `export_included`,
`flags`, `name`, `description`, `style_name`).

Se in futuro si aggiungono attributi per-scena letti dal JS lato bulk/state,
metterli in entrambi (o far convergere `list_ordered` a riusare `scene_hash`).

## Bridge Ruby ↔ JavaScript

JS chiama Ruby via `window.sketchup.<callback>(JSON.stringify(payload))`.
Ruby risponde via `dlg.execute_script("window.SM.setState(...)")` che
ri-renderizza tutta la lista (pattern unidirezionale, niente diff).

Callback principali in `ui/dialog.rb`:

| Callback | Scopo |
|---|---|
| `sm_ready` | UI pronta, manda primo state |
| `sm_refresh` | force refresh state |
| `sm_reorder` | drop completato, riordina ordine logico |
| `sm_select_page` | attiva scena nel viewport |
| `sm_update_page` | salva name/desc/flags |
| `sm_update_from_view` | come bottone Update nativo |
| `sm_delete` | cancella scene selezionate |
| `sm_folder_create` / `_update` / `_delete` / `_toggle` | CRUD cartelle |
| `sm_assign_style` | riassegna stile a scena (`{ id, style_name }`) |
| `sm_open_style` | apre Mini Style Manager (`{ id, style_name }`) |
| `sm_log` | debug → `Ruby Console` |

Firma `sm_reorder`: `{ ids: [], before_id: id|null, dest_folder_id: id|null }`.
`dest_folder_id=null` = root; `before_id=null` = append in coda.

`SettingsDialog`, `PropertiesDialog`, `ExportDialog`, `StyleDialog` registrano i
propri callback (prefissi `sm_settings_*`, `sm_properties_*`, `sm_export_*`,
`sm_style_*` rispettivamente).

## Installazione e deploy locale

**Macchina dev (questa postazione)**: i file in
`%APPDATA%\SketchUp\SketchUp 2019\SketchUp\Plugins\scene_manager_plus`
sono **copie reali**, non junction (admin privileges non disponibili sempre).

**Claude esegue automaticamente la copia** dopo ogni modifica al codice del
plugin (anche dopo `git pull` che tocca file del plugin), senza chiedere
conferma. Comando da eseguire:

```powershell
$src = "C:\Claude\Sketchup Plugins\SceneManagerPlus"
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
Remove-Item "$plug\scene_manager_plus" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$plug\scene_manager_plus.rb" -Force -ErrorAction SilentlyContinue
Copy-Item "$src\scene_manager_plus.rb" "$plug\scene_manager_plus.rb" -Force
Copy-Item "$src\scene_manager_plus" "$plug\" -Recurse
```

- Modifiche **Ruby (.rb)** → **avvisare l'utente di riavviare SketchUp**.
- Modifiche **HTML/CSS/JS** → basta chiudere+riaprire la finestra del plugin
  (c'è cache-bust su `index.html` / `settings.html` / `properties.html` /
  `style.html` / `export.html`).

Per il deploy ideale via symlink/junction (richiede admin) e altre note vedi
`docs/SU2019-LESSONS.md` (sezione "Deploy / packaging").

Avvio: SketchUp 2019 → menu **Plugins → Scene Manager+** (o icona toolbar).

## Defer mode (`Core::Buffer`)

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
- `select_page` (navigation)
- `update_from_view` (cattura viewport dipende dal qui-e-ora)
- `assign_style` (modifica `styles.selected_style` + `page.update` con bit STYLE,
  dipende dal qui-e-ora come `update_from_view`)
- Mini Style Manager (`StyleDialog.apply_changes`): edit live, scrive
  `rendering_options` + `styles.update_selected_style` immediatamente

Auto-flush in `Dialog.set_on_closed`.

## Previews persistenti

`Core::Previews` salva PNG 480×300 in
`~/.scene_manager_plus/previews/<model_key>/<uid>.png`.

`model_key`: preferisce `Sketchup::Model#guid` (stabile per file SKP),
fallback hash MD5 del path.

Cache in-memory idratata da disco al primo accesso (`refresh_from_disk!`).
Idempotente: se `model_key` non cambia non rilegge.

Generazione asincrona: `generate(uids, on_progress:, on_done:)` usa catena
di `UI.start_timer(0.01, false)` per processare una scena per tick (con
delay 0 diretto, CEF non ridipinge la progress bar).

Salva e ripristina `pages.selected_page` e `view.camera` prima/dopo.

## Sync scena attiva nativo → plugin

Polling 250ms in `Dialog#poll_active_scene`. Legge `pages.selected_page`,
confronta con `@last_active_uid`, se diverso esegue
`dlg.execute_script("SM.setActiveFromNative(uid)")`. In defer mode il polling
è no-op.

Polling attaccato in `Dialog.show` e fermato in `set_on_closed`.

(`Pages#add_frame_change_observer` NON funziona per i tab clicks — vedi
`SU2019-LESSONS.md`.)

## Properties dialog (dblclick)

Live commit, niente Apply: name salva su Enter o blur, description su blur,
flag su change. `setState` da Ruby evita di sovrascrivere il campo se è
`document.activeElement` (pattern `setIfNotFocused`).

`scene_payload` usa `SceneModel.scene_hash(p, uid)` che fa già l'overlay del
Buffer in defer mode, così il dialog mostra valori coerenti.

## Settings dialog

Tre sezioni: `naming`, `export`, `logo`. Tutte **auto-save** (debounce 350ms
sui campi testuali, immediato su checkbox/select). Naming espone in più un
bottone "Rename scenes now" per l'apply action.

Vedi `core/settings.rb` per i defaults.

Pattern naming: `{prefix}{sep}{nnn}{sep}{scene_name}` con `prefix_mode` =
`skp_name` | `custom` | `none`.

## Export — smart output dir: `Immagini` / `Superate/NN`

Quando `export.output_dir` è vuoto:
- **Caso A**: `Immagini/` non esiste accanto al `.skp` → la crea, esporta lì
- **Caso B**: `Immagini/` esiste e ha file → crea `Superate/NN/` con NN
  successivo (zero-padded 2 cifre), SPOSTA i file di `Immagini` lì, poi
  esporta in `Immagini` ora svuotata
- **Caso C**: `Immagini/` esiste vuota → esporta lì
- Se il `.skp` non è salvato → fallback al picker manuale

Le note di archivio entrano negli `errors` mostrati nel messagebox finale.

## Modello dati cartelle

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

Cartelle annidabili nel modello (`parent_id`), ma UI/DnD oggi filtra le
nested. Scene non in nessuna cartella vivono al root. L'ordine root è
quello di `Core::SceneModel.logical_order`.

## Filename label sull'export

Stampa il nome file (senza estensione) in basso-sx dell'immagine esportata.
Settings group `filename_label` (font_family, font_size, bold, color hex,
offset_x/y, opacity).

- **Render testo**: `Core::TextRender.render_batch` lancia PowerShell +
  `System.Drawing` (font/size/colore real). Una sola spawn per export
  (rende tutte le label in batch, una PNG ciascuna). Spawn **nascosta**
  via `WScript.Shell.Run(cmd, 0, true)` — niente flash di console.
  Fallback a `system()` se Win32OLE non c'è.
- **Composite**: `Core::Exporter.apply_overlays(image_path, specs)` sostituisce
  il vecchio `apply_watermark` e gestisce logo + label in **un solo**
  load/blend/save → su JPG niente doppia ri-codifica quando entrambi attivi.
  Le spec hanno `anchor_x` (`:left`/`:right`), `anchor_y` (`:top`/`:bottom`),
  `offset_x/y`, opzionale `width_pct` per scalare, `opacity`.
- **Color picker**: `<input type="color">` in CEF di SU 2019 è inaffidabile
  (accetta solo hex lowercase, `#FFFFFF` viene rifiutato silenziosamente
  e l'input rimane a `#000000`; il `change` event non sempre scatta).
  Usato invece input testuale hex + swatch + 6 preset clickabili
  (vedi `settings.html` group-filename-label). Sempre lowercase.

## Settings: persistenza per-file (model attributes)

Tutti i settings viaggiano col file `.skp` via `model.set_attribute` /
`model.get_attribute` (dict `'SceneManagerPlus_cfg'`). Non più
`Sketchup.write_default` (era globale per macchina).

- `read_one`: legge da `model.get_attribute`, ritorna `default` se `nil`.
- `write_one`: scrive su `model.set_attribute` con coercizione di tipo.
- Se `Sketchup.active_model` è `nil`: no-op / ritorna default.

La costante `SECTION = 'SceneManagerPlus'` non è più usata per i settings
(resta per folder/order/uid page attributes).

## Title block (cartiglio) sull'export

`Core::TitleBlock` aggiunge un cartiglio sotto l'immagine esportata
(estende il canvas verso il basso, NON copre l'immagine). Coesiste
indipendente da logo watermark e filename label.

Layout 6 box (left → right):
1. **Cliente** (top) / **Oggetto** (bottom, merged) — box 0. Cliente =
   `naming.prefix_custom`. Oggetto = `page.name`. CLIENTE è nella sola riga
   superiore del box 0; OGGETTO si estende su tutta la larghezza di box 0 +
   box 1b (riga inferiore unificata).
1b. **Fase di progetto** — box 1b, solo riga superiore. Label "PROGETTO:"
   (midLabelFont bold), valore scelto nei settings tra "Preliminare",
   "Definitivo", "Esecutivo" (midValueFont regular). Centrata in [0, halfH].
   Il divisore verticale tra box 0 e box 1b è **parziale** (0..halfH), così
   la riga OGGETTO non viene spezzata.
2. **Tavola nr. / Data** — MID font (`midRatio = 0.82` × labelSz/valueSz),
   block centrato come unità nel box; label "TAVOLA nr.:" e "DATA:"
   alla stessa X, valore inline dopo. Tavola = stesso `{nnn}` del naming
   pattern padded. Data = `Time.now.strftime('%d/%m/%Y')` o override da
   `titleblock.date_override`.
3. **Progetto / Disegnato e controllato da** — stessi MID font del box 2.
4. **Dati aziendali** — bundlato in `assets/titleblock/company.txt`. Prima
   riga in `boldFont`, le altre in `smallFont`. Interlinea compatta
   (`lineHeight = smallSz`, no descent intero), blocco centrato verticalmente.
   Tutte le righe left-aligned alla stessa X.
5. **Logo** — bundlato in `assets/titleblock/logo.jpg`, 10% di W fissa.

**Trappola `$halfH` prima del loop bordi**: nel PS script `$halfH` DEVE essere
definito PRIMA del loop che disegna i divisori verticali (che usa `$halfH` per
il divisore parziale del box 1b). Se definito dopo, la riga parziale viene
disegnata da 0 a 0 (invisibile). Già successo — `$halfH = [int]($H / 2)` va
subito dopo `$g.FillRectangle`.

**Divisore verticale parziale** (pattern per celle unite):
```powershell
if ($i -eq 0) {
  $g.DrawLine($borderPen, $xAccum, 0, $xAccum, $halfH)  # solo metà
} else {
  $g.DrawLine($borderPen, $xAccum, 0, $xAccum, $H)
}
```

Assets bundlati in `scene_manager_plus/assets/titleblock/`:
`company.txt` (4 righe), `logo.jpg`. Letti da
`Settings.titleblock_company_txt_path` / `Settings.titleblock_logo_path`
(percorsi sotto `PLUGIN_DIR` per funzionare anche su Junction install).

**Auto-size dei box**: Logo fisso 10%; box 1b/2/3/4 = larghezza testo
× `boxBreath` (1.15, "respiro" 15%) + 2×pad; box 0 (Cliente) = remainder.

**Font global auto-shrink**: il calcolo larghezze gira in loop. Se
`sum(box widths) > target`, scala TUTTI i font -1px e ricalcola.
Mid font ricreati al volo a `labelSz × midRatio`. Ferma quando entra
o a `valueSz ≤ 10`. Iters tipico 5-10.

**Cross-box baseline alignment**: `bY_top` e `bY_bot` calcolati una sola
volta sul `labelFont`/`valueFont` (box 1, font più grande). Tutti i
testi degli altri box vengono posizionati a `bY - propria_ascent`
(via `Get-Asc`, che calcola ascent in pixel da `FontFamily.GetCellAscent
/ GetEmHeight × Font.Size`). Così la riga superiore di tutti i box ha
la stessa baseline anche con font size diverse.

**Render**: `Core::TitleBlock.render_batch` — singola spawn PowerShell
in batch (uno per scena, cambia solo Cliente/Tavola/Oggetto). Stesso
pattern hidden-spawn di `TextRender`.

**Composite**: `Exporter.append_titleblock(image_path, tb_png_path)`
estende il canvas verso il basso. Carica image base + titleblock,
costruisce buffer BGRA top-down `bw × (bh + th)`, copia base nella parte
superiore e titleblock in quella inferiore, salva via `ImageRep.set_data`
+ `save_file`. Applicato DOPO `apply_overlays` così logo+label restano
nell'immagine originale.

**Trappola PS case-insensitive**: PowerShell tratta `$w` e `$W`,
`$h` e `$H` come la STESSA variabile. Mai usare `$w` come temp se in
scope esterno c'è `$W` (width canvas) — collassa width totale a un
numero piccolo e l'output viene schiacciato. Usare `$ww`, `$bw`, ecc.
Già successo due volte durante lo sviluppo del cartiglio.

## Line scale multiplier

Due moltiplicatori separati nei settings:
- `export.line_scale_multiplier` (default 2.0): applicato durante l'export.
- `preview.line_scale_multiplier` (default 1.0): applicato durante la
  generazione thumbnail 300×150.

Pattern (SU 2019 senza `scale_factor` in write_image): si mutano
temporaneamente `RenderingOptions['EdgeWidth']` e `['ProfileWidth']` e si
ripristinano in `finish`. **Trappola**: se la scena ha
`PAGE_USE_RENDERING_OPTIONS`, SU al `pages.selected_page = page` ripristina
i valori salvati nella scena, sovrascrivendo la modifica fatta prima del
loop. Soluzione: settare EdgeWidth/ProfileWidth **dentro lo step**, dopo
`pages.selected_page = page` e prima di `view.write_image` (sia in Exporter
sia in Previews).

**Limite noto sulle thumbnails**: anche con il fix sopra, il line scale
multiplier sulle thumbnail **non sembra produrre cambio visibile**, mentre
sull'export funziona. Ipotesi non confermata: a 300×150 con
`antialias: false` la rasterizzazione di SU clampa la line width a 1px.
Va indagato più a fondo — per ora il moltiplicatore Thumbnails è esposto
ma di fatto inefficace.

## `add_from_view` e visibilità layer — risolto (2026-05)

Storia in due atti.

**Atto 1 — drift da toggle manuale**: quando l'utente toggla un layer dal
Layer Manager dopo aver attivato una scena, SU 2019 aggiorna
`layer.visible?` ma NON sincronizza `page.layers` (override stale). Il
viewport in caso di drift mostra sempre `layer.visible?`. Confermato con
diag in entrambe le direzioni (accensione e spegnimento) sul modello
Pedrazzoli.

**Atto 2 — `pages.add` muta il model**: il Layers Manager registra un
observer su `pages.add` che, per i layer con "Add visible tag" attivo
(globally visible quando la AVT-page è attiva), durante l'add:
1. Riporta `layer.visible? = false` (model)
2. Aggiunge il layer alla hidden list della nuova scena

Quindi tra PRE e POST `pages.add` lo stato del modello cambia. Nessuna
formula calcolata POST-add può ricostruire la visibilità effettiva del
viewport PRE-add.

**Fix applicato** in `SceneModel.add_from_view`:
1. **Prima** di `pages.add`, snapshottare `layer.visible?` di tutti i
   layer (= ciò che il viewport sta mostrando).
2. Dopo `pages.add`, ripristinare il model state per i layer dove
   l'observer LM ha sbragato, e applicare lo stesso state alla nuova
   page via `page.set_visibility`.

Questo gestisce contestualmente sia AVT sia il drift da toggle manuale:
in entrambi i casi la fonte di verità è `layer.visible?` PRE-add.

Tabella di verità chiusa:

| Caso                          | visible? PRE | in active.layers | viewport | new page |
|-------------------------------|--------------|------------------|----------|----------|
| Layer normale hidden          | F            | T                | F        | F ✓      |
| Layer normale visible         | T            | F                | T        | T ✓      |
| AVT (Add Visible Tag)         | T            | F                | T        | T ✓      |
| Utente accende layer hidden   | T            | T (stale)        | T        | T ✓      |
| Utente spegne layer visible   | F            | F (stale)        | F        | F ✓      |

## Workaround Scene Tabs visibili dopo riapertura file (SU 2019)

Bug noto SU 2019: se chiudi un file con Scene Tabs OFF, alla riapertura le
tabs restano visibili nel viewport anche se nel menu `View → Scene Tabs`
risultano off. Workaround manuale: clicca la voce nel menu (accende — no
effetto visibile per il bug) e ricliccala (spegne davvero).

Riprodotto in `Dialog#force_hide_scene_tabs_if_enabled` con due
`Sketchup.send_action(10534)` consecutivi. Opt-in via Settings → Interface
→ "Force Scene Tabs OFF when the plugin opens" (default false: chi vuole
le tabs ON non vuole vederle nascoste da noi). Override dell'ID via
`Sketchup.write_default('SceneManagerPlus', 'scene_tabs_cmd_id', N)`.

### Come trovare command IDs su SU 2019 Windows

Trimble non documenta gli ID numerici di `send_action` per Windows.
Selectors string Mac (`"showSceneTabs:"` ecc.) ritornano `false` su
Windows e non funzionano. Soluzione deterministica:
`tools/dump-su-menu.ps1` enumera il menu di SU via Win32 `GetMenu` /
`GetSubMenu` / `GetMenuString` / `GetMenuItemID` e stampa tutti gli item
con percorso menu + command ID.

Uso: SU aperto in primo piano, poi:
```
powershell -ExecutionPolicy Bypass -File tools/dump-su-menu.ps1
```

Output esempio: `ID=10534     > &View > &Scene Tabs`. ID utili scoperti:
- 10522 = View → Axes (per Mini Style Manager: SU 2019 Ruby API non espone
  state né setter per il display assi nemmeno via RenderingOptions/options)
- 10534 = View → Scene Tabs
- 10535 = View → Animation → Next Scene
- 10536 = View → Animation → Previous Scene
- 21067 = View → Animation → Add Scene
- 21068 = View → Animation → Update Scene
- 21078 = View → Animation → Delete Scene

Anti-pattern (perso ~mezz'ora): cercare l'ID online. Su forum si trova
10624 ma è "Camera Properties dialog" (undocumented Windows-only test
window), NON Scene Tabs. Per qualsiasi nuovo bisogno di command ID,
lanciare direttamente lo script.

## Style management (lettera badge + Mini Style Manager)

Tre layer di interazione sulla stessa lettera per-row:

| Trigger | Effetto |
|---|---|
| Render | Lettera A,B,C... (badge mono) = lo stile assegnato alla scena |
| Click sx | Apre Mini Style Manager (`StyleDialog.show_for`) per quello stile |
| Click dx | Apre style picker (`showStylePickerMenu` in app.js) — lista A `<name>`, B `<name>`... lo stile corrente in giallo, click per riassegnare |

**Letter mapping** (`SceneModel.styles_map`): ordine alfabetico per nome stile,
include **tutti** gli stili del modello (non solo quelli usati). Oltre la Z
continua con AA, AB... (`letter_for_index`, base 26). Esposto nel `push_state`
come `state.styles = [{ name, letter }, ...]`. Per-scena `state.scenes[].style_name`
da `Sketchup::Page#style` (esistente in SU 2019). JS `letterForStyle()` cerca
e ritorna '?' se nil (stato pre-push o stile orfano).

**Riassegnazione** (`SceneModel.assign_style`): non c'è un setter pulito
`page.style=` in SU 2019. Workaround: attiva la pagina target, set
`styles.selected_style = X`, forza `use_style = true` + `use_rendering_options =
true` (altrimenti `page.update` con STYLE bit non lega davvero lo stile), poi
`page.update(STYLE_BIT | RO_BIT)`, ripristina la pagina attiva precedente.
Tutto in 1 `start_operation` = 1 Ctrl+Z. Side-effect: se lo stile uscente era
dirty, le pending si perdono (comportamento equivalente al nativo). Anche in
defer mode è immediata (dipende dal qui-e-ora del viewport).

**Mini Style Manager** (`ui/style_dialog.rb`, `STYLE_DIALOG`): edit live di
rendering options (chiavi `EdgeColorMode`, `TransparencySort`, `BackgroundColor`,
`DrawHorizon`, `SkyColor`, `DrawHidden`, `DisplaySectionPlanes`,
`DisplaySectionCuts`). Apre attivando la scena di contesto (live feedback nel
viewport). Ogni edit → coerce per tipo (hex→`Sketchup::Color`, bool, int) →
`ro[k] = v` → `styles.update_selected_style` (committa al persistente; senza
questo gli edit valgono solo per la sessione e all'attivazione successiva
SU riapplica lo stile salvato perdendo le modifiche).

**Scope = sempre "all scenes using this style"**: l'API Ruby SU 2019 non
permette di clonare/rinominare uno stile programmaticamente
(`Sketchup::Style` non ha `name=`; `Sketchup::Styles#add_style` accetta solo
file `.style` da disco). Quindi "Only this scene" non è implementabile in
modo pulito. Banner nel dialog spiega: per override per singola scena,
duplicare lo stile via Window → Styles nativo, poi riassegnare con
right-click sulla lettera.

**Trappola "Color is for edges, not faces"**: il dropdown "Color" del Style
panel SU si riferisce al colore delle **linee/spigoli** (RenderingOption
`EdgeColorMode`, valori 0=All same / 1=By material / 2=By axis). Esiste
anche `FaceColorMode` per le facce, ma il controllo nativo SU lo chiama
"Color" e si applica agli edges — già confuso una volta in dev, lasciato
come `EdgeColorMode`.

**Model axes: niente API Ruby in SU 2019**. Non esiste rendering option né
metodo `View#display_axes` né provider in `model.options` per leggere/settare
il display degli assi del modello. Verificato enumerando tutto. L'unico
modo è `Sketchup.send_action(10522)` (ID View → Axes su Windows; selector
`'showHideAxes:'` su Mac). Quindi nel Mini Style Manager Model Axes è un
**bottone Toggle** (non checkbox): fire-and-forget, no state tracking.
Override ID via `Sketchup.write_default('SceneManagerPlus', 'axes_cmd_id', N)`.

## Match Photo: limite invalicabile dell'API Ruby SU 2019

**Sintomo**: creare una nuova scena dal plugin partendo da una scena Match
Photo fa sparire la foto di sfondo nella nuova scena.

**Causa**: SU 2019 Ruby API non espone praticamente nulla del Match Photo
subsystem:
- `Sketchup::Page#matchphoto?` NON esiste
- `Sketchup::Page#matchphoto` NON esiste
- Nessun flag `use_matchphoto?` né costante `PAGE_USE_MATCHPHOTO`
- `Sketchup::Matchphoto` class NON definita
- `Page#attribute_dictionaries` e `Model#attribute_dictionaries` NON
  contengono nulla relativo a Match Photo (verificato con
  `tools/dump-matchphoto-attrs.rb`)
- Nessuna `Sketchup::Image` o ComponentDefinition nasconde la foto
- Nessun path di file immagine accessibile via attributi

L'unica API esposta è `Sketchup::Pages#add_matchphoto_page(image_filename,
camera, page_name)` ma richiede di passare il path della foto a mano —
e non c'è verso di leggerlo dall'API Ruby.

**Code path nativi diversi**:
- `pages.add(name)` (quello che usavamo) → NON copia Match Photo
- `Sketchup.send_action(21067)` (View → Animation → Add Scene) → NON copia
- **Window → Scenes inspector "+"** → copia correttamente

L'inspector "+" usa una funzione C++ interna che ha accesso al Match Photo
subsystem. Non corrisponde a nessun `send_action` ID Ruby (testato range
21065..21077, 10530..10540, 10620..10630, nessuno aggiunge scena
preservando Match Photo). Probabilmente è una command "privata" registrata
solo in SU UI nativa.

**Workaround scartati**:
- `add_matchphoto_page` programmatico — serve il path foto, non leggibile
- Win32 UI scripting (simulare click sulla "+" dell'inspector) —
  fragile, dipende da window class hierarchy non documentata
- send_action range più ampio — improbabile, ID inspector privati

**Fix accettato** (in `SceneModel.add_from_view`):
- Predicate `SceneModel.matchphoto?(page)` con euristica:
  `page.camera.aspect_ratio != 0`. Verificato empiricamente: solo scene
  Match Photo hanno aspect_ratio settato esplicitamente (matchando la
  foto). Scene normali hanno 0.0 (= "usa aspect del viewport").
- All'inizio di `add_from_view`, se `matchphoto?(active)` mostra
  `UI.messagebox` YES/NO con spiegazione + suggerimento di usare la "+"
  dell'inspector nativo. NO = abort.

Se la heuristic si rivelasse insufficiente (false positive/negative su
casi reali), valutare combinare con `camera.image_width` o altre signal.

Documentazione di partenza: `tools/dump-matchphoto-api.rb` (cosa l'API
Ruby espone su Match Photo) e `tools/dump-matchphoto-attrs.rb` (cosa
salva negli attribute_dictionaries — niente di utile).

## Style pool + nickname per-modello (Fase 1A — "+ New style…")

**Problema risolto**: SU 2019 Ruby API non permette di:
- creare programmaticamente un nuovo stile da zero (`Styles#add_style`
  accetta solo `.style` file da disco),
- rinominare uno stile esistente (`Sketchup::Style#name=` non esiste),
- clonare uno stile (no `Style#save_as`, no `Style#duplicate`).

**Soluzione architetturale**: due meccanismi disaccoppiati che insieme
emulano la creazione di stili nuovi con nomi arbitrari.

### 1. Pool di slot bundled (`Core::Styles.allocate_new_slot`)

25 file `.style` pre-generati in `scene_manager_plus/assets/styles/slot_NN.style`,
ciascuno contenente uno stile col nome embedded `"SM+ Slot NN"` (NN = 01..25).
Generati one-shot via `tools/generate-slot-styles.rb` + un `_template.style`
esportato a mano dal native Styles browser (SU 2019 non espone Style#save_as
da API, quindi il dev fa l'export manuale una volta, poi PowerShell +
System.IO.Compression duplica e rinomina lo style.name dentro
`document.xml`). Vedi commit del tool e `tools/_slot_styles_ps.ps1`.

Due funzioni di allocazione, una primitiva e una di alto livello:

**`allocate_new_slot(nickname:)`** — primitiva pulita:
1. Trova il primo NN il cui `"SM+ Slot NN"` non è già in `model.styles`
   (così supporta file legacy, riempie buchi se l'utente ha cancellato a
   mano slot, ecc. — niente counter persistito da mantenere in sync)
2. `model.styles.add_style(slot_path, false)` — activate=false per non
   toccare lo `selected_style` se c'è uno style dirty pending
3. Recupera il `Sketchup::Style` per nome (post-add) e lo ritorna
4. Se nickname passato, `set_nickname(style.name, nick)`

Lo stile risultante ha le rendering options del **template** (quello
esportato a mano nella fase generator: "Architectural Design Style").
Utile solo come primitiva interna: l'utente raramente vuole "uno stile
generico".

**`allocate_new_slot_from_viewport(nickname:)`** — quello che usa il
picker "+ New style…" e quello che userà il futuro branch "Save as new"
del dirty-style dialog. Cattura le rendering options correnti del
viewport (dirty edit inclusi) dentro lo slot. Flusso:

1. Snapshot di `model.rendering_options.each_pair` PRIMA di toccare nulla
2. `add_style(slot_path, false)`
3. `styles.selected_style = new_slot` — viewport ora mostra le RO
   template dello slot; eventuali dirty edit sullo stile precedente
   vengono droppati silenziosamente (è OK: li abbiamo nello snapshot,
   e lo stile precedente torna pulito al suo state salvato — equivalente
   al "Don't save" nativo)
4. Riapplica snapshot sulle `ro[k] = v` (rescue su chiavi read-only)
5. `styles.update_selected_style` — committa lo snapshot dentro lo slot
6. Set nickname

Tutto in 1 `start_operation` = 1 Ctrl+Z (l'assign_style alla scena di
contesto fa una seconda operazione, quindi totale 2 Ctrl+Z per la
sequenza completa "+ New style + assign").

Pool esaurito → `UI.messagebox` con istruzioni per estendere
(rigenerare con NUM_SLOTS > 25 in `tools/generate-slot-styles.rb` e
committare i nuovi `slot_NN.style`).

### 2. Nickname per-modello (`Core::Styles.{get,set,clear}_nickname`)

Mappa `native_style_name → friendly_name` salvata come attribute dict
del modello, key = `'SMP_style_nicks'`. Travels with the `.skp`.

- **Plugin-only**: il native Styles browser SU mostra sempre il nome
  reale ("SM+ Slot 03"). Solo il plugin sostituisce con il nickname
  ovunque (letter badge tooltip, picker dropdown, scene letter mapping).
- Funziona su **qualunque stile**, non solo sugli slot del pool: l'utente
  può nickname-are anche stili pre-esistenti (es. "Default Style" →
  "Vista normale") in file legacy senza toccare il nome nativo.
- `set_nickname(name, '')` salva stringa vuota = clear logico
  (`set_attribute(..., nil)` non garantisce delete della entry, usare ''
  è più semplice e `get_nickname` ritorna nil per "" comunque).

Helper `Core::Styles.display_name(style_name)` = nickname o nome nativo.

### Integrazione UI (Fase 1A)

- `SceneModel.styles_map` ora ritorna `[{ name, display_name, nick,
  letter }, ...]` — ordinato per `display_name.downcase` (la lettera
  riflette ciò che l'utente vede, non il nome nativo).
- Picker stili (right-click su letter badge): voce "+ New style…" in
  cima, sopra l'elenco. Click → `SMBridge.newStyle(sceneId)` →
  `sm_style_new` callback in `dialog.rb`.
- `sm_style_new`: prompt `UI.inputbox` per nickname (skippabile = stringa
  vuota), poi `allocate_new_slot_from_viewport(nickname: ...)` (il nuovo
  stile cattura ciò che il viewport sta mostrando!), poi `assign_style`
  alla scena di contesto se `scene_id` presente. 2 Ctrl+Z totali
  (allocate-from-viewport + assign).
- Tooltip letter badge per row: "Style: <nickname> (native: <native>)"
  se nickname presente, altrimenti solo "Style: <native>".

### Nickname edit nel Mini Style Manager (Fase 1B)

Header del dialog ora ha un input "Nickname:" editabile (commit su
Enter/blur, Esc ripristina). Sotto, riga piccola "Native: <nome>".
Stringa vuota = clear del nickname (mostra solo il nome nativo nel
plugin).

Callback `sm_style_set_nickname { nickname: str }`:
- `Core::Styles.set_nickname(@style_name, str)`
- `push_state` (refresha l'header del style dialog)
- `Dialog.push_state` (refresha lettere/picker/tooltip nel main dialog,
  che dipendono dal display_name calcolato sul nickname)

Pattern setIfNotFocused per il nickname input: nel `setState` del JS, se
l'input è attualmente in focus (utente sta scrivendo) NON sovrascriviamo
il value — evita race con push_state che arriva durante l'edit.

### "Save as new" nel dirty-style dialog (Fase 1C)

`update_from_view` e `add_from_view` ora gestiscono il branch NO del
dialog YES/NO/CANCEL con `Core::Styles.allocate_new_slot_from_viewport`:

- `UI.inputbox` chiede il nickname (skippabile = stringa vuota)
- `allocate_new_slot_from_viewport(nickname:)` cattura le RO correnti
  nel nuovo slot
- **update_from_view**: chiama `assign_style(scene, new_style.name)`
  per riassegnare la scena al nuovo stile, poi maschera fuori dal
  mask i bit STYLE+RO (li ha già gestiti assign_style) e continua
  con `page.update(mask)` per gli altri flag (camera, layers, ecc.)
- **add_from_view**: allocate_new_slot_from_viewport ha già fatto
  `selected_style = new_style`, quindi il successivo `pages.add` crea
  una page legata al nuovo stile pulito automaticamente

Lo stile originale (dirty) torna allo state salvato silenziosamente:
gli edit dirty erano in `model.rendering_options` (la "in-memory dirty
copy" di SU), che viene riscritta quando si fa `selected_style = X`.
Quindi cambia stile = perdi dirty edits sul precedente — comportamento
voluto qui (gli edit sono stati "spostati" sul nuovo slot via snapshot
+ restore + update_selected_style).

### Limiti noti / TODO

- **Pulizia slot inutilizzati**: se utente crea Slot 01 e poi non lo
  assegna a nessuna scena, resta nel modello. Per ora si cancella a
  mano dal native browser; valutare bottone "purge unused SM+ slots".
- **Conflict nickname duplicati**: oggi nessun controllo se due stili
  hanno lo stesso nickname → due lettere distinte ma stesso label nel
  picker. Confonde. Valutare validazione di unicità nel set_nickname
  con rifiuto + messagebox.

## Note per future sessioni

- Lavoro condiviso tra postazioni → utente continuerà da un'altra macchina.
- Lingua di interazione con l'utente: **italiano**.
- L'utente preferisce sviluppo **per fasi con verifica intermedia**, non big-bang.
- Niente preview scene nel pannello (esplicita richiesta per performance —
  ma esistono thumbnails inline come opt-in).
- **Non committare** se non esplicitamente richiesto.
- Quando affronti bug/feature toccando un'area "delicata" (composite watermark,
  CEF/HtmlDialog, predicate API, settings UI), apri prima `docs/SU2019-LESSONS.md`
  per evitare di re-scoprire gotcha già documentati.
