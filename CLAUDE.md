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
| Stile finestra principale | `STYLE_UTILITY` (palette sempre sopra viewport, posizione+dimensione persistite affidabilmente — `STYLE_DIALOG` non salva la posizione su SU 2019). Auto-riaprire all'avvio se era aperta (flag `main_dialog_open` via `write_default`, ri-show con timer 0.5s dopo `file_loaded`). Settings/Properties restano `STYLE_DIALOG` (sono modali-ish). |
| Navigazione tastiera | `PageUp`/`PageDown`/`Home`/`End` scorrono la selezione lungo l'ordine logico visibile (cartelle chiuse saltate). `ArrowUp`/`ArrowDown` invece **spostano** la selezione (singola o multi-contigua sotto lo stesso parent) nell'ordine logico. Non c'è modo pulito in SU 2019 di hijacker i tasti globalmente, quindi fuori dal plugin resta il comportamento nativo. |
| Nuova scena da vista | Icona toolbar (📷+) → `SceneModel.add_from_view`. Replica gli override di visibilità layer della pagina attiva (vedi sotto, "Add visible tag"). |
| Rinomina inline | Right-click su scena → context menu → "Rename" → input nella row, Enter = commit, Esc/blur-senza-modifiche = annulla. |
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
│   ├── text_render.rb              # PowerShell+System.Drawing per filename label
│   └── titleblock.rb               # PowerShell+System.Drawing per cartiglio
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
