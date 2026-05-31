require 'json'

module SceneManagerPlus
  module UI
    # Finestra "Scene Clipboard": ospita Copia / Incolla scene cross-file.
    # Aperta dal bottone (ex-refresh) della toolbar principale. Tenuta come
    # finestra a parte per non affollare la toolbar (richiesta utente).
    #
    # Copy agisce sulla SELEZIONE corrente della main window (passata in
    # show(selected_ids:), come fa ExportDialog). Paste incolla dal
    # clipboard.json nel modello corrente.
    module ClipboardDialog
      module_function

      @dialog       = nil
      @selected_ids = []

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'clipboard.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)                  { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'clipboard.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] clipboard prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      def show(selected_ids: [])
        @selected_ids = Array(selected_ids)
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          push_state
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Scene Clipboard",
          preferences_key: 'SceneManagerPlus.ClipboardDialog',
          scrollable:      true,
          resizable:       true,
          width:           380,
          height:          360,
          min_width:       320,
          min_height:      280,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_clip_ready') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_clip_refresh') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_clip_copy') do |_ctx|
          do_copy
        end

        dlg.add_action_callback('sm_clip_paste') do |_ctx|
          do_paste
        end

        dlg.add_action_callback('sm_clip_log') do |_ctx, msg|
          puts "[SM+ Clipboard UI] #{msg}"
        end
      end

      def do_copy
        report = Core::Clipboard.copy(@selected_ids)
        if report.nil?
          ::UI.messagebox("Nothing to copy.")
          push_state
          return
        end
        if report[:copied] == 0
          if report[:skipped_mp].any?
            ::UI.messagebox(
              "No scenes copied.\n\n" \
              "All selected scenes are Match Photo and cannot be copied " \
              "(SketchUp 2019 API limitation)."
            )
          else
            ::UI.messagebox("Select one or more scenes in the main window first.")
          end
          push_state
          return
        end
        msg = "Copied #{report[:copied]} scene#{report[:copied] == 1 ? '' : 's'} " \
              "(#{report[:styles]} style#{report[:styles] == 1 ? '' : 's'})."
        if report[:skipped_mp].any?
          msg += "\n\nSkipped #{report[:skipped_mp].size} Match Photo scene(s):\n" \
                 "#{report[:skipped_mp].first(6).join(', ')}"
        end
        ::UI.messagebox(msg)
        push_state
      end

      def do_paste
        report = Core::Clipboard.paste
        push_state
        return if report.nil?
        msg = "Pasted #{report[:pasted]} scene#{report[:pasted] == 1 ? '' : 's'} " \
              "(#{report[:styles]} style#{report[:styles] == 1 ? '' : 's'} allocated)"
        msg += " from #{report[:source]}" unless report[:source].to_s.empty?
        msg += "."
        msg += "\n\nNote: you pasted into the same file you copied from." if report[:same_model]
        ::UI.messagebox(msg)
        # Refresh main window: nuove scene + eventuali nuovi stili/colori.
        Dialog.push_state rescue nil
      end

      def push_state
        return unless @dialog && @dialog.visible?
        names = @selected_ids.map do |uid|
          p = Core::SceneModel.find_by_id(uid)
          next nil unless p
          { 'name' => p.name.to_s, 'mp' => Core::SceneModel.matchphoto?(p) }
        end.compact
        state = {
          selected_count: names.size,
          selected:       names,
          clipboard:      Core::Clipboard.peek
        }
        @dialog.execute_script("window.SMClip && SMClip.setState(#{state.to_json});")
      end
    end
  end
end
