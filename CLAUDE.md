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
| Nuova scena da vista | Icona toolbar (📷+) → `SceneModel.add_from_view`. Replica gli override di visibilità layer della pagina attiva (vedi sotto, "Add visible tag"). **Forza tutti gli 8 `FLAG_KEYS` (use_camera, use_style, ecc.) a `true`** dopo `pages.add`, così la nuova scena cattura sempre lo state completo del viewport — `pages.add` da solo rispetta i "Default Scene Properties" globali di SU e se l'utente li ha personalizzati (es. Style/Fog OFF) la scena nascerebbe monca. Scelta UX: il flusso del plugin è "scatta foto completa", non "rispetta i miei default SU". **Se la scena attiva è Match Photo** prende invece il ramo `add_from_view_native` (comando nativo via `send_action`, asincrono → post-processing in timer): vedi sezione "Match Photo". Da lì in poi `add_from_view` ritorna la Page solo nel ramo sincrono — **i chiamanti devono usare il blocco `on_created`**. |
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
├── assets/styles/_template.style   # UNICO template per creare stili nuovi
│                                   # (vedi sez. "Stili nativi: creazione + rinomina")
├── assets/titleblock/              # asset bundlati per il cartiglio
│   ├── company.txt                 # 4 righe dati aziendali
│   └── logo.jpg                    # logo aziendale per il cartiglio
├── core/
│   ├── buffer.rb                   # Defer mode: stato globale edit in RAM + flush!
│   ├── native_panel.rb             # controlli Win32 dei pannelli nativi (fiddle)
│   ├── exporter.rb                 # Batch export PNG/JPG + watermark + titleblock via ImageRep
│   ├── folders.rb                  # cartelle logiche (schema + load/save)
│   ├── layers.rb                   # layer/tag model-wide + payload per-scena
│   ├── naming.rb                   # format/preview/apply_rename pattern
│   ├── previews.rb                 # cache PNG anteprime per-modello persistente
│   ├── scene_model.rb              # wrapper su Sketchup.active_model.pages
│   ├── settings.rb                 # config persistente con defaults
│   ├── styles.rb                   # pool slot + nickname per-modello
│   ├── text_render.rb              # PowerShell+System.Drawing per filename label
│   ├── titleblock.rb               # PowerShell+System.Drawing per cartiglio
│   └── variants.rb                 # varianti colore per-scena (override materiali)
└── ui/
    ├── dialog.rb                   # Main HtmlDialog + bridge + polling scene attiva
    ├── export_dialog.rb            # Dialog Export (scope picker + progress)
    ├── layer_info_dialog.rb        # Contenuto di un layer (HTML generato, no asset)
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

### Nota "Version Control X" nel dialog Export (solo promemoria)

In fondo alla sezione Output di `export.html` c'è un riquadro ambra
(`.warn-vcx` in `export.css`) che ricorda la trappola dei set condivisi via
Version Control X (repo `C:\Claude\Version Control X`): l'export archivia e
rimpiazza solo il set **locale**; se si tolgono o rinominano scene, nelle
cartelle dei colleghi restano immagini del set vecchio che sembrano valide
(la numerazione `{nnn}` slitta: l'orfano è l'ultimo numero) e la bonifica di
VCX le riporterebbe sul master. È testo statico, nessuna logica — se si
cambia il flusso di export/archivio, aggiornare anche la nota. VCX dal canto
suo esclude `Superate/` dalla propria bonifica (dalla sua v3.18); una difesa
attiva (manifest del set scritto dall'export) è discussa ma non implementata.

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

## Match Photo — cosa l'API non espone, e cosa invece si può fare

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
>   `capture_style!`), assicurarsi che il comportamento atteso da
>   3dg_photomatch sia ancora coperto. In particolare: le scene create da
>   `add_matchphoto_page` nascono con `page.style == nil`, ed è quello che
>   rende necessaria la cattura dello stile (vedi "Style and Fog" più sotto).
>   Se un domani 3dg_photomatch salvasse uno stile alla creazione, la
>   cattura diventerebbe un no-op — non un problema, ma sapendolo si evita
>   di cercare un bug che non c'è.
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
- **Opacità "Foreground Photo" / "Background Photo"** (gli slider nella
  sezione Match Photo del pannello Styles → Edit) NON è esposta da
  nessuna parte. Verificato live via MCP `eval_ruby` (2026-07-07,
  SU 2019): enumerate tutte le **61** rendering options (`ro.each_pair`)
  → nessuna chiave photo/foreground/background-opacity/alpha; enumerate
  tutti i 5 provider di `model.options` (PageOptions, UnitsOptions,
  SlideshowOptions, NamedOptions, PrintOptions) → niente. Le uniche RO
  "fore/back" sono `ForegroundColor`/`BackgroundColor` (colori bordi/sfondo)
  e `FaceBackColor`/`DrawBackEdges`.
  Ri-verificato il **2026-08-01 con la scena Match Photo ATTIVA nel
  viewport** — la condizione in cui una chiave dovrebbe materializzarsi:
  61 chiavi prima, 61 dopo, **zero chiavi nuove**. Altri angoli battuti,
  tutti negativi: 14 nomi plausibili letti a mano
  (`ForegroundPhotoOpacity`, `PhotoOpacity`, `DisplayForegroundPhoto`...)
  → tutti `nil`; `Sketchup::Style` **è un `Entity`** e quindi espone
  `attribute_dictionaries`/`get_attribute`, ma sullo stile MP ritorna
  `nil`; `page.attribute_dictionaries` vuoto; **`page.rendering_options`
  ritorna `nil`** in SU 2019; il formato `.style` su disco non contiene
  campi photo/opacity. (La costante globale `PhotoMatch` che compare in
  `Object.constants` è il plugin `3dg_photomatch`, non un'API SU.)
  ⚠️ **La feature è comunque implementata** (2026-08-01): il valore vive
  nel pannello nativo, che su Windows è Win32, e i suoi slider sono
  `msctls_trackbar32` veri — leggibili e scrivibili dall'interno di
  SketchUp. Vedi la sezione **"Controlli dei pannelli nativi
  (`Core::NativePanel`)"**. La conclusione precedente ("archiviata come
  non fattibile") era giusta sull'API e sbagliata sulla feature: non
  confondere "l'API non lo espone" con "non si può fare".

L'unica API esposta è `Sketchup::Pages#add_matchphoto_page(image_filename,
camera, page_name)`, che richiede il path della foto — non leggibile
dall'API. (La foto però è recuperabile dal `.skp`: vedi più sotto.)

### RISOLTO (2026-07-31): `pages.add` era l'unico colpevole

**La vecchia teoria dei "due binari diversi" era sbagliata.** Sosteneva che
solo il click manuale sul menù raggiungesse l'handler C++ con accesso al
Match Photo, mentre `send_action(21067)` sarebbe stato instradato su un
handler "scripting-safe" che lo bypassa. Non è così.

Verificato live su SU 19.3.253 (modello `Roman - Esecutivo.skp`):

| Via | Foto nella scena creata |
|---|---|
| `pages.add(name)` | ❌ persa — **è l'unico percorso che la perde** |
| `Sketchup.send_action(21067)` | ✅ **0 differenze su 47.000 campioni** |
| `PostMessage(WM_COMMAND, 21067)` al frame Win32 | ✅ 0 differenze |

**Come verificare** (usare questo, non le proprietà della pagina):
attivare un'altra scena, tornare sulla nuova, `view.write_image` e
**confrontare i pixel** con un render dell'originale. Leggere
`aspect_ratio` / `is_2d?` NON basta — vedi falsi positivi più sotto.

**Perché l'errore è sopravvissuto così a lungo**: `send_action` è
**asincrono**. Accoda il comando e ritorna subito; nella stessa chiamata
Ruby `pages.count` è ancora quello di prima e la pagina non esiste
ancora. Chi controlla immediatamente dopo vede "non ha fatto niente" e
conclude che non funziona. Quella misura fragile è finita in questo file
promossa a *"limite invalicabile"*, e da lì nessuna sessione l'ha più
rimessa in discussione. **Lezione di metodo: una misura negativa su
un'API asincrona non è una prova.** (Trappola viva: è ricascato nello
stesso errore anche chi ha scritto il fix, misurando il callback prima
che il timer scattasse.)

**Implementazione** (`SceneModel.add_from_view`, ramo `is_mp`):

- `add_from_view_native` → `send_action(add_scene_cmd_id)`;
- `await_native_page` → catena di `UI.start_timer(0.05)` (max 60 giri)
  che rileva la pagina nuova per diff di `page.object_id` (**stabile in
  sessione**, verificato);
- `finalize_native_page` → nome, flag, override visibilità layer, uid,
  dentro `start_operation(..., transparent=true)` così un solo Ctrl+Z
  annulla scena + finalizzazione insieme;
- `add_from_view` accetta un blocco `on_created`, chiamato in linea nel
  ramo normale e **dal timer** nel ramo MP. Il valore di ritorno è la
  Page solo nel ramo sincrono: **chi chiama deve usare il blocco**;
- la finalizzazione scrive un flag **solo se differisce** (write spuri
  costano ~5s sui modelli con AttributeObserver terzi), e il dialog dello
  stile dirty è saltato di proposito: il ramo "Save as new style"
  cambierebbe `selected_style` sostituendo lo stile che porta la foto;
- **`use_style` / `use_rendering_options` NON sono più esclusi**
  (2026-08-01): venivano lasciati spenti per la vecchia teoria del
  "toccarli su MP crasha", smontata dal fix del null-deref. Ora li accende
  `capture_style!`, che scrive i flag **e** cattura lo stile nella stessa
  mossa — accenderli e basta è ciò che lascia la pagina nello stato che
  splatta quando `page.style` è `nil`. Risultato: la scena copiata da una
  MP nasce con tutte e 8 le proprietà spuntate (grip **giallo**, non
  rosso). Precondizione di `capture_style!`: la pagina dev'essere quella
  attiva — il comando nativo la attiva, ma se non lo fosse la cattura
  viene **saltata con un warning**, mai forzata attivandola in quello
  stato. Stessa protezione difensiva aggiunta al ramo sincrono
  (`pages.add` con i Default Scene Properties che hanno "Style and Fog"
  spento produceva `page.style == nil` + flag accesi = stesso stato
  pericoloso);
- command ID overridabile:
  `Sketchup.write_default('SceneManagerPlus', 'add_scene_cmd_id', N)`.

**Differenza visibile**: il comando nativo inserisce la scena **subito
dopo quella attiva**, mentre `pages.add` accodava in fondo.

### `matchphoto?` dà falsi positivi (2026-07-31)

L'euristica resta `page.camera.aspect_ratio != 0`. Ma `pages.add` copiava
la camera MP (aspect incluso) **senza** la foto: le scene create dal
vecchio percorso restano quindi marcate come Match Photo pur non
avendola. Col fix non se ne creano di nuove, ma i file esistenti ne
contengono. L'unico segnale davvero affidabile trovato finora per
distinguerle è renderizzare e guardare lo sfondo.

### La foto Match Photo È dentro il `.skp` (2026-07-31)

Non serve più per `add_from_view`, ma serve per la **clipboard
cross-file**, dove oggi le scene MP sono escluse per principio.

Nel binario del `.skp` c'è il path della foto come stringa **UTF-16**
(relativo al modello, es. `.\Rilievo\Foto\2026-06-04 19.12.32.jpg`),
subito dopo il blocco di geolocalizzazione della scena. **~90 byte più
avanti inizia il JPEG completo**, a piena risoluzione (4096×3072 nel caso
provato, aspect coincidente con `page.camera.aspect_ratio`).

Note pratiche:
- funziona anche quando il **file originale su disco non esiste più** —
  ed era il caso reale;
- serve il `.skp` **salvato**: il modello in RAM non basta;
- per isolare il JPEG **non fidarsi del primo `FF D9`** (il thumbnail
  EXIF ne ha uno suo, e si ottiene un file troncato): passare una coda
  abbondante al decoder lasciandogli ignorare il resto, oppure cercare il
  primo `FF D9` che produce un decode valido;
- anche le texture dei materiali stanno nello stesso file con lo stesso
  schema: distinguerle per path (quelle MP sono relative, `.\`) o per
  aspect ratio.

Con questo `add_matchphoto_page(foto_estratta, camera, nome)` torna
percorribile. Incognita mai testata: se la calibrazione two-point
sopravviva (`camera.is_2d?`) — vedi "Two Point Perspective" in
`docs/SU2019-LESSONS.md`.

Documentazione di partenza: `tools/dump-matchphoto-api.rb` (cosa l'API
Ruby espone su Match Photo) e `tools/dump-matchphoto-attrs.rb` (cosa
salva negli attribute_dictionaries — niente di utile).

### RISOLTO (2026-08-01): "Style and Fog" era un null-deref, non una maledizione MP

**Sintomo storico**: accendere "Style and Fog" (`use_style` +
`use_rendering_options`) su una scena Match Photo da SM+ portava al
BugSplat alla successiva attivazione. Ripiego adottato per mesi: il
checkbox non toggava, apriva il pannello **Scenes nativo** e l'utente
metteva la spunta lì.

**Causa reale** (misurata su 19.3.253 via MCP `eval_ruby`): non c'entrano
né Match Photo né i setter Ruby. Quelle pagine hanno **`page.style == nil`**
— non hanno MAI salvato uno stile, perché sono nate con i flag di stile
spenti (`add_matchphoto_page` di plugin terzi, o il vecchio
`pages.add` di SM+). Accendere `use_style` significa "all'attivazione
ripristina lo stile salvato": se non ce n'è uno, `pages.selected_page = page`
mette **`model.styles.selected_style` a `nil`** e da lì il modello è in uno
stato dal quale qualunque operazione successiva può splattare.

Sequenza verificata, con dentro il controllo negativo:

| Passo | `page.style` | `styles.selected_style` |
|---|---|---|
| partenza (scena MP legacy) | `nil` | ok |
| `use_style = true` (solo flag) | `nil` | ok |
| → attivazione | `nil` | **`nil`** ← qui nasce lo splat |
| `use_style = true` + `page.update(8\|2)` con la pagina attiva | lo stile corrente | ok |
| → attivazione, ripetuta | stabile | ok, **foto intatta** |

Il pannello nativo non usa un "pathway C++ pulito": fa esattamente
flag + cattura, cioè quello che ora fa `SceneModel.capture_style!`.

**Fix applicato** — `Core::SceneModel.capture_style!` / `style_missing?`,
chiamati da `update_page`, `Buffer.flush!` e dal comando "Save all
properties" in `main.rb`. Due vincoli d'ordine non negoziabili:

1. la pagina va **attivata PRIMA** di scrivere i flag — attivarla dopo
   significa attivare proprio la combinazione che azzera `selected_style`;
2. `page.update` cattura ciò che il viewport mostra **adesso**, quindi la
   pagina deve essere quella attiva (in `Buffer.flush!` le pagine da
   catturare sono rimandate a un secondo passaggio per questo).

La condizione è `page.style.nil?`, **non** `matchphoto?`: è generale, le
scene MP sono solo il caso in cui capita in pratica. Una volta che una
pagina ha uno stile salvato, spegnere e riaccendere il flag **non** lo
perde (verificato) — il pericolo esiste solo alla prima accensione.

**Persistenza verificata**, ed era la prova che contava di più: salvato il
file e riletto davvero da disco, flag e stile ci sono ancora e le foto sono
intatte. Se il flag persistesse e lo stile no, riaprire il file ricreerebbe
lo stato che splatta — il fix sarebbe peggio del problema. Per forzare una
rilettura di un file già aperto (serve per rifare questa prova) vedi
`SU2019-LESSONS.md`: `open_file` sullo stesso path è un **no-op** che ritorna
`true`, e `file_new` è **accodato** come `send_action`.

**Lezione di metodo, la stessa di `send_action`**: "scrivere i flag su una
scena MP crasha" era una correlazione osservata una volta e promossa a
causa. La causa vera si vedeva leggendo `page.style` un istante prima
dell'attivazione. Prima di aggirare un crash con un ripiego UI, misurare
*quale stato* il crash trova.

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

⚠️ **Questa diagnosi è probabilmente sbagliata nella parte "write spuri"**
(vedi la sezione precedente, 2026-08-01). Il repro citato — "scrivere tutti
gli 8 flag crasha, `p.use_axes = true` da solo no" — si spiega interamente col
null-deref: fra gli 8 c'è `use_style = true`, e quelle pagine avevano
`page.style == nil`; `use_axes` da solo non tocca lo stile. Non è stato
rimisurato isolando le due ipotesi. La regola del diff **resta valida** per
un'altra ragione, quella sì verificata: sui modelli con AttributeObserver di
plugin terzi ogni write costa ~5s.

### RISOLTO (2026-08-01): cambiare stile a una scena MP si può — era lo stesso null-deref

**Storia**: `SceneModel.assign_style` (e di riflesso "+ New style…") era
**vietato** sulle scene MP, con questa motivazione agli atti: *"`page.update`
con bit STYLE+RO sovrascrive lo stile MP interno (background foto) →
corruzione → splat; e comunque sostituire lo stile MP toglie la foto"*.
Il click destro sul badge lettera deviava sul pannello Styles nativo.

**Rimisurato**, un passo per volta, con **confronto di render** (non leggendo
proprietà): scena MP reale su 19.3.253, `styles.selected_style = altro` →
`page.update(8|2)` → uscita e rientro nella scena → `save` + rilettura da
disco.

| Passo | Esito |
|---|---|
| cambio stile attivo stando sulla scena MP | nessun crash, **foto presente** |
| `page.update(STYLE\|RO)` per legare la scena | nessun crash |
| esco e rientro (dove arrivava il BugSplat) | nessun crash, foto e `is_2d?` intatti |
| rimetto lo stile MP originale | render **identico** alla partenza |
| salvo, riapro da disco | foto presente, stile nuovo mantenuto |

**Due affermazioni della vecchia motivazione erano false**:

1. **La foto NON è agganciata allo stile.** Cambiando stile la foto resta;
   cambia solo come è disegnata la geometria. Coerente col fatto, già noto,
   che **nessuna delle 61 rendering options ha a che vedere con la foto**:
   se la foto non è nelle RO, uno stile non può portarsela via.
2. **Il crash non era del Match Photo.** È lo stesso null-deref di "Style and
   Fog": quelle scene hanno `page.style == nil` (le MP di plugin terzi
   nascono così) e accendere `use_style` su una pagina senza stile salvato
   mette `selected_style` a `nil`. Le scene MP di questo test uno stile ce
   l'avevano (`[Architectural Design Style]1`, il duplicato che SU crea da
   sé) e infatti non è successo nulla.

**Fix applicato**:
- `assign_style`: il divieto è sostituito da `confirm_mp_style_change` —
  `UI.messagebox` OK/Cancel mostrato **una sola volta per macchina**
  (`Sketchup.write_default('SceneManagerPlus', 'mp_style_change_ack', true)`;
  rimettere a `false` per rivederlo). Serve solo perché l'operazione cambia
  visibilmente il disegno e può partire da un clic destro di striscio.
- `assign_style` chiama `capture_style!(p) if style_missing?(p)` **con la
  pagina già attiva**, prima di toccare `selected_style`. È il vero
  discrimine, e copre le scene MP di `3dg_photomatch`.
- `sm_style_new` (`ui/dialog.rb`) chiede la conferma **prima** di creare lo
  stile: `assign_style` la chiederebbe da sé, ma a stile già creato, e un
  annullamento lascerebbe uno stile orfano nel modello.
- `app.js`: rimossa la deviazione `is_matchphoto → openNativeStylesPanel` nel
  `contextmenu` del badge. Il callback `sm_open_native_styles` e
  `SMBridge.openNativeStylesPanel` restano (non più chiamati da lì).

**NON verificato** (da fare quando capita sotto mano un file adatto): il ramo
`capture_style!(p) if style_missing?(p)` dentro `assign_style` è stato scritto
per le scene MP di `3dg_photomatch` (`page.style == nil`) ma **collaudato solo
su scene MP che uno stile ce l'avevano già** — nel file di prova non c'erano
scene senza stile. Il ramo è difensivo e replica una sequenza già verificata
altrove (il fix "Style and Fog"), ma non è stato esercitato in quella
condizione. Se un domani riappare un BugSplat assegnando uno stile a una scena
MP, **è il primo posto da guardare**.

⚠️ **Terza volta che la stessa diagnosi sbagliata viene smontata** (dopo
`send_action` e "Style and Fog"). Il pattern è sempre lo stesso: un crash
osservato una volta su una scena MP, promosso a proprietà del Match Photo,
e da lì mai più rimesso in discussione. Se in questo file trovi un'altra
frase del tipo "su Match Photo non si può X", **prima di costruirci sopra un
ripiego, misura quale stato il crash trova** — di solito è `page.style`.

### Letter badge "?" = scena MP (sintomo diagnostico)

Se nel main dialog di SM+ il letter badge di una scena mostra `?`, significa
che `page_style_name` ritorna nil.

Causa misurata (2026-08-01, 19.3.253): quasi sempre **`page.style` è proprio
`nil`** — la pagina non ha mai salvato uno stile. Non è che "lo stile MP non
sia enumerato in `model.styles`": su un file MP reale il suo stile c'era
eccome (`"[Architectural Design Style]1"`, il duplicato che SU crea per la
scena MP). Il badge resta comunque un buon marker delle scene MP di plugin
terzi, perché sono quelle che nascono senza stile salvato.

Conseguenza del fix "Style and Fog" (sezione sopra): appena si accende quel
flag la pagina acquisisce uno stile e **il `?` diventa una lettera**.

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

## Controlli dei pannelli nativi (`Core::NativePanel`) — 2026-08-01

Quando l'API Ruby non espone un'impostazione **ma il pannello nativo sì**, il
plugin può pilotare il controllo Win32 vero. Primo (e per ora unico) uso:
l'opacità Foreground/Background Photo della sezione Match Photo del pannello
Styles, che non esiste da nessuna parte nell'API (vedi la sezione Match Photo
per l'elenco degli angoli battuti).

**`fiddle` funziona dentro SU 2019** (stdlib Ruby): si parla con `user32.dll`
direttamente, niente spawn di PowerShell come per `TextRender`/`TitleBlock`.
Le `SendMessage` partono dal thread UI di SketchUp, che è lo stesso che
possiede quelle finestre → sono chiamate sincrone dirette alla window proc,
nessun rischio di deadlock.

### Le due trappole che fanno "non succede niente"

1. **`TBM_SETPOS` da solo non basta**: sposta il cursore dello slider ma NON
   notifica il parent. Serve il `WM_HSCROLL` successivo
   (`SB_THUMBPOSITION` + `SB_ENDSCROLL`, con l'hwnd della trackbar in lParam),
   altrimenti l'applicazione non sa che il valore è cambiato.
2. **`BM_SETCHECK` idem**: cambia solo il disegno della checkbox, serve il
   `WM_COMMAND`/`BN_CLICKED` al parent.

Con solo il primo messaggio tutto "sembra" funzionare (rileggendo il controllo
il valore è quello nuovo) ma il viewport non cambia: verificare sempre con un
confronto di render, non con la rilettura del controllo.

### Identificazione dei controlli: etichetta, non ID

Gli ID numerici non sono documentati e cambiano tra versioni. La strada
primaria è l'**etichetta**: nel pannello ogni slider segue immediatamente la
propria checkbox, quindi si cerca il `Button` con testo "Foreground Photo" e
si prende la prima trackbar dopo di lui. Si auto-valida (ha ritrovato
esattamente gli ID mappati a mano). Gli ID restano come fallback per SU
localizzato, sovrascrivibili con `write_default` (`mp_fg_track_ctrl_id` ecc.),
stessa convenzione di `add_scene_cmd_id`.

Per rimappare su un'altra versione: **`Core::NativePanel.dump('Styles')`**
stampa classe/id/testo/valore di ogni controllo. È l'equivalente di
`tools/dump-su-menu.ps1` per i command ID dei menu.

Mappa su 19.3.253: `Button 2881 "Foreground Photo"` + trackbar `2884`,
`Button 2880 "Background Photo"` + trackbar `2882` (range 0..100).

### Note operative

- Il pannello resta una finestra **top-level** anche se ancorato in un tray, e
  si trova per titolo (`"Styles"`) filtrando per PID. I controlli rispondono ai
  messaggi **anche quando sono invisibili** (tray su un'altra scheda) —
  verificato: non serve che l'utente abbia il pannello aperto sulla scheda
  giusta. Se la finestra non esiste proprio, `panel!` la apre con
  `UI.show_inspector`.
- Gli hwnd sono cachati e validati con `IsWindow`, così la chiusura del
  pannello non lascia handle morti.
- Tutto degrada: se `fiddle` manca o il controllo non si trova, i chiamanti
  disabilitano la UI invece di fallire.

### Sezione "Match Photo" nel Mini Style Manager

Checkbox + slider 0-100 + campo numerico per Foreground e Background Photo.
Dettagli non ovvi:

- **Visibile solo sulle scene Match Photo** (`state.is_matchphoto`): i controlli
  nativi esistono per qualunque stile ma non fanno nulla altrove. Il contesto è
  la scena da cui il dialog è stato aperto (fallback: la scena attiva).
  `match_photo_state` viene letto solo se serve — sulle scene normali non
  cammina nemmeno l'albero delle finestre.
- **Niente `update_selected_style`**: misurato che una modifica regge al cambio
  scena anche senza commit, e su scene MP committare lo stile è la mossa
  storicamente rischiosa.
- Drag throttlato a 60ms: ogni invio è un messaggio Win32 + un redraw.
- Dopo ogni scrittura si ri-pusha lo stato **letto dal pannello**: se la
  scrittura non fa presa la UI torna al valore reale invece di mentire.

### ⚠️ `selected_style = <stile già selezionato>` NON è un no-op

Riassegnare lo stile corrente **riapplica lo stile salvato e scarta le
modifiche pendenti**. `StyleDialog.select_style!` ora esce subito se il target
è già selezionato: senza quella guardia, ogni tick del drag dello slider Match
Photo (che passa da `select_style!` prima di scrivere) azzerava la scrittura
precedente. Vale per qualunque codice futuro che tocchi `selected_style=`.

### Non verificato

Se il valore finisca nel `.skp` salvato. `model.modified?` non diventa mai
`true`, nemmeno dopo `update_selected_style`, quindi i proxy non bastano:
serve salvare e rileggere da disco. Nota però che stiamo pilotando **lo stesso
identico controllo** dello slider nativo, quindi il comportamento è per
costruzione quello di SketchUp.

## Stili nativi: creazione + rinomina (2026-08-01 — sostituisce il pool)

> ⚠️ **Il pool dei 25 slot e i nickname NON esistono più.** Le sezioni
> "Fase 1A…1E" più sotto sono conservate come storia del perché il codice
> ha avuto quella forma, ma descrivono API rimosse
> (`allocate_new_slot*`, `prompt_nickname_loop`, `next_free_slot_index`).
> Il riferimento attuale è questa sezione.

### Cosa era sbagliato

Tutta l'architettura precedente poggiava su "`Sketchup::Style#name=` non
esiste in SU 2019". **È falso.** `name=` e `description=` esistono,
funzionano, e **persistono nel `.skp` salvato e riletto da disco**
(verificato 2026-08-01 su 19.3.253 — vedi tabella sotto). Da lì:

- **un solo template** (`assets/styles/_template.style`) importato N volte e
  rinominato subito dopo ogni import ⇒ stili illimitati con nomi arbitrari.
  I 25 `slot_NN.style` sono stati cancellati;
- **i nickname erano una finzione resa necessaria dal nome non scrivibile**.
  Ora il nome nativo è il nome: Window → Styles di SketchUp mostra finalmente
  la stessa cosa che mostra il plugin.

### Fatti verificati (19.3.253, 2026-08-01)

| Verifica | Esito |
|---|---|
| `style.name=` / `description=` dopo save + rilettura da disco | ✅ persistono |
| Legame scena→stile dopo rename | ✅ regge — è **per riferimento**, non per nome (come le istanze di un componente rinominato). Vale anche dopo reload |
| Rename sporca lo stile | ✅ no, `active_style_changed` resta `false` |
| `add_style` dello stesso file N volte | ✅ crea N stili distinti |
| `Style#persistent_id` | ❌ **stub, ritorna 0** (come `Material`) — inutilizzabile come chiave |
| Identità wrapper `Style` (`==` / `object_id`) | ✅ stabile in sessione |

### ⚠️ Unicità dei nomi: la trappola che obbliga a validare

SU **non valida l'unicità in sessione** (due stili omonimi convivono
tranquillamente), ma **al salvataggio ne rinomina uno in silenzio** con un
suffisso numerico (`"Foo"` + `"Foo"` → `"Foo"` + `"Foo1"`), e **non è
deterministico quale** dei due lo prenda. Siccome i metadata del plugin
(`SMP_style_colors`) sono chiavati per nome, un duplicato lascerebbe appunti
orfani **dopo la riapertura del file**, quando la causa non è più visibile.

Quindi l'unicità la impone il plugin, a monte: `style_name_taken?`,
`unique_style_name` (suffisso " 2", " 3"…), `rename_style` che rifiuta i
duplicati. Non è una rifinitura: è il requisito che tiene in piedi il resto.

### API `Core::Styles` attuale

| Funzione | Note |
|---|---|
| `import_template(m)` | Importa `_template.style` e ritorna lo Style nuovo. Identificazione **per identità wrapper** (`before`/`after` diff con `==`), NON per nome: il nome embedded può già esistere nel modello (file legacy) e un diff per nome fallirebbe in silenzio |
| `create_style(name:)` | Stile nuovo con le RO del template |
| `create_style_from_viewport(name:)` | Cattura le RO correnti (dirty edit inclusi) — usato da "+ New style…" e dal ramo "Save as new" del dirty-style dialog |
| `create_style_from_ro_hash(ro, name:)` | Snapshot RO arbitrario — usato dal paste cross-file |
| `rename_style(old, new)` | Rinomina + `rekey_metadata`. `false` se il nome è occupato |
| `rekey_metadata(old, new)` | Sposta il badge color; **cancella** il nickname legacy (dopo un rename esplicito il nome nativo è la verità) |
| `set_description` / `get_description` | Campo nativo SU |
| `prompt_style_name_loop(title:, label:, default:)` | Sostituisce `prompt_nickname_loop`. Ritorna stringa non vuota o `:aborted` |
| `legacy_nickname_candidates` / `migrate_legacy_nicknames!` | Migrazione (sotto) |

`display_name(name)` **resta** e rispetta ancora il nickname: serve ai file
legacy non ancora migrati, che devono continuare a funzionare come prima.

### Migrazione dei file legacy — bottone, mai automatica

Settings → Styles → **"Update legacy style names…"**
(`sm_settings_migrate_style_names`): per ogni stile con nickname, il nickname
diventa il nome nativo, il badge color lo segue, la entry del dict sparisce.
Collisioni risolte con `unique_style_name`. Tutto in **una sola
`start_operation`** (i write di attributi costano ~5s l'uno sui modelli con
AttributeObserver di plugin terzi).

**Scelta esplicita dell'utente (2026-08-01): mai in automatico all'apertura.**
Rinominare stili dentro file già consegnati o condivisi (vedi la nota su
Version Control X) è una decisione sua, non un effetto collaterale.

Migrazione "opportunistica" gratuita: nel Mini Style Manager il campo **Name**
mostra il `display_name`, quindi su un file legacy mostra il nickname —
committarlo rinomina lo stile nativo e butta via il nickname. Un singolo stile
si migra da sé senza che l'utente debba saperlo.

⚠️ **Dopo un rename, `StyleDialog` aggiorna `@style_name`**: senza,
`select_style!` / `apply_changes` dei callback successivi cercherebbero un
nome che non esiste più.

### Storia (obsoleta, per contesto)

Le sottosezioni "Fase 1A…1E" seguenti descrivono il pool. Conservate perché
spiegano perché esistevano `SMP_style_nicks`, la validazione sui display_name
e il messagebox "pool esaurito" — non perché siano ancora vere.

## Style pool + nickname per-modello (Fase 1A — "+ New style…") — RIMOSSO

**Problema che si credeva irrisolvibile**: SU 2019 Ruby API non permette di:
- creare programmaticamente un nuovo stile da zero (`Styles#add_style`
  accetta solo `.style` file da disco) — ✅ vero,
- rinominare uno stile esistente (`Sketchup::Style#name=` non esiste) —
  ❌ **FALSO**, vedi sezione sopra,
- clonare uno stile (no `Style#save_as`, no `Style#duplicate`) — ✅ vero,
  ma irrilevante una volta che si può rinominare.

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
- ~~**WM_COMMAND Win32 per Match Photo**~~: **risolto 2026-07-31**, e
  senza Win32 — bastava `send_action`. Vedi sezione "Match Photo".
- ~~**`Sketchup::Style#name=` e `#description=`**~~: **chiuso 2026-08-01.**
  Entrambe le incognite verificate (persistenza su disco ✅, unicità: SU non
  valida in sessione ma **rinomina in silenzio al salvataggio** ⚠️), pool e
  nickname rimossi. Vedi "Stili nativi: creazione + rinomina".

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

## Cornice export + margine bianco anti-stampa (2026-07)

Due feature accoppiate in `Core::Exporter`, entrambe sul canvas **finale**
(disegno + eventuale cartiglio):

- **Cornice (frame)**: rettangolo nero sui 4 lati del canvas finale, come
  prosecuzione del bordo del cartiglio. Costanti `FRAME_ENABLED = true` /
  `FRAME_THICKNESS = 2` (px, = borderPen del titleblock) in cima al modulo —
  hardcoded per scelta utente, editabili al volo. Disegnata da `draw_frame!`
  (scrive byte neri opachi sul buffer BGRA, quindi visibile anche su export
  a sfondo trasparente). Il lato inferiore/angoli in basso **coincidono**
  con il bordo già disegnato dal cartiglio (stesso spessore/posizione) → si
  sovrappongono senza artefatti; drawing di un rettangolo pieno è quindi
  idempotente lì.
- **Margine bianco esterno** (`titleblock.white_margin_px`, default 2):
  `pad_white` espande il canvas di N px per lato con **bianco opaco**
  (`"\xFF".b * ...` = BGRA B=G=R=A=255) DOPO aver disegnato la cornice, così
  la cornice non è più sul bordo estremo e la stampa taglia il bianco invece
  della cornice (il problema era: in stampa il bordo destro veniva "mangiato").

Trappole / note di design:
- **`composite_to_file` ora gira SEMPRE**: la condizione di composite è
  `FRAME_ENABLED || white_margin > 0 || overlays || tb`. Con `FRAME_ENABLED`
  true, ogni export fa un load/set_data/save_file anche senza logo/label/
  cartiglio. È il costo di una cornice sempre-on (accettato). Se un domani si
  spegne la cornice, la condizione tiene comunque conto del margine e degli
  overlay.
- **Il margine vive nel gruppo settings `titleblock`** ma è applicato
  **sempre** (anche a cartiglio disabilitato), perché la cornice è
  indipendente dal cartiglio. UI: campo "White frame margin (px)" nella
  sezione Title block dei Settings.
- Ordine in `composite_to_file`: build buf (base + tb append) → blend overlays
  (clippati a `bh`) → `draw_frame!` sul canvas `bw × final_h` → `pad_white` →
  `set_data`. Il frame va disegnato PRIMA del pad, sennò finirebbe sotto il
  bianco.
- Rimosso il bottone "Rename scenes now" dai Settings (naming): era ridondante
  (l'utente non lo usa). `#apply-status` e `setStatus` restano (li usa ancora
  il "Saved" del naming auto-save); `SMS.setApplyResult` / `sm_naming_apply`
  sono ora dead-code innocuo.

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
   e in `properties_dialog.rb` (`sm_props_open_scenes_panel`). **Regola futura**:
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

## Layers nel Properties dialog (`Core::Layers`) — 2026-07-30

Sezione "Layers in this scene" sopra Display Fog: mini pannello Layers dentro
la scheda della singola scena.

### I due assi sono separati (decisione esplicita dell'utente)

- **Filtro della lista = PER-SCENA**: `model.layers − page.layers` (`page.layers`
  e' la hidden-list della pagina — semantica controintuitiva, vedi
  `docs/SU2019-LESSONS.md`). Se `use_hidden_layers?` e' false la scena non
  ripristina override: in quel caso si elencano TUTTI i layer e il payload
  espone `scene_tracks=false` perche' la UI lo spieghi.
- **Tutte le operazioni = SUL MODELLO**, come il pannello Layers nativo:
  visibilita', rename, layer corrente, colore, line style, add/delete/purge.
  La scena le cattura solo con "Update from view".

Conseguenza importante e non ovvia: **togliere la spunta NON fa sparire la riga**,
perche' il filtro dipende da `page.layers` e la spunta da `layer.visible?`. Le
righe con `visible? == false` si mostrano grigie/corsivo (`.is-hiddenmodel`):
e' il "drift" scena↔modello reso visibile. I layer nascosti *dalla scena* non
sono raggiungibili da qui — la nota in fondo li elenca per nome, e per
riaccenderli serve il pannello nativo + Update from view. Era chiaro all'utente
quando ha scelto il filtro: NON "correggerlo" in futuro senza chiedere.

### Bottone `+👁` — layer visibile solo in QUESTA scena

Variante di "Add Visible Tag" del plugin Layers Manager (repo di fianco,
`C:\Claude\Sketchup Plugins\Layers (add visible tag)`, vedi
`layers/layers_loader.rb` ~riga 178). L'originale fa:

```ruby
active = model.pages.selected_page
model.pages.each { |p| p.set_visibility(layer, p == active) }
```

cioe' e' ancorato alla scena **attiva**. Qui il target e' la scena aperta nel
Properties dialog, che puo' NON essere quella attiva — per questo
`Core::Layers.add_layer_visible_only_in(page)` e' una funzione separata e non
un riuso di quel comando. Aggiunge un passo che l'originale non ha:

```ruby
want_now = (active == page)
l.visible = want_now if l.visible? != want_now
```

**Serve per via dell'asimmetria di `set_visibility`** (verificata su SU 19.3.253,
vedi `SU2019-LESSONS.md`): su pagina NON attiva non tocca `layer.visible?`, su
pagina ATTIVA lo sincronizza. Quindi senza quella riga, con target ≠ attiva o
con `selected_page == nil`, il layer nascerebbe `visible? == true` e comparirebbe
subito nel viewport della scena sbagliata.

Come l'originale, setta `page_behavior = LAYER_IS_HIDDEN_ON_NEW_PAGES` (= 32 in
SU 2019) cosi' le scene future lo nascondono. Nota: `SceneModel.add_from_view`
snapshotta comunque `layer.visible?` PRE-add e lo applica alla nuova scena, quindi
creando una scena *dalla vista del target* il layer resta visibile anche li' —
coerente con la filosofia "scatta foto completa" del plugin, non un bug.

Ritorna anche `unconstrained`: le scene con "Visible Layers" spento non possono
nascondere nulla, quindi mostrerebbero il layer comunque → messagebox che le
elenca invece di promettere un'esclusivita' inesistente.

### Dettagli implementativi

- **Chiave di identita' = il NOME**, non `persistent_id` (su `Layer` non e'
  affidabile in SU 2019, stesso sospetto gia' confermato per `Material`, che
  ritorna 0). Il rename passa `{name, value}` e subito dopo si ri-pusha lo state.
- **Layer0 protetto** da rename e delete. Cancellare il layer **corrente**
  richiede di riportare prima `model.active_layer` sul default, altrimenti SU
  rifiuta.
- Delete: `UI.messagebox` YES/NO/CANCEL = mantieni geometria (va su Layer0) /
  cancella anche la geometria / annulla. `layers.remove` ha arity -1 e accetta
  `(layer, remove_geometry)`; c'e' comunque un `rescue ArgumentError` sul
  fallback a 1 argomento.
- Colore in `commitOnEnd` (vedi sez. `SMColorPopup`): si vede nel viewport solo
  con "Color by layer" attivo, quindi niente live update e una sola write.
  L'hex viaggia in `data-hex` sullo swatch: rileggere `style.background`
  darebbe `rgb(r, g, b)`, che `SMColorPopup` non accetta.
- `PropertiesDialog.push_state` ha ora il kwarg **`focus_layer:`**: il layer
  appena creato entra in rename inline, come il "+" nativo. Se aggiungi altri
  campi top-level allo state ricordati della trappola dei tre posti (vedi sez.
  "Trappola push_state").
- `renderLayers` **salta il re-render se l'input di rename ha il focus**
  (stesso principio del `setIfNotFocused`), e `finish()` fa `input.blur()`
  PRIMA di chiamare Ruby: sul path Enter l'input non perderebbe mai il focus
  da solo e il push_state di risposta verrebbe scartato.
- **Niente scroll interno alla lista** (richiesta esplicita): `.lay-list` non
  ha ne' `max-height` ne' `overflow`. Attenzione, basta impostare `overflow` su
  UN asse per creare un contenitore di scroll anche sull'altro. A scrollare e'
  `.body` dell'intero dialog.
- Il markup di `SMColorPopup` e' stato duplicato anche in `properties.html`
  (in CEF non si includono fragment HTML).

## Azioni sui layer + finestra contenuto (2026-07-31)

Estensione della sezione Layers del Properties dialog. Tre controlli nuovi:
`i` e `→` per-riga (stessa dimensione dello swatch colore, alla sinistra di
quest'ultimo) e `C` in toolbar.

| Controllo | Cosa fa |
|---|---|
| `→` per riga | Sposta la selezione del viewport su quel layer, **previa conferma OK/Cancel** con il riepilogo di cosa verrà spostato |
| `i` per riga | Apre `UI::LayerInfoDialog` col contenuto del layer |
| `C` in toolbar | Toggle `DisplayColorByLayer` (checkbox "Color by layer" nativa) |

**La conferma sulla freccia non è negoziabile**: il bottone sta in una riga
fitta, il click parte facile, e spostare geometria di layer si nota molto dopo
(se il layer di destinazione è spento, la geometria "sparisce" — il messagebox
lo avvisa esplicitamente). Semantica = Entity Info nativo: agisce sulle entità
**selezionate**, senza scendere dentro gruppi/componenti.

**`Core::Layers` ora ha un walker unico** `each_entity_on_layer(l)` che yielda
`(entity, 'root'|'nested', owner_definition_name)`. Ci passano `stats_for`
(conteggi) e `select_on_layer` (selezione): devono classificare allo stesso
modo, altrimenti la finestra promette N e la selezione ne prende un altro
numero. La classificazione sta in `category_of` — unica.

### `UI::LayerInfoDialog` — dialog senza asset HTML

Unico dialog del plugin che **non** ha file in `ui/html/`: il report è generato
in Ruby e iniettato con `set_html`, e i refresh sostituiscono il body via
`execute_script`. Conseguenze da rispettare se lo si tocca:

- tutti i listener JS sono in **delegation su `document`**, definiti nell'
  `<head>`: un listener agganciato alle righe morirebbe al primo refresh;
- lo stato che il JS deve conoscere (isolamento attivo) viaggia come
  **data-attribute nel body** (`data-iso`), non come variabile JS globale, per
  lo stesso motivo;
- `swap_body` confronta col body precedente e **non tocca il DOM se nulla è
  cambiato** — vedi la regola sul click mangiato in `SU2019-LESSONS.md`.

Il riquadro di stato è `position: sticky; bottom: 0`. Non è cosmetica: era in
coda al report e su un layer con 250 definition finiva a schermate di distanza,
quindi l'utente cliccava una riga e concludeva che non funzionasse nulla —
segnalato come bug, era solo feedback fuori vista.

### Selezione per categoria e vicolo cieco dei gruppi

Click su una riga = seleziona quelle entità. Ma la selezione di SU vive nel
contesto di editing aperto (dettagli e verifiche in `SU2019-LESSONS.md`,
sezione "Selezione"), quindi su un layer come Layer0 — 300k entità di cui 2 al
primo livello — la risposta onesta è "0 selezionate".

Per non lasciare un vicolo cieco, il messaggio elenca **i contenitori** con i
rispettivi conteggi (primi 12 + coda aggregata), e ogni riga dell'elenco è
cliccabile: `select_containers_of` seleziona le istanze di quel gruppo/
componente, risalendo la catena se anche quelle sono annidate.

Tasto destro su una riga: **Select all** / **Select all and isolate the layer**
/ **Restore layer visibility** (quest'ultima solo se un isolamento è ancora in
piedi davvero — vedi la nota su `isolation_active?` in `SU2019-LESSONS.md`).

### Il Properties dialog segue sempre la scena attiva

`PropertiesDialog.follow_active(uid)`, chiamato da `Dialog#poll_active_scene`
(tab nativi) e dal callback `sm_select_page` (click nella lista, che non deve
aspettare i 250ms del polling). Mostrare le proprietà di una scena diversa da
quella nel viewport è ambiguo, e rendeva la sezione Fog perennemente
disabilitata. In defer mode resta ferma, coerentemente col resto.

`push_state` ha ora anche il kwarg **`status:`** per l'esito di operazioni che
non meritano un messagebox (es. quante entità sono finite sul layer): il JS lo
mostra nella status bar per 4s. Ricorda la trappola dei campi top-level (vedi
"Trappola push_state").

## Selezione multipla dei layer + propagazione (2026-07-31)

Shift+click (intervallo), Ctrl+click (aggiungi/togli), tasto destro sulla lista
→ Select all / Invert selection / Clear selection. `laySel` in `properties.js`
è passato da stringa singola ad **array**.

**Il punto non ovvio è il mousedown della riga.** Se un click su un controllo
(spunta, swatch, dash, radio Cur, `i`, `→`) collassasse sempre la selezione
alla riga cliccata, la propagazione non avrebbe MAI più di un bersaglio: la
selezione verrebbe distrutta un istante prima che parta il `change`. Regola
implementata in `bindLayerRows`: click semplice su un controllo di una riga
**già selezionata** → la selezione resta com'è; su una riga fuori selezione →
collassa a quella riga (comportamento classico). Stessa logica per il tasto
destro, altrimenti il menu contestuale lavorerebbe su una selezione appena
distrutta dal click che lo ha aperto.

Altri vincoli emersi, da rispettare se si tocca la sezione:

- **La selezione non passa da Ruby**: `paintLaySel` tocca la sola classe
  `.is-sel`, nessun `push_state`, nessun re-render. È l'unico modo perché
  shift-click su 20 righe resti istantaneo sui modelli con AttributeObserver
  di plugin terzi.
- **Prune a ogni render**: `renderLayers` filtra `laySel` contro le righe del
  payload. Senza, dopo un delete/rename (o quando la scena nasconde un layer)
  restano nomi fantasma e i bottoni di gruppo agiscono su layer inesistenti.
  Il rename inline aggiorna `laySel[i]` e `layAnchor` col nuovo nome per lo
  stesso motivo.
- **`user-select: none` su `.lay-row`** (shift+click su una lista trascina una
  selezione di testo), con `user-select: text` rimesso su `.lay-name-input`
  perché il campo di rename parte con `.select()`.
- Restano **single-target** per natura: `Cur` (radio), `i`, `→` (spostare la
  selezione del viewport su N layer non significa niente).

**Lato Ruby i setter accettano nome O array** (`Core::Layers.layers_for`), e
il batch gira in **una sola `op`** → un solo Ctrl+Z anche cambiando 20 layer
insieme. Vale anche per `delete_layers`, che fa **una sola** domanda
YES/NO/CANCEL per l'intera selezione (N messagebox in fila sono solo un modo
per farle confermare senza leggere) e non fa fallire il gruppo per un layer
non cancellabile: Layer0/spariti finiscono in `errors` e vengono riportati a
fine operazione. `delete_layer` singolo è rimasto come wrapper.

**Bottone 🎨 (colori casuali)**: le tinte sono **distribuite sul cerchio
cromatico** (`offset casuale + i × 360/n`, slot mescolati), non estratte a caso
una per una — con 5-6 layer il random puro produce quasi sempre due tinte
gemelle, che è esattamente ciò che la feature deve evitare. Saturazione 0.45-0.80
e valore 0.70-0.95: i colori si vedono con "Color by layer" acceso, e un giallo
fluo o un blu notte rendono la geometria illeggibile. `Core::Layers.hsv_color`
è l'unico convertitore HSV→`Sketchup::Color` del progetto (verificato live:
h=0 rosso, 120 verde, 300 magenta).

**`showCtxMenu(x, y, header, entries)`** in `properties.js` è ora il costruttore
generico di menu contestuali del dialog (`entries = [{label, onPick}]`);
`showPartialMenu` (update parziale) gli delega. Ne vive uno solo alla volta
(`#smp-ctx-menu`).

### Verificare il JS di un dialog senza SketchUp

`properties.html` si apre in un browser normale (file://) e il JS gira: le
chiamate a Ruby passano da `window.sketchup`, che basta rimpiazzare con un
Proxy che registra i payload. Poi si inietta uno state finto con
`SMP.setState({...})` e si simulano i click con `dispatchEvent(new MouseEvent(...))`.
Così shift/ctrl/invert e i payload di propagazione si verificano **prima** di
aprire SketchUp, senza toccare il modello dell'utente. Nota: `.click()` su una
checkbox NON genera il `mousedown` — vanno dispatchati entrambi, o la logica di
selezione non viene esercitata.

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

## Varianti colore per-scena (`Core::Variants`) — 2026-07-19

Le scene native SU NON catturano i materiali. La feature emula "varianti
colore" per-scena: override materiale registrati dall'utente via schermata
"Color variant" e applicati/ripristinati a ogni attivazione scena.

### Architettura

- **Storage**: page attribute `SceneManagerPlus/color_variant` (JSON
  `{v:1, overrides:[{pid, mat, base}]}`). Vive sulla *pagina* (non
  sull'uid) → viaggia col file gratis, zero dipendenza dal sistema uid.
- **Chiave = `Entity#persistent_id`**, materiali **by-name** (vedi fatti
  verificati sotto). `mat: null` = rimuovi materiale.
- **Motore diff-apply** (`on_scene_activated`): ripristina lo snapshot RAM
  della variante precedente + applica la nuova, in UNA transparent op.
  Il **restore runtime usa lo snapshot RAM** catturato all'apply (ciò che
  il modello aveva un istante prima), NON il `base` persistito (che è solo
  riferimento/recovery): robusto se l'utente cambia i materiali base dopo
  la registrazione. Guard no-op su ri-attivazione stessa scena (evita
  snapshot pollution).
- **Editing SOLO dalla schermata** (`ui/variant_dialog.rb`): selezione
  viewport → picker materiale → record+apply. Il secchiello nativo usato
  con variante attiva NON entra nella variante (niente observer sul paint
  nativo — scelta di design). Il dialog attiva la scena di contesto
  all'apertura, così `@applied` è sempre coerente (nil o la scena stessa).
- **Copy/paste** (context menu): clipboard RAM di sessione, **solo stesso
  modello** (i pid non significano nulla altrove). Paste sovrascrive e
  ri-applica se la scena target è attiva.
- **Igiene**: `prune_missing` (bottone "Clean missing" nel dialog) rimuove
  override con pid orfani; materiali mancanti → option disabilitata
  "missing: X" nel dropdown + skip con report all'apply.

### Hook (tutti i punti che attivano una scena)

| Punto | Nota |
|---|---|
| `SceneModel.select_page` | dopo `selected_page=` |
| Polling 250ms (`poll_active_scene`) | **deroga documentata** alla regola "il polling non scrive": `on_scene_activated` è zero-write a regime (stesso uid → return; niente varianti → sola lettura attributo); scrive materiali SOLO nella transizione con variante coinvolta. In defer mode il polling è no-op → tab nativi non applicano varianti in defer. |
| `Exporter` / `Previews` loop | dopo `pages.selected_page = page` nello step; in `finish` riallinea alla scena ripristinata |
| Save (`SaveObserver`) | `onPreSaveModel` → restore base (il **.skp su disco è sempre stato base**); `onPostSaveModel` → re-apply. Attach via `install_observers!` in main.rb + `AppObserver` per file aperti dopo. |

### Fatti verificati via MCP su SU 2019 (19.3.253), 2026-07-19

- `Entity#persistent_id` valido su Face/Group/ComponentInstance anche
  annidati; **sopravvive a salva/riapri**. `find_entity_by_persistent_id`
  accetta array (nil per i mancanti). MAI lookup con pid ≤ 0 (ritorna
  entità arbitrarie, es. un Layer).
- **`Material#persistent_id` è uno stub: ritorna 0** in SU 2019 →
  materiali referenziabili solo by-name (rename nativo = riferimento
  rotto, gestito con report).
- **`onPreSaveModel` esiste, è sincrono, e le mutazioni fatte lì dentro
  ENTRANO nel file salvato** (verificato con reopen). In pre-save niente
  `start_operation` (mutazione diretta).
- **Transparent op: sporca comunque `model.modified?`** e si aggancia
  all'op precedente nell'undo stack → un Ctrl+Z utente può portarsi via
  anche l'apply della variante (si risistema alla prossima attivazione).
  Caveat accettato e non mitigato (onTransactionUndo possibile ma rischia
  di combattere l'undo dell'utente).

### Conseguenze UX accettate

- Navigare scene con varianti = modello dirty (SU chiede "Save changes?"
  anche solo per aver navigato). Dopo un save il modello torna dirty
  subito (re-apply post-save).
- Due scene possono differire solo per COME sono colorati i materiali
  delle stesse entità; "in variante B questo pannello usa un altro
  materiale" sì, ma la geometria è condivisa.
- Varianti NON trasferibili cross-file (❌ anche nella clipboard scene).

### Trappola collegata: debounce attivazione scena (app.js)

Il primo click su una row NON chiama più Ruby subito: `scheduleSelectPage`
rimanda `selectPageLocal` di `DBLCLICK_MS` (400ms). Motivo: select_page ora
può costare (variante: restore+apply materiali; modelli con observer terzi)
e se SU congela tra i due click del doppio click, la detection manuale
(lastClickId/lastClickTs) scadeva e Properties non si apriva mai. Col
debounce la detection è indipendente dai tempi Ruby; al dblclick il timer
viene cancellato e la scena attivata esplicitamente prima di openProperties.
Chiamate dirette a `selectPageLocal` (keynav) cancellano il timer pending.
Click rapidi su più scene = si attiva solo l'ultima (bonus sui modelli lenti).

### Trappola push_state: i campi top-level vanno aggiunti in TRE posti

`Dialog.push_state` costruisce lo state con field-list esplicita: un campo
nuovo in `ui_payload` NON arriva al JS finché non viene aggiunto anche lì.
Già successo con `variant_clipboard` (la voce "Paste color variant" non
compariva mai). Regola: campo per-scena → `scene_hash` + `list_ordered`
(trappola due-payload esistente); campo top-level → `ui_payload` + la
field-list in `Dialog.push_state`.

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
- **Stile dei report all'utente** (richiesta esplicita, 2026-08-01): l'utente è
  un esperto di grafica 3D e conosce SketchUp a fondo, ma non è un
  programmatore (zero Ruby). Quando gli si riporta cosa è stato fatto o gli si
  propone un piano, spiegare in termini del SUO mondo: scene, stili, pannelli,
  file .skp, componenti — con analogie da SketchUp/3D dove aiutano. Niente
  gergo da codice (API, hash, callback, refactor...) senza una traduzione
  immediata in linguaggio comune. I dettagli tecnici (nomi di funzioni, file,
  costanti) vanno in coda o omessi, non nel corpo della spiegazione. Questo
  vale per i riepiloghi, non per i commenti nel codice o per questo file.
- L'utente preferisce sviluppo **per fasi con verifica intermedia**, non big-bang.
- Niente preview scene nel pannello (esplicita richiesta per performance —
  ma esistono thumbnails inline come opt-in).
- **Non committare** se non esplicitamente richiesto.
- Quando affronti bug/feature toccando un'area "delicata" (composite watermark,
  CEF/HtmlDialog, predicate API, settings UI), apri prima `docs/SU2019-LESSONS.md`
  per evitare di re-scoprire gotcha già documentati.
