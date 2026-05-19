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

Usare lookup difensivo (`Object.const_defined?`) che prova più nomi e prende
quello presente.

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
