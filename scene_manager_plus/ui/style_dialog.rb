require 'json'

module SceneManagerPlus
  module UI
    # Mini Style Manager: edit rapido dei rendering options chiave per uno
    # stile. Aperto cliccando con il sinistro sulla lettera badge di una scena.
    #
    # Scope: gli edit modificano lo stile (styles.update_selected_style), quindi
    # tutte le scene che usano quello stile sono interessate. Per modificare
    # solo una scena, l'utente crea un nuovo stile ("+ New style…" nel picker
    # del badge lettera) e glielo assegna.
    #
    # Nome e descrizione sono editabili: `Sketchup::Style#name=` e
    # `#description=` funzionano in SU 2019 e persistono nel .skp (verificato
    # 2026-08-01). Il rename passa da Core::Styles.rename_style, che sposta con
    # sé i metadata chiavati per nome e rifiuta i duplicati.
    #
    # Settings esposti (chiavi rendering_options con lookup difensivo):
    #   FaceColorMode (0=All same, 1=By material, 2=By axis)
    #   TransparencySort (0=Faster, 1=Medium, 2=Nicer)
    #   BackgroundColor (color)
    #   DrawHorizon (bool — "Sky on/off") + SkyColor
    #   DrawHidden (bool — Hidden Geometry)
    #   DisplaySectionPlanes (bool)
    #   DisplaySectionCuts (bool)
    #   DisplaySketchAxes (bool — Model Axes display)
    #
    # Model Axes: contrariamente a quanto si credeva, il display degli assi del
    # modello SI si espone via rendering option 'DisplaySketchAxes' (bool).
    # Verificato via MCP eval_ruby su SU 2019.0.685: ro['DisplaySketchAxes']=false
    # nasconde gli assi, ed è catturato per-scena via PAGE_USE_RENDERING_OPTIONS.
    # Quindi è un checkbox stateful come gli altri Display — niente più hack
    # Sketchup.send_action(10522). Vedi docs/SU2019-LESSONS.md.
    module StyleDialog
      module_function

      @dialog        = nil
      @scene_id      = nil  # contesto: scena da cui è stato aperto (per attivarla)
      @style_name    = nil  # stile target di edit

      RO_KEYS = %w[
        EdgeColorMode TransparencySort
        BackgroundColor DrawHorizon SkyColor
        HorizonColor
        ModelTransparency DrawHidden DisplaySectionPlanes DisplaySectionCuts
        DrawSilhouettes ProfileWidth DisplaySketchAxes
      ].freeze

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'style.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)               { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'style.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] style prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      def show_for(scene_id, style_name)
        @scene_id   = scene_id
        # Attiva la scena di contesto così il viewport mostra lo stile in edit
        # e l'utente vede live le modifiche. Skip se defer mode (per coerenza
        # con il resto: in defer non tocchiamo la pagina nel viewport).
        page = nil
        unless Core::Buffer.deferred?
          m = Sketchup.active_model
          if m && scene_id
            page = Core::SceneModel.find_by_id(scene_id)
            # Skip se è già la pagina attiva: riassegnare la stessa MP scene
            # (con use_style=true) può scatenare un restore-cycle interno
            # del subsystem Match Photo → BugSplat.
            if page && m.pages.selected_page != page
              m.pages.selected_page = page
            end
          end
        end
        # Su scene Match Photo style_name arriva vuoto (lo stile MP interno
        # non è enumerato in model.styles). Risolviamo da page.style dopo
        # l'attivazione: SU rende selected_style = stile MP automaticamente
        # all'attivazione, quindi update_selected_style colpirà lo stile
        # giusto anche senza select_style! esplicito.
        if (style_name.nil? || style_name.to_s.empty?) && page && page.respond_to?(:style)
          style_name = (page.style.name.to_s rescue '')
        end
        @style_name = style_name
        # Assicura che lo stile target sia attivo, così update_selected_style
        # committerà le modifiche al posto giusto. No-op se non trovato in
        # model.styles (caso MP): l'attivazione della pagina sopra ha già
        # messo lo selected_style giusto.
        select_style!(style_name) if style_name && !style_name.empty?

        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          push_state
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Style",
          preferences_key: 'SceneManagerPlus.StyleDialog',
          scrollable:      true,
          resizable:       true,
          width:           360,
          height:          480,
          min_width:       300,
          min_height:      360,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_on_closed { @dialog = nil }
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_style_ready') do |_ctx|
          push_state
        end

        # Cambia uno o più rendering option e committa lo stile.
        # payload: { changes: { Key1: val1, Key2: val2, ... }, style_name: '...' }
        dlg.add_action_callback('sm_style_apply') do |_ctx, payload|
          data = parse(payload)
          changes = data['changes'] || {}
          apply_changes(changes)
          push_state
          # Aggiorna anche il main dialog (in caso la modifica abbia effetto
          # sui badge — es. style name non cambia ma in futuro magari).
          Dialog.push_state if defined?(Dialog)
        end

        # Apre il pannello Styles nativo (Window → Styles). API Trimble
        # cross-platform, niente command ID Windows da indovinare. Stesso
        # entry-point usato nel main dialog per il click destro sul badge
        # stile delle scene Match Photo.
        dlg.add_action_callback('sm_style_open_native') do |_ctx|
          begin
            ::UI.show_inspector('Styles')
          rescue => e
            warn "[SM+] open native Styles: #{e.class}: #{e.message}"
          end
        end

        # "Profiles → 1": accende DrawSilhouettes e setta ProfileWidth = 1
        # in un'unica operazione atomica, poi committa lo stile.
        dlg.add_action_callback('sm_style_set_profiles_default') do |_ctx|
          apply_changes('DrawSilhouettes' => true, 'ProfileWidth' => 1)
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Rinomina lo stile correntemente in edit (nome NATIVO: si vede anche
        # in Window → Styles di SketchUp).
        #
        # Su un file legacy non ancora migrato l'input mostra il nickname:
        # committarlo rinomina lo stile nativo e butta via il nickname, cioè
        # migra quel singolo stile senza che l'utente debba saperlo.
        #
        # Nome vuoto o già usato da un altro stile → rifiutato con messagebox
        # (SU accetterebbe il duplicato in sessione, salvo poi rinominarlo di
        # nascosto al salvataggio — vedi Core::Styles). push_state rimette il
        # valore precedente nell'input (il JS rispetta setIfNotFocused).
        dlg.add_action_callback('sm_style_set_name') do |_ctx, payload|
          data = parse(payload)
          want = data['name'].to_s.strip
          if want.empty?
            ::UI.messagebox('The style name cannot be empty.')
          elsif Core::Styles.rename_style(@style_name, want)
            # Il target di ogni callback successivo è cambiato: senza questo,
            # select_style!/apply_changes cercherebbero un nome che non esiste più.
            @style_name = want
          else
            ::UI.messagebox(
              "A style named '#{want}' already exists.\n" \
              "Please choose a different name."
            )
          end
          push_state
          # Refresh main dialog: lettere + tooltip + picker label dipendono dal
          # nome dello stile.
          Dialog.push_state if defined?(Dialog)
        end

        # Descrizione dello stile (campo nativo SU, visibile anche nel
        # pannello Styles). Commit su blur/Enter, come il nome.
        dlg.add_action_callback('sm_style_set_description') do |_ctx, payload|
          data = parse(payload)
          Core::Styles.set_description(@style_name, data['description'].to_s)
          push_state
        end

        # Set/clear del colore del badge associato allo stile. Stringa vuota
        # o null = nessun colore (badge usa lo style default CSS).
        dlg.add_action_callback('sm_style_set_color') do |_ctx, payload|
          data = parse(payload)
          hex  = data['color'].to_s
          ok = Core::Styles.set_color(@style_name, hex)
          unless ok
            ::UI.messagebox("Invalid color value: #{hex.inspect}\nExpected #rrggbb hex string.")
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Mostra la lista delle scene che usano lo stile corrente in un messagebox.
        # Usato dal footer della finestra stile (overlay CSS problematico in CEF SU 2019).
        dlg.add_action_callback('sm_style_show_scenes') do |_ctx|
          using = scenes_using_style(@style_name)
          display = Core::Styles.display_name(@style_name) rescue @style_name
          if using.empty?
            ::UI.messagebox("No scenes use style '#{display}'.")
          else
            names = using.map.with_index(1) { |p, i| "  #{i}. #{p.name}" }.join("\n")
            ::UI.messagebox("Scenes using style '#{display}' (#{using.size}):\n\n#{names}")
          end
        end

        # === Match Photo (via pannello nativo Win32) ===
        # Foreground/Background Photo non esistono nell'API Ruby di SU 2019
        # (61 rendering options enumerate anche con la scena MP attiva: zero
        # chiavi a tema). Si pilotano i controlli veri del pannello Styles.
        # Vedi Core::NativePanel per misure e trappole.
        #
        # Dopo ogni scrittura si ri-pusha lo stato LETTO dal pannello: se la
        # scrittura non ha fatto presa, la UI torna da sola al valore reale
        # invece di mostrare una bugia.
        dlg.add_action_callback('sm_style_mp_enable') do |_ctx, payload|
          data = parse(payload)
          select_style!(@style_name) if @style_name && !@style_name.empty?
          Core::NativePanel.match_photo_set_enabled(data['which'], data['on'])
          push_state
        end

        dlg.add_action_callback('sm_style_mp_opacity') do |_ctx, payload|
          data = parse(payload)
          select_style!(@style_name) if @style_name && !@style_name.empty?
          Core::NativePanel.match_photo_set_opacity(data['which'], data['value'].to_i)
          push_state
        end

        dlg.add_action_callback('sm_style_log') do |_ctx, msg|
          puts "[SM+ Style UI] #{msg}"
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        m = Sketchup.active_model
        return unless m
        using = scenes_using_style(@style_name)
        # I controlli Match Photo esistono nel pannello nativo per qualunque
        # stile, ma hanno effetto solo sulle scene Match Photo: fuori da
        # quelle la sezione si nasconde invece di offrire comandi inerti.
        # Contesto = la scena da cui il dialog e' stato aperto; se manca
        # (aperto senza scena) si guarda quella attiva nel viewport.
        ctx  = (@scene_id ? Core::SceneModel.find_by_id(@scene_id) : nil) || m.pages.selected_page
        is_mp = ctx ? Core::SceneModel.matchphoto?(ctx) : false
        state = {
          style_name:   @style_name,
          # Valore mostrato nell'input "Name": sui file già migrati coincide
          # con style_name; sui legacy è ancora il nickname, e committarlo
          # rinomina lo stile nativo (vedi sm_style_set_name).
          display_name: Core::Styles.display_name(@style_name),
          nickname:     Core::Styles.get_nickname(@style_name),
          description:  Core::Styles.get_description(@style_name),
          badge_color:  Core::Styles.get_color(@style_name),
          scene_id:     @scene_id,
          scenes_count: using.size,
          scenes_list:  using.map { |p| p.name },
          values:       current_values,
          is_matchphoto: is_mp,
          # Letto solo se serve: match_photo_state cammina l'albero delle
          # finestre del pannello nativo, inutile farlo per scene normali.
          # nil con is_matchphoto=true = pannello non raggiungibile -> la
          # sezione si mostra disabilitata invece di fingere di funzionare.
          match_photo:  (is_mp ? (Core::NativePanel.match_photo_state rescue nil) : nil)
        }
        @dialog.execute_script("window.SMS && SMS.setState(#{state.to_json});")
      rescue => e
        warn "[SM+] style push_state ERROR: #{e.class}: #{e.message}"
        warn e.backtrace.first(3).join("\n")
      end

      # === Helpers ===

      def select_style!(name)
        m = Sketchup.active_model
        return unless m && m.respond_to?(:styles) && name
        target = m.styles.find { |s| s.name.to_s == name.to_s }
        return unless target
        # Riassegnare lo stile GIA' selezionato non e' un no-op per SU:
        # riapplica lo stile salvato e butta via le modifiche pendenti. Con
        # i controlli Match Photo (che non passano da update_selected_style)
        # significherebbe azzerare la scrittura precedente a ogni tick del
        # drag dello slider.
        return if m.styles.selected_style == target
        m.styles.selected_style = target
      rescue => e
        warn "[SM+] select_style!: #{e.class}: #{e.message}"
      end

      def scenes_using_style(style_name)
        m = Sketchup.active_model
        return [] unless m && style_name
        m.pages.select do |p|
          (p.style.name.to_s == style_name.to_s) rescue false
        end
      end

      # Legge i valori correnti dai rendering_options + model.options.
      # Restituisce hash JSON-friendly (colori come hex string).
      def current_values
        m = Sketchup.active_model
        return {} unless m
        ro = m.rendering_options
        vals = {}
        RO_KEYS.each do |k|
          v = read_ro(ro, k)
          vals[k] = serialize_value(v, k)
        end
        vals
      end

      def read_ro(ro, key)
        # ProfileWidth: alias non-ufficiale in SU 2019. La chiave RenderingOption
        # canonica per la larghezza dei profili è SilhouetteWidth (DrawSilhouettes
        # ON). Leggiamo SilhouetteWidth con fallback, così la UI mostra il valore
        # reale anche se prima era stato scritto solo ProfileWidth.
        if key == 'ProfileWidth'
          v = (ro['SilhouetteWidth'] rescue nil)
          return v unless v.nil?
        end
        ro[key]
      rescue
        nil
      end

      def serialize_value(v, key = nil)
        if v.is_a?(Sketchup::Color)
          # HorizonColor: il template degli slot ha #000000 a=0 (sentinel
          # "non impostato"). Mostrarlo come #ffffff (default effettivo SU),
          # coerente con Core::Styles.normalize_horizon! e con la scrittura
          # che è sempre opaca. Così il valore iniziale combacia con
          # l'orizzonte bianco invece di mostrare un nero fuorviante.
          if key == 'HorizonColor' &&
             (v.alpha == 0 || (v.red == 0 && v.green == 0 && v.blue == 0))
            return '#ffffff'
          end
          format('#%02x%02x%02x', v.red, v.green, v.blue)
        elsif v == true || v == false
          v
        elsif v.is_a?(Integer)
          v
        elsif v.is_a?(Float)
          if FLOAT01_KEYS.include?(key)
            # 0..1 → 0..100 con due decimali per la UI
            (v * 100.0).round(2)
          else
            v
          end
        elsif v.nil?
          nil
        else
          v.to_s
        end
      end

      # Applica le modifiche a rendering_options + committa lo stile.
      # changes: { 'FaceColorMode' => 1, 'BackgroundColor' => '#aabbcc', ... }
      def apply_changes(changes)
        m = Sketchup.active_model
        return false unless m
        # Assicura che lo stile target sia ancora quello selezionato
        select_style!(@style_name)
        ro = m.rendering_options

        m.start_operation('SM+ Edit style', true)
        begin
          changes.each do |k, v|
            next unless RO_KEYS.include?(k)
            coerced = coerce_for_ro(k, v)
            next if coerced.nil? && !v.nil?
            begin
              ro[k] = coerced
              # ProfileWidth è alias non-ufficiale: la chiave canonica in
              # SU 2019 è SilhouetteWidth. Scrivendo solo ProfileWidth il
              # viewport non riflette il cambio. Scriviamo entrambe — quella
              # ignorata fa no-op silenzioso.
              if k == 'ProfileWidth'
                begin
                  ro['SilhouetteWidth'] = coerced
                rescue => e2
                  warn "[SM+] apply_changes: cannot set SilhouetteWidth=#{coerced.inspect}: #{e2.class}: #{e2.message}"
                end
              end
            rescue => e
              warn "[SM+] apply_changes: cannot set #{k}=#{coerced.inspect}: #{e.class}: #{e.message}"
            end
          end
          # Committa le modifiche IN-MEMORY al persistente: senza questo, le
          # modifiche valgono per la sessione corrente ma quando una scena viene
          # ri-attivata SU riapplica lo style "salvato" e le perde.
          if m.styles.respond_to?(:update_selected_style)
            m.styles.update_selected_style
          end
          m.commit_operation
          true
        rescue => e
          m.abort_operation
          warn "[SM+] apply_changes failed: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          false
        end
      end

      # Coerce JS values verso il tipo atteso da RenderingOptions per ogni chiave.
      # Boolean → bool, Color → Sketchup::Color da hex, Integer → int.
      COLOR_KEYS = %w[BackgroundColor SkyColor HorizonColor].freeze
      BOOL_KEYS  = %w[DrawHorizon ModelTransparency DrawHidden DisplaySectionPlanes DisplaySectionCuts DrawSilhouettes DisplaySketchAxes].freeze
      INT_KEYS   = %w[EdgeColorMode TransparencySort ProfileWidth].freeze
      FLOAT01_KEYS = %w[].freeze  # Fog spostata in PropertiesDialog (è per-scena, non per-stile)

      def coerce_for_ro(key, v)
        if COLOR_KEYS.include?(key)
          hex_to_color(v)
        elsif BOOL_KEYS.include?(key)
          !!v
        elsif INT_KEYS.include?(key)
          v.to_i
        elsif FLOAT01_KEYS.include?(key)
          f = v.to_f / 100.0
          f = 0.0 if f < 0.0
          f = 1.0 if f > 1.0
          f
        else
          v
        end
      end

      def hex_to_color(hex)
        s = hex.to_s.strip
        s = s.sub(/^#/, '')
        return nil unless s =~ /^[0-9a-fA-F]{6}$/
        r = s[0,2].to_i(16); g = s[2,2].to_i(16); b = s[4,2].to_i(16)
        Sketchup::Color.new(r, g, b)
      rescue
        nil
      end

      def parse(payload)
        return {} if payload.nil? || payload.to_s.empty?
        JSON.parse(payload)
      rescue
        {}
      end
    end
  end
end
