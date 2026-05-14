require 'json'

module SceneManagerPlus
  module UI
    module Dialog
      module_function

      @dialog = nil

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
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
        @dialog.set_file(File.join(html_dir, 'index.html'))
        @dialog.show
        @dialog
      end

      # Bridge: la UI chiama window.sketchup.<callback>(JSON.stringify(args))
      # e attende risposta tramite sketchup.callback(reqId, result).
      def register_callbacks(dlg)
        dlg.add_action_callback('sm_ready') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_refresh') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_reorder') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.reorder(data['ids'], data['target_id'])
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
      end

      def push_state
        return unless @dialog && @dialog.visible?
        state = {
          scenes:  Core::SceneModel.list_ordered,
          folders: Core::Folders.all,
          flag_keys: Core::SceneModel::FLAG_KEYS
        }
        js = "window.SM && SM.setState(#{state.to_json});"
        @dialog.execute_script(js)
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
