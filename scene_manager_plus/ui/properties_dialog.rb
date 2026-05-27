require 'json'

module SceneManagerPlus
  module UI
    # Dialog dedicato alle proprietà di una singola scena.
    # Apri con `PropertiesDialog.show_for(scene_id)`. Riusa la stessa finestra
    # se è già aperta, cambia solo il contesto.
    module PropertiesDialog
      module_function

      @dialog   = nil
      @scene_id = nil

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'properties.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)               { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'properties.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] properties prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      def show_for(scene_id)
        @scene_id = scene_id
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          push_state
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Scene properties",
          preferences_key: 'SceneManagerPlus.PropertiesDialog',
          scrollable:      true,
          resizable:       true,
          width:           420,
          height:          520,
          min_width:       340,
          min_height:      380,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_props_ready') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_props_apply') do |_ctx, payload|
          data = parse(payload)
          id   = data['id'] || @scene_id
          if id
            Core::SceneModel.update_page(id, data)
            Dialog.push_state
            # Non re-pushiamo al props dialog: ha già i valori giusti.
          end
        end

        dlg.add_action_callback('sm_props_update_from_view') do |_ctx, payload|
          data = parse(payload)
          id   = data['id'] || @scene_id
          if id
            only = data['flags'].is_a?(Array) && !data['flags'].empty? ? data['flags'] : nil
            Core::SceneModel.update_from_view(id, only_keys: only)
            Dialog.push_state
            push_state
          end
        end

        dlg.add_action_callback('sm_props_log') do |_ctx, msg|
          puts "[SM+ Props UI] #{msg}"
        end

        # Click su "Style and Fog" per scena Match Photo: scrivere quei flag
        # via setter Ruby corrompe lo state MP interno (BugSplat al successivo
        # selected_page = page). L'inspector Scenes nativo invece li scrive
        # in modo safe. Quindi: attiviamo la scena (così l'inspector mostra
        # i suoi checkbox) e apriamo l'inspector via UI.show_inspector.
        dlg.add_action_callback('sm_props_open_scenes_panel') do |_ctx, payload|
          data = parse(payload)
          id = data['id'] || @scene_id
          if id
            p = Core::SceneModel.find_by_id(id)
            if p && Sketchup.active_model.pages.selected_page != p
              Sketchup.active_model.pages.selected_page = p
            end
          end
          ::UI.show_inspector('Scenes')
        end

        # Attiva la scena nel viewport (utile per la fog: legge/scrive dalle
        # rendering_options del modello, che riflettono la scena attiva).
        dlg.add_action_callback('sm_props_activate_scene') do |_ctx, payload|
          data = parse(payload)
          id = data['id'] || @scene_id
          if id
            p = Core::SceneModel.find_by_id(id)
            m = Sketchup.active_model
            if p && m && m.pages.selected_page != p
              m.pages.selected_page = p
            end
          end
          push_state
        end

        # Applica i settings fog alla scena. Pattern (replica del nativo
        # Window → Fog di SU):
        #  1. Modifica model.rendering_options[DisplayFog/FogStartDist/FogEndDist]
        #  2. Se la scena è quella attiva, page.update(PAGE_USE_RENDERING_OPTIONS)
        #     per snapshottare le RO correnti nella scena → al successivo cambio
        #     scena e ritorno, la fog viene ripristinata.
        # NON chiama update_selected_style: lo stile diventa "dirty" come fa il
        # native Fog dialog, ma le altre scene mantengono il loro fog.
        dlg.add_action_callback('sm_props_fog_apply') do |_ctx, payload|
          data = parse(payload)
          id   = data['id'] || @scene_id
          fog_apply(id, data) if id
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        scene = scene_payload(@scene_id)
        preview = @scene_id ? Core::Previews.url_map[@scene_id] : nil
        state = {
          scene:       scene,
          flag_keys:   Core::SceneModel::FLAG_KEYS,
          preview_url: preview
        }
        @dialog.execute_script("window.SMP && SMP.setState(#{state.to_json});")
      rescue => e
        warn "[SM+] properties push_state ERROR: #{e.class}: #{e.message}"
      end

      def scene_payload(id)
        return nil unless id
        p = Core::SceneModel.find_by_id(id)
        return nil unless p
        # Usa scene_hash che applica già l'overlay del Buffer in deferred mode
        h = Core::SceneModel.scene_hash(p, id)
        {
          'id'           => h[:id],
          'name'         => h[:name],
          'description'  => h[:description],
          'flags'        => h[:flags],
          'pending'      => !!h[:pending],
          'is_matchphoto'=> Core::SceneModel.matchphoto?(p),
          'is_active'    => active_page_id == id,
          'fog'          => read_fog
        }
      end

      def active_page_id
        m = Sketchup.active_model
        return nil unless m
        p = m.pages.selected_page
        return nil unless p
        Core::SceneModel.page_id(p)
      rescue
        nil
      end

      # Fattore moltiplicativo inches-per-user-unit. SU memorizza tutte le
      # lunghezze internamente in inches; l'utente le vede convertite secondo
      # Model Info → Units. Length unit: 0=in, 1=ft, 2=mm, 3=cm, 4=m.
      INCHES_PER_UNIT = {
        0 => 1.0,
        1 => 12.0,
        2 => 1.0 / 25.4,
        3 => 10.0 / 25.4,
        4 => 1000.0 / 25.4
      }.freeze

      def inches_per_user_unit
        m = Sketchup.active_model
        return 1.0 unless m
        u = (m.options['UnitsOptions']['LengthUnit'].to_i rescue 0)
        INCHES_PER_UNIT[u] || 1.0
      end

      def user_unit_label
        m = Sketchup.active_model
        return 'in' unless m
        u = (m.options['UnitsOptions']['LengthUnit'].to_i rescue 0)
        ['in', 'ft', 'mm', 'cm', 'm'][u] || 'in'
      end

      # Scala massima dello slider (in unità modello). Logica: bbox model
      # diagonal × 2, con minimo ragionevole. Asse slider 0..max → la posizione
      # del thumb riflette la distanza fisica dalla camera.
      def fog_max_user_units
        m = Sketchup.active_model
        return 100.0 unless m
        bb = m.bounds
        diag_in = (bb.diagonal rescue 0.0).to_f
        return 100.0 if diag_in <= 0.0
        diag_user = diag_in / inches_per_user_unit
        # Minimo 1 (es. modello micro), massimo arbitrario per non rendere
        # lo slider inutile con scene enormi.
        v = diag_user * 2.0
        v = 1.0 if v < 1.0
        v.round(2)
      end

      # Legge i settings fog dalle rendering_options del MODELLO. Questo è il
      # state visualizzato dal viewport (= scena attiva se la scena ha
      # use_rendering_options).
      #
      # FogStartDist/EndDist sono float in inches (SU interna). Convertiamo
      # in unità modello per la UI.
      def read_fog
        m = Sketchup.active_model
        return nil unless m
        ro = m.rendering_options
        ipu = inches_per_user_unit
        s_in = (ro['FogStartDist'] rescue 0.0).to_f
        e_in = (ro['FogEndDist']   rescue 0.0).to_f
        {
          'display'   => (ro['DisplayFog'] rescue false) ? true : false,
          'start'     => (s_in / ipu).round(3),
          'end'       => (e_in / ipu).round(3),
          'max'       => fog_max_user_units,
          'unit_lbl'  => user_unit_label
        }
      rescue
        nil
      end

      def fog_apply(id, data)
        m = Sketchup.active_model
        return unless m
        p = Core::SceneModel.find_by_id(id)
        return unless p

        ro = m.rendering_options
        ipu = inches_per_user_unit

        m.start_operation('SM+ Fog', true)
        begin
          ro['DisplayFog']   = !!data['display']   if data.key?('display')
          ro['FogStartDist'] = data['start'].to_f * ipu if data.key?('start')
          ro['FogEndDist']   = data['end'].to_f   * ipu if data.key?('end')

          # Se la scena è quella attiva nel viewport, snapshottiamo le RO
          # correnti nella scena. Altrimenti il modello cambia ma la scena
          # non lo cattura (al cambio scena perde la modifica).
          if m.pages.selected_page == p
            ro_bit = ro_use_bit_safe
            p.update(ro_bit) if ro_bit && ro_bit != 0
          end
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] fog_apply failed: #{e.class}: #{e.message}"
        end
        push_state
      end

      # Lookup difensivo per PAGE_USE_RENDERING_OPTIONS: la costante può
      # vivere in Sketchup:: o Sketchup::Page::. SU 2019 la espone in entrambi
      # i namespace storicamente, ma proteggiamoci.
      def ro_use_bit_safe
        if defined?(Sketchup::PAGE_USE_RENDERING_OPTIONS)
          Sketchup::PAGE_USE_RENDERING_OPTIONS
        elsif defined?(Sketchup::Page::PAGE_USE_RENDERING_OPTIONS)
          Sketchup::Page::PAGE_USE_RENDERING_OPTIONS
        else
          2 # fallback: documentato come 2 in tutte le versioni SU note
        end
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
