require 'json'

module SceneManagerPlus
  module UI
    module Dialog
      module_function

      @dialog            = nil
      @poll_timer_id     = nil
      @last_active_uid   = nil

      # Polling 250ms: se selected_page cambia (e defer è OFF), aggiorna la
      # selezione nel plugin. Più affidabile del frame_change_observer che
      # in SU 2019 non scatta sempre sui click ai tab nativi.
      def start_active_scene_poll
        stop_active_scene_poll
        @last_active_uid = nil
        @poll_timer_id = ::UI.start_timer(0.25, true) do
          poll_active_scene
        end
        puts "[SM+] active scene poll started"
      end

      def stop_active_scene_poll
        if @poll_timer_id
          begin
            ::UI.stop_timer(@poll_timer_id)
          rescue
          end
          @poll_timer_id = nil
        end
      end

      def poll_active_scene
        return unless @dialog && @dialog.visible?
        return if Core::Buffer.deferred?
        m = Sketchup.active_model
        return unless m
        page = m.pages.selected_page
        return unless page
        uid = Core::SceneModel.page_id(page)
        return if uid == @last_active_uid
        @last_active_uid = uid
        @dialog.execute_script("window.SM && SM.setActiveFromNative(#{uid.to_json});")
      rescue => e
        warn "[SM+] poll_active_scene: #{e.class}: #{e.message}"
      end

      # Accessor usato da ExportDialog per pushare progress al main dialog.
      def dialog_handle
        @dialog
      end

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      # Scrive un index.html temporaneo accanto all'originale, con cache-buster
      # ?v=<ts> sui tag <script src=> e <link href=>. Ritorna il path.
      def prepare_index
        src = File.join(html_dir, 'index.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)               { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'index.cb.html')
          File.write(dst, html)
          puts "[SM+] cache-busted index ready: #{dst}"
          dst
        rescue => e
          warn "[SM+] prepare_index failed (#{e.class}: #{e.message}), falling back to original"
          src
        end
      end

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    PLUGIN_NAME,
          preferences_key: 'SceneManagerPlus.MainDialog',
          scrollable:      false,
          resizable:       true,
          width:           420,
          height:          640,
          min_width:       320,
          min_height:      400,
          # STYLE_UTILITY: palette sempre sopra la viewport SU, posizione e
          # dimensione persistite in modo affidabile via preferences_key tra
          # sessioni e tra file diversi (come i pannelli nativi). STYLE_DIALOG
          # in SU 2019 salvava la dimensione ma non sempre la posizione.
          style:           ::UI::HtmlDialog::STYLE_UTILITY
        )

        register_callbacks(@dialog)
        # Auto-flush eventuali edit pending + stop polling alla chiusura.
        # Salviamo anche "open=false" così il prossimo avvio di SU sa di non
        # riaprire automaticamente la finestra (l'utente l'ha chiusa di sua
        # volontà). Vedi auto_show_if_was_open per il ripristino.
        @dialog.set_on_closed do
          if Core::Buffer.deferred?
            edits, deletes = Core::Buffer.flush!
            puts "[SM+] auto-flush on close: #{edits} edit(s), #{deletes} delete(s)"
          end
          stop_active_scene_poll
          Sketchup.write_default('SceneManagerPlus', 'main_dialog_open', false)
        end
        # Cache-bust JS/CSS riscrivendo index.html in un file temporaneo con
        # ?v=<timestamp> sui tag <script src> e <link href>. CEF di SU 2019
        # può tenersi in cache i file file:// tra una sessione e l'altra.
        @dialog.set_file(prepare_index)
        @dialog.show
        Sketchup.write_default('SceneManagerPlus', 'main_dialog_open', true)
        start_active_scene_poll
        # Fallback: se sm_ready non arriva entro 1s, forziamo push_state.
        # Utile se il bridge JS->Ruby non si aggancia per qualche motivo.
        ::UI.start_timer(1.0, false) do
          begin
            puts "[SM+] fallback timer: forcing push_state"
            push_state
          rescue => e
            warn "[SM+] fallback push_state failed: #{e.message}"
          end
        end
        @dialog
      end

      # Bridge: la UI chiama window.sketchup.<callback>(JSON.stringify(args))
      # e attende risposta tramite sketchup.callback(reqId, result).
      def register_callbacks(dlg)
        dlg.add_action_callback('sm_ready') do |_ctx|
          puts "[SM+] sm_ready received from UI"
          push_state
        end

        dlg.add_action_callback('sm_refresh') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_reorder') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.reorder(data['ids'], data['before_id'], data['dest_folder_id'])
          push_state
        end

        dlg.add_action_callback('sm_select_page') do |_ctx, payload|
          # In defer mode non tocchiamo SU: niente viewport change.
          unless Core::Buffer.deferred?
            data = parse(payload)
            Core::SceneModel.select_page(data['id'])
          end
        end

        dlg.add_action_callback('sm_update_page') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.update_page(data['id'], data)
          push_state
        end

        dlg.add_action_callback('sm_update_from_view') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.update_from_view(data['id'])
          push_state
        end

        dlg.add_action_callback('sm_delete') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.delete_pages(data['ids'])
          push_state
        end

        dlg.add_action_callback('sm_log') do |_ctx, msg|
          puts "[SM+ UI] #{msg}"
        end

        dlg.add_action_callback('sm_open_settings') do |_ctx|
          SettingsDialog.show
        end

        dlg.add_action_callback('sm_open_export') do |_ctx, payload|
          data = parse(payload)
          ExportDialog.show(selected_ids: Array(data['selected']))
        end

        dlg.add_action_callback('sm_export_cancel_running') do |_ctx|
          Core::Exporter.request_cancel!
        end

        dlg.add_action_callback('sm_open_properties') do |_ctx, payload|
          data = parse(payload)
          PropertiesDialog.show_for(data['id']) if data['id']
        end

        dlg.add_action_callback('sm_generate_previews') do |_ctx, payload|
          data = parse(payload)
          ids  = Array(data['ids'])

          on_progress = lambda do |done, total, _uid|
            js = "window.SM && SM.setPreviewProgress(#{done.to_json}, #{total.to_json});"
            begin
              dlg.execute_script(js)
            rescue
            end
          end

          on_done = lambda do |count|
            puts "[SM+] previews generated: #{count}"
            begin
              dlg.execute_script("window.SM && SM.setPreviewProgress(null, null);")
            rescue
            end
            push_state
            PropertiesDialog.push_state if defined?(PropertiesDialog)
          end

          # segnala "starting"
          begin
            dlg.execute_script("window.SM && SM.setPreviewProgress(0, #{ids.empty? ? -1 : ids.size});")
          rescue
          end

          Core::Previews.generate(ids, on_progress: on_progress, on_done: on_done)
        end

        dlg.add_action_callback('sm_defer_toggle') do |_ctx|
          if Core::Buffer.deferred?
            edits, deletes = Core::Buffer.flush!
            puts "[SM+] flush: #{edits} edit(s), #{deletes} delete(s)"
          else
            Core::Buffer.enable!
            puts "[SM+] defer mode ON"
          end
          push_state
        end

        dlg.add_action_callback('sm_new_scene_from_view') do |_ctx|
          Core::SceneModel.add_from_view
          push_state
        end

        dlg.add_action_callback('sm_folder_create') do |_ctx, payload|
          data = parse(payload)
          Core::Folders.create(name: data['name'] || 'New folder')
          push_state
        end

        dlg.add_action_callback('sm_folder_update') do |_ctx, payload|
          data = parse(payload)
          Core::Folders.update(data['id'], data)
          push_state
        end

        dlg.add_action_callback('sm_folder_delete') do |_ctx, payload|
          data = parse(payload)
          Core::Folders.delete(data['id'])
          push_state
        end

        dlg.add_action_callback('sm_folder_toggle') do |_ctx, payload|
          data = parse(payload)
          f = Core::Folders.find(data['id'])
          if f
            Core::Folders.update(data['id'], 'expanded' => !f['expanded'])
            push_state
          end
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        model      = Sketchup.active_model
        scenes_raw = Core::SceneModel.list_ordered
        tree       = Core::SceneModel.tree
        state = {
          scenes:    scenes_raw,
          tree:      tree,
          folders:   Core::Folders.all,
          flag_keys: Core::SceneModel::FLAG_KEYS,
          deferred:  Core::Buffer.deferred?,
          pending:   Core::Buffer.pending_count,
          previews:  Core::Previews.url_map,
          model_info: {
            title:        (model ? model.title.to_s : ''),
            pages_count:  (model ? model.pages.count : 0)
          }
        }
        puts "[SM+] push_state: model=#{state[:model_info][:title].inspect} " \
             "native_pages=#{state[:model_info][:pages_count]} " \
             "scenes=#{scenes_raw.length} folders=#{state[:folders].length} tree_items=#{tree.length}"
        js = "window.SM && SM.setState(#{state.to_json});"
        @dialog.execute_script(js)
      rescue => e
        warn "[SM+] push_state ERROR: #{e.class}: #{e.message}"
        warn e.backtrace.first(5).join("\n")
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
