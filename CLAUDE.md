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
- **Per-row ⟳** icona update-from-view (come "Update Scene" nativo).

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
| Cartelle | Solo logiche (ordine in `model.attribute`), no sync alle pagine native (vedi sotto) |
| Formati export | PNG + JPG |
| Watermark | Composizione via `Sketchup::ImageRep` (PNG + JPG unificati). ChunkyPNG scartato, niente `vendor/`. Logo bundled in `scene_manager_plus/assets/default_logo.png` |
| Persistenza cartelle/ordine | Attributi sul `Sketchup.active_model` (vivono col file SKP) |
| Persistenza settings | `Sketchup.write_default` per-leaf (vedi `SU2019-LESSONS.md`) |
| Lingua UI | Inglese (UX standard) |
| Preview scene | NON implementata nel pannello, per richiesta utente (no rallentamento refresh). Esiste come thumbnails inline opzionali. |

## Struttura repo

```
scene_manager_plus.rb               # loader, registra l'extension
scene_manager_plus/
├── main.rb                         # entry point: menu + toolbar + comando
├── assets/default_logo.png         # logo bundled per watermark
├── core/
│   ├── buffer.rb                   # Defer mode: stato globale edit in RAM + flush!
│   ├── exporter.rb                 # Batch export PNG/JPG + watermark via ImageRep
│   ├── folders.rb                  # cartelle logiche (schema + load/save)
│   ├── naming.rb                   # format/preview/apply_rename pattern
│   ├── previews.rb                 # cache PNG anteprime per-modello persistente
│   ├── scene_model.rb              # wrapper su Sketchup.active_model.pages
│   └── settings.rb                 # config persistente con defaults
└── ui/
    ├── dialog.rb                   # Main HtmlDialog + bridge + polling scene attiva
    ├── export_dialog.rb            # Dialog Export (scope picker + progress)
    ├── properties_dialog.rb        # Dialog Properties singola scena (dblclick)
    ├── settings_dialog.rb          # Dialog Settings (naming + export + logo)
    └── html/
        ├── index.html              # finestra principale
        ├── export.html             # finestra Export
        ├── properties.html         # finestra Properties
        ├── settings.html           # finestra Settings
        ├── css/{style,export,properties,settings}.css
        └── js/
            ├── app.js              # logica lista, selezione, defer, thumbs
            ├── bridge.js           # window.SMBridge → sketchup.<callback>
            ├── dnd.js              # drag&drop custom (no HTML5 native)
            ├── export.js           # logica dialog Export
            ├── properties.js       # logica dialog Properties (live commit)
            └── settings.js         # logica dialog Settings
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
| `sm_log` | debug → `Ruby Console` |

Firma `sm_reorder`: `{ ids: [], before_id: id|null, dest_folder_id: id|null }`.
`dest_folder_id=null` = root; `before_id=null` = append in coda.

`SettingsDialog`, `PropertiesDialog`, `ExportDialog` registrano i propri callback
(prefissi `sm_settings_*`, `sm_properties_*`, `sm_export_*` rispettivamente).

## Installazione e deploy locale

**Macchina dev (questa postazione)**: i file in
`%APPDATA%\SketchUp\SketchUp 2019\SketchUp\Plugins\scene_manager_plus`
sono **copie reali**, non junction (admin privileges non disponibili sempre).
Dopo ogni modifica:

```powershell
$src = "D:\Claude\SceneManager+"
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
Remove-Item "$plug\scene_manager_plus" -Recurse -Force
Copy-Item "$src\scene_manager_plus.rb" "$plug\scene_manager_plus.rb" -Force
Copy-Item "$src\scene_manager_plus" "$plug\" -Recurse
```

- Modifiche **Ruby (.rb)** → **riavvia SketchUp**.
- Modifiche **HTML/CSS/JS** → basta chiudere+riaprire la finestra del plugin
  (c'è cache-bust su `index.html` / `settings.html` / `properties.html`).

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
