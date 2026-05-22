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
        # Persiste tutti i cambi RAM-only al close del dialog. Su modelli
        # con observer terzi pesanti, set_attribute è caro (~5s) → tutti
        # i save durante editing vivono in RAM (Core::Settings.set non
        # tocca il disco), e solo qui consolidiamo in 1 batch.
        @dialog.set_on_closed do
          begin
            Core::Settings.flush!
          rescue => e
            warn "[SM+] settings flush on close: #{e.class}: #{e.message}"
          end
        end
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
          # Settings che influenzano la main dialog (es. banner ordine):
          # forziamo un push_state lì, altrimenti la modifica non si vede
          # finché l'utente non interagisce con la lista.
          Dialog.push_state if group == 'ui'
          # NIENTE push_state qui: il form JS ha già i valori appena inviati,
          # e rileggerli via Sketchup.read_default subito dopo write_default è
          # inaffidabile in SU 2019 (la lettura può tornare il valore vecchio
          # / il default). Il round-trip sovrascriveva i campi adiacenti già
          # blurati con il valore "stale" → l'utente vedeva il proprio input
          # tornare al valore precedente cambiando campo (caso classico:
          # logo offset_x/offset_y). Se in futuro serve sincronizzare flag
          # laterali (vedi sm_pick_logo), push_state esplicito in quel
          # callback specifico.
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

        dlg.add_action_callback('sm_pick_dir') do |_ctx, payload|
          data = parse(payload)
          cur  = data['current'].to_s
          start_dir = (cur && File.directory?(cur)) ? cur : Dir.home
          chosen = ::UI.select_directory(title: 'Choose export folder', directory: start_dir)
          if chosen
            cfg = Core::Settings.get('export')
            Core::Settings.set('export', cfg.merge('output_dir' => chosen))
            dlg.execute_script("window.SMS && SMS.setOutputDir(#{chosen.to_json});")
          end
        end

        dlg.add_action_callback('sm_pick_logo') do |_ctx, payload|
          data = parse(payload)
          cur  = data['current'].to_s
          start_dir = (!cur.empty? && File.file?(cur)) ? File.dirname(cur) : Dir.home
          chosen = ::UI.openpanel('Choose logo PNG', start_dir, 'PNG Files|*.png;*.PNG||')
          if chosen
            cfg = Core::Settings.get('logo')
            # Scegliere un file logo implica voler usarlo come watermark
            # custom: forziamo enabled=true e use_default=false.
            Core::Settings.set('logo', cfg.merge(
              'path'        => chosen,
              'enabled'     => true,
              'use_default' => false
            ))
            push_state # rinfresca UI con i nuovi flag
            dlg.execute_script("window.SMS && SMS.setLogoPath(#{chosen.to_json});")
          end
        end

        dlg.add_action_callback('sm_settings_log') do |_ctx, msg|
          puts "[SM+ Settings UI] #{msg}"
        end

        # Purge degli stili non usati. SU 2019 non ha per-style delete via
        # Ruby — solo styles.purge_unused (model-wide). Quindi mostriamo
        # confirmation con lista degli stili che verranno cancellati
        # (inclusi non-SM+) prima di procedere.
        dlg.add_action_callback('sm_settings_purge_unused_styles') do |_ctx|
          unused = Core::Styles.unused_styles
          if unused.empty?
            ::UI.messagebox("All styles are in use by at least one scene. Nothing to purge.")
            next
          end
          list = unused.map { |h|
            if h[:display_name] != h[:name]
              "  • #{h[:display_name]} (native: #{h[:name]})"
            else
              "  • #{h[:name]}"
            end
          }.join("\n")
          mb_yesno = Object.const_defined?(:MB_YESNO) ? MB_YESNO : 4
          id_yes   = Object.const_defined?(:IDYES)   ? IDYES   : 6
          answer = ::UI.messagebox(
            "The following #{unused.size} style(s) will be deleted:\n\n" \
            "#{list}\n\n" \
            "This action cannot be undone via Ctrl+Z (styles.purge_unused is\n" \
            "not transactional in SU 2019 Ruby API).\n\n" \
            "Continue?",
            mb_yesno
          )
          if answer == id_yes
            removed = Core::Styles.purge_unused_styles
            puts "[SM+] purge_unused_styles: removed #{removed.size} style(s): #{removed.inspect}"
            ::UI.messagebox("Purged #{removed.size} style(s) and cleaned up their nicknames.")
            Dialog.push_state if defined?(Dialog)
          else
            puts "[SM+] purge_unused_styles: aborted by user"
          end
        end
      end

      def push_state
        return unless @dialog && @dialog.visible?
        default_logo = Core::Settings.default_logo_path
        state = {
          settings:           Core::Settings.all,
          skp_title:          (Sketchup.active_model ? Sketchup.active_model.title.to_s : ''),
          default_logo_name:  (default_logo ? File.basename(default_logo) : nil)
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
