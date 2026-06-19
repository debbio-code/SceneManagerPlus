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
- **MCP `eval_ruby` per probing API live** — esiste un server MCP locale
  (repo sibling `debbio-code/SketchUp-Mcp-mhyrr`, in `D:\Claude\sketchup-mcp`)
  che esegue Ruby arbitrario dentro SketchUp via socket. Usarlo per rispondere
  in un turno a "questa API/costante/RenderingOption esiste davvero in SU 2019?"
  invece di scrivere `tools/dump-*.rb` + copia/incolla dalla Ruby Console.
  Dettagli, gotcha di setup e funzione PowerShell `Invoke-SUEval` per il test
  diretto: `docs/SU2019-LESSONS.md` (sezione "MCP per il probing API") e il
  CLAUDE.md del repo MCP. Va avviato da `Extensions → MCP Server → Start Server`
  dopo ogni restart di SU.

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
| Mini Style Manager (click sx lettera) | `UI::StyleDialog` (`STYLE_DIALOG`) con 3 gruppi: **Edges** (`EdgeColorMode` 0/1/2 = All same/By material/By axis — è il colore *delle linee*, non delle facce; `TransparencySort` 0/1/2); **Background** (`BackgroundColor`, `DrawHorizon` on/off, `SkyColor`); **Display** (`DrawHidden`, Model axes checkbox `DisplaySketchAxes`, `DisplaySectionPlanes`, `DisplaySectionCuts`). Edit live → `rendering_options[k] = v` + `styles.update_selected_style` per committare al persistente. All'apertura, la scena di contesto viene attivata nel viewport per feedback live. **Scope sempre = "all scenes using this style"**: niente "only this scene" perché l'API Ruby SU 2019 non espone `style.name=` né `Styles#add_style` da memoria, quindi clonare programmaticamente uno stile non è fattibile pulitamente. Banner nel dialog spiega il workaround manuale: duplicare lo stile in Window → Styles nativo, poi riassegnare via right-click su lettera. **Model Axes è un checkbox stateful** come gli altri Display: la rendering option `DisplaySketchAxes` (bool) controlla il display degli assi del modello — scoperto via MCP `eval_ruby` su SU 2019.0.685 (vedi sezione "Style management"). Niente più hack `Sketchup.send_action(10522)`/`axes_cmd_id`. |
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
  In alternativa, se l'MCP è attivo, **reload a caldo** via `eval_ruby` senza
  riavvio: dopo la copia in Plugins, `load '<path>/file.rb'` sui file toccati
  (i moduli sono `module_function`, il re-eval è idempotente). Verificare poi
  che il cambiamento sia attivo (es. `Method#parameters`). Pattern già usato
  per aggiungere kwarg a `Exporter.export` senza restart. Trappola diagnostica:
  se la UI mostra una feature nuova ma "non fa quanto concordato", controllare
  PRIMA che il Ruby in memoria sia aggiornato — l'HTML/JS si ricaricano da soli
  (cache-bust) ma il `.rb` no, e un payload sconosciuto può cadere su un ramo
  `else` col comportamento di default sbagliato.
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

**Uid letto via `Core::SceneModel.page_id(page)`** (non `page.get_attribute`
diretto): `page_id` restituisce l'uid transient se non ancora persistito,
garantendo che il marker giallo funzioni anche su scene mai riordinate/cartellate
(che non hanno ancora uid su disco). `page_id` è read-only (no write su SU):
usa solo la cache `@transient_uids` in RAM — sicuro nel polling.

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

## Export — smart output dir: `Immagini` / `Immagini/Superate/NN`

Quando `export.output_dir` è vuoto:
- **Caso A**: `Immagini/` non esiste accanto al `.skp` → la crea, esporta lì
- **Caso B**: `Immagini/` esiste e ha file (oltre alla sotto-cartella
  `Superate`) → crea `Immagini/Superate/NN/` con NN successivo
  (zero-padded 2 cifre), SPOSTA i file di `Immagini` lì (skippando la
  cartella `Superate` stessa), poi esporta in `Immagini` ora svuotata
- **Caso C**: `Immagini/` esiste vuota (o contiene solo `Superate/`) →
  esporta lì
- Se il `.skp` non è salvato → fallback al picker manuale

`Superate` vive **dentro** `Immagini/` (non al fianco del `.skp`) così la
root del progetto resta pulita. Conseguenza: la scansione di Immagini per
decidere Caso B vs C **deve escludere** la entry `Superate`, altrimenti
dopo il primo archivio scatterebbe sempre Caso B.

Le note di archivio entrano negli `errors` mostrati nel messagebox finale.

### Quarta opzione: "Current selection → choose folder…"

Radio `selected_dir` nel dialog Export (sotto "Specific folders…"). Esporta
le scene della **selezione blu** (stessi uid di `scope='selected'`) in una
cartella scelta **ogni volta** col picker Windows (`UI.select_directory`),
**bypassando del tutto** la logica `Immagini/`/`Superate/` e **sovrascrivendo**
in caso di conflitto nome (no `unique_path`). Si abilita/disabilita come
"Current selection" (dipende da `has_select`).

Implementazione: in `ExportDialog.run`, se `scope=='selected_dir'` apre il
picker (se annullato → resta nel dialog), poi rimappa a `scope='selected'`
passando a `Exporter.export` i due nuovi kwarg `out_dir_override:` (bypassa
`resolve_output_dir`) e `overwrite: true` (salta `unique_path`). `collect_targets`
NON è stato toccato (riusa il caso `'selected'`).

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
- **Color picker**: `<input type="color">` in CEF di SU 2019 è
  **completamente broken**: cliccato non apre il dialog nativo OS, non
  scatena eventi, è un dead element. Stesso problema in tutti i contesti
  dove viene usato. Quirks ulteriori scoperti prima (accetta solo hex
  lowercase, change event inaffidabile) sono irrilevanti perché non
  riusciamo nemmeno a interagire col picker. Per i settings (filename
  label) usato input testuale hex + swatch + 6 preset clickabili. Per
  il **Mini Style Manager** (Background + Sky color) costruito un picker
  HSV custom in HTML/JS — `window.SMS` IIFE include un sub-modulo
  privato `ColorPopup` con: SB square (saturation × value, gradient
  CSS), hue slider verticale (gradient rainbow CSS), hex input, preview
  swatch, 24 preset 8×3. Swatch della row clickabile apre il popup
  posizionato sotto. Drag/click live-applica via `onApply` callback →
  text input + swatch della row + Ruby (in viewport vedi il cambio
  immediatamente). Outside click o Esc chiudono. Funziona al 100% in
  CEF SU 2019 perché usa solo standard DOM/CSS senza el `<input
  type="color">`.
- **Spellcheck italiano**: non riusciti a forzarlo. Tentato (2026-05) con
  `spellcheck="true" lang="it"` su input rename inline + Properties name/desc
  e `<html lang="it">` + `<meta http-equiv="Content-Language" content="it">`:
  CEF di SU 2019 ignora — il dizionario resta inglese (parole italiane
  sottolineate come errori). Causa probabile: la lista lingue per i
  dizionari Hunspell di CEF è una command-line flag (`--accept-lang=it`) che
  Trimble non espone all'API Ruby, e non c'è verso di forzare il download
  del dizionario IT dall'interno del plugin. **Scelta**: spellcheck
  disabilitato (`spellcheck="false"`) sul rename inline scena e sui campi
  Name/Description del Properties dialog. Se in futuro si vuole riprovare:
  esplorare se SU 2019 espone una pref CEF nascosta via `write_default`, o
  se è possibile pre-installare manualmente il dizionario `it-IT.bdic` nella
  cache CEF di SketchUp.

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
1. **Cliente** (top) / **Oggetto** (bottom, merged) — box 0. Cliente = il
   **prefisso del naming pattern** secondo `naming.prefix_mode` (non solo
   `prefix_custom`!): `custom`→`prefix_custom`, `skp_name`→titolo SKP
   sanitizzato, `skp_first_word`→prima parola del titolo, `none`→vuoto.
   Stessa logica di `Naming.format` (replicata in `Exporter`, non riusata —
   `Naming.format` costruisce il nome intero, qui serve solo il prefisso).
   Già stato un bug: era hardcoded su `prefix_custom`, quindi con
   `skp_first_word` (oggi default) il Cliente usciva vuoto.
   Oggetto = `page.name`. CLIENTE è nella sola riga
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
o a `valueSz ≤ 10`. Iters tipico 5-10. **L'OGGETTO (nome scena) NON
partecipa a questo `autoSum`**: il box 0 (Cliente/Oggetto) è il
"remainder" e ha come floor solo `CLIENTE:` (valore costante) + il label
`OGGETTO:`. Prima il box 0 era dimensionato sul nome scena più lungo del
batch, così un oggetto lungo gonfiava `autoSum` e rimpiccioliva il testo
di TUTTI i box. Regola: a parità di altezza del cartiglio, i testi delle
altre voci devono restare invariati.

**Wrap dell'OGGETTO su 2 righe** (`Fit-Object` + `Split-Balanced` nel PS):
- Sta su una riga a font pieno → una riga, **nessun rimpicciolimento**.
- Non ci sta → va **sempre** davvero a capo su 2 righe, partendo da -30%
  del font pieno e scalando ancora solo se serve fino a 9px. Le 2 righe
  sono centrate verticalmente nella riga inferiore `[halfH, H]` del box 0
  (label `OGGETTO:` allineata alla 1ª riga).
- **Trappola risolta**: un wrap *greedy* (riempi riga 1 fino a maxW, resto
  in riga 2) al 70% faceva rientrare tutto su riga 1 lasciando riga 2 vuota
  → usciva un testo rimpicciolito su UNA riga (= il difetto segnalato).
  Fix: `Split-Balanced` divide le parole nel punto che minimizza la
  differenza di larghezza tra le due righe → SEMPRE 2 righe non vuote
  (con ≥2 parole). Parola singola troppo lunga: non si può andare a capo,
  fallback `Fit-Fnt` (shrink su una riga).

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
- 10522 = View → Axes (storicamente usato dal Mini Style Manager come hack
  toggle; NON più necessario: la RO `DisplaySketchAxes` espone state+setter —
  vedi sezione "Style management")
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
`EdgeColorMode`). Esiste anche `FaceColorMode` per le facce, ma il controllo
nativo SU lo chiama "Color" e si applica agli edges — già confuso una volta
in dev, lasciato come `EdgeColorMode`.

**Valori reali di `EdgeColorMode` (verificati empiricamente):**
`0 = By material`, `1 = All same`, `2 = By axis`. **Controintuitivo**: 0 non
è "All same" come si aspetterebbe — nel Mini Style Manager le opzioni HTML
hanno `value="1"` per "All same" e `value="0"` per "By material".

**`TransparencySort`**: solo due valori reali in SU 2019: `0 = Faster`,
`2 = Nicer`. Il valore `1` ("Medium") non corrisponde a niente di nativo e
non produce effetti visibili — non esporre nella UI.

**X-Ray**: la chiave RenderingOptions per il modo X-Ray è `ModelTransparency`
(bool). Il nome `XRayAll` non esiste in SU 2019 — trovato per diff delle RO
prima/dopo toggle nativo.

**`use_style` + `use_rendering_options` = "Style and Fog" nativo**:
la UI nativa SU espone 7 checkbox (non 8). "Style and Fog" corrisponde a
ENTRAMBI i flag Ruby `use_style?` e `use_rendering_options?` — sempre settati
insieme. Nel plugin: un solo checkbox "Style and Fog" scrive entrambi. Il
flag `use_rendering_options` da solo non ha effetto visibile in SU 2019.

**Model axes: rendering option `DisplaySketchAxes` (bool)**. Contrariamente a
quanto si era concluso in passato (e a quanto SU documenta), il display degli
assi del modello SI è leggibile/settabile via `rendering_options['DisplaySketchAxes']`.
Scoperto via MCP `eval_ruby` su SU 2019.0.685 (vedi `docs/SU2019-LESSONS.md`,
sezione "MCP per il probing API"): `Object.constants.grep(/PAGE_USE/)` e l'enum
delle RO hanno rivelato la chiave, che la vecchia indagine "enumerando tutto"
aveva mancato. Verificato empiricamente: `ro['DisplaySketchAxes']=false` nasconde
gli assi nel viewport; ed è catturato **per-scena** via `PAGE_USE_RENDERING_OPTIONS`
(una scena con `use_rendering_options` ripristina il valore salvato). Quindi nel
Mini Style Manager Model Axes è un **checkbox stateful** come gli altri Display
controls — niente più `Sketchup.send_action(10522)`, `WIN_AXES_CMD_ID` né override
`axes_cmd_id`. **Lezione di metodo**: il MCP eval_ruby chiude in un turno indagini
API che prima richiedevano `tools/dump-*.rb` + copia/incolla dalla Ruby Console.

## Match Photo: limite invalicabile dell'API Ruby SU 2019

> ⚠️ **Sibling repo accoppiato**: `3dg_photomatch` vive in
> `C:\Claude\Sketchup Plugins\3dg_photomatch\` (remote
> https://github.com/debbio-code/3dg_photomatch). Le guard MP descritte
> qui sotto esistono **per le scene create da quel plugin**. Modifiche
> a una delle due parti vanno verificate sull'altra:
>
> - Se cambia `3dg_photomatch.rb` (es. flag impostati alla creazione MP,
>   chiamata `update_selected_style`, comportamento `add_matchphoto_page`),
>   le guard di SM+ qui sotto potrebbero richiedere aggiornamento.
> - Se cambia un guard di SM+ (es. block in `assign_style`, `update_page`,
>   Properties checkbox "Style and Fog ↗"), assicurarsi che il
>   comportamento atteso da 3dg_photomatch sia ancora coperto.
> - Il `CLAUDE.md` di 3dg_photomatch contiene la stessa storia da
>   prospettiva opposta — leggi entrambi se devi toccare il dominio MP.


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

**Code path nativi diversi — divergenza menu-vs-send_action**:
- `pages.add(name)` (quello che usavamo) → NON copia Match Photo
- `Sketchup.send_action(21067)` → NON copia, anche se 21067 è l'ID
  riportato da `dump-su-menu.ps1` per "View → Animation → Add Scene"
- **Click manuale sul menù "View → Animation → Add Scene"** → COPIA
- **Click manuale su Window → Scenes inspector "+"** → COPIA

Quindi SU ha letteralmente **due binari diversi** per la stessa command:
quando l'utente clicca il menù a mano, SU esegue il vero handler C++ che
ha accesso al Match Photo subsystem. Quando si invoca via
`Sketchup.send_action` con lo stesso ID, SU instrada attraverso un
handler separato (probabilmente legacy o "scripting-safe") che bypassa
Match Photo. Comportamento non documentato Trimble ma riproducibile.

Conseguenza: non c'è modo da Ruby di colpire il binario "menù manuale".
Testato range `send_action` 21065..21077, 10530..10540, 10620..10630 —
nessuno aggiunge scene preservando Match Photo.

**Ipotesi non ancora testata**: simulare un WM_COMMAND Win32 al main
window di SU con ID 21067 (via `user32!SendMessage`). Questo dovrebbe
emulare un click di menù vero invece di passare per il routing
`send_action`. Se funziona, automazione completa. Se no (probabile: SU
potrebbe distinguere via stato/sender della command), torniamo qui.

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

### Crash pattern: write spuri sui flag `use_*` su scene MP (2026-05)

Scoperto debuggando interazione con plugin terzo `3dg_photomatch`: scrivere
TUTTI i flag `page.use_xxx = v` (anche su quelli già allineati al valore
corrente) dentro una singola `start_operation` su una scena Match Photo
→ il subsystem MP C++ marca lo state interno come dirty → al successivo
`pages.selected_page = page` (anche un semplice click in SM+) il restore
re-entra sopra uno state non più consistente → BugSplat.

Riprodotto deterministicamente: scrivere un singolo flag (`p.use_axes = true`)
non crasha; iterare e scrivere tutti gli 8 con `p.send(setter, v)` senza
controllo se sono cambiati → crash al re-attivare la scena.

**Fix applicato** in `SceneModel.update_page` e `Buffer.flush!`: scrivere
un flag solo se `current != v`. Beneficio collaterale anche sui modelli con
AttributeObserver di plugin terzi (meno write = meno freeze a 5s).

**Regola generale per il futuro**: ogni volta che si scrivono attributi/flag
su `Sketchup::Page` in loop, fare il diff `current_value != new_value` prima
del setter. Non è solo questione di performance — è questione di stabilità.

### Crash pattern: `page.update(STYLE|RO)` su scena MP

`SceneModel.assign_style` (e di riflesso "+ New style…") su scena MP
crashava SU. Causa: `page.update` con bit STYLE+RO sovrascrive lo stile
MP interno (background foto) → corruzione → splat. Anche se non crashasse,
sostituire lo stile MP con uno normale toglie la foto di sfondo, che è
l'opposto del comportamento atteso.

**Fix applicato**: guard in `SceneModel.assign_style` che usa `matchphoto?(p)`
e mostra messagebox + abort. Aggiunta anche guard early in `sm_style_new`
(`ui/dialog.rb`): senza, `allocate_new_slot_from_viewport` avrebbe già
allocato uno slot del pool (con le RO MP catturate) prima del rifiuto di
`assign_style` → slot orfano nel pool e RO inquinate.

### Letter badge "?" = scena MP (sintomo diagnostico)

Se nel main dialog di SM+ il letter badge di una scena mostra `?`, significa
che `page.style.name` non matcha nessuno stile in `model.styles`. Su scene
Match Photo questo è normale: lo stile MP interno non è enumerato in
`model.styles`. È un marker utile per identificare scene MP create da
plugin terzi anche prima della heuristic `camera.aspect_ratio != 0`.

### `add_matchphoto_page` lascia lo selected_style dirty

`Sketchup::Pages#add_matchphoto_page` configura `model.rendering_options`
per il background image MP, ma NON committa lo stile risultante. Il Match
Photo nativo dopo aver creato la scena chiama internamente
`styles.update_selected_style`. Plugin terzi che usano solo
`add_matchphoto_page` (es. `3dg_photomatch` nella sua versione originale)
lasciano lo stile precedente "dirty" — se l'utente clicca "Update" nello
Style panel inquina lo stile uscente con le RO Match Photo. Disastro.

**Per chi scrive plugin che usano `add_matchphoto_page`**: chiamare
`model.styles.update_selected_style` subito dopo, come fa il nativo.
Applicato nella nostra copia patchata di `3dg_photomatch.rb`.

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

### Validazione unicità nickname (Fase 1D)

`Core::Styles.set_nickname` rifiuta il write se il nickname (o il nome
nativo) è già usato come display_name da un altro stile. Validazione
case-sensitive, trim'ata, esclude lo stile target tramite parametro
`except_native:`. Return value bool — true = scritto, false = conflict.

Helper UI `Core::Styles.prompt_nickname_loop(title:, label:)`:
re-prompt loop su `UI.inputbox` con messagebox + retry su conflict.
Ritorna stringa nickname o `:aborted`. Usato da:
- `sm_style_new` (picker "+ New style…") in `ui/dialog.rb`
- Branch NO ("Save as new") in `update_from_view` e `add_from_view` in
  `core/scene_model.rb`

Per il Mini Style Manager (`sm_style_set_nickname`): no loop perché
l'input è già "live" — su rifiuto mostriamo messagebox + push_state,
JS rispetta `setIfNotFocused` quindi l'input torna al valore
precedente automaticamente.

### Purge stili non usati (Fase 1E)

Limite SU 2019: nessuna API per cancellare uno stile specifico. Solo
`styles.purge_unused` (model-wide).

Bottone "Purge unused styles…" aggiunto a Settings dialog, sezione
"Style pool". Flusso:
1. `Core::Styles.unused_styles` enumera stili non referenziati da
   alcuna scena (compresi non-SM+: c'è un disclaimer nel testo della
   sezione)
2. Callback `sm_settings_purge_unused_styles` mostra messagebox con
   la lista completa (display_name + native se diverso) + warning
   "not undoable"
3. Conferma → `Core::Styles.purge_unused_styles` chiama
   `styles.purge_unused` + `remove_nickname_attr` per ognuno → ritorna
   l'array dei nomi rimossi
4. Messagebox finale di conferma + `Dialog.push_state` per refresh

`remove_nickname_attr(name)` usa `dict.delete_key(name)` invece di
`set_nickname(name, '')` per cancellare proprio la entry dal dizionario
modello (vs lasciare stringhe vuote che si accumulano).

### Limiti noti / TODO ancora aperti

Nessuno strettamente bloccante. Possibili miglioramenti futuri:
- **Line scale multiplier su thumbnails**: ineffective in SU 2019 a
  300×150 (documentato come limite presunto in sezione "Line scale
  multiplier"). Da indagare se diventa fastidioso.
- **WM_COMMAND Win32 per Match Photo**: tentativo non testato di
  emulare un click di menù vero per clonare scene Match Photo. Esito
  incerto. Vedi sezione "Match Photo" più sopra.

## Performance su modelli con AttributeObserver di plugin terzi (2026-05)

Su alcuni file dell'utente certi plugin terzi (Layers Manager, plugin BIM,
ecc.) registrano un AttributeObserver che reagisce a ogni
`model.set_attribute`/`page.set_attribute`. Quel callback gira `O(modello)`
e in pratica costa **~5 secondi per ogni write singolo**. Non possiamo
fixare l'altro plugin, ma dobbiamo evitare di scatenargli writes inutili.

Regole emerse, da rispettare in ogni feature futura:

### 1. Il polling NON deve mai scrivere

`Dialog#poll_active_scene` gira ogni 250ms. Anche una sola
`set_attribute` lì = blocco massivo. Implementazione corrente:
- Reorder-detect via `p.object_id` (stabile in sessione, zero side-effect).
- Lettura uid corrente via `Core::SceneModel.page_id(page)`: read-only,
  usa la cache `@transient_uids` in RAM se l'uid non è ancora persistito.
  **Non usare `page.get_attribute` diretto**: funzionerebbe solo per uid
  già persistiti, lasciando il marker giallo immobile su scene "vergini".

### 2. UID di pagine: cache transient in RAM + persist lazy

`SceneModel.page_id(page)`:
1. Legge l'attribute persistente. Se presente → return.
2. Altrimenti consulta `@transient_uids[[m.object_id, page.object_id]]`.
3. Se assente in cache → genera e cachea. **Nessuna scrittura su disco**.

Il transient è stabile per la sessione SU corrente. Quando l'uid deve
sopravvivere a chiusura/riapertura del file, viene persistito
esplicitamente via `SceneModel.persist_uids_for_ids(ids)` che fa una
sola `start_operation(disable_ui=true, transparent=true)` batch.

Call site che persistono (esegue persistuids automaticamente):
- `SceneModel.write_order_raw(ids)` — prima di scrivere logical_order.
- `Folders.write_raw(list)` — prima di scrivere folders+scene_ids.

Side-effect UX: la prima volta che l'utente crea una folder o riordina
scene su un file "vergine", c'è un freeze (~5s su modelli pesanti) per
il batch persist. Successivi reorder/folder edit: zero freeze.

Per file che già avevano uid persistiti dalla precedente versione del
plugin: backward compat OK, `ensure_all_uids` non scrive nulla.

NON chiamare `page_id` in loop senza pre-`ensure_all_uids` se il loop
sta solo leggendo: meglio popolare la cache transient in batch (ora è
zero-cost) e poi leggere.

### 3. Settings: RAM-only durante editing, flush on close

`Core::Settings` mantiene `@runtime[model.object_id][group][key] = value`.
- `Settings.set(group, hash)` aggiorna SOLO la RAM. Niente disk write.
- `Settings.get(group)` merge: runtime override > attribute_dictionary >
  DEFAULTS. Una sola chiamata `attribute_dictionary(..., false)` per group,
  niente get_attribute per ogni leaf.
- `Settings.flush!(model)` consolidate-write in 1 `start_operation` batch.
  Chiamato in:
  - `SettingsDialog.set_on_closed` (chiusura dialog Settings).
  - `Exporter.export` all'inizio (garantisce SKP coerente prima di esportare).

UX: l'editing dei settings ha **lag 0** anche su file con observer terzo
a 5s/write. Un solo freeze al close del Settings dialog. Tutti i lettori
(Export, Properties, ecc.) vedono i valori RAM aggiornati via `Settings.get`
senza bisogno di flush intermedi.

Lato JS (`ui/html/js/settings.js`): tutti gli input testuali/numerici
salvano su evento `change` (blur/Enter), NON `input`. Così se l'utente
digitava `"3000"` non scattavano 4 save intermedi, ma uno solo al tab-out.
Checkbox/select restano su `change` come prima (eventi discreti).

### 4. Per qualsiasi `model.set_attribute` non-trivial: start_operation

Pattern obbligatorio per write fuori dal critical path utente
(es. background, batch, lazy-persist):

```ruby
model.start_operation('SM+ <descrizione>', true, false, true)
# disable_ui=true → SU non rinfresca inspector tra write
# next_transparent=false
# transparent=true → niente entry nell'undo stack
begin
  # ... writes ...
  model.commit_operation
rescue => e
  model.abort_operation
  raise
end
```

Anche se il singolo write è inevitabilmente lento per l'observer terzo,
`disable_ui=true` evita i refresh sincroni di SU sull'undo stack e gli
inspector. `transparent=true` evita di sporcare l'undo dell'utente con
operazioni del plugin che non devono essere undoable (es. assegnazione
uid lazy, save settings).

## Composite export ottimizzato (2026-05)

`Core::Exporter` non usa più `apply_overlays + append_titleblock` (due
load/save separati = doppia ricompressione JPG). Adesso `composite_to_file`
fa tutto in un singolo load → set_data → save_file. Helpers chiave:

- **`imagerep_to_bgra(img)`**: estrae i pixel come buffer BGRA top-down
  via `ImageRep#data` (1 C-level call) invece di `colors.each` (1 oggetto
  `Sketchup::Color` per pixel). Fast path per 32bpp / no padding (PNG da
  SU). Su 24bpp fa byte-copy row-by-row senza allocazioni Color. Fallback
  finale via `colors.each` come safety net.
- **Logo pre-rasterizzato 1 volta per export**: prima del loop scene, il
  logo viene ricampionato a `tw × th` finali in BGRA, e il blend per-scena
  è solo index-math sul buffer. Prima `color_at_uv` veniva chiamato per
  pixel × ogni scena.
- **`blend_stamp!`**: fast-path per pixel completamente opachi (la=255,
  opacity=1.0) → 3 byte copy senza math floating point.
- **Singolo load/save per logo+label+titleblock**: il buffer base è
  un concat di `imagerep_to_bgra(base) + tb_bgra` (top-down). Gli
  overlay vengono blendati clippati nella zona base (`bh`), poi un solo
  `set_data + save_file` finale. Niente più doppia ricompressione JPG.

Misure indicative su modelli reali: 3-8x più veloce in funzione delle
feature attive (più sono attive più si guadagna dal merge).

## Trappola Edit tool → smart quotes nei file JS (2026-05)

Il tool Edit dell'assistente, quando il `new_string` contiene caratteri
non-ASCII (es. `→`, `—`, `↔`), a volte normalizza gli apostrofi ASCII
(`'`, U+0027) in smart quotes Unicode (`'`/`'`, U+2018/U+2019).

**JavaScript non riconosce smart quotes come delimitatori di stringa**.
Una sola riga corrotta del tipo:
```js
'To affect only one scene'  // ASCII OK
'To affect only one scene'  // U+2018/U+2019 → SyntaxError
```
manda in `SyntaxError` l'intera IIFE → `window.SMS` non viene mai
definito → niente nel mini Style Manager funziona (no setState,
nessun listener agganciato, footer resta a "—").

**Sintomo**: una finestra HtmlDialog si apre ma è completamente
"morta" — non aggiorna i campi, click non funzionano, ma non c'è
errore visibile (CEF console non è esposta in SU 2019).

**Diagnosi rapida** (PowerShell):
```powershell
$f = "path\to\file.js"
$c = [System.IO.File]::ReadAllText($f)
([regex]::Matches($c, "[‘’“”]")).Count
```

**Fix bulk**:
```powershell
$c = $c -replace [char]0x2018, "'"
$c = $c -replace [char]0x2019, "'"
[System.IO.File]::WriteAllText($f, $c, [System.Text.UTF8Encoding]::new($false))
```

Quando devi editare un file JS con caratteri Unicode (frecce, em-dash,
ecc.), verifica sempre dopo l'edit con il check sopra. Pattern alternativo:
fai l'edit con `Write` invece di `Edit` quando puoi.

## Debugging mode (checkbox Settings → Interface) — 2026-06-01

Checkbox "Debugging mode on startup (Ruby Console + MCP server)" in Settings →
Interface. A ogni avvio di SketchUp apre la Ruby Console e avvia il server MCP,
così le verifiche live via `eval_ruby` sono disponibili senza riaprire nulla
(comodo nei tanti riavvii dovuti a modifiche `.rb`).

**Logica** in `SettingsDialog.activate_debug_mode` (riusata da `main.rb` allo
startup e dal callback della checkbox):
- Console: `::SKETCHUP_CONSOLE.show` (fallback `Sketchup.send_action('showRubyPanel:')`).
- MCP: il plugin MCP `su_mcp` espone il server come **ivar del modulo**
  `SU_MCP` → si avvia con `::SU_MCP.instance_variable_get(:@server).start`
  (idempotente, `return if @running`). Porta letta da `srv.instance_variable_get(:@port)`
  (default 9876). Tutto guardato con `defined?(::SU_MCP)`: su macchine senza MCP
  apre solo la console e lo segnala nello status.

**Persistenza = flag GLOBALE per-macchina** via `Sketchup.write_default(
'SceneManagerPlus', 'debug_mode_on_open', bool)`, **NON** il gruppo settings
`ui` (che è per-file model attribute). Motivo: è una preferenza di sviluppo che
deve valere su qualsiasi `.skp` apri, non solo su quello dove hai spuntato.
Stesso pattern di `main_dialog_open`. Quindi nel `push_state` del Settings
dialog `debug_mode_on_open` è un campo **top-level** dello state (non dentro
`settings.ui`), e in `settings.js` la checkbox `#ui-debug-on-open` si setta da
`state.debug_mode_on_open` (non da `writeUi`). Avvio in `main.rb`: timer 0.7s
(dopo l'auto-open del dialog, per dar tempo a `su_mcp` di registrarsi).

**Nota diagnostica**: la Ruby Console che si apre da sola a ogni avvio di SU
**NON è Scene Manager+** — è il plugin MCP `su_mcp/main.rb` che fa
`SKETCHUP_CONSOLE.show` a livello top-level (riga ~7) e di nuovo in
`Server#initialize` (eseguito perché `@server = Server.new` parte al load).
Il server MCP però NON parte da solo: solo la console viene mostrata. Per non
far aprire la console all'avvio, il fix va fatto in `su_mcp`, non qui.

## Update from view parziale (tasto destro)

Right-click su `btn-update` (toolbar) e su `btn-update-view` (Properties dialog)
mostra un menu "Update only…" con le property attive per la scena selezionata.
Click su una voce aggiorna **solo quella property** invece di tutte.

**API Ruby**: `SceneModel.update_from_view(id, only_keys: nil)`:
- `only_keys: nil` → comportamento standard (gated su `p.use_*?`).
- `only_keys: ['use_camera', ...]` → bitmask costruita solo da quelle chiavi,
  ignora lo stato corrente della pagina. La lista può contenere qualsiasi
  sottoinsieme di `FLAG_KEYS`.

**Dirty-style guard**: in modalità parziale scatta se `'use_style'` è in
`only_keys` (intent esplicito), non se `p.use_style?`. Stesso dialog
YES/NO/CANCEL.

**Bridge**: `SMBridge.updateFromView(id, flags)` — `flags` array opzionale
propagato nel payload `{ id, flags }` e letto come `data['flags']` in Ruby.

**Menu JS**: `UPDATE_FLAG_UI` in `app.js` (stesso ordine di `FLAG_UI` in
`properties.js`); `showUpdatePartialMenu` ricicla `hideContextMenu` /
`onDocMouseDownCloseMenu` già esistenti. In Properties usa helper locali
(`showPartialMenu` / `hidePartialMenu`) per non interferire col main dialog.

## Badge color per-stile

Colore associato a uno stile, mostrato come background del letter badge
nella main window e nel picker right-click.

**Storage**: dict `'SMP_style_colors'` su `Sketchup.active_model` (separato
da `SMP_style_nicks`). API: `Core::Styles.get_color / set_color / clear_color /
remove_color_attr`. `purge_unused_styles` pulisce anche colori orfani.

**Push**: `styles_map` include `:color`; `StyleDialog.push_state` include
`badge_color`; callback `sm_style_set_color { color: '#rrggbb'|'' }`.

**UI Style Manager**: riga "Badge color" sotto il Nickname nell'header —
swatch + hex input + bottone ✕. Swatch apre lo stesso `ColorPopup` HSV di
Background/Sky. Swatch "vuoto" = pattern CSS a quadretti (`.swatch-empty`).

**Contrasto automatico** (`readableTextColor` in `app.js`): dato un colore
hex calcola luminanza e sceglie testo `#1a1a1a` (scuro) o `#ffffff` (chiaro).

**Picker**: inline color sul `.ctx-letter` applicato **solo** se lo stile
NON è `.current` (per non sovrascrivere il giallo che segnala lo stile attivo).

## Color picker condiviso (`SMColorPopup`) + per-scene color

`ui/html/js/color_popup.js` + `ui/html/css/color_popup.css` espongono
`window.SMColorPopup`, un picker HSV unificato usato sia da `app.js` (main
window) sia da `style_dialog.js` (Mini Style Manager). Markup `#sm-color-popup`
+ `#cp-*` deve essere presente nell'HTML del dialog che lo usa (vedi
`index.html` e `style.html`).

**API**: `SMColorPopup.show(triggerEl, currentHex, onApply, opts)` con:
- `opts.allowNone = true` → mostra bottone **None** (commit string vuota).
- `opts.commitOnEnd = true` → NON chiama `onApply` durante drag/typing; lo
  chiama una sola volta alla `hide()` del popup con il colore finale.

**Modalità `commitOnEnd`**: introdotta per il colore per-scena. Senza, ogni
movimento nel SB square / hue slider triggera un write `set_attribute` su
`Sketchup.active_model`, che su modelli con AttributeObserver di plugin terzi
costa ~5s/write → picker inutilizzabile. Regola da estendere ad ogni futuro
picker dove il colore NON ha effetto live nel viewport (es. cosmetico,
tag/etichetta). Per i picker dove il colore SI vede live nel viewport
(Background/Sky color del Mini Style Manager), live mode è quello giusto.

**Recenti**: gli ultimi 5 colori applicati sono salvati su `localStorage`
chiave `sm_color_popup_recent`, fallback in-memory se CEF non lo supporta.
Push automatico in `hide()` se è stato applicato un colore valido. Sono
condivisi tra TUTTI i picker (main window + Mini Style Manager), perché
vivono nello stesso modulo `SMColorPopup`. CEF di SU 2019 supporta
localStorage (verificato).

**Enter/Esc nel campo hex** chiudono il popup (= commit in `commitOnEnd`,
no-op altrimenti perché il colore è già stato applicato live).

**Style dialog**: `style_dialog.js` aveva una IIFE privata `ColorPopup`
identica; ora aliassata a `window.SMColorPopup` (il legacy `_ColorPopupLegacy`
è dead-code lasciato come fallback rapido, mai inizializzato). Switching ha
portato anche la riga "Recenti" e l'Enter-commit nel Style Manager.

**Per-scene color** (`Core::SceneModel`):
- Storage in dict `'SMP_scene_colors'` su `Sketchup.active_model`, key = uid
  scena, value = `'#rrggbb'`. Separato da `SMP_style_colors` (stesso pattern
  ma per scene invece che per stili). API `get_scene_color(uid)` /
  `set_scene_color(uid, hex)`. Empty/nil = clear.
- Esposto in `scene_hash` come `color` (overlay buffer NON applica color edits:
  niente staging defer per il colore, è write diretto immediato — è
  un'operazione cosmetica e usare il commit-on-end del picker basta a
  contenere i write).
- Callback Ruby: `sm_scene_set_color { id, color }`.
- Bridge JS: `SMBridge.setSceneColor(id, hex)`.

**UX**: solo lo swatch a destra del nome scena prende il colore (la row NON
viene tintata). Vuoto = pattern a quadretti CSS, pieno = `background` inline.
Click sx swatch → popup `allowNone:true, commitOnEnd:true`. Click dx swatch
→ `setSceneColor(id, '')` immediato (clear shortcut).

**Trappola**: il popup HTML markup deve essere presente nel dialog che lo
usa. Se aggiungi un nuovo dialog che vuole usare `SMColorPopup`, copia il
blocco `<div id="sm-color-popup">...</div>` da `index.html` e includi
`color_popup.css` + `color_popup.js`. Il markup è duplicato tra `index.html`
e `style.html` (in CEF non si possono includere fragment HTML).

## Shortcut globali → `UI::Command`, non keydown JS

CEF HtmlDialog `STYLE_UTILITY` in SU 2019 **non riceve keydown** in modo
affidabile, neanche col focus dentro al dialog: l'OS instrada quasi sempre
i tasti a SketchUp. Quindi un listener `document.addEventListener('keydown')`
nel JS può servire SOLO per shortcut interni che funzionano dopo un click
nel dialog (tipo Arrow/PageUp/PageDown già esistenti) — **non per shortcut
globali**.

Per shortcut "veri" (utente preme tasto col viewport in focus): registrare
una `UI::Command` con menu item visibile, e lasciare che l'utente assegni
lo shortcut da **Window → Preferences → Shortcuts** (SU 2019 espone lì
solo i comandi che hanno una voce di menu — se rimuovi `menu_text` o non
fai `add_item`, la voce sparisce anche dal dialog Shortcuts).

Esempio in `main.rb` (Plugins → "Scene Manager+: Jump to active scene"):
riassegnare `model.pages.selected_page = model.pages.selected_page`
ri-applica camera/stile/layers (= clic sul nome scena).

`cmd.set_shortcut("J")` non è stato testato; per ora si assegna a mano.

## Mini Style Manager — extra buttons + Fog spostata fuori (2026-05)

Tre estensioni allo Style dialog (`ui/style_dialog.rb` + `ui/html/style.*`):

1. **Bottone "⧉" header → apre Window → Styles nativo**. Usa
   `::UI.show_inspector('Styles')` — API Trimble cross-platform, niente
   command ID Windows da indovinare via `dump-su-menu.ps1`. Stesso pattern
   già usato in `dialog.rb` per il right-click su badge stile di scene MP
   e in `properties_dialog.rb` per "Style and Fog ↗". **Regola futura**:
   per qualsiasi necessità di aprire un pannello nativo SU dal plugin,
   provare PRIMA `UI.show_inspector('<NomePanel>')`, e solo se non esiste
   quel panel (raro) ricadere su `Sketchup.send_action` con numeric ID.

2. **Bottone "→ 1" in sezione Edges**: setta atomicamente
   `DrawSilhouettes=true` + `ProfileWidth=1` in un'unica `start_operation`.
   Stato feedback visivo: classe CSS `.is-active` (sfondo blu) quando lo
   stile è già nel target.

3. **`ProfileWidth` è alias non-ufficiale di `SilhouetteWidth`** in SU 2019.
   La chiave canonica RenderingOption per la larghezza dei profili è
   `SilhouetteWidth`; `ProfileWidth` viene accettata in scrittura senza
   errore ma è ignorata silenziosamente dal viewport. L'exporter del
   plugin la usava da sempre (vedi `Core::Exporter`, `Core::Previews`)
   senza che ce ne accorgessimo perché il line scale multiplier comunque
   "sembrava" funzionare via altri side-effect. **Fix in
   `StyleDialog.apply_changes`**: quando si scrive ProfileWidth, scriviamo
   anche SilhouetteWidth nella stessa operazione. **In lettura** (`read_ro`)
   preferiamo SilhouetteWidth con fallback su ProfileWidth.

   **Regola futura**: ogni volta che si tocca la profile width (export,
   preview, qualsiasi flusso), scrivere ENTRAMBE le chiavi. Se serve mai
   solo leggere lo stato, leggere SilhouetteWidth.

**Fog rimossa dallo Style Manager**: inizialmente messa lì (perché vive
in `rendering_options`), poi spostata nel Properties dialog (= per-scena)
perché concettualmente la fog è una proprietà di scena anche se
tecnicamente cattura via `use_rendering_options`. Vedi sezione "Fog
control nel Properties dialog" sotto.

## Fog control nel Properties dialog (2026-05)

Nuova sezione "Fog" nel Properties dialog (`ui/properties_dialog.rb` +
`ui/html/properties.*`) che replica `Window → Fog` nativo con un'interfaccia
più precisa.

### Semantica del dual-handle slider (gotcha forte)

Le label **"0%" e "100%" sotto i thumb sono FISSE — si riferiscono alla
DENSITÀ della nebbia**, non alla posizione del thumb sull'asse.

- L'asse rappresenta DISTANZA dalla camera (in unità modello, da 0 a "∞").
- Thumb "0%" (blu) = punto dove la nebbia INIZIA (densità 0%, ancora
  trasparente).
- Thumb "100%" (arancione) = punto dove la nebbia è OPACA (densità 100%).
- Tra i due thumb la densità interpola linearmente.

**Errore facile** ed effettivamente commesso durante lo sviluppo:
interpretare "0%" e "100%" come posizione percentuale sull'asse. Il nativo
non funziona così — lo sliderr stesso scorre tra 0 e una distanza max,
e i thumb sono valori di distanza, le label "0%" e "100%" sono nomi-densità
fissi.

### Unità di `FogStartDist` / `FogEndDist`

Sono float in **inches** (unità interna SU), NON 0..1 normalizzati come
si potrebbe pensare leggendo la doc Trimble. Empiricamente: su un modello
con bbox diagonal ~83000 inches, valori tipici per fog sono nell'ordine
di centinaia o migliaia di inches.

UI Properties converte:
- inches ↔ unità modello via `INCHES_PER_UNIT[length_unit]` dove
  `length_unit = model.options['UnitsOptions']['LengthUnit']` (0=in,
  1=ft, 2=mm, 3=cm, 4=m).
- Range slider dinamico: `fog_max_user_units = bbox.diagonal_user * 2`
  (clamp min 1.0). Così su modelli da 100m o da 10mm lo slider ha sempre
  proporzioni utili.

Label dell'unità (es. "m", "mm") accanto a ogni input numerico, presa da
`user_unit_label`.

### Pattern apply (replica nativo Window → Fog)

`PropertiesDialog.fog_apply`:
1. Scrive `model.rendering_options['DisplayFog'/'FogStartDist'/'FogEndDist']`.
2. **Se la scena del Properties è quella attiva nel viewport**, fa
   `page.update(PAGE_USE_RENDERING_OPTIONS)` per snapshottarsi le RO
   correnti nella scena. Altrimenti il modello cambia ma la scena non
   lo cattura.
3. **MAI `update_selected_style`**: lo stile diventa "dirty" come fa il
   native Fog dialog, ma le altre scene mantengono il loro fog. Se
   committassimo nello style, tutte le scene che lo usano cambierebbero
   fog.

PAGE_USE_RENDERING_OPTIONS lookup difensivo via `ro_use_bit_safe` (prova
`Sketchup::PAGE_USE_RENDERING_OPTIONS`, poi `Sketchup::Page::...`,
fallback `2`).

### Vincolo "scena attiva"

La fog si può leggere/editare solo sulla scena attualmente attiva nel
viewport (è una RO del modello → riflette il viewport, non la scena
arbitraria che l'utente ha aperto in Properties). Se Properties è
aperto su scena non-attiva: controlli `disabled` + banner con bottone
"Activate this scene" → callback `sm_props_activate_scene`.

`scene_payload` include `is_active = active_page_id == id` per il flag.

### Vincolo `start < end`

Applicato lato JS in tutti i punti di modifica utente (drag thumb,
click track, bottoni +/-, input numerico). Helpers `constrainStart` /
`constrainEnd` con epsilon adattivo `max/10000`. Il thumb in movimento
si ferma al limite, l'altro non viene spinto via (= comportamento
nativo SU).

Negli input numerici il clamp scatta **al commit** (change/blur/Enter),
NON durante typing — così l'utente può digitare "1500" un digit alla
volta senza che il campo si auto-corregga.

### Dual-handle slider custom (pattern)

HTML5 non offre nativamente un range con due thumb. Costruito con:
- `<div id="fog-dual">` container con width fluida.
- `<div class="fog-track">` linea di sfondo.
- `<div id="fog-fill">` riempimento gradient tra i due thumb (densità).
- Due `<div class="fog-thumb">` posizionati con `style.left = '%'`,
  draggabili via `mousedown` + `mousemove`/`mouseup` su document.
- Click sulla track sposta il thumb PIÙ VICINO alla posizione del click
  (decide via `Math.abs(v - fogValues.start) <= Math.abs(v - end)`).
- Le label "0%" / "100%" dentro ai thumb (`.fog-thumb-lbl`) sono assolute
  e centrate, non draggabili (pointer-events: none).

Commit a Ruby solo al rilascio del drag (`onFogUp`), non durante:
mantiene il pattern "no write-spam su modelli con AttributeObserver
terzo a 5s/write".

### Number input spinner in CEF SU 2019: sono inutilizzabili

I `<input type="number">` in CEF di SU 2019 hanno spinner microscopici
(2-3 px wide) e a volte i click non vengono registrati. Soluzione
standard adottata per la fog (replicabile altrove):

1. Nasconderli via CSS:
   ```css
   input[type="number"] { -webkit-appearance: textfield; appearance: textfield; }
   input[type="number"]::-webkit-inner-spin-button,
   input[type="number"]::-webkit-outer-spin-button {
     -webkit-appearance: none; margin: 0;
   }
   ```
2. Fornire bottoni custom `−` / `+` 22×22px ai lati dell'input.
3. **Auto-repeat**: dopo 350ms di hold parte un `setInterval` ogni 60ms,
   stoppato su mouseup/mouseleave/blur. Un solo commit Ruby alla fine.
4. **Modificatori**: Shift = step×10 (passo largo), Ctrl = step÷10
   (passo fine). Cattura `e.shiftKey` / `e.ctrlKey` al mousedown,
   NON al click successivo (perdita stato modificatore).
5. **Step adattivo alla scala**: `baseStep = max / 200` arrotondato a
   "step rotondo" (1/2/5 × 10ⁿ) — su modello 100m → 0.5m, su modello
   10mm → 0.05mm.

## Copia/incolla scene cross-file (Fase A+B implementate — 2026-05-31)

> ✅ **Fase A (Copy) + Fase B (Paste base) IMPLEMENTATE.** Fase C (layer
> match-by-name) e D (rifiniture) ancora da fare — il design sotto resta il
> riferimento per quelle.
>
> **Variante UX rispetto al design originale**: NON due bottoni toolbar
> Copy/Paste (no spazio in larghezza). Invece il vecchio bottone **refresh**
> (`btn-refresh`, ridondante: ri-pushava lo stato già pushato a ogni mutazione,
> non era nel manuale) è stato **riusato** come bottone 📋 (`btn-clipboard`)
> che apre una **finestra separata** `UI::ClipboardDialog` con Copy/Paste
> (e spazio per futuri bottoni).
>
> File implementati:
> - `core/clipboard.rb` — `copy(uids)` / `read` / `peek` / `paste`. Clipboard
>   su `~/.scene_manager_plus/clipboard.json` (schema `smp-scene-clipboard/1`).
> - `ui/clipboard_dialog.rb` + `html/clipboard.{html,css}` + `js/clipboard.js`
>   (mirror leggero di ExportDialog, `STYLE_DIALOG`, callback `sm_clip_*`).
> - `Core::Styles.allocate_new_slot_from_ro_hash(ro_hash, nickname:)` — variante
>   di `allocate_new_slot_from_viewport` che applica uno snapshot RO arbitrario
>   (hex→Color via `hex_to_color`/`color_to_hex`, helper riusabili). Scrive
>   sempre `SilhouetteWidth`+`ProfileWidth`.
> - Wiring: `sm_open_clipboard` in `dialog.rb`, `openClipboard` in `bridge.js`,
>   handler `btn-clipboard` in `app.js` (passa `selection` corrente).
>
> Cosa viaggia: camera (eye/target/up in inches, persp/fov o ortho/height),
> name, description, flag `use_*` (diff `current != v` in paste — regola
> anti-crash MP), stile (snapshot delle **61** rendering_options → slot pool,
> con nickname+badge color), fog (dentro le RO), colore scena. Match Photo
> escluse con report. Layer/section planes/hidden geometry NO (Fase C+).
>
> Copy agisce sulla **selezione della main window** (come Export). Ri-cliccare
> 📋 con la finestra aperta aggiorna la selezione (bring_to_front + push_state).
>
> **Verifica live via MCP `eval_ruby` (2026-05-31)**: moduli caricati, color
> hex↔Color round-trip esatto, `Sketchup::Camera.new` OK persp/ortho, **61 RO
> serializzate / 0 scartate**. Round-trip copy→paste reale su 2 file validato
> dall'utente (con i fix sotto).
>
> **Fix di rifinitura applicati (2026-05-31, dopo test utente)** — vedi anche
> `docs/SU2019-LESSONS.md`:
> - **Alpha-preserving transfer**: `Core::Styles.color_to_hex` ora emette
>   `#rrggbbaa` e `hex_to_color` accetta 6 o 8 cifre (sono usati SOLO dal
>   clipboard; badge/scene color/mini style manager hanno percorsi 6-hex
>   separati). Senza, il `HorizonColor` nativo "non impostato" `(0,0,0,a=0)`
>   diventava nero opaco e non si trasferiva: il colore nativo si trasferiva
>   solo se modificato almeno una volta. **`normalize_horizon!` RIMOSSO dal
>   paste** (`allocate_new_slot_from_ro_hash`): col transfer fedele il paste deve
>   riprodurre l'orizzonte sorgente esatto; `normalize_horizon!` resta solo in
>   `allocate_new_slot_from_viewport` ("+ New style", default bianco).
> - **HorizonColor risolto**: controllo "Horizon color" aggiunto al Mini Style
>   Manager (Background) — espone una RO che SU non mostra da nessuna UI nativa.
>   `serialize_value` mostra `#ffffff` come display quando il valore è il sentinel
>   cattivo (nero/alpha-0), coerente con `normalize_horizon!`. Nuovi slot ("+ New
>   style") nascono con orizzonte bianco.
> - **Viewport invisibile a copy/paste**: copy (`read_styles_snapshot`) e paste
>   salvano la vista attiva e la ripristinano a fine operazione. Ripristino via
>   `selected_page = prev_page` (ricarica la camera salvata COMPLETA, two-point +
>   pan inclusi); `Camera.new(eye,target,up,persp)` è solo fallback per camera
>   libera ed è **lossy** (perde il two-point). In copy guard MP: la pagina
>   attiva è la stessa → ri-selezionarla se MP rischia BugSplat, quindi per MP
>   non ri-seleziono (lo snap ha già ripristinato la camera).
> - **Color popup**: aprire lo swatch non committa più il colore corrente
>   (`color_popup.js`: `onApply` annullato durante il `setFromHex` iniziale di
>   `show()`). Prima, aprire il popup riscriveva subito il colore mostrato.
>
> **LIMITE INVALICABILE — Two Point Perspective non trasferibile**: le scene
> "raddrizzate" (`camera.is_2d? == true`) NON sono ricreabili da dati
> serializzati. SU 2019 NON espone `center_2d=`/`scale_2d=`/`is_2d=`
> (tutti NoMethodError) e `Camera#copy` AZZERA lo stato 2d (verificato via MCP
> anche su pan reale). L'unico modo di ottenere il 2d è `selected_page = page`
> su una scena che lo ha GIÀ salvato. Quindi la scena incollata mantiene
> eye/target corretti ma in **prospettiva normale** (non raddrizzata). `camera_of`
> serializza comunque `is_2d`/`center_2d`/`scale_2d` (record/detection) e la copy
> **avvisa** nel report quando ci sono scene two-point. Workaround imperfetto non
> implementato (scelta utente): `send_action` Two-Point in paste raddrizzerebbe
> le verticali ma con pan centrato (≠ sorgente).
>
> **Limiti noti / TODO aperti ancora veri**:
> - Fase B alloca uno slot per ogni stile sorgente distinto (no riuso di stili
>   equivalenti già in destinazione — è Fase D). Possibile esaurimento pool su
>   incolli ripetuti.
> - `color_to_hex` 8-hex preserva l'alpha; le scene incollate two-point restano
>   prospettiva normale (vedi sopra).

### Obiettivo

Selezione scene nel file A → "Copy scenes" → apertura file B → "Paste
scenes" → ricreazione delle scene con camera, stile, fog, flag, naming.

### Vincoli architetturali che obbligano il design

1. **No oggetto `Style` trasferibile**: `Styles#add_style` accetta solo
   `.style` da disco; niente clone/rename via API (vedi sez. "Style pool").
   → Lo stile viaggia come **snapshot del dict `rendering_options`** (colori
   serializzati hex) e in destinazione viene iniettato in uno **slot del
   pool** riusando `allocate_new_slot_from_viewport` (o una sua variante che
   prende un hash RO invece del viewport corrente).
2. **Cross-processo**: SU 2019 Windows può aprire file in istanze separate →
   una var Ruby module-level NON è condivisa. → Clipboard su **file su disco**:
   `~/.scene_manager_plus/clipboard.json`.
3. **No keydown globali in CEF** + Ctrl+C/Ctrl+V riservati da SU per la
   geometria → **bottoni toolbar** "Copy scenes"/"Paste scenes" (+ opz.
   `UI::Command` con voce menu per shortcut assegnabile da Preferences).
4. **Layer = oggetti diversi nei due file** → match **solo by-name**.
5. **Match Photo non trasferibile** (foto/path non leggibili) → escludere
   con avviso, come già in `add_from_view`.

### Tabella trasferibilità

| Campo scena | Trasferibile | Note |
|---|---|---|
| Camera (eye/target/up/perspective/fov/aspect_ratio) | ✅ pieno | API completa R/W |
| Nome | ✅ | dedup nomi in destinazione |
| Descrizione | ✅ | |
| Flag `use_*` (8) | ✅ | riscrivere con diff `current != v` |
| Stile (rendering_options) | ✅ via slot pool | snapshot RO → slot; dedup per stile sorgente |
| Fog (DisplayFog/FogStartDist/FogEndDist) | ✅ | dentro le RO |
| Nickname stile / badge color / colore scena | ✅ | metadata plugin, riapplicabili |
| Visibilità tag/layer | ⚠️ parziale | match by-name; mancanti ignorati o creati su opzione |
| Section planes | ❌ | legati a geometria del file sorgente |
| Hidden geometry | ❌ | idem |
| Scene Match Photo | ❌ | API non espone foto/path → escludere con avviso |

### Schema `clipboard.json` (v1)

```jsonc
{
  "schema": "smp-scene-clipboard/1",
  "created_at": "2026-05-30T12:00:00",          // ISO8601 local
  "source_model": "Pedrazzoli.skp",             // basename, solo per UI/debug
  "source_model_guid": "abc-123",               // sanity check (paste su stesso file = warn)
  "styles": [                                    // dedup: 1 entry per stile sorgente usato
    {
      "key": "src-style-0",                      // id locale referenziato dalle scene
      "native_name": "SM+ Slot 03",             // info, NON usato in destinazione
      "nickname": "Vista normale",              // riapplicato come nickname in dest (se libero)
      "badge_color": "#4ea1ff",                 // "" se assente
      "rendering_options": {                     // snapshot completo, colori → "#rrggbb"
        "EdgeColorMode": 1,
        "SilhouetteWidth": 1.0,                  // scrivere ANCHE ProfileWidth in dest
        "BackgroundColor": "#ffffff",
        "DisplayFog": false,
        "FogStartDist": 0.0,
        "FogEndDist": 0.0
        // ... tutte le chiavi di model.rendering_options.each_pair
      }
    }
  ],
  "scenes": [
    {
      "name": "Sezione AA",
      "description": "",
      "scene_color": "#ffcc00",                  // "" se assente (metadata plugin per-scena)
      "style_key": "src-style-0",                // ref in styles[]; null se scena senza stile
      "flags": {                                 // gli 8 use_*
        "use_camera": true, "use_style": true, "use_shadow_info": true,
        "use_hidden": true, "use_layer_visibility": true,
        "use_section_planes": true, "use_axes": true,
        "use_rendering_options": true
      },
      "camera": {
        "perspective": true,
        "eye": [x, y, z], "target": [x, y, z], "up": [x, y, z],
        "fov": 35.0,                             // se perspective
        "height": null,                          // se ortho (camera.height)
        "aspect_ratio": 0.0,                     // 0.0 = usa viewport; !=0 → probabile MP, escludere a monte
        "image_width": null
      },
      "layer_visibility": [                       // by-name; SOLO override significativi
        { "name": "Quote", "visible": false },
        { "name": "Arredi", "visible": true }
      ],
      "is_matchphoto": false                      // se true → NON serializzare (avviso in Copy)
    }
  ]
}
```

**Note di serializzazione:**
- Colori: `Sketchup::Color` → `"#rrggbb"` (drop alpha). In lettura hex → `Sketchup::Color`.
- Lunghezze camera in **inches** (unità interna SU), nessuna conversione: il
  paste le riapplica raw.
- `layer_visibility`: salvare la visibilità **effettiva** della scena
  (`page.layers` è la hidden-list, semantica controintuitiva — vedi
  `SU2019-LESSONS.md` "Sketchup::Page#layers"). Da decidere in Fase C se
  salvare tutti i layer o solo i diff dal default; propendere per "tutti i
  layer non-visibili" per minimizzare il payload.

### Regole di paste (destinazione)

1. **Tutto in 1 `start_operation`** (1 Ctrl+Z), con `disable_ui=true`.
2. **Stili: dedup + riuso.** Per ogni `styles[].key` allocare **uno** slot
   (non uno per scena). Prima di allocare, cercare in destinazione uno stile
   con stesso nickname/RO equivalenti → riusarlo. Pool esaurito → messagebox
   come già in `allocate_new_slot`. Scrivere SEMPRE sia `SilhouetteWidth` che
   `ProfileWidth` (alias non-ufficiale, vedi sez. Mini Style Manager).
3. **Scene**: `pages.add`, poi forzare i flag dallo schema con diff
   `current != v` (regola anti-crash MP), set camera, assegnare lo stile via
   `assign_style` (riusa il workaround esistente), applicare fog se la scena
   diventa attiva (`page.update(PAGE_USE_RENDERING_OPTIONS)`).
4. **Layer (Fase C)**: per ogni `layer_visibility[]` se esiste layer omonimo
   → `page.set_visibility(layer, visible)`; mancanti → report (opzione "crea").
5. **Nomi**: dedup con suffisso incrementale se collisione.
6. **Metadata**: applicare nickname (se libero, validazione unicità esistente),
   badge color, colore scena.
7. **Ordine logico**: appendere le nuove scene in coda all'ordine logico
   corrente (o opz. dentro una cartella "Pasted").
8. **Report finale**: messagebox con conteggio scene create / stili
   riusati vs allocati / layer mancanti / scene MP saltate.

### Fasi di sviluppo

- **Fase A — Copy**: serializzazione selezione → `clipboard.json`, esclusione
  MP con avviso, bottone toolbar.
- **Fase B — Paste base**: camera + flag + nome + stile (slot+dedup) + fog,
  report. (Niente layer ancora.)
- **Fase C — Layer match-by-name**: override visibilità + opzione "crea
  mancanti".
- **Fase D — Rifiniture**: dedup/riuso stili intelligente, metadata completi,
  ordine logico/cartella "Pasted", gestione pool esaurito.

### Primitive esistenti da riusare

- `Core::Styles.allocate_new_slot_from_viewport` → serve una variante
  `allocate_new_slot_from_ro_hash(ro_hash, nickname:)` che applichi uno
  snapshot arbitrario invece del viewport corrente.
- `Core::SceneModel.assign_style`, `matchphoto?`, `page_id`, `set_scene_color`.
- `Core::Styles.set_nickname` (validazione unicità), `set_color`.
- Pattern hidden-spawn non serve (niente PowerShell qui).

## Generazione manuale utente (docx/pdf) — toolchain su questa postazione

Manuale utente in `Scene Manager+ - Manuale utente.docx` + `.pdf` (root repo),
generato da `tools/gen-manual.py`. Da rigenerare quando si aggiungono feature.

Trappole ambiente (dev machine):
- **Niente Node/npm**: la skill `docx` di Anthropic usa `docx-js` (Node) →
  non funziona qui. Usare **`python-docx`** (`py -m pip install python-docx`).
  `tools/gen-manual.py` è già in python-docx, idempotente, riscrive entrambi
  i file.
- **Niente LibreOffice**: `soffice` non installato → lo script `soffice.py`
  della skill fallisce. Per il PDF usare **Word via COM** (Office 2013 in
  `C:\Program Files\Microsoft Office\Office15\WINWORD.EXE`):
  `Word.Application` → `Documents.Open` → `Fields.Update()` +
  `TablesOfContents.Update()` (aggiorna l'indice TOC) → `SaveAs(pdf, 17)`
  (17 = `wdFormatPDF`) → `Quit()`. L'indice è un vero campo `TOC` inserito via
  OOXML in gen-manual.py, quindi va aggiornato prima del SaveAs.

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
