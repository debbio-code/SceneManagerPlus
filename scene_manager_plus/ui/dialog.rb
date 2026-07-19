require 'json'

module SceneManagerPlus
  module UI
    module Dialog
      module_function

      @dialog            = nil
      @poll_timer_id     = nil
      @last_active_uid   = nil
      @last_native_sig   = nil

      # Polling 250ms: se selected_page cambia (e defer è OFF), aggiorna la
      # selezione nel plugin. Più affidabile del frame_change_observer che
      # in SU 2019 non scatta sempre sui click ai tab nativi.
      def start_active_scene_poll
        stop_active_scene_poll
        @last_active_uid = nil
        @last_native_sig = nil
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
        # CRITICO: questa funzione gira ogni 250ms. NON deve mai chiamare
        # API che scrivono nel modello (set_attribute, ecc.), perché su
        # modelli con AttributeObserver di plugin terzi ogni write può
        # costare secondi → loop di polling che martella + apertura file
        # bloccata indefinitamente.
        #
        # Detect riordino nativo via `p.object_id`: stabile nella sessione
        # (l'identity Ruby della Page non cambia per riordini interni di
        # SU) e zero side-effect. NON usiamo `SceneModel.page_id` perché
        # quello fa lazy-write dell'uid sulle pagine che non l'hanno → da
        # un polling che gira spesso può scatenare un blocco massivo.
        native_sig = m.pages.map { |p| p.object_id }.join('|')
        if @last_native_sig && native_sig != @last_native_sig
          @last_native_sig = native_sig
          push_state
        else
          @last_native_sig = native_sig
        end
        page = m.pages.selected_page
        return unless page
        # Usiamo page_id (non get_attribute diretto) così funziona anche
        # per scene con uid solo transient (non ancora persistiti su disco).
        # page_id è read-only: legge get_attribute e, se nil, restituisce
        # il transient uid dalla cache RAM (stessa identità usata dal JS
        # tramite push_state → ui_payload). Nessuna write su SU.
        uid = Core::SceneModel.page_id(page)
        return unless uid
        return if uid == @last_active_uid
        @last_active_uid = uid
        # Variante colore: il cambio scena via TAB NATIVI passa solo da qui.
        # Deroga consapevole alla regola "il polling non scrive mai":
        # on_scene_activated è zero-write se né la scena entrante né quella
        # uscente hanno varianti (uid identico → return; nessuna variante e
        # niente applied → sola lettura attributo). Scrive materiali SOLO
        # nella transizione che coinvolge una variante — evento raro,
        # equivalente a un click utente, non un write per-tick.
        begin
          page_for_variant = m.pages.selected_page
          Core::Variants.on_scene_activated(page_for_variant) if page_for_variant
        rescue => e
          warn "[SM+] poll variant apply: #{e.class}: #{e.message}"
        end
        @dialog.execute_script("window.SM && SM.setActiveFromNative(#{uid.to_json});")
      rescue => e
        warn "[SM+] poll_active_scene: #{e.class}: #{e.message}"
      end

      # Workaround bug SU 2019: dopo apertura file le Scene Tabs possono
      # restare visibili nel viewport anche se nel menu risultano off, e
      # l'unico modo per ri-sincronizzare è togglare due volte dal menu
      # (on → no-op visibile, off → spegne davvero). Riproduciamo la
      # stessa cosa via send_action. Opt-in da Settings → Interface
      # (settings.ui.hide_scene_tabs_on_open, default false).
      #
      # Command IDs: su Mac il selettore string "showSceneTabs:" funziona;
      # su Windows SU 2019 serve l'ID numerico, e Trimble non lo documenta.
      # Identificato 10534 enumerando il menu di SU via Win32 GetMenu/
      # GetMenuString (script tools/dump-su-menu.ps1, 2026-05-21).
      # Override possibile via:
      #   Sketchup.write_default('SceneManagerPlus', 'scene_tabs_cmd_id', N)
      WIN_SHOW_SCENE_TABS_CMD_ID = 10534

      def scene_tabs_cmd_id
        Sketchup.read_default('SceneManagerPlus', 'scene_tabs_cmd_id', WIN_SHOW_SCENE_TABS_CMD_ID).to_i
      end

      def force_hide_scene_tabs_if_enabled
        return unless Core::Settings.get('ui')['hide_scene_tabs_on_open']
        toggle_scene_tabs!
        toggle_scene_tabs!
      rescue => e
        warn "[SM+] force_hide_scene_tabs_if_enabled: #{e.class}: #{e.message}"
      end

      def toggle_scene_tabs!
        if RUBY_PLATFORM =~ /darwin/
          Sketchup.send_action('showSceneTabs:')
        else
          Sketchup.send_action(scene_tabs_cmd_id)
        end
      end

      # Helper di diagnostica: prova un command ID dalla Ruby Console.
      # Uso:
      #   SceneManagerPlus::UI::Dialog.try_scene_tabs_cmd(21031)
      # Se le Scene Tabs si toggle-ano (anche se in modo buggy), abbiamo
      # trovato l'ID giusto. Per fissarlo in modo persistente:
      #   Sketchup.write_default('SceneManagerPlus', 'scene_tabs_cmd_id', 21031)
      def try_scene_tabs_cmd(id)
        puts "[SM+] try send_action(#{id})"
        Sketchup.send_action(id.to_i)
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
        force_hide_scene_tabs_if_enabled
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
          only = data['flags'].is_a?(Array) && !data['flags'].empty? ? data['flags'] : nil
          Core::SceneModel.update_from_view(data['id'], only_keys: only)
          push_state
        end

        dlg.add_action_callback('sm_assign_style') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.assign_style(data['id'], data['style_name'])
          push_state
        end

        dlg.add_action_callback('sm_open_style') do |_ctx, payload|
          data = parse(payload)
          StyleDialog.show_for(data['id'], data['style_name'])
        end

        dlg.add_action_callback('sm_open_variant') do |_ctx, payload|
          data = parse(payload)
          VariantDialog.show_for(data['id']) if data['id']
        end

        # Copy/paste variante colore tra scene (clipboard RAM di sessione,
        # stesso modello). Push state dopo entrambi: copy abilita la voce
        # "Paste" nel context menu, paste aggiorna il badge.
        dlg.add_action_callback('sm_variant_copy') do |_ctx, payload|
          data = parse(payload)
          page = Core::SceneModel.find_by_id(data['id'])
          if page
            n = Core::Variants.copy_variant(page)
            puts "[SM+] variant copy: #{n} override(s) from '#{page.name}'"
          end
          push_state
        end

        dlg.add_action_callback('sm_variant_paste') do |_ctx, payload|
          data = parse(payload)
          page = Core::SceneModel.find_by_id(data['id'])
          if page
            ok = Core::Variants.paste_variant(page)
            puts "[SM+] variant paste onto '#{page.name}': #{ok}"
            # Se il dialog Color variant è aperto su questa scena, refresh
            VariantDialog.push_state if defined?(VariantDialog)
          end
          push_state
        end

        # Right-click sul badge stile di una scena Match Photo: apriamo
        # l'inspector Styles nativo, stesso principio di "Style and Fog
        # → Scenes panel" in Properties dialog. Il picker normale è
        # comunque bloccato per MP (assign_style e + New style rifiutano),
        # quindi questa è la via "che funziona" per l'utente.
        dlg.add_action_callback('sm_open_native_styles_panel') do |_ctx, payload|
          data = parse(payload)
          id = data['id']
          if id
            p = Core::SceneModel.find_by_id(id)
            if p && Sketchup.active_model.pages.selected_page != p
              Sketchup.active_model.pages.selected_page = p
            end
          end
          ::UI.show_inspector('Styles')
        end

        # "Nuovo stile" da picker right-click. Alloca lo slot successivo
        # dal pool, prompt per nickname (skippabile, retry su duplicato),
        # poi assegna lo stile alla scena di contesto.
        dlg.add_action_callback('sm_style_new') do |_ctx, payload|
          data = parse(payload)
          scene_id = data['id']
          # Match Photo guard: evita di allocare uno slot (che catturerebbe
          # le RO MP, inclusa la foto di sfondo) per poi non poterlo
          # assegnare. assign_style rifiuta comunque le MP scene, ma senza
          # questo guard lo slot resterebbe orfano nel pool.
          scene_page = scene_id ? Core::SceneModel.find_by_id(scene_id) : nil
          if scene_page && Core::SceneModel.matchphoto?(scene_page)
            ::UI.messagebox(
              "Scene '#{scene_page.name}' is a Match Photo scene.\n\n" \
              "Cannot assign a custom style to a Match Photo scene."
            )
            next
          end
          result = Core::Styles.prompt_nickname_loop(
            title: 'Scene Manager+ — Nuovo stile',
            label: 'Nickname (vuoto = usa nome nativo "Slot NN"):'
          )
          if result == :aborted
            puts "[SM+] sm_style_new: aborted by user"
          else
            nickname = result.empty? ? nil : result
            # Variante from_viewport: il nuovo stile cattura le rendering
            # options correnti (dirty edit inclusi). Senza questo lo slot
            # manterrebbe le RO del template generator (Architectural Design
            # Style), non quelle che l'utente vede nel viewport.
            style = Core::Styles.allocate_new_slot_from_viewport(nickname: nickname)
            if style
              puts "[SM+] sm_style_new: allocated #{style.name.inspect} from viewport (nick=#{nickname.inspect})"
              Core::SceneModel.assign_style(scene_id, style.name) if scene_id
            end
          end
          push_state
        end

        dlg.add_action_callback('sm_scene_set_color') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.set_scene_color(data['id'], data['color'])
          push_state
        end

        dlg.add_action_callback('sm_delete') do |_ctx, payload|
          data = parse(payload)
          Core::SceneModel.delete_pages(data['ids'])
          push_state
        end

        dlg.add_action_callback('sm_set_export_included') do |_ctx, payload|
          data = parse(payload)
          ids = data['ids'] || (data['id'] ? [data['id']] : [])
          Core::SceneModel.set_export_included_bulk(ids, data['included'])
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

        dlg.add_action_callback('sm_open_clipboard') do |_ctx, payload|
          data = parse(payload)
          ClipboardDialog.show(selected_ids: Array(data['selected']))
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
          page = Core::SceneModel.add_from_view
          push_state
          if page
            uid = Core::SceneModel.page_id(page)
            js_uid = uid.to_s.inspect
            dlg.execute_script("window.SM && SM.selectId && SM.selectId(#{js_uid});")
          end
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
        ui_cfg = Core::Settings.get('ui')
        payload = Core::SceneModel.ui_payload(
          show_order_banner: ui_cfg['show_order_banner']
        )
        scenes_raw = payload[:scenes]
        tree       = payload[:tree]
        state = {
          scenes:    scenes_raw,
          tree:      tree,
          active_id: payload[:active_id],
          folders:   payload[:folders],
          flag_keys: Core::SceneModel::FLAG_KEYS,
          styles:    Core::SceneModel.styles_map,
          deferred:  Core::Buffer.deferred?,
          pending:   Core::Buffer.pending_count,
          previews:  Core::Previews.url_map,
          model_info: payload[:model_info],
          native_order_divergent: payload[:native_order_divergent],
          variant_clipboard: payload[:variant_clipboard]
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
