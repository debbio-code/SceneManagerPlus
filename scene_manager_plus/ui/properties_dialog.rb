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
          'is_matchphoto'=> Core::SceneModel.matchphoto?(p)
        }
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
