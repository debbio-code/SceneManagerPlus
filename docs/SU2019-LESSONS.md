# SketchUp 2019 — Gotcha e pattern

Trappole, comportamenti non documentati, e pattern-da-tenere-a-mente quando si
lavora sull'API di SketchUp 2019 (Ruby + HtmlDialog/CEF). Referenziato da
`CLAUDE.md`. Per i bug storici concreti vedi `RESOLVED-BUGS.md`.

---

## API SketchUp / Ruby

### `Sketchup::ImageRep#set_data` su Windows: BGRA top-down, NON RGBA

Per 32 bpp, `set_data(w, h, 32, 0, buf)` su SU 2019 Windows si aspetta i byte
in ordine **BGRA** (DIB convention), NON RGBA. Sintomi se sbagli:
- Wood marrone diventa blu, e simmetricamente i blu diventano rossi (R↔B swap)
- Le righe NON vengono flippate (set_data legge top-down come io scrivo), quindi
  il logo non finisce capovolto a causa dei byte di base.

Ordine corretto per ogni pixel:
```ruby
buf.setbyte(j,     c.blue)
buf.setbyte(j + 1, c.green)
buf.setbyte(j + 2, c.red)
buf.setbyte(j + 3, 255)
```

### `ImageRep#color_at_uv` usa convenzione OpenGL (v=0 in basso)

Se indicizzi top-down (riga 0 = top), devi flippare v:
```ruby
v = 1.0 - (dy + 0.5) / th.to_f
```
Altrimenti il logo finisce capovolto verticalmente nell'output (testo "ʇsɐıdǝp").

### `Sketchup.write_default` con stringhe JSON è inaffidabile in SU 2019

Salvare `'{"width":3840,"format":"jpg"}'` come singolo valore può non
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

### `view.write_image(:scale_factor)` esiste solo in SU 2020+

Per Line Scale Multiplier su SU 2019 fallback: manipola
`model.rendering_options['EdgeWidth']` e `['ProfileWidth']` temporaneamente
prima del batch render, ripristina in `finish` (anche su cancel/errore).
Funziona solo se lo stile attivo ha edges/profili visibili.

### `view.write_image` per JPG apre la dialog "JPG Image Options"

Senza `compression:` esplicito. Sempre passare `compression: 0.9` (o altro)
per JPG così l'export è silent.

### `Pages#add_frame_change_observer` non scatta sui tab clicks

In SU 2019 con scene transitions disabilitate (preferenze SU), il
`frame_change_observer` non emette `frameChange` quando l'utente clicca un
tab scena nativo. È pensato per le transizioni animate.

**Soluzione**: polling `UI.start_timer(0.25, true)` che legge
`pages.selected_page` e confronta con `@last_active_uid`. Carico minimo.

### `UI.start_timer(0, false)` da action_callback non affidabile

Tentativo di deferire una scrittura con `UI.start_timer(0, false) { ... }`
dentro una bridge callback: il timer non sempre fira in SU 2019.

**Pattern sicuro**: `delay >= 0.01`, mai 0. Per catene di lavoro asincrono
(progress bar) `0.01s` è il minimo che lascia a CEF il tempo di ridipingere.

### `PAGE_USE_*` constants: nomi diversi per versione SU

`Sketchup::Page#update(mask)` accetta una bitmask di costanti top-level
`PAGE_USE_*`. **In SU 2019 i nomi differiscono dai docs SU recenti**.

Costanti effettivamente esposte in SU 2019 19.3.253 (verificato con
`tools/dump-page-use.rb`):

| Costante                     | Valore | Significato                |
|------------------------------|-------:|----------------------------|
| `PAGE_USE_CAMERA`            |      1 | camera + assi              |
| `PAGE_USE_RENDERING_OPTIONS` |      2 | rendering options          |
| `PAGE_USE_SHADOWINFO`        |      4 | shadow settings            |
| `PAGE_USE_SKETCHCS`          |      8 | **style** (sketch coord sys) |
| `PAGE_USE_HIDDEN`            |     16 | hidden geometry            |
| `PAGE_USE_LAYER_VISIBILITY`  |     32 | tag visibility             |
| `PAGE_USE_SECTION_PLANES`    |     64 | active section planes      |
| `PAGE_USE_ALL`               |   4095 | tutto                      |
| `PAGE_NO_CAMERA`             |   4094 | = ALL − CAMERA (NON 0)     |

Costanti che **NON esistono** in SU 2019: `PAGE_USE_STYLE`, `PAGE_USE_AXES`,
`PAGE_USE_HIDDEN_GEOMETRY`, `PAGE_USE_HIDDEN_LAYERS`,
`PAGE_USE_ACTIVE_SECTION_PLANES`.

Note:
- **`PAGE_USE_SKETCHCS = 8` è la costante per lo Style** (non per gli
  assi/coordinate, malgrado il nome). Confermato dal dump.
- Gli **assi non hanno un bit dedicato** in SU 2019: piggyback su
  `PAGE_USE_CAMERA` (gli assi vengono salvati insieme alla camera).
- `PAGE_USE_ALL = 4095 = 0xFFF` (12 bit) ma le costanti coprono solo 7 bit
  (somma 127). I 5 bit alti sono usati internamente da SU per cose non
  esposte all'API Ruby.

Mappatura predicate → flag (con lookup difensivo, prova in ordine):
- `use_camera?` → CAMERA
- `use_axes?` → AXES → CAMERA (fallback piggyback se AXES non esiste)
- `use_rendering_options?` → RENDERING_OPTIONS
- `use_style?` → STYLE → SKETCHCS → RENDERING_OPTIONS (fallback piggyback)
- `use_shadow_info?` → SHADOWINFO
- `use_hidden_layers?` → LAYER_VISIBILITY → HIDDEN_LAYERS
- `use_hidden?` → HIDDEN_GEOMETRY → HIDDEN
- `use_section_planes?` → ACTIVE_SECTION_PLANES → SECTION_PLANES

Usare lookup difensivo (`Object.const_defined?`) che prova più nomi e prende
quello presente. Per verificare quali costanti esistono effettivamente nella
versione SU in uso → `load 'tools/dump-page-use.rb'` nella Ruby Console.
Lo script stampa anche tutte le `Object.constants.grep(/\APAGE_/)` per non
perdere nomi non previsti.

**Nota su `use_style?` (2026-05)**: la mappatura precedente piggybackava
sempre su RENDERING_OPTIONS partendo dall'assunzione "style è parte di
rendering". Verificato che in SU recenti `PAGE_USE_STYLE` esiste come bit
dedicato, e SU 2019 espone `PAGE_USE_SKETCHCS` con lo stesso significato.
Se l'utente ha solo `use_style=true` (e `use_rendering_options=false`), il
piggyback aggiornava il bit sbagliato → style non veniva catturato.

### MCP per il probing API live (2026-05)

Installato un server MCP locale (`mhyrr/sketchup-mcp`, community) che espone il
tool **`eval_ruby`**: esegue Ruby arbitrario nel contesto di SU via socket TCP
(127.0.0.1:9876) e ritorna il risultato. Sostituisce il flusso "scrivo
`tools/dump-*.rb` → carico nella Ruby Console → copio/incollo l'output": ora
l'introspezione API si chiude in un turno.

Usarlo per qualunque domanda del tipo "questa API/costante/RO esiste davvero in
SU 2019?". Esempi già fatti: enum `Object.constants.grep(/PAGE_USE/)` (confermata
la tabella sopra — sono **top-level**, non sotto `Sketchup`), enum
`rendering_options.keys`, test di persistenza per-scena.

Setup: estensione `.rbz` da installare in SU + server Python via `uvx
sketchup-mcp` con pin `mcp[cli]==1.3.0` (la 0.1.17 crasha con l'SDK mcp recente).
Il server va riavviato (Extensions → MCP Server → Start Server) dopo ogni
restart di SketchUp. Trappola packaging: il `.rbz` deve contenere solo il loader
`su_mcp.rb` + `su_mcp/main.rb` — se ci finiscono `package.rb`/`extension.json`
nella root, SU li auto-carica all'avvio e `package.rb` crasha (`require 'zip'`).

**Protocollo wire + `Invoke-SUEval` (verificato 2026-07-07).** Il server è un
`TCPServer` su `127.0.0.1:9876` che legge **una riga** JSON (`client.gets`,
newline-terminata), valuta, e risponde con JSON + `\n`. Il formato più semplice
è la shorthand `command` (non serve `method`/`params`):
`{"command":"eval_ruby","parameters":{"code":"<ruby>"},"id":1}`. Il risultato
Ruby (già `.to_s`) torna in `result.content[0].text`. Funzione PowerShell
minimale (nessun modulo esterno):

```powershell
function Invoke-SUEval {
  param([Parameter(Mandatory)][string]$Code)
  $req = @{ command='eval_ruby'; parameters=@{ code=$Code }; id=1 } |
         ConvertTo-Json -Compress -Depth 6
  $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1',9876)
  $s = $c.GetStream()
  $w = [System.IO.StreamWriter]::new($s); $w.WriteLine($req); $w.Flush()
  $line = [System.IO.StreamReader]::new($s).ReadLine(); $c.Close(); $line
}
```

⚠️ **`eval_ruby` gira sul modello aperto IN QUEL MOMENTO.** Un check "il modello
e' vuoto, posso testarci sopra" fatto a inizio sessione **non vale piu'** dopo
che l'utente ha aperto un file: SU riusa la stessa istanza e `Sketchup.active_model`
cambia sotto i piedi senza alcun segnale. Successo davvero (2026-07-30: scene di
test e un layer creati dentro un file di produzione dell'utente, `selected_page`
lasciata `nil` e non ripristinabile). **Regola: ri-leggere `model.path` / `title` /
`pages.count` nello stesso turno, subito prima di ogni snippet che SCRIVE** — non
fidarsi di una verifica precedente. Per i test distruttivi chiedere all'utente un
modello nuovo (Ctrl+N) e verificarlo.

### API layer/tag disponibili in SU 2019 (verificate 19.3.253, 2026-07-30)

- `Sketchup::LineStyles` e `Layer#line_style` / `line_style=` **esistono**
  (introdotti in SU 2019). `model.line_styles.names` ritorna 12 stili
  ("Solid Basic", "Short dash", "Dash", "Dot", "Dash dot", ...).
  `layer.line_style = nil` riporta al default.
- `LAYER_IS_HIDDEN_ON_NEW_PAGES` = **32** (costante top-level), per
  `Layer#page_behavior=`.
- `model.layers.unique_name` esiste.
- `Layers#remove` ha **arity -1** e accetta `(layer, remove_geometry)`.
- `Layers#purge_unused` esiste; ritorna il collection, quindi per sapere quanti
  ne ha tolti va fatto il diff di `layers.count` prima/dopo.
- SU **rifiuta** di rimuovere il layer corrente: riportare prima
  `model.active_layer` sul default (`layers[0]`, sempre "Layer0").

Gotcha: `TOPLEVEL_BINDING.dup` come binding — variabili non persistono tra
chiamate, quindi ogni `eval_ruby` è self-contained (mettere tutto in un unico
snippet, usare `\n` per multi-statement). Per enumerare RO:
`Sketchup.active_model.rendering_options.each_pair { |k,v| ... }` (in SU 2019
sono **61** chiavi — vedi lista in CLAUDE.md sez. Match Photo).

### `DisplaySketchAxes`: gli assi del modello SONO una RenderingOption (2026-05)

Correzione di una conclusione errata precedente ("Model axes: niente API Ruby
in SU 2019"). Il display degli assi del modello è leggibile/settabile via
`rendering_options['DisplaySketchAxes']` (bool). Scoperto enumerando le RO con
l'MCP eval_ruby; la vecchia indagine "enumerando tutto" l'aveva mancato (forse
cercando solo `Axes`/`ShowAxes` o tra `model.options`).

Verifiche empiriche (SU 2019.0.685):
- `ro['DisplaySketchAxes']=false` + `view.invalidate` → gli assi spariscono dal
  viewport.
- È catturato **per-scena** via `PAGE_USE_RENDERING_OPTIONS`: creata una scena
  con assi ON, spenti nel viewport, riattivata la scena → assi ripristinati ON.
- Quindi committabile in uno stile via `styles.update_selected_style`, esattamente
  come `DrawHidden`/`DisplaySectionPlanes`.

Conseguenza: nel Mini Style Manager Model Axes è ora un **checkbox stateful**
(non più bottone toggle + `Sketchup.send_action(10522)`). Vedi `ui/style_dialog.rb`
(`RO_KEYS`/`BOOL_KEYS` includono `DisplaySketchAxes`).

Nota: esiste anche `DisplayInstanceAxes` (default false) — assi delle istanze
group/component, non testato; non confondere con `DisplaySketchAxes`.

### `HorizonColor`: il cielo va da SkyColor a HorizonColor (RO nascosta) (2026-05)

Il gradiente del cielo in SU non è SkyColor → bianco: è **`SkyColor` (zenit) →
`HorizonColor` (orizzonte)**. `HorizonColor` è una RenderingOption **non esposta
da NESSUNA UI**: il pannello Background nativo (Window → Styles → Edit) mostra
solo Sky e Ground; `HorizonColor` si tocca solo via `rendering_options`.

Trappola concreta: il template degli slot bundled del plugin
(`assets/styles/slot_NN.style`, derivati da "Architectural Design Style") ha
`HorizonColor = #000000 a=0` → **banda nera all'orizzonte** nel cielo di ogni
nuovo slot allocato (`+ New style`, paste, ecc.). L'utente non può correggerlo
perché non è esposto. Verificato live via MCP eval_ruby (SU 2019): settando
`ro['HorizonColor'] = Sketchup::Color.new(198,205,208,255)` +
`update_selected_style` + `view.invalidate` il nero sparisce.

Nota alpha: il valore di default ha `a=0` ma rende comunque nero; non basta
l'alpha per "spegnerlo", va cambiato l'RGB. Quando si serializza un colore RO
per la clipboard (`Core::Styles.color_to_hex`) si scarta l'alpha → un
`HorizonColor a=0` torna opaco in paste (TODO: preservare alpha).

Follow-up FATTO (2026-05-31): controllo "Horizon" aggiunto alla sezione
Background del Mini Style Manager (`HorizonColor` in `RO_KEYS`/`COLOR_KEYS`).
Display: `serialize_value` mostra `#ffffff` quando il valore è il sentinel
cattivo (nero o alpha 0), così l'iniziale non è un nero fuorviante.

### Two Point Perspective NON è trasferibile programmaticamente (2026-05-31)

Le viste "raddrizzate" (Camera → Two-Point Perspective) hanno uno stato 2D —
`camera.is_2d? == true`, `camera.center_2d` (il pan 2D), `camera.scale_2d` — che
**non si può impostare via API** in SU 2019:

- `center_2d=`, `scale_2d=`, `is_2d=` → **NoMethodError** (sono solo getter).
- `Sketchup::Camera#copy` **azzera** lo stato 2d (verificato via MCP: copia di una
  camera con pan reale → `is_2d? == false`, `center_2d == [0,0,0]`).
- `Sketchup::Camera.new(eye, target, up, persp)` costruisce solo prospettiva
  normale (1-point).

L'UNICO modo di ottenere una camera 2D è `model.pages.selected_page = page` su una
scena che ha **già** il 2d salvato (SU ricarica lo stato completo). Quindi:

- **Ripristinare** la vista di una scena 2D esistente: OK via `selected_page`
  (lo usano copy/paste del clipboard per non muovere il viewport).
- **Ricreare** una scena 2D da dati serializzati (es. paste cross-file): IMPOSSIBILE.
  La scena incollata mantiene eye/target ma in prospettiva normale.

È un limite analogo a Match Photo. Per il clipboard: `camera_of` serializza
comunque `is_2d`/`center_2d`/`scale_2d` (record/detection) e la copy avvisa
l'utente quando copia scene two-point.

Workaround imperfetto NON implementato: `Sketchup.send_action` "Two-Point
Perspective" sul viewport in paste raddrizzerebbe le verticali, ma con pan
centrato (azzerato), diverso da quello sorgente. Verticali dritte ma inquadratura
non identica.

### `Sketchup::Page#layers`, `pages.add`, drift e AVT — quadro completo

In SU 2019 `page.layers` ritorna l'array dei layer che la pagina vuole
tenere nascosti quando attivata. Gli altri vengono mostrati (override su
model state, finché `use_hidden_layers?` è true).

**Drift da toggle manuale (confermato 2026-05)**: quando l'utente toggla
un layer dal Layer Manager dopo l'attivazione di una scena, SU aggiorna
`layer.visible?` (model) ma NON sincronizza `page.layers` della scena
attiva. L'override resta stale. In caso di mismatch il viewport mostra
sempre `layer.visible?`, in entrambe le direzioni (accensione e
spegnimento).

**`pages.add` muta il model (confermato 2026-05)**: se il Layers Manager
è caricato e ci sono layer con "Add visible tag" attivo (layer globally
visible tramite override AVT sulla page attiva), un observer di LM
reagisce a `pages.add` durante l'esecuzione e:
1. Riporta `layer.visible? = false` (model state)
2. Aggiunge il layer alla hidden list della nuova page

Quindi `pages.add` **non è puro**: tra PRE e POST cambia lo stato del
modello. Qualsiasi formula calcolata POST-add perde l'informazione di
ciò che il viewport stava mostrando PRE-add.

**Pattern corretto** per replicare la visibilità effettiva della pagina
attiva sulla nuova:

```ruby
# 1. Snapshot PRIMA di pages.add (sennò AVT observer ti spegne i layer)
pre_visible = {}
model.layers.each { |l| pre_visible[l] = l.visible? }

page = model.pages.add(name)

# 2. Ripristina il model state (per i layer che l'observer ha mutato)
#    e applica lo stesso state alla new page
pre_visible.each do |layer, was_visible|
  layer.visible = was_visible if layer.visible? != was_visible
  page.set_visibility(layer, was_visible)
end
```

**Asimmetria di `set_visibility` attiva vs non attiva (2026-07-30)**. Verificato
su SU 19.3.253:

| Chiamata | effetto su `page.layers` | effetto su `layer.visible?` (model) |
|---|---|---|
| `set_visibility` su pagina **non attiva** | scritto | **nessuno** |
| `set_visibility` su pagina **attiva**     | scritto | **sincronizzato** |

Quindi il pattern classico `pages.each { |p| p.set_visibility(l, p == target) }`
sistema anche lo stato del modello **solo se `target` e' la pagina attiva** (ed
e' per questo che "Add Visible Tag" del Layers Manager funziona: lavora sempre
sulla scena attiva). Se il target e' una pagina qualsiasi — o se
`pages.selected_page` e' `nil` — il layer resta `visible? == true` e compare nel
viewport della scena sbagliata. In quel caso va forzato a valle:

```ruby
want_now = (active == target_page)
l.visible = want_now if l.visible? != want_now
```

Usato da `Core::Layers.add_layer_visible_only_in` (vedi CLAUDE.md, sez. "Layers
nel Properties dialog").

**Tentativi precedenti che NON funzionano**:
- `set_visibility(layer, !layer.visible?)` su `active.layers` → bug opposto.
- `set_visibility(layer, !hidden_on_active.include?(layer))` → preserva
  AVT ma rompe i toggle manuali (drift) in entrambe le direzioni.
- `set_visibility(layer, layer.visible?)` post-add senza snapshot →
  funziona per drift ma perde AVT (l'observer lo ha già spento prima
  della nostra `set_visibility`).

### `model.options['PageOptions']['TransitionTime'] = 0` per batch render

Il vero collo di bottiglia di un batch `pages.selected_page = page` + 
`view.write_image` è l'**animazione di transizione** tra scene (default
~1s/scena). Disabilitarla per la durata del batch e ripristinare a fine:

```ruby
po = model.options['PageOptions']
saved_t = po['TransitionTime']
saved_s = po['ShowTransition']
po['TransitionTime'] = 0
po['ShowTransition'] = false
# ... batch ...
po['TransitionTime'] = saved_t
po['ShowTransition'] = saved_s
```

Da solo questo fa ~70-80% del guadagno su un batch di preview. Altri
fattori (antialias, risoluzione, frequenza yield a CEF) contano molto
meno.

### Predicate getter — `use_camera?` NON `use_camera`

I flag di `Sketchup::Page` hanno **getter con `?`** e **setter senza**
(convenzione predicate Ruby/SU). Non sono mai accessibili come
`page.use_camera` — `page.send(:use_camera)` solleva NoMethodError.

```ruby
p.use_camera?           # => true/false   (getter, OK)
p.use_camera = true     # (setter, OK)
# p.use_camera          # ❌ NoMethodError
```

Vale per tutti i flag (`use_hidden?`, `use_style?`, `use_axes?`, ecc.) e
generalmente per qualsiasi predicate dell'API SU (`Entity#valid?`,
`Group#locked?`, `Drawingelement#visible?`).

Pattern: per lookup dinamico via `send`, costruire `"#{key}?"` per leggere e
`"#{key}="` per scrivere.

### `PLUGIN_DIR` via Junction NON risale al repo

`File.expand_path('..', PLUGIN_DIR)` in deploy via Junction risale a
`%APPDATA%/.../Plugins/`, NON alla cartella di repo. **Bundle gli asset
DENTRO PLUGIN_DIR** (es. `scene_manager_plus/assets/`). Non usare `..` per
cercare risorse fuori dalla cartella plugin.

### `module_function` non rende il metodo `respond_to?`-positive

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
chiama direttamente.

---

## CEF / HtmlDialog

### CEF carica vecchi JS/CSS dalla cache anche dopo edit

Modifico `dnd.js`, chiudo/riapro la finestra HtmlDialog, ma il codice in
esecuzione è ancora quello vecchio.

**Soluzione**: `Dialog#prepare_index` genera a runtime un `index.cb.html`
accanto all'originale, riscrivendo i tag `<script src>` e `<link href>` con
`?v=<timestamp>`. CEF è obbligato a rileggere asset. Il temp file è
gitignored.

### CEF non ridipinge il DOM durante un HTML5 native drag

`draggable=true` + `dragstart`/`dragover`/`drop` congela tutti gli update
visivi del DOM fino al rilascio del mouse. Un drop-indicator dinamico
risulta invisibile.

**Pattern**: in SU 2019 (e probabilmente in tutte le SU con CEF vecchia)
**evitare HTML5 native drag** per qualsiasi UI che debba dare feedback
visivo in tempo reale. Usare `mousedown`/`mousemove`/`mouseup` custom con
una soglia (es. 4px) per distinguere click da drag.

### `dblclick` non scatta in CEF SU 2019 se render ricrea l'elemento

Se la riga DOM viene rimossa e ricreata tra il primo e il secondo click
(es. la lista re-renderizza ad ogni `setState`), CEF non emette `dblclick`
sull'elemento "originale".

**Pattern**: rilevamento manuale con timestamp + id. Se due mousedown
sullo stesso id arrivano entro N ms (es. 400ms) senza modificatori,
triggerare l'azione doppio-click.

### `STYLE_DIALOG` vs `STYLE_UTILITY` per persistenza posizione

`HtmlDialog.new(preferences_key: ...)` dovrebbe persistere posizione +
dimensione tra sessioni. In pratica su SU 2019:
- `STYLE_DIALOG` salva la **dimensione** ma la **posizione spesso si
  ricentra** all'apertura successiva.
- `STYLE_UTILITY` (palette/inspector, sempre sopra il viewport) persiste
  **posizione + dimensione** in modo affidabile tra sessioni e tra file
  diversi. È il pattern dei tray nativi di SU.

Trade-off: `STYLE_UTILITY` non può andare DIETRO la viewport SU. Per un
pannello pensato come sostituto di una finestra nativa è il
comportamento giusto.

### Auto-riaprire un HtmlDialog all'avvio di SU se era aperto

Pattern "pannello che si ricorda di essere aperto":
1. In `Dialog#show` → `write_default(section, 'main_dialog_open', true)`.
2. In `set_on_closed` → `write_default(..., false)`.
3. In `main.rb` dopo `file_loaded`:
   ```ruby
   if Sketchup.read_default(section, 'main_dialog_open', false)
     ::UI.start_timer(0.5, false) { Dialog.show rescue warn ... }
   end
   ```

Il timer 0.5s è importante: a `file_loaded` la UI di SU non è ancora
pronta a ospitare un HtmlDialog (posizione errata, o crash silenzioso).

### `innerHTML = ''` azzera `scrollTop` del contenitore

Una lista re-renderizzata via `listEl.innerHTML = ''` + append delle nuove
row PERDE la posizione di scroll: con i figli rimossi il browser non ha
più nulla da scrollare, `scrollTop` torna a 0, e quando re-appendiamo
contenuto la scrollbar ricomincia dall'inizio.

**Pattern**: salvare e ripristinare manualmente intorno al re-render:

```js
function render() {
  var savedScroll = listEl.scrollTop;
  listEl.innerHTML = '';
  // ... append rows
  listEl.scrollTop = savedScroll;
}
```

Sintomo se manca: ogni click che triggera render fa "saltare in cima" una
lista più lunga della viewport.

### `<img src="file:///...?t=ts">` cache-buster ribumpato a ogni render

Tentazione: usare un cache-buster `?t=Date.now()` sull'URL `<img>` per
forzare CEF a rileggere il PNG. Se però bumpiamo il timestamp a OGNI
`setState` (e setState fira dopo ogni edit/rename/reorder), CEF
ri-richiede il file innumerevoli volte → ogni tanto la richiesta fallisce
(race con il filesystem, o quirk di CEF su `file://` + query string) e la
preview "sparisce" finché un altro render non capita di farla ricaricare.

**Pattern**: bumpare il cache-buster SOLO quando i file potrebbero essere
cambiati davvero. In pratica:
- al cambio del set di chiavi (es. nuova scena aggiunta con preview), e
- al segnale di fine-generazione esplicito dal Ruby (`setPreviewProgress(null, null)`),
  per il caso di rigenerazione che riscrive lo STESSO uid con contenuto
  nuovo (signature di chiavi invariata).

Tra un'operazione e l'altra l'URL resta identico → CEF tiene tutto in
cache, niente fetch ripetuti.

### Doppia rilevazione `dblclick` (manuale + delegation) → race

Se si usa la rilevazione manuale del doppio click (necessaria perché CEF
SU 2019 non emette `dblclick` se la row viene ricreata tra i due click —
vedi nota sopra), **non aggiungere ANCHE un listener `dblclick` su un
contenitore stabile come `listEl`**: il secondo click triggera entrambi
gli handler, il callback viene chiamato due volte di fila.

Sintomo concreto: `openProperties(id)` chiamato due volte rapidamente →
prima call crea l'HtmlDialog ma il JS di CEF non è ancora pronto, seconda
call trova `@dialog.visible? === true` e fa `execute_script(setState(...))`
ma `window.SMP` è ancora `undefined` → il primo setState va perso → il
dialog mostra il titolo iniziale statico (`—`) o resta su uno stato
precedente.

### `setState` con state vuoto NON deve azzerare la UI esistente

Pattern difensivo per dialog che ricevono push_state da Ruby: se arriva
uno state senza scene/payload (race in apertura, o scena cancellata),
**non sovrascrivere** i campi correnti se ne avevamo di validi. Solo se
non avevamo niente, mostrare "scene not found".

```js
SMP.setState = function (state) {
  const s = state && state.scene;
  if (!s) {
    if (SMP.state && SMP.state.scene) return; // race: ignora
    // ... mostra "not found"
    return;
  }
  // ... applica
};
```

### Intercettare click su sub-element prima di selezione/drag

Per un bottone interno a una row che fa anche da selezione/drag, registrare
il listener sul container in **capture phase** con `stopPropagation`:

```js
listEl.addEventListener('mousedown', function (e) {
  if (!e.target.classList.contains('row-update')) return;
  e.stopPropagation();
  e.preventDefault();
}, true); // CAPTURE
```

Capture phase fira PRIMA degli handler bubble. `stopPropagation` blocca
tutto il flow successivo.

---

## Pattern di concorrenza / state UI

### Async step chain + multiple Save → on_done chiamato N volte

In un export asincrono (catena di `UI.start_timer`), serve:
1. `done_fired` (closure) per garantire chiamata singola a `on_done`
2. `stopped` flag per far ritornare immediatamente i timer già in coda
3. `@running` module-level per rifiutare export concorrenti

Senza queste guard, click multipli su Cancel o doppio click su Export
producevano N messagebox finali (uno per immagine in alcuni casi).

### Settings dialog con `push_state` che riscrive tutti i form

`push_state` riscrive TUTTI i form da storage. Se l'utente modifica la
sezione A ma per qualunque motivo `push_state` viene triggerato (es.
auto-save della sezione B), le modifiche non ancora salvate in A vengono
cancellate.

**Soluzioni adottate**:
1. **Auto-save** su input change per ogni sezione (debounce 350ms su testuali)
2. `setIfNotFocused(el, prop, val)` — non sovrascrive il campo che è
   `document.activeElement`
3. Niente bottoni Save manuali per sezioni con auto-save (l'utente non si
   aspetta di doverlo cliccare)

### ⚠️ `Sketchup.read_default` subito dopo `write_default` può tornare stale

Su SU 2019 le scritture via `write_default` NON sono garantite di essere
visibili a una `read_default` immediatamente successiva nello stesso tick.
La rilettura può tornare il **valore precedente** o il **default**.

Sintomo concreto: in `sm_settings_set` chiamavamo `Core::Settings.set(...)`
e subito dopo `push_state` (che fa `Core::Settings.all` → tante
`read_default`). Lo state ri-pushato conteneva i valori stale. Il
`writeLogo`/`writeExport` in JS sovrascriveva i campi non-focused
(setIfNotFocused passa perché il focus è già su un altro campo) con i
valori vecchi → l'utente vedeva il proprio input "tornare indietro"
cambiando campo.

**Fix**: NON fare `push_state` automatico dopo un save che proviene da
auto-save dal form stesso. Il form JS ha già i valori appena inviati,
non serve un round-trip. Fare `push_state` esplicito solo in callback
che cambiano flag laterali (es. `sm_pick_logo` setta anche `enabled` e
`use_default`).

### Numeric `parseInt(x) || N` collassa 0 sul fallback

`0 || 20 === 20` perché 0 è falsy. Per numerici che ammettono 0 (offset,
opacity 0%, padding, ecc.) serve:

```js
function toIntOr(v, fallback) {
  if (v === '' || v == null) return fallback;
  var n = parseInt(v, 10);
  return Number.isFinite(n) ? n : fallback;
}
```

Solo empty/NaN scattano il fallback, 0 è preservato.

---

## Deploy / packaging

### Sulla macchina dev — copie reali, NON symlink

Idealmente symlink/junction nella cartella Plugins di SU 2019 (PowerShell
admin); ma su alcune macchine i privilegi non bastano e i file sono **copie
reali**. Dopo ogni modifica:

```powershell
$src = "D:\Claude\SceneManager+"
$plug = "$env:APPDATA\SketchUp\SketchUp 2019\SketchUp\Plugins"
Remove-Item "$plug\scene_manager_plus" -Recurse -Force
Copy-Item "$src\scene_manager_plus.rb" "$plug\scene_manager_plus.rb" -Force
Copy-Item "$src\scene_manager_plus" "$plug\" -Recurse
```

⚠️ Trappola: `Copy-Item "$src\dir" "$plug\dir" -Recurse` quando `$plug\dir`
**esiste** annida `$plug\dir\dir\...`. Sempre rimuovere prima la
destinazione.

- Modifiche **Ruby (.rb)** → **riavvia SketchUp**.
- Modifiche **HTML/CSS/JS** → basta chiudere+riaprire la finestra del plugin
  (c'è il cache-bust su `index.html`).
