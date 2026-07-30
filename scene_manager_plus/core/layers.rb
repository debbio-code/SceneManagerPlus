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
          'layers'              => rows,
          'hidden_names'        => hidden.sort_by { |n| n.downcase },
          'hidden_count'        => hidden.size,
          'total_count'         => all.size,
          'scene_tracks'        => scene_tracks,
          'line_styles'         => line_style_names,
          'supports_line_style' => line_styles_supported?
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
