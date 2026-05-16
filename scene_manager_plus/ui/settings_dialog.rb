require 'json'

module SceneManagerPlus
  module UI
    # Dialog separato per Settings. Riusa il pattern cache-bust di Dialog.
    module SettingsDialog
      module_function

      @dialog = nil

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'settings.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)               { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'settings.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] settings prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      def show
        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Settings",
          preferences_key: 'SceneManagerPlus.SettingsDialog',
          scrollable:      true,
          resizable:       true,
          width:           480,
          height:          620,
          min_width:       380,
          min_height:      400,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_settings_ready') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_settings_get') do |_ctx|
          push_state
        end

        dlg.add_action_callback('sm_settings_set') do |_ctx, payload|
          data = parse(payload)
          # data = { group: 'naming'|'export'|'logo', values: {...} }
          group = data['group']
          vals  = data['values'] || {}
          Core::Settings.set(group, vals) if group
          push_state
        end

        dlg.add_action_callback('sm_naming_preview') do |_ctx, payload|
          data    = parse(payload)
          settings = (data['values'] || {})
          # merge con defaults+stored per non perdere chiavi
          base = Core::Settings.get('naming')
          merged = base.merge(settings)
          samples = Core::Naming.preview(merged, limit: 6)
          js = "window.SMS && SMS.setPreview(#{samples.to_json});"
          dlg.execute_script(js)
        end

        dlg.add_action_callback('sm_naming_apply') do |_ctx, payload|
          data = parse(payload)
          settings = (data['values'] || {})
          base = Core::Settings.get('naming')
          merged = base.merge(settings)
          # salva subito prima di applicare
          Core::Settings.set('naming', merged)
          count = Core::Naming.apply_rename(merged)
          js = "window.SMS && SMS.setApplyResult(#{count.to_json});"
          dlg.execute_script(js)
          # ri-pusha state alla finestra principale (i nomi sono cambiati)
          Dialog.push_state
        end

        dlg.add_action_callback('sm_settings_log') do |_ctx, msg|
          puts "[SM+ Settings UI] #{msg}"
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        state = {
          settings:  Core::Settings.all,
          skp_title: (Sketchup.active_model ? Sketchup.active_model.title.to_s : '')
        }
        js = "window.SMS && SMS.setState(#{state.to_json});"
        @dialog.execute_script(js)
      rescue => e
        warn "[SM+] settings push_state ERROR: #{e.class}: #{e.message}"
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
