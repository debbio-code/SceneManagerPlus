module SceneManagerPlus
  module Core
    # Gestione layer (in SU 2019 si chiamano ancora "Layers", non "Tags")
    # esposta dentro il Properties dialog di una scena.
    #
    # Semantica scelta (vedi CLAUDE.md, sezione "Layers nel Properties dialog"):
    #
    #  - **Filtro della lista = per-scena**: mostriamo solo i layer che QUESTA
    #    scena non nasconde, cioe' `model.layers - page.layers` (`page.layers`
    #    e' la hidden-list della pagina, semantica controintuitiva documentata
    #    in docs/SU2019-LESSONS.md).
    #  - **Tutte le operazioni = sul modello**, esattamente come il pannello
    #    Layers nativo: visibilita', rename, layer corrente, colore, line style,
    #    add/delete/purge cambiano il modello e valgono per tutte le scene. La
    #    scena le cattura solo con "Update from view".
    #
    # I due assi restano quindi indipendenti: togliere la spunta di visibilita'
    # NON fa sparire il layer dalla lista (il filtro dipende da `page.layers`,
    # non da `layer.visible?`).
    #
    # Chiave di identita' = il NOME del layer. I nomi sono unici in SU e il
    # rename e' l'unica operazione che li cambia: passa esplicitamente old/new
    # e subito dopo viene ri-pushato lo state completo.
    # (`Layer#persistent_id` non e' affidabile in SU 2019 — stesso sospetto
    # gia' confermato per `Material#persistent_id`, che ritorna 0.)
    module Layers
      module_function

      def model
        Sketchup.active_model
      end

      # ── Lookup ────────────────────────────────────────────────────────

      def find(name)
        m = model
        return nil unless m && name
        n = name.to_s
        m.layers.to_a.find { |l| (l.name.to_s rescue nil) == n }
      rescue
        nil
      end

      # Il layer di default (Layer0) non e' rinominabile ne' cancellabile,
      # come nel pannello nativo.
      def default?(layer)
        return false unless layer
        return true if (layer.name.to_s rescue '') == 'Layer0'
        m = model
        return false unless m
        d = (m.layers[0] rescue nil)
        !!(d && d == layer)
      rescue
        false
      end

      # ── Line styles (SU 2019+) ────────────────────────────────────────
      # `Sketchup::LineStyles` e `Layer#line_style` sono stati introdotti in
      # SU 2019, ma li interroghiamo in modo difensivo: se un giorno il plugin
      # gira su una build che non li espone, la colonna Dashes sparisce dalla
      # UI invece di far esplodere il payload.

      def line_styles_supported?
        m = model
        return false unless m && m.respond_to?(:line_styles) && m.line_styles
        l = (m.layers[0] rescue nil)
        !!(l && l.respond_to?(:line_style) && l.respond_to?(:line_style=))
      rescue
        false
      end

      def line_style_names
        return [] unless line_styles_supported?
        ls = model.line_styles
        arr = if ls.respond_to?(:names)
                ls.names
              elsif ls.respond_to?(:map)
                ls.map { |x| x.name }
              else
                []
              end
        arr.map { |x| x.to_s }.reject { |x| x.empty? }
      rescue
        []
      end

      def line_style_name_of(layer)
        return '' unless layer.respond_to?(:line_style)
        ls = layer.line_style
        ls ? ls.name.to_s : ''
      rescue
        ''
      end

      # ── Color by layer ────────────────────────────────────────────────
      # E' la checkbox "Color by layer" del pannello Layers nativo, cioe' una
      # RenderingOption del MODELLO (non un attributo dei layer). Come tutte le
      # RO viene catturata per-scena da `use_rendering_options` e sporca lo
      # stile attivo: non chiamiamo `update_selected_style`, esattamente come il
      # nativo e come `fog_apply` nel Properties dialog.
      #
      # Il nome della chiave viene cercato invece che assunto: se un giorno
      # cambia, la funzione la ritrova per pattern e il bottone continua a
      # funzionare (o sparisce dalla UI, invece di scrivere a vuoto).
      COLOR_BY_LAYER_KEYS = ['DisplayColorByLayer', 'ColorByLayer'].freeze

      def color_by_layer_key
        return @cbl_key if @cbl_probed
        @cbl_probed = true
        @cbl_key = nil
        m = model
        return nil unless m
        ro = m.rendering_options
        COLOR_BY_LAYER_KEYS.each do |k|
          v = (ro[k] rescue nil)
          if !v.nil?
            @cbl_key = k
            return k
          end
        end
        ro.each_pair { |k, _v| @cbl_key ||= k.to_s if k.to_s =~ /colorbylayer/i }
        @cbl_key
      rescue
        nil
      end

      def color_by_layer?
        m = model
        k = color_by_layer_key
        return false unless m && k
        (m.rendering_options[k] rescue false) ? true : false
      end

      def set_color_by_layer(value)
        m = model
        k = color_by_layer_key
        return false unless m && k
        v = value ? true : false
        return true if (m.rendering_options[k] rescue nil) == v
        op('SM+ Color by layer') { m.rendering_options[k] = v }
        true
      end

      # ── Payload per la UI ─────────────────────────────────────────────

      # I layer nascosti DA QUESTA SCENA (hidden-list della pagina).
      def hidden_names_for(page)
        return [] unless page
        (page.layers || []).map { |l| (l.name.to_s rescue nil) }.compact
      rescue
        []
      end

      def color_hex(layer)
        c = (layer.color rescue nil)
        return '' unless c && c.respond_to?(:red)
        format('#%02x%02x%02x', c.red, c.green, c.blue)
      rescue
        ''
      end

      def row_for(layer, current_name)
        {
          'name'       => layer.name.to_s,
          'visible'    => ((layer.visible? rescue true) ? true : false),
          'current'    => (layer.name.to_s == current_name),
          'color'      => color_hex(layer),
          'line_style' => line_style_name_of(layer),
          'is_default' => default?(layer)
        }
      end

      # Costruisce il payload della sezione Layers per la pagina `page`.
      #
      # Se la scena NON ha `use_hidden_layers?` non salva override di
      # visibilita': in quel caso "i layer della scena" sono semplicemente
      # tutti quelli del modello, e lo segnaliamo con `scene_tracks=false`
      # cosi' la UI puo' spiegarlo invece di mostrare un filtro bugiardo.
      def payload_for_page(page)
        m = model
        return nil unless m

        scene_tracks = page ? ((page.use_hidden_layers? rescue true) ? true : false) : true
        hidden       = scene_tracks ? hidden_names_for(page) : []
        hidden_set   = {}
        hidden.each { |n| hidden_set[n] = true }

        current = (m.active_layer.name.to_s rescue nil)
        all     = m.layers.to_a
        listed  = scene_tracks ? all.reject { |l| hidden_set[l.name.to_s] } : all

        rows = listed.map { |l| row_for(l, current) }
        rows.sort_by! { |r| [r['is_default'] ? 0 : 1, r['name'].to_s.downcase] }

        {
          'layers'                  => rows,
          'hidden_names'            => hidden.sort_by { |n| n.downcase },
          'hidden_count'            => hidden.size,
          'total_count'             => all.size,
          'scene_tracks'            => scene_tracks,
          'line_styles'             => line_style_names,
          'supports_line_style'     => line_styles_supported?,
          'color_by_layer'          => color_by_layer?,
          'supports_color_by_layer' => !color_by_layer_key.nil?
        }
      rescue => e
        warn "[SM+] Layers.payload_for_page failed: #{e.class}: #{e.message}"
        nil
      end

      # ── Operazioni ────────────────────────────────────────────────────

      # Wrapper start_operation/commit. disable_ui=true: su modelli con
      # AttributeObserver di plugin terzi evita i refresh sincroni degli
      # inspector (vedi CLAUDE.md, sezione performance).
      def op(label)
        m = model
        return nil unless m
        m.start_operation(label, true)
        begin
          r = yield m
          m.commit_operation
          r
        rescue => e
          m.abort_operation
          warn "[SM+] Layers #{label} failed: #{e.class}: #{e.message}"
          nil
        end
      end

      def set_visible(name, value)
        l = find(name)
        return false unless l
        v = value ? true : false
        # Diff prima del setter: regola generale del progetto, meno write =
        # meno freeze sui modelli con observer terzi.
        return true if (l.visible? rescue nil) == v
        op('SM+ Layer visibility') { l.visible = v }
        true
      end

      # Layer corrente = `model.active_layer`. Non e' una modifica del modello
      # (non sporca l'undo stack), quindi niente start_operation.
      def set_current(name)
        m = model
        l = find(name)
        return false unless m && l
        return true if m.active_layer == l
        m.active_layer = l
        true
      rescue => e
        warn "[SM+] Layers.set_current failed: #{e.class}: #{e.message}"
        false
      end

      # Ritorna [ok, error_key]. error_key: 'not_found' | 'empty' | 'exists' |
      # 'default'.
      def rename(old_name, new_name)
        m = model
        l = find(old_name)
        return [false, 'not_found'] unless m && l
        nn = new_name.to_s.strip
        return [false, 'empty'] if nn.empty?
        return [true, nil] if nn == l.name.to_s
        return [false, 'default'] if default?(l)
        clash = m.layers.to_a.find { |x| x != l && (x.name.to_s.downcase rescue '') == nn.downcase }
        return [false, 'exists'] if clash
        op('SM+ Rename layer') { l.name = nn }
        [true, nil]
      end

      def set_color(name, hex)
        l = find(name)
        return false unless l
        c = Styles.hex_to_color(hex)
        return false unless c
        op('SM+ Layer color') { l.color = c }
        true
      end

      # `ls_name` vuoto = torna al line style di default (nil).
      def set_line_style(name, ls_name)
        m = model
        l = find(name)
        return false unless m && l && l.respond_to?(:line_style=)
        s = ls_name.to_s
        target = nil
        unless s.empty?
          target = (m.line_styles[s] rescue nil)
          return false unless target
        end
        op('SM+ Layer line style') { l.line_style = target }
        true
      end

      # Sposta la selezione corrente del modello su questo layer, come fa
      # Entity Info nativo: agisce sulle entita' SELEZIONATE, senza scendere
      # dentro gruppi/componenti (se e' selezionato un gruppo, va sul layer il
      # gruppo, non le facce che contiene).
      #
      # Ritorna un hash { 'moved', 'already', 'skipped', 'total' } oppure nil
      # se il layer non esiste. Selezione vuota => total 0, nessuna operazione.
      def assign_selection(name)
        m = model
        l = find(name)
        return nil unless m && l
        sel = (m.selection.to_a rescue [])
        res = { 'moved' => 0, 'already' => 0, 'skipped' => 0, 'total' => sel.size }
        return res if sel.empty?

        op('SM+ Move selection to layer') do
          sel.each do |e|
            begin
              if !(e.valid? rescue false) || !e.respond_to?(:layer=)
                res['skipped'] += 1
                next
              end
              if (e.layer rescue nil) == l
                res['already'] += 1
                next
              end
              e.layer = l
              res['moved'] += 1
            rescue
              res['skipped'] += 1
            end
          end
        end
        res
      end

      # ── Contenuto di un layer (finestra info) ─────────────────────────

      # Ogni entita' del modello, esattamente una volta: le entita' al primo
      # livello stanno in `model.entities`, tutto cio' che vive dentro gruppi e
      # componenti sta nelle `entities` della relativa DEFINITION (i gruppi in
      # SU hanno una definition come i componenti). Iterare le istanze invece
      # delle definition conterebbe N volte lo stesso contenuto.
      #
      # Yielda (entity, 'root'|'nested', owner) dove `owner` e' il nome della
      # definition che contiene l'entita' (nil al primo livello). Serve a dire
      # DOVE stanno le entita' che non si riescono a selezionare.
      def each_entity_on_layer(l)
        m = model
        return unless m && l
        m.entities.each do |e|
          yield(e, 'root', nil) if (e.layer rescue nil) == l
        end
        m.definitions.each do |d|
          next if (d.deleted? rescue false)
          next if (d.image? rescue false) # la faccia interna di un'immagine non e' contenuto utile
          owner = (d.name.to_s rescue '?')
          d.entities.each do |e|
            yield(e, 'nested', owner) if (e.layer rescue nil) == l
          end
        end
      end

      # Categoria di una entita', condivisa da stats_for (conteggi), dalla
      # conferma dello spostamento e dalla selezione per categoria: le tre cose
      # devono classificare allo stesso modo, altrimenti la finestra info
      # promette N e la selezione ne prende un altro numero.
      #
      # Image e Group vengono prima di ComponentInstance: se in qualche build
      # una delle due ereditasse da ComponentInstance finirebbe nel ramo
      # sbagliato. Dimension non ha un `when` dedicato (non e' garantita in
      # tutte le build): cade nel ramo generico col proprio nome classe.
      def category_of(e)
        case e
        when Sketchup::Face  then 'faces'
        when Sketchup::Edge  then 'edges'
        when Sketchup::Image then 'images'
        when Sketchup::Group then 'groups'
        when Sketchup::ComponentInstance then 'components'
        when Sketchup::Text  then 'text'
        when Sketchup::ConstructionLine, Sketchup::ConstructionPoint then 'guides'
        when Sketchup::SectionPlane then 'section_planes'
        else (e.class.name.to_s.split('::').last rescue 'Entity')
        end
      end

      # Etichette leggibili per i messaggi di conferma/stato.
      CATEGORY_LABELS = {
        'faces'          => 'faces',
        'edges'          => 'edges',
        'images'         => 'images',
        'groups'         => 'groups',
        'components'     => 'component instances',
        'text'           => 'text',
        'guides'         => 'guides',
        'section_planes' => 'section planes',
        'root'           => 'entities at the model root',
        'nested'         => 'entities inside groups / components',
        'all'            => 'entities'
      }.freeze

      def category_label(key)
        CATEGORY_LABELS[key.to_s] || key.to_s
      end

      # "4 faces" / "1 face": i messaggi di conferma sono pieni di conteggi e
      # "1 faces" fa sciatto.
      def count_label(n, key)
        lbl = category_label(key)
        lbl = lbl[0..-2] if n.to_i == 1 && lbl.end_with?('s')
        "#{n} #{lbl}"
      end

      # Ritorna un hash pronto per la UI, o nil se il layer non esiste.
      def stats_for(name)
        m = model
        l = find(name)
        return nil unless m && l

        counts = Hash.new(0)   # categoria => n
        other  = Hash.new(0)   # classe SU non prevista => n
        defs   = Hash.new(0)   # nome definition => n istanze sul layer
        scope  = { 'root' => 0, 'nested' => 0 }

        each_entity_on_layer(l) do |e, where|
          scope[where] += 1
          cat = category_of(e)
          if cat == 'components'
            counts['components'] += 1
            defs[(e.definition.name.to_s rescue '?')] += 1
          elsif CATEGORY_LABELS.key?(cat)
            counts[cat] += 1
          else
            counts['other'] += 1
            other[cat] += 1
          end
        end

        {
          'name'        => l.name.to_s,
          'color'       => color_hex(l),
          'visible'     => ((l.visible? rescue true) ? true : false),
          'current'     => (m.active_layer == l rescue false),
          'line_style'  => line_style_name_of(l),
          'is_default'  => default?(l),
          'total'       => scope['root'] + scope['nested'],
          'root'        => scope['root'],
          'nested'      => scope['nested'],
          'counts'      => counts,
          'other'       => other,
          'definitions' => defs.sort_by { |n, c| [-c, n.downcase] },
          'model_title' => (m.title.to_s rescue '')
        }
      rescue => e
        warn "[SM+] Layers.stats_for failed: #{e.class}: #{e.message}"
        nil
      end

      # Cosa verrebbe spostato dalla freccia, per la conferma prima di agire.
      # { 'total', 'already', 'counts' => { categoria => n } }.
      def selection_summary(name)
        m = model
        l = find(name)
        return nil unless m && l
        sel = (m.selection.to_a rescue [])
        counts  = Hash.new(0)
        already = 0
        sel.each do |e|
          counts[category_of(e)] += 1
          already += 1 if (e.layer rescue nil) == l
        end
        { 'total' => sel.size, 'already' => already, 'counts' => counts }
      rescue
        nil
      end

      # Seleziona nel modello le entita' di una categoria che stanno su questo
      # layer. `category`: chiave di category_of, oppure 'root' / 'nested' /
      # 'all'. `def_name` non nil = solo le istanze di quella definition.
      #
      # LIMITE SU 2019: la selezione vive nel contesto di editing aperto. Le
      # entita' dentro gruppi/componenti si possono aggiungere alla collection
      # (verificato: `selection.add` non solleva e il count sale) ma SketchUp
      # non le evidenzia ne' le tratta come selezionate, e `Model#active_path=`
      # — l'unico modo di entrare in un contesto da codice — esiste solo dal
      # 2020. Quindi selezioniamo SOLO cio' che sta in `active_entities` e
      # riportiamo il resto, invece di fingere una selezione fantasma.
      #
      # Ritorna { 'selected', 'total', 'elsewhere' } o nil.
      def select_on_layer(name, category, def_name = nil)
        m = model
        l = find(name)
        return nil unless m && l
        cat = category.to_s

        in_ctx = {}
        (m.active_entities.to_a rescue []).each do |e|
          id = (e.entityID rescue nil)
          in_ctx[id] = true if id
        end

        picked = []
        total  = 0
        missed = Hash.new(0)   # contenitore => quante entita' irraggiungibili
        each_entity_on_layer(l) do |e, where, owner|
          next unless category_match?(e, where, cat, def_name)
          total += 1
          id = (e.entityID rescue nil)
          if id && in_ctx[id]
            picked << e
          else
            # owner nil = primo livello: succede quando l'utente sta lavorando
            # DENTRO un gruppo, quindi e' la radice a essere fuori contesto.
            missed[owner || '(model root)'] += 1
          end
        end

        sel = m.selection
        sel.clear
        sel.add(picked) unless picked.empty?
        { 'selected'  => picked.size,
          'total'     => total,
          'elsewhere' => total - picked.size,
          'inside'    => missed.sort_by { |k, v| [-v, k.to_s.downcase] } }
      rescue => e
        warn "[SM+] Layers.select_on_layer failed: #{e.class}: #{e.message}"
        nil
      end

      # ── Isolamento (mostra solo questo layer) ─────────────────────────
      #
      # Snapshot in RAM della visibilita' di tutti i layer + spegnimento di
      # tutti tranne il target. E' un'operazione di MODELLO come le altre della
      # sezione Layers: le scene con "Visible Layers" la sovrascrivono appena
      # vengono riattivate, quindi l'isolamento e' di fatto temporaneo (oltre a
      # essere undoable con Ctrl+Z).
      #
      # Lo snapshot e' per-sessione e indicizzato per NOME: se nel frattempo un
      # layer viene rinominato la sua entry viene semplicemente saltata al
      # ripristino, invece di ripristinare il layer sbagliato.
      @iso_snapshot = nil
      @iso_expected = nil

      # Non basta "abbiamo isolato": l'isolamento viene disfatto in continuazione
      # da fuori — attivare una scena con "Visible Layers" riscrive la
      # visibilita' di tutti i layer, e infatti succede al primo click su una
      # scena. Se dichiarassimo attivo un isolamento che non c'e' piu', il
      # ripristino riverserebbe una fotografia vecchia sopra lo stato nuovo.
      # Quindi confrontiamo con quello che avevamo lasciato nel modello.
      def isolation_active?
        return false unless @iso_snapshot && @iso_expected
        m = model
        return false unless m
        m.layers.each do |x|
          exp = @iso_expected[x.name.to_s]
          next if exp.nil?
          return false if ((x.visible? rescue true) ? true : false) != exp
        end
        true
      rescue
        false
      end

      def isolate_layer(name)
        m = model
        l = find(name)
        return nil unless m && l
        snap = {}
        m.layers.each { |x| snap[x.name.to_s] = ((x.visible? rescue true) ? true : false) }
        op('SM+ Isolate layer') do
          m.layers.each do |x|
            want = (x == l)
            next if (x.visible? rescue nil) == want
            begin
              x.visible = want
            rescue => e
              # Non e' un motivo per abortire l'isolamento del resto.
              warn "[SM+] isolate: cannot set #{x.name}: #{e.class}"
            end
          end
        end
        # Conteggio a posteriori, non "quanti ne ho provati a spegnere":
        # verificato su SU 2019 che il layer di default NON si lascia nascondere
        # (nessuna eccezione, semplicemente resta visibile).
        hidden   = 0
        refused  = []
        expected = {}
        m.layers.each do |x|
          vis = ((x.visible? rescue true) ? true : false)
          expected[x.name.to_s] = vis
          next if x == l
          if vis
            refused << x.name.to_s
          else
            hidden += 1
          end
        end
        @iso_snapshot = snap
        @iso_expected = expected
        { 'hidden' => hidden, 'refused' => refused }
      rescue => e
        warn "[SM+] Layers.isolate_layer failed: #{e.class}: #{e.message}"
        nil
      end

      def restore_visibility
        m = model
        # isolation_active? verifica che il modello sia ANCORA come l'abbiamo
        # lasciato: se nel frattempo una scena ha riscritto la visibilita', non
        # dobbiamo sovrascriverla con lo snapshot vecchio.
        return false unless m && @iso_snapshot && isolation_active?
        snap = @iso_snapshot
        op('SM+ Restore layer visibility') do
          m.layers.each do |x|
            v = snap[x.name.to_s]
            next if v.nil?
            (x.visible = v) if (x.visible? rescue nil) != v
          end
        end
        @iso_snapshot = nil
        @iso_expected = nil
        true
      rescue => e
        warn "[SM+] Layers.restore_visibility failed: #{e.class}: #{e.message}"
        false
      end

      # Seleziona i CONTENITORI di una definition: le istanze di `def_name` che
      # si riescono a selezionare dal contesto aperto. E' la via d'uscita al
      # limite di `select_on_layer`: le facce dentro un componente non sono
      # selezionabili, ma il componente che le contiene si'.
      #
      # Se nemmeno le istanze dirette sono raggiungibili (componente dentro
      # componente), si sale: dalla definition si passa a quelle che la
      # contengono, finche' non si trova qualcosa nel contesto aperto. Cosi' un
      # click porta comunque a selezionare l'oggetto di primo livello che, in
      # fondo alla catena, contiene quella roba.
      #
      # Ritorna { 'selected', 'climbed' (livelli risaliti), 'name' } o nil.
      MAX_CLIMB = 12

      def select_containers_of(def_name)
        m = model
        return nil unless m && def_name && !def_name.to_s.empty?

        ctx_ids = {}
        (m.active_entities.to_a rescue []).each do |e|
          id = (e.entityID rescue nil)
          ctx_ids[id] = true if id
        end

        visited = {}
        queue   = [def_name.to_s]
        picked  = []
        climbed = 0

        while !queue.empty? && climbed < MAX_CLIMB
          up = []
          queue.each do |dn|
            next if visited[dn]
            visited[dn] = true
            d = (m.definitions[dn] rescue nil)
            next unless d
            (d.instances rescue []).each do |inst|
              id = (inst.entityID rescue nil)
              if id && ctx_ids[id]
                picked << inst
              else
                par = (inst.parent rescue nil)
                up << par.name.to_s if par.is_a?(Sketchup::ComponentDefinition)
              end
            end
          end
          break unless picked.empty?
          queue = up.uniq
          climbed += 1
        end

        sel = m.selection
        sel.clear
        sel.add(picked) unless picked.empty?
        { 'selected' => picked.size, 'climbed' => climbed, 'name' => def_name.to_s }
      rescue => e
        warn "[SM+] Layers.select_containers_of failed: #{e.class}: #{e.message}"
        nil
      end

      def category_match?(e, where, cat, def_name)
        if def_name && !def_name.to_s.empty?
          return false unless category_of(e) == 'components'
          return (e.definition.name.to_s rescue '') == def_name.to_s
        end
        case cat
        when 'all'    then true
        when 'root'   then where == 'root'
        when 'nested' then where == 'nested'
        when 'other'  then !CATEGORY_LABELS.key?(category_of(e))
        else category_of(e) == cat
        end
      end

      def next_layer_name
        m = model
        return 'Layer1' unless m
        taken = m.layers.map { |l| (l.name.to_s.downcase rescue '') }
        i = 1
        i += 1 while taken.include?("layer#{i}")
        "Layer#{i}"
      end

      # Crea un layer con nome auto-univoco ("Layer1", "Layer2", ...) e lo
      # ritorna, cosi' la UI puo' aprirci sopra il rename inline.
      def add_layer
        m = model
        return nil unless m
        nn = next_layer_name
        op('SM+ Add layer') { m.layers.add(nn) }
        nn
      end

      # Crea un layer visibile SOLO nella scena `page`.
      #
      # Variante di "Add Visible Tag" del plugin Layers Manager, che fa
      # `pages.each { |p| p.set_visibility(l, p == selected_page) }` — cioe' e'
      # ancorato alla scena ATTIVA. Qui il target e' la scena aperta nel
      # Properties dialog, che puo' NON essere quella attiva nel viewport.
      #
      # Verificato su SU 19.3.253:
      #  - `set_visibility` su una pagina NON attiva non tocca `layer.visible?`;
      #  - sulla pagina ATTIVA invece lo sincronizza.
      # Quindi il loop da solo fa gia' la cosa giusta quando una delle pagine e'
      # attiva, ma NON quando `selected_page` e' nil (nessuna scena attiva): in
      # quel caso il layer nasce `visible? == true` e comparirebbe nel viewport.
      # Per questo lo stato del modello viene forzato esplicitamente a valle.
      #
      # Ritorna { 'name' => nome, 'unconstrained' => [nomi delle scene che non
      # salvano la visibilita' dei layer, e che quindi lo mostreranno comunque] }.
      def add_layer_visible_only_in(page)
        m = model
        return nil unless m && page
        name   = next_layer_name
        active = (m.pages.selected_page rescue nil)
        unconstrained = []
        op('SM+ Add layer visible only in this scene') do
          l = m.layers.add(name)
          # Come "Add Visible Tag": le scene create in futuro lo nascondono.
          l.page_behavior = LAYER_IS_HIDDEN_ON_NEW_PAGES if defined?(LAYER_IS_HIDDEN_ON_NEW_PAGES)
          m.pages.each do |p|
            want = (p == page)
            # Diff-check prima di scrivere: regola generale del progetto sui
            # modelli con AttributeObserver di plugin terzi.
            cur = !(p.layers.include?(l) rescue false)
            p.set_visibility(l, want) if cur != want
            # Una scena senza "Visible Layers" non ripristina la hidden-list,
            # quindi il layer le sfugge: lo segnaliamo invece di mentire.
            unconstrained << p.name.to_s if !want && !(p.use_hidden_layers? rescue true)
          end
          want_now = (active == page)
          l.visible = want_now if l.visible? != want_now
        end
        { 'name' => name, 'unconstrained' => unconstrained }
      end

      # mode: 'move' = cancella il layer e sposta la geometria su Layer0
      #       'erase' = cancella il layer E la sua geometria
      # Ritorna [ok, error_key].
      def delete_layer(name, mode)
        m = model
        l = find(name)
        return [false, 'not_found'] unless m && l
        return [false, 'default'] if default?(l)
        return [false, 'last'] if m.layers.count <= 1
        erase = (mode.to_s == 'erase')
        # Se e' il layer corrente SU rifiuta la remove: riportiamo il corrente
        # sul default prima di cancellare.
        m.active_layer = m.layers[0] if m.active_layer == l
        op('SM+ Delete layer') do
          begin
            m.layers.remove(l, erase)
          rescue ArgumentError
            # Build senza il secondo parametro: rimuove il layer preservando
            # la geometria (che finisce su Layer0).
            m.layers.remove(l)
          end
        end
        [true, nil]
      end

      # Ritorna il numero di layer rimossi.
      def purge_unused
        m = model
        return 0 unless m
        before = m.layers.count
        op('SM+ Purge unused layers') { m.layers.purge_unused }
        after = m.layers.count
        d = before - after
        d > 0 ? d : 0
      rescue
        0
      end
    end
  end
end
