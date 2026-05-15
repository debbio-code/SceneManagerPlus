require 'json'

module SceneManagerPlus
  module UI
    module Dialog
      module_function

      @dialog = nil

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
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        # Cache-bust JS/CSS riscrivendo index.html in un file temporaneo con
        # ?v=<timestamp> sui tag <script src> e <link href>. CEF di SU 2019
        # può tenersi in cache i file file:// tra una sessione e l'altra.
        @dialog.set_file(prepare_index)
        @dialog.show
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
          data = parse(payload)
          Core::SceneModel.select_page(data['id'])
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
