require 'json'

module SceneManagerPlus
  module UI
    # Mini Style Manager: edit rapido dei rendering options chiave per uno
    # stile. Aperto cliccando con il sinistro sulla lettera badge di una scena.
    #
    # Scope: gli edit modificano lo stile (styles.update_selected_style), quindi
    # tutte le scene che usano quello stile sono interessate. Per modificare
    # solo una scena, l'utente deve prima duplicare lo stile via Window → Styles
    # di SketchUp. Limite dell'API Ruby SU 2019: non c'è add_style/clone da
    # memoria né style.name= per rinominare programmaticamente un duplicato.
    #
    # Settings esposti (chiavi rendering_options con lookup difensivo):
    #   FaceColorMode (0=All same, 1=By material, 2=By axis)
    #   TransparencySort (0=Faster, 1=Medium, 2=Nicer)
    #   BackgroundColor (color)
    #   DrawHorizon (bool — "Sky on/off") + SkyColor
    #   DrawHidden (bool — Hidden Geometry)
    #   DisplaySectionPlanes (bool)
    #   DisplaySectionCuts (bool)
    # Model Axes: model.options['DrawingOptions']['ShowAxes'] se disponibile.
    module StyleDialog
      module_function

      @dialog        = nil
      @scene_id      = nil  # contesto: scena da cui è stato aperto (per attivarla)
      @style_name    = nil  # stile target di edit

      RO_KEYS = %w[
        EdgeColorMode TransparencySort BackgroundColor DrawHorizon SkyColor
        ModelTransparency DrawHidden DisplaySectionPlanes DisplaySectionCuts
      ].freeze

      # Model Axes display: SU 2019 NON espone state né setter via Ruby API
      # (no rendering option, no Sketchup::View accessor). L'unico modo è
      # Sketchup.send_action con il command ID nativo Windows del menu
      # View → Axes. Identificato 10522 enumerando il menu di SU via Win32
      # GetMenu/GetMenuString (script tools/dump-su-menu.ps1).
      # Override possibile via:
      #   Sketchup.write_default('SceneManagerPlus', 'axes_cmd_id', N)
      # Su Mac: selettore string 'showHideAxes:' (non testato sulla nostra
      # postazione Windows ma documentato Trimble).
      WIN_AXES_CMD_ID = 10522

      def axes_cmd_id
        Sketchup.read_default('SceneManagerPlus', 'axes_cmd_id', WIN_AXES_CMD_ID).to_i
      end

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
        @style_name = style_name
        # Attiva la scena di contesto così il viewport mostra lo stile in edit
        # e l'utente vede live le modifiche. Skip se defer mode (per coerenza
        # con il resto: in defer non tocchiamo la pagina nel viewport).
        unless Core::Buffer.deferred?
          m = Sketchup.active_model
          if m && scene_id
            p = Core::SceneModel.find_by_id(scene_id)
            m.pages.selected_page = p if p
          end
        end
        # Assicura che lo stile target sia attivo, così update_selected_style
        # committerà le modifiche al posto giusto.
        select_style!(style_name)

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

        dlg.add_action_callback('sm_style_toggle_axes') do |_ctx|
          toggle_axes!
        end

        # Rinomina (nickname) lo stile correntemente in edit. Vuoto = clear.
        # Il nickname vive solo come attributo di modello (vedi Core::Styles).
        # Se conflict (display_name già usato da altro stile), set_nickname
        # ritorna false → messagebox di avviso e push_state rimette il valore
        # precedente nell'input (il JS rispetta setIfNotFocused).
        dlg.add_action_callback('sm_style_set_nickname') do |_ctx, payload|
          data = parse(payload)
          nick = data['nickname'].to_s
          ok = Core::Styles.set_nickname(@style_name, nick)
          unless ok
            ::UI.messagebox(
              "Nickname '#{nick.strip}' is already used by another style.\n" \
              "Please choose a different name."
            )
          end
          push_state
          # Refresh main dialog: lettere + tooltip + picker label dipendono dal
          # display_name calcolato sul nickname.
          Dialog.push_state if defined?(Dialog)
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

        dlg.add_action_callback('sm_style_log') do |_ctx, msg|
          puts "[SM+ Style UI] #{msg}"
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        m = Sketchup.active_model
        return unless m
        using = scenes_using_style(@style_name)
        state = {
          style_name:   @style_name,
          nickname:     Core::Styles.get_nickname(@style_name),
          badge_color:  Core::Styles.get_color(@style_name),
          scene_id:     @scene_id,
          scenes_count: using.size,
          scenes_list:  using.map { |p| p.name },
          values:       current_values
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
        m.styles.selected_style = target if target
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
          vals[k] = serialize_value(v)
        end
        vals
      end

      def read_ro(ro, key)
        ro[key]
      rescue
        nil
      end

      def serialize_value(v)
        if v.is_a?(Sketchup::Color)
          format('#%02x%02x%02x', v.red, v.green, v.blue)
        elsif v == true || v == false
          v
        elsif v.is_a?(Integer)
          v
        elsif v.nil?
          nil
        else
          v.to_s
        end
      end

      def toggle_axes!
        if RUBY_PLATFORM =~ /darwin/
          Sketchup.send_action('showHideAxes:')
        else
          Sketchup.send_action(axes_cmd_id)
        end
        true
      rescue => e
        warn "[SM+] toggle_axes!: #{e.class}: #{e.message}"
        false
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
      COLOR_KEYS = %w[BackgroundColor SkyColor].freeze
      BOOL_KEYS  = %w[DrawHorizon ModelTransparency DrawHidden DisplaySectionPlanes DisplaySectionCuts].freeze
      INT_KEYS   = %w[EdgeColorMode TransparencySort].freeze

      def coerce_for_ro(key, v)
        if COLOR_KEYS.include?(key)
          hex_to_color(v)
        elsif BOOL_KEYS.include?(key)
          !!v
        elsif INT_KEYS.include?(key)
          v.to_i
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
