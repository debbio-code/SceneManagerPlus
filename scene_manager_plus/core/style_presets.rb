module SceneManagerPlus
  module Core
    # Preset di stile: stili "pronti" che il plugin sa ricreare in qualunque
    # file. Si scelgono dal picker del badge lettera (tasto destro), sotto
    # "+ New style…": il preset crea lo stile e lo assegna alle scene
    # bersaglio, come "+ New style…" ma senza chiedere il nome.
    #
    # Un preset è il template bundled (Core::Styles) più:
    #   ro:          rendering options da scrivere (colori come "#rrggbb");
    #   match_photo: voci Foreground/Background Photo. NON sono rendering
    #                options (l'API non le espone): passano dal pannello
    #                Styles nativo, Core::NativePanel. Per ogni voce `on`
    #                (checkbox) e, facoltativa, `opacity` (0..100).
    #
    # Photomatch (2026-10-24): rifatto sullo stile omonimo costruito a mano
    # dall'utente. Sfondo #ccccc9 e cielo #c6cdd0 coincidono già col
    # template, ma si scrivono lo stesso: il preset non deve dipendere da
    # come è stato esportato il template.
    # Opacità delle foto NON impostate: nello screenshot di riferimento
    # valevano 0 e 0, che è la tipica lettura "vecchia" del pannello nativo
    # (vedi NativePanel.match_photo_state) — e una foto di sfondo a opacità 0
    # non si vedrebbe. Restano quelle del template. Per fissarle, aggiungere
    # opacity: N alla voce.
    #
    # Disegni Tecnici e Prospettive (2026-10-24): anche questi dagli stili
    # omonimi dell'utente. Niente voci Match Photo (sono per scene normali),
    # quindi restano quelle del template.
    #
    # description: nil = tiene quella del template (Photomatch, come nello
    # stile di riferimento); '' = vuota; altrimenti il testo.
    module StylePresets
      module_function

      PRESETS = [
        {
          id:   'photomatch',
          name: 'Photomatch',
          ro: {
            'EdgeColorMode'        => 1,          # All same (0 = By material)
            'TransparencySort'     => 2,          # Nicer
            'DrawSilhouettes'      => true,       # Profiles
            'SilhouetteWidth'      => 1,          # apply_ro_snapshot scrive anche ProfileWidth
            'BackgroundColor'      => '#ccccc9',
            'DrawHorizon'          => false,      # Sky
            'SkyColor'             => '#c6cdd0',
            'HorizonColor'         => '#ffffff',
            'ModelTransparency'    => false,      # X-ray
            'DrawHidden'           => false,      # Hidden geometry
            'DisplaySketchAxes'    => true,       # Model axes
            'DisplaySectionPlanes' => false,
            'DisplaySectionCuts'   => true
          },
          match_photo: {
            'foreground' => { on: false },
            'background' => { on: true }
          }
        },
        {
          id:   'disegni_tecnici',
          name: 'Disegni Tecnici',
          ro: {
            'EdgeColorMode'        => 1,          # All same
            'TransparencySort'     => 2,          # Nicer
            'DrawSilhouettes'      => true,       # Profiles
            'SilhouetteWidth'      => 1,
            'BackgroundColor'      => '#fffefe',
            'DrawHorizon'          => false,      # Sky
            'SkyColor'             => '#159bd4',
            'HorizonColor'         => '#ffffff',
            'ModelTransparency'    => false,      # X-ray
            'DrawHidden'           => false,      # Hidden geometry
            'DisplaySketchAxes'    => false,      # Model axes
            'DisplaySectionPlanes' => false,
            'DisplaySectionCuts'   => true
          },
          description: ''
        },
        {
          id:   'prospettive',
          name: 'Prospettive',
          ro: {
            'EdgeColorMode'        => 1,          # All same
            'TransparencySort'     => 2,          # Nicer
            'DrawSilhouettes'      => true,       # Profiles
            'SilhouetteWidth'      => 1,
            'BackgroundColor'      => '#ccccc9',
            'DrawHorizon'          => true,       # Sky
            'SkyColor'             => '#80b2f1',
            'HorizonColor'         => '#ffffff',
            'ModelTransparency'    => false,      # X-ray
            'DrawHidden'           => false,      # Hidden geometry
            'DisplaySketchAxes'    => false,      # Model axes
            'DisplaySectionPlanes' => false,
            'DisplaySectionCuts'   => true
          },
          description: "Voli d'uccello e prospettive dal basso"
        }
      ].freeze

      MANUAL_HINT = 'Set them by hand in the Style window (left click on the letter).'.freeze

      # Per il picker della finestra principale (state.style_presets).
      def list
        PRESETS.map { |p| { id: p[:id], name: p[:name] } }
      end

      def find(id)
        PRESETS.find { |p| p[:id] == id.to_s }
      end

      # Flusso completo del picker: crea lo stile del preset (o riusa quello
      # omonimo, se l'utente vuole) e lo assegna alle scene `ids`.
      # Ritorna il nome dello stile assegnato, nil se annullato o fallito.
      #
      # Ctrl+Z: creazione e assegnazione sono due operazioni, come
      # "+ New style…"; le voci Match Photo passano dal pannello nativo.
      def apply_to_scenes(id, ids)
        preset = find(id)
        unless preset
          ::UI.messagebox("Unknown style preset: #{id.inspect}")
          return nil
        end
        pages = Array(ids).map { |i| SceneModel.find_by_id(i) }.compact
        # Match Photo: la conferma va chiesta PRIMA di creare lo stile (come
        # in sm_style_new): un annullamento dopo lascerebbe uno stile orfano.
        mp_pages = pages.select { |p| SceneModel.matchphoto?(p) }
        return nil if !mp_pages.empty? && !SceneModel.confirm_mp_style_change(mp_pages)

        style, created = resolve_style(preset)
        return nil unless style
        name = style.name.to_s
        return nil if !pages.empty? && SceneModel.assign_styles(ids, name).to_i == 0
        if created
          problem = apply_match_photo!(preset, style, pages)
          ::UI.messagebox(problem) if problem
        end
        puts "[SM+] style preset '#{preset[:id]}': style=#{name.inspect} " \
             "created=#{created} scenes=#{pages.map(&:name).inspect}"
        name
      end

      # [Style, creato?] — se esiste già uno stile col nome del preset chiede
      # se riusarlo o crearne uno nuovo ("Photomatch 2"). [nil, false] se
      # annullato o se la creazione fallisce.
      def resolve_style(preset)
        existing = Styles.find_style(preset[:name])
        if existing
          mb_const  = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
          id_yes    = Object.const_defined?(:IDYES) ? IDYES : 6
          id_no     = Object.const_defined?(:IDNO)  ? IDNO  : 7
          choice = ::UI.messagebox(
            "A style named '#{preset[:name]}' already exists in this model.\n\n" \
            "YES = Use the existing style.\n" \
            "NO  = Create a new style from the preset " \
            "('#{Styles.unique_style_name(preset[:name])}').\n" \
            "CANCEL = Do nothing.",
            mb_const
          )
          return [existing, false] if choice == id_yes
          return [nil, false] unless choice == id_no
        end
        st = create_style(preset)
        [st, !st.nil?]
      end

      def create_style(preset)
        m = Sketchup.active_model
        return nil unless m
        prev = m.styles.selected_style
        st = Styles.create_style_from_ro_hash(preset[:ro], name: preset[:name],
                                              description: preset[:description])
        return nil unless st
        # create_style_from_ro_hash lascia selezionato lo stile nuovo: si
        # rimette quello che il viewport mostrava, così assign_styles parte
        # dallo stato di prima e alla fine sa cosa ripristinare.
        m.styles.selected_style = prev if prev && prev != st
        st
      end

      # Scrive le voci Match Photo del preset nello stile appena creato.
      # Stanno nel pannello Styles nativo, che mostra sempre lo stile
      # selezionato e ha effetto solo sulle scene Match Photo: serve una scena
      # MP fra quelle appena cambiate, attiva nel viewport. Se la scena attiva
      # non lo è si passa alla prima MP e poi si torna indietro (non in defer
      # mode, dove la scena nel viewport non si sposta).
      #
      # Nessuna scena MP fra le bersaglio = niente da fare: lo stile tiene le
      # voci del template finché non lo si assegna a una scena MP e le si
      # cambia dalla finestra dello stile.
      #
      # Ritorna nil se tutto ok (o niente da fare), altrimenti il messaggio
      # da mostrare all'utente.
      def apply_match_photo!(preset, style, pages)
        mp = preset[:match_photo]
        return nil unless mp && !mp.empty?
        m = Sketchup.active_model
        name = style.name.to_s
        mp_pages = pages.select do |p|
          SceneModel.matchphoto?(p) && ((p.style.name.to_s == name) rescue false)
        end
        return nil if mp_pages.empty?
        unless NativePanel.available?
          return "Style '#{name}' created, but its Match Photo settings could not " \
                 "be applied (Styles panel not reachable).\n#{MANUAL_HINT}"
        end

        prev   = m.pages.selected_page
        target = mp_pages.include?(prev) ? prev : nil
        moved  = false
        if target.nil?
          if Buffer.deferred?
            return "Style '#{name}' created, but its Match Photo settings need a " \
                   "Match Photo scene in the viewport (defer mode is on).\n#{MANUAL_HINT}"
          end
          target = mp_pages.first
          SceneModel.select_page(SceneModel.page_id(target))
          moved = true
        end
        begin
          # Riassegnare lo stile già selezionato non è un no-op (butta via le
          # modifiche pendenti), quindi solo se serve. Attivare la scena di
          # norma lo ha già selezionato.
          m.styles.selected_style = style unless m.styles.selected_style == style
          # Il pannello va aperto (se non lo è) e la scheda Edit rinfrescata:
          # i suoi controlli mostrano lo stile di prima finché non succede, e
          # match_photo_set_enabled leggerebbe un valore vecchio saltando la
          # scrittura.
          NativePanel.panel!(NativePanel::STYLES_PANEL)
          NativePanel.refresh_styles_panel!
          ok = true
          mp.each do |which, cfg|
            unless cfg[:on].nil?
              ok = false unless NativePanel.match_photo_set_enabled(which, cfg[:on])
            end
            unless cfg[:opacity].nil?
              ok = false unless NativePanel.match_photo_set_opacity(which, cfg[:opacity])
            end
          end
          # = il bottone Update del pannello nativo. Le scritture sopra
          # segnano lo stile come modificato; senza questo sparirebbero al
          # primo cambio di scena.
          Styles.update_selected_style_keeping_description(m) if m.styles.active_style_changed
          return nil if ok
          "Style '#{name}' created, but some Match Photo settings could not be " \
          "applied.\n#{MANUAL_HINT}"
        ensure
          SceneModel.select_page(SceneModel.page_id(prev)) if moved && prev
        end
      rescue => e
        warn "[SM+] style preset match photo: #{e.class}: #{e.message}"
        "Style '#{style.name}' created, but its Match Photo settings failed " \
        "(#{e.class}).\n#{MANUAL_HINT}"
      end
    end
  end
end
