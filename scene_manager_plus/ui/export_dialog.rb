require 'json'

module SceneManagerPlus
  module UI
    # Piccolo dialog "scope picker" per il batch export.
    # Mostra radio All / Selected / Folders + checkbox cartelle, e lancia
    # Core::Exporter.export con il scope scelto. La progress bar è quella
    # della finestra principale.
    module ExportDialog
      module_function

      @dialog = nil

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'export.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)               { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'export.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] export prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      # selected_ids: array di uid scene attualmente selezionate nel main dialog
      def show(selected_ids: [])
        @selected_ids = Array(selected_ids)
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          push_state
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Export",
          preferences_key: 'SceneManagerPlus.ExportDialog',
          scrollable:      true,
          resizable:       true,
          width:           420,
          height:          480,
          min_width:       360,
          min_height:      360,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_export_ready') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_export_run') do |_ctx, payload|
          data = parse(payload)
          run(dlg, data)
        end

        dlg.add_action_callback('sm_export_cancel') do |_ctx|
          dlg.close
        end

        dlg.add_action_callback('sm_export_log') do |_ctx, msg|
          puts "[SM+ Export UI] #{msg}"
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        folders = Core::Folders.all.map do |f|
          { 'id' => f['id'], 'name' => f['name'].to_s, 'count' => Array(f['scene_ids']).size }
        end
        state = {
          folders:    folders,
          selected:   @selected_ids,
          has_select: !@selected_ids.empty?,
          settings:   Core::Settings.get('export')
        }
        @dialog.execute_script("window.SMX && SMX.setState(#{state.to_json});")
      end

      def run(dlg, data)
        scope      = (data['scope'] || 'all').to_s
        folder_ids = Array(data['folder_ids'])
        sel_ids    = @selected_ids

        main = Dialog.dialog_handle # accessor; nil-safe
        progress_cb = lambda do |done, total, name|
          if main && main.visible?
            js = "window.SM && SM.setExportProgress(#{done.to_json},#{total.to_json},#{name.to_json});"
            begin; main.execute_script(js); rescue; end
          end
        end
        done_cb = lambda do |count, out_dir, errors, cancelled|
          if main && main.visible?
            begin; main.execute_script("window.SM && SM.setExportProgress(null,null,null);"); rescue; end
          end
          header = cancelled ? "Export cancelled — #{count} scene#{count == 1 ? '' : 's'} saved" \
                             : "Exported #{count} scene#{count == 1 ? '' : 's'}"
          msg = header
          msg += "\n#{out_dir}" if out_dir
          if errors && !errors.empty?
            msg += "\n\nIssues:\n" + errors.first(8).join("\n")
            msg += "\n(+#{errors.size - 8} more)" if errors.size > 8
          end
          ::UI.messagebox(msg)
        end

        # Chiudi questo dialog prima di lanciare l'export (lungo)
        dlg.close

        Core::Exporter.export(
          scope:        scope,
          selected_ids: sel_ids,
          folder_ids:   folder_ids,
          on_progress:  progress_cb,
          on_done:      done_cb
        )
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
