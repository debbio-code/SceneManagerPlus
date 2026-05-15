# Scene Manager+ — SketchUp 2019 Plugin

Plugin di gestione scene avanzata per SketchUp 2019, in stile "livelli Photoshop":
lista scene riordinabile, cartelle, batch export con watermark logo, naming pattern.

## Stato attuale: Fase 1 completata

Sviluppo in 4 fasi (concordato con l'utente):

1. **Fase 1 — Scaffolding + finestra base con lista scene + selezione/DnD** ✅
2. **Fase 2 — Cartelle (logiche + sync ordine reale SKP)** ⏳
3. **Fase 3 — Settings + naming pattern** ⏳
4. **Fase 4 — Batch export + watermark** ⏳

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
│   ├── scene_model.rb              # wrapper su Sketchup.active_model.pages
│   ├── folders.rb                  # stub Fase 2 (schema + load/save)
│   └── settings.rb                 # config persistente con defaults
└── ui/
    ├── dialog.rb                   # HtmlDialog wrapper + bridge Ruby↔JS
    └── html/
        ├── index.html              # finestra principale
        ├── css/style.css           # tema scuro Photoshop-like
        └── js/
            ├── bridge.js           # window.SMBridge → sketchup.<callback>
            ├── dnd.js              # drag&drop multi-selezione + drop indicator
            └── app.js              # logica lista, selezione, props
```

## Cosa funziona già (Fase 1)

- Finestra HtmlDialog tema scuro, ridimensionabile, posizione persistente
- Lista scene numerata con drag handle
- Selezione: click singolo, **Shift+click** range, **Ctrl+click** toggle
- Drag & drop multi-selezione con drop indicator blu (linea sopra/sotto target)
- Click singolo sincronizza la scena attiva nel viewport SU
- Pannello proprietà collassabile con: Name, Description, e tutti i flag nativi:
  `use_camera`, `use_hidden`, `use_hidden_layers`, `use_style`,
  `use_shadow_info`, `use_axes`, `use_section_planes`, `use_rendering_options`
- Bottone **Update** = `page.update(mask)` con i flag attualmente attivi
- Bottone **Delete** con conferma
- Bottoni Export / Settings presenti ma disabilitati (Fasi 3-4)

## Limite SU 2019 e workaround "ordine logico"

`Sketchup::Pages` **non espone API pubblica per riordinare le pagine** in SU 2019.

**Workaround attuale**: l'ordine drag&drop è salvato come *ordine logico* in
`model.set_attribute('SceneManagerPlus', 'logical_order', [uid, uid, ...])`.
Vive col file SKP. Le pagine SketchUp restano nell'ordine nativo.

**Da fare in Fase 2**: bottone "Sync to SketchUp" che applica realmente l'ordine
cancellando e ricreando le pagine. Va fatto con cura (preservare proprietà,
camera, style, descrizione, attributi custom, ecc.).

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
| `sm_log` | debug → `Ruby Console` |

## Installazione per test

Symlink/junction nella cartella Plugins di SU 2019 (PowerShell admin):

```powershell
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
New-Item -ItemType SymbolicLink -Path "$plug\scene_manager_plus.rb"  -Target "D:\Claude\SceneManager+\scene_manager_plus.rb"
New-Item -ItemType Junction     -Path "$plug\scene_manager_plus"     -Target "D:\Claude\SceneManager+\scene_manager_plus"
```

Poi: SketchUp 2019 → menu **Plugins → Scene Manager+** (o icona toolbar).

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

### ⚠️ Da implementare in Fase 2

- Sync ordine logico → ordine reale `Sketchup::Pages`
- UI cartelle (collapsibili, drag scene dentro/fuori)

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
