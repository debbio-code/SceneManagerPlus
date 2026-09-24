module SceneManagerPlus
  module Core
    # Controllo rilievo di fine esecutivo: reimporta il DWG del Leica 3D Disto
    # nel modello, ripulito, su un layer e in una scena dedicati, cosi' si puo'
    # sovrapporlo al progetto e vedere se qualche punto e' stato spostato.
    #
    # Replica il flusso manuale dell'utente (riferimento: file "Modello
    # Pulito.skp" e la scena "Controllo Rilievo" di Cenciarini, misurati via
    # MCP il 2026-09-24):
    #
    #   1. import del DWG in CENTIMETRI, origine del DWG = origine del modello;
    #   2. via i marker a X sui punti (componenti "point"/"single_point" da 2
    #      spigoli ciascuno), via le foto; restano spigoli + punti di costruzione;
    #   3. tutto su Layer0 e senza materiali dentro il componente, che viene
    #      dipinto di rosso ([Color A04]) → con lo stile a "Color: By material"
    #      le linee escono rosse;
    #   4. componente all'origine, sul layer "LEICA_Controllo Rilievo",
    #      visibile solo nella scena di controllo;
    #   5. stile "Controllo Rilievo" (quello della vista + Edges By material) e
    #      scena "Controllo Rilievo" in coda all'elenco.
    #
    # La sovrapposizione al modello la fa l'utente a mano: qui si arriva al
    # rilievo pulito, all'origine, nella sua scena.
    #
    # Fatti misurati che spiegano le scelte (SU 19.0.685):
    #  - `model.import` di un DWG e' sincrono, non attacca nulla al cursore e
    #    mette UN componente al primo livello (identita' con preserve_origin).
    #  - L'unita' si impone con `:units => 'cm'`. 'centimeters', 'centimeter'
    #    e simili sono ignorati IN SILENZIO e l'importer usa l'ultima unita'
    #    scelta a mano nel dialog (sulla postazione dev: metri → rilievo 100
    #    volte piu' grande). Numeri non sono affidabili (3 dava un'altra scala).
    #  - L'import NON si annulla con Ctrl+Z, e committa l'eventuale operazione
    #    aperta dal chiamante: per questo si importa PRIMA e la ripulitura vive
    #    in un'operazione sua (un Ctrl+Z annulla pulizia/layer/stile/scena, non
    #    l'import).
    module SurveyCheck
      module_function

      LAYER_NAME    = 'LEICA_Controllo Rilievo'.freeze
      SCENE_NAME    = 'Controllo Rilievo'.freeze
      STYLE_NAME    = 'Controllo Rilievo'.freeze
      MATERIAL_NAME = '[Color A04]'.freeze # rosso della palette Colors di SU
      MATERIAL_RGB  = [255, 50, 50].freeze

      # EdgeColorMode: 0 = By material (controintuitivo, vedi CLAUDE.md sez.
      # "Style management").
      EDGE_BY_MATERIAL = 0

      IMPORT_OPTS = {
        units: 'cm',
        preserve_origin: true,
        merge_coplanar_faces: false,
        orient_faces: false,
        show_summary: false
      }.freeze

      DIR_PREF = 'survey_check_dir'.freeze

      # Punto d'ingresso (bottone toolbar). Ritorna la Page della scena di
      # controllo, o nil se annullato/fallito. I messaggi all'utente li mostra
      # da se'.
      #
      # path:/mode:/show_report: servono al collaudo via MCP eval_ruby, dove un
      # dialog modale bloccherebbe la chiamata: con un path non si apre il picker,
      # con mode (:new/:replace) non si chiede, con show_report: false niente
      # riepilogo finale (le stats restano in last_stats).
      def run(path: nil, mode: nil, show_report: true)
        m = Sketchup.active_model
        return nil unless m

        path ||= pick_file
        return nil unless path

        mode ||= choose_mode(m)
        return nil if mode == :cancel

        before_ents   = m.entities.to_a
        before_defs   = m.definitions.to_a
        before_layers = m.layers.to_a
        before_mats   = m.materials.to_a

        ok = begin
          m.import(path, IMPORT_OPTS.dup)
        rescue => e
          warn "[SM+] survey_check import: #{e.class}: #{e.message}"
          false
        end
        fresh = (m.entities.to_a - before_ents)
        inst  = fresh.find { |e| e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) }
        unless ok && inst
          ::UI.messagebox("Could not import:\n#{path}\n\nNothing was changed in the model.")
          return nil
        end

        stats = nil
        page  = nil
        m.start_operation('SM+ Survey check', true)
        begin
          stats = clean!(m, inst)
          purge_import_leftovers!(m, inst, before_defs, before_layers, before_mats)

          inst.transformation = Geom::Transformation.new
          inst.material = red_material(m)

          layer = m.layers[LAYER_NAME] || m.layers.add(LAYER_NAME)
          stats[:replaced] = (mode == :replace) ? remove_previous!(m, layer, inst) : 0
          inst.layer = layer
          # Come "Add Visible Tag": le scene future non lo mostrano.
          if defined?(LAYER_IS_HIDDEN_ON_NEW_PAGES) && layer.page_behavior != LAYER_IS_HIDDEN_ON_NEW_PAGES
            layer.page_behavior = LAYER_IS_HIDDEN_ON_NEW_PAGES
          end
          layer.visible = true unless layer.visible?

          existing = m.pages[SCENE_NAME]
          if mode == :replace && existing
            # Si sostituisce solo il rilievo: la scena resta com'era (vista,
            # stile, layer), l'utente l'aveva gia' sistemata.
            page = existing
            m.pages.selected_page = page unless m.pages.selected_page == page
          else
            ensure_style!(m)
            page = create_scene!(m)
          end

          stats[:unconstrained] = show_layer_only_in!(m, layer, page)
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] survey_check: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).join("\n")
          ::UI.messagebox(
            "The survey was imported but the clean-up failed:\n#{e.message}\n\n" \
            "The raw import is still in the model (SketchUp cannot undo a DWG import)."
          )
          return nil
        end

        @last_stats = stats
        report(path, page, stats) if show_report
        page
      end

      def last_stats
        @last_stats
      end

      # ── Passi ─────────────────────────────────────────────────────────

      def pick_file
        dir = Sketchup.read_default('SceneManagerPlus', DIR_PREF, nil)
        if dir.nil? || !File.directory?(dir.to_s)
          mp  = Sketchup.active_model.path.to_s
          dir = mp.empty? ? nil : File.dirname(mp)
        end
        path = ::UI.openpanel('Survey check — choose the 3D Disto DWG', dir.to_s,
                              'AutoCAD (*.dwg, *.dxf)|*.dwg;*.dxf||')
        return nil if path.nil? || path.to_s.empty?
        Sketchup.write_default('SceneManagerPlus', DIR_PREF, File.dirname(path))
        path
      end

      # :new (default), :replace (via il rilievo precedente, la scena resta),
      # :cancel. Chiede solo se c'e' gia' qualcosa di un controllo precedente.
      def choose_mode(m)
        layer   = m.layers[LAYER_NAME]
        has_ents = layer && m.entities.any? { |e| e.layer == layer }
        page    = m.pages[SCENE_NAME]
        return :new unless has_ents || page

        mb  = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
        yes = Object.const_defined?(:IDYES) ? IDYES : 6
        no  = Object.const_defined?(:IDNO)  ? IDNO  : 7
        found = []
        found << "scene '#{SCENE_NAME}'" if page
        found << "a survey on layer '#{LAYER_NAME}'" if has_ents
        choice = ::UI.messagebox(
          "This model already has #{found.join(' and ')}.\n\n" \
          "YES = Replace: remove the previous survey from layer '#{LAYER_NAME}' " \
          "and keep the existing scene as it is.\n" \
          "NO  = Add: keep the previous one and create a new scene.\n" \
          'CANCEL = Do nothing.',
          mb
        )
        case choice
        when yes then :replace
        when no  then :new
        else :cancel
        end
      end

      # Svuota il componente importato di tutto cio' che non e' il rilievo:
      # foto e marker a X via, altri blocchi esplosi (le loro linee restano),
      # tutto su Layer0, niente materiali. Lavora sulla DEFINIZIONE: il
      # componente importato ha una sola istanza.
      def clean!(m, inst)
        stats = Hash.new(0)
        defn  = inst.definition
        ents  = defn.entities
        layer0 = m.layers[0]

        20.times do
          nested = ents.select do |e|
            e.is_a?(Sketchup::ComponentInstance) || e.is_a?(Sketchup::Group) ||
              e.is_a?(Sketchup::Image)
          end
          break if nested.empty?
          nested.each do |e|
            next unless e.valid?
            if photo?(e)
              e.erase!
              stats[:photos] += 1
            elsif marker?(e)
              e.erase!
              stats[:markers] += 1
            else
              e.explode
              stats[:exploded] += 1
            end
          end
        end

        ents.each do |e|
          e.layer = layer0 if e.layer != layer0
          e.material = nil if e.respond_to?(:material=) && e.material
          e.back_material = nil if e.is_a?(Sketchup::Face) && e.back_material
          case e
          when Sketchup::ConstructionPoint then stats[:points] += 1
          when Sketchup::Edge              then stats[:edges]  += 1
          when Sketchup::Text              then stats[:texts]  += 1
          end
        end
        stats
      end

      def photo?(e)
        return true if e.is_a?(Sketchup::Image)
        return true if (e.layer.name.to_s =~ /photo|foto/i)
        d = (e.definition rescue nil)
        !!(d && d.entities.any? { |x| x.is_a?(Sketchup::Image) })
      end

      # Il marker del 3D Disto e' una X: un blocco di soli 2 spigoli ("point",
      # "single_point"). Tolleranza fino a 8 spigoli e nient'altro dentro, cosi'
      # un blocco con geometria vera viene esploso invece che buttato.
      def marker?(e)
        d = (e.definition rescue nil)
        return false unless d
        es = d.entities.to_a
        !es.empty? && es.size <= 8 && es.all? { |x| x.is_a?(Sketchup::Edge) }
      end

      # Toglie cio' che l'import ha creato e che dopo la pulizia non serve
      # piu': definizioni dei marker/foto, i layer LEICA_* nuovi, i materiali
      # <auto>. Solo roba NUOVA: layer/definizioni/materiali che il modello
      # aveva gia' (es. un vecchio import del rilievo) non si toccano.
      def purge_import_leftovers!(m, inst, before_defs, before_layers, before_mats)
        (m.definitions.to_a - before_defs).each do |d|
          next if d == inst.definition
          next unless d.instances.empty?
          begin
            m.definitions.remove(d)
          rescue => e
            warn "[SM+] survey_check: definitions.remove #{d.name}: #{e.message}"
          end
        end
        (m.layers.to_a - before_layers).each do |l|
          next if l.name == LAYER_NAME
          begin
            m.layers.remove(l)
          rescue => e
            warn "[SM+] survey_check: layers.remove #{l.name}: #{e.message}"
          end
        end
        (m.materials.to_a - before_mats).each do |mat|
          next if mat.name == MATERIAL_NAME
          begin
            m.materials.remove(mat)
          rescue => e
            warn "[SM+] survey_check: materials.remove #{mat.name}: #{e.message}"
          end
        end
      end

      def red_material(m)
        mat = m.materials[MATERIAL_NAME]
        return mat if mat
        mat = m.materials.add(MATERIAL_NAME)
        mat.color = Sketchup::Color.new(*MATERIAL_RGB)
        mat
      end

      # Modo "replace": via cio' che il controllo precedente aveva messo sul
      # layer (al primo livello), e le definizioni rimaste senza istanze.
      def remove_previous!(m, layer, keep)
        old = m.entities.select { |e| e.layer == layer && e != keep }
        defs = old.map { |e| (e.definition rescue nil) }.compact.uniq
        m.entities.erase_entities(old) unless old.empty?
        defs.each do |d|
          next unless d.valid? && d.instances.empty?
          m.definitions.remove(d) rescue nil
        end
        old.size
      end

      # Stile "Controllo Rilievo" selezionato nel viewport e con le linee "By
      # material". Se esiste gia' (secondo controllo sullo stesso file) si
      # riusa: l'utente puo' averlo ritoccato. Altrimenti nasce dalla vista
      # corrente, come "+ New style…".
      #
      # Nota: selezionare un altro stile scarta le modifiche non salvate di
      # quello corrente (= "Don't save" nativo). Qui e' accettato: la scena di
      # controllo non deve ereditare ritocchi a meta'.
      def ensure_style!(m)
        st = Styles.find_style(STYLE_NAME)
        if st
          m.styles.selected_style = st unless m.styles.selected_style == st
        else
          st = Styles.build_style_from_viewport!(m, STYLE_NAME)
          raise "could not create style '#{STYLE_NAME}'" unless st
        end
        ro = m.rendering_options
        ro['EdgeColorMode'] = EDGE_BY_MATERIAL if ro['EdgeColorMode'] != EDGE_BY_MATERIAL
        m.styles.update_selected_style
        st
      end

      def create_scene!(m)
        # Un aspect sulla camera del viewport (scena Match Photo, o bande della
        # stampa in scala) finirebbe salvato nella scena nuova, che verrebbe
        # poi scambiata per una Match Photo. La scena di controllo non ne vuole.
        begin
          view = m.active_view
          if view.camera.aspect_ratio.to_f != 0.0
            if defined?(PrintScale) && PrintScale.respond_to?(:force_clear_bands)
              PrintScale.force_clear_bands(view)
            else
              view.camera.aspect_ratio = 0.0
            end
          end
        rescue => e
          warn "[SM+] survey_check aspect: #{e.message}"
        end

        pre_visible = {}
        m.layers.each { |l| pre_visible[l] = l.visible? }
        SceneModel.build_page_from_view!(m, unique_scene_name(m), pre_visible)
      end

      def unique_scene_name(m)
        return SCENE_NAME unless m.pages[SCENE_NAME]
        i = 2
        i += 1 while m.pages["#{SCENE_NAME} #{i}"]
        "#{SCENE_NAME} #{i}"
      end

      # Layer visibile solo nelle scene di controllo: nascosto in tutte le
      # altre (diff-check prima di scrivere, regola del progetto). "Scene di
      # controllo" al plurale perche' in modalita' Add il nuovo rilievo finisce
      # sullo stesso layer del vecchio, e la "Controllo Rilievo" precedente non
      # deve perdere il suo. Ritorna i nomi delle scene che non salvano la
      # visibilita' dei layer e quindi lo mostreranno comunque.
      def show_layer_only_in!(m, layer, page)
        unconstrained = []
        control = /\A#{Regexp.escape(SCENE_NAME)}( \d+)?\z/
        m.pages.each do |p|
          want = (p == page) || !!(p.name.to_s =~ control)
          cur  = !(p.layers.include?(layer) rescue false)
          p.set_visibility(layer, want) if cur != want
          unconstrained << p.name.to_s if !want && !(p.use_hidden_layers? rescue true)
        end
        unconstrained
      end

      def report(path, page, stats)
        lines = []
        lines << "Survey imported: #{File.basename(path)}"
        lines << "  #{stats[:points]} survey points, #{stats[:edges]} lines"
        lines << "  removed: #{stats[:markers]} X markers" \
                 "#{stats[:photos] > 0 ? ", #{stats[:photos]} photos" : ''}"
        lines << "  #{stats[:exploded]} other blocks exploded" if stats[:exploded] > 0
        lines << "  #{stats[:texts]} text labels kept" if stats[:texts] > 0
        lines << "  previous survey removed (#{stats[:replaced]} object(s))" if stats[:replaced].to_i > 0
        lines << ''
        lines << "Scene: #{page ? page.name : '?'}  ·  style: #{STYLE_NAME}"
        lines << "Layer: #{LAYER_NAME} (visible only in this scene)"
        lines << 'The survey sits at the model origin, in red: move it onto the model to compare.'
        unc = Array(stats[:unconstrained])
        unless unc.empty?
          lines << ''
          lines << "These scenes don't save layer visibility and will show the survey too:"
          lines << '  ' + unc.first(10).join(', ') + (unc.size > 10 ? ", … (#{unc.size})" : '')
        end
        lines << ''
        lines << 'Ctrl+Z undoes the clean-up, layer, style and scene, but not the DWG import itself.'
        ::UI.messagebox(lines.join("\n"))
      end
    end
  end
end
