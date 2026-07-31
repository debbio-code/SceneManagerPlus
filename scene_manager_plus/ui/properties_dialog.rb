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

      # Il dialog segue SEMPRE la scena attiva nel viewport: mostrare le
      # proprieta' di una scena diversa da quella che si sta guardando e'
      # ambiguo (e la sezione Fog, che legge le rendering options del modello,
      # sarebbe per forza disabilitata).
      #
      # Chiamato da `Dialog#poll_active_scene` (cambio scena dai tab nativi) e
      # dal callback `sm_select_page` (click nella lista del plugin, che non
      # aspetta il polling). No-op se il dialog e' chiuso o se la scena e' gia'
      # quella mostrata.
      def follow_active(uid)
        return unless @dialog && (@dialog.visible? rescue false)
        return if uid.nil? || uid == @scene_id
        @scene_id = uid
        push_state
      rescue => e
        warn "[SM+] properties follow_active: #{e.class}: #{e.message}"
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

        # Sezione Layers: un unico dispatcher invece di 8 callback separati.
        # Payload: { op: 'visible'|'current'|'rename'|'color'|'line_style'|
        #                'add'|'delete'|'purge', name: <layer>, value: ... }
        dlg.add_action_callback('sm_props_layer_op') do |_ctx, payload|
          handle_layer_op(parse(payload))
        end
      end

      # Tutte le operazioni sui layer sono MODEL-WIDE (come il pannello Layers
      # nativo): valgono per ogni scena, e la scena corrente le cattura solo
      # con "Update from view". La lista invece e' filtrata per-scena.
      # Sono immediate anche in defer mode, come assign_style: toccano il
      # modello, non gli attributi di pagina bufferizzati.
      def handle_layer_op(data)
        op     = data['op'].to_s
        name   = data['name'].to_s
        focus  = nil
        status = nil
        # Visibilita', colore e line style si propagano a tutta la selezione:
        # `names` arriva dalla UI quando le righe selezionate sono piu' di una
        # (shift/ctrl-click), altrimenti si lavora sul solo `name`.
        targets = data['names'].is_a?(Array) && !data['names'].empty? ? data['names'] : [name]

        case op
        when 'visible'
          Core::Layers.set_visible(targets, data['value'])
        when 'current'
          Core::Layers.set_current(name)
        when 'rename'
          ok, err = Core::Layers.rename(name, data['value'])
          unless ok
            ::UI.messagebox(rename_error_message(err, data['value']))
          end
        when 'color'
          Core::Layers.set_color(targets, data['value'])
        when 'random_colors'
          status = randomize_colors_status(targets)
        when 'line_style'
          Core::Layers.set_line_style(targets, data['value'])
        when 'add'
          focus = Core::Layers.add_layer
        when 'add_scene_only'
          focus = add_layer_visible_only_in_scene
        when 'color_by_layer'
          Core::Layers.set_color_by_layer(data['value'])
        when 'assign_selection'
          status = assign_selection_status(name)
        when 'info'
          LayerInfoDialog.show_for(name)
        when 'delete'
          delete_layers_interactive(targets)
        when 'purge'
          n = Core::Layers.purge_unused
          ::UI.messagebox(
            n > 0 ? "#{n} unused layer(s) purged.\n\nUndo with Ctrl+Z if this was a mistake."
                  : 'No unused layers to purge.'
          )
        end

        push_state(focus_layer: focus, status: status)
      rescue => e
        warn "[SM+] handle_layer_op failed: #{e.class}: #{e.message}"
      end

      # "+ occhio": crea un layer visibile SOLO nella scena aperta in questo
      # dialog, che puo' non essere quella attiva nel viewport (differenza
      # sostanziale rispetto ad "Add Visible Tag" del Layers Manager, che
      # lavora sempre sulla scena attiva).
      def add_layer_visible_only_in_scene
        return nil unless @scene_id
        p = Core::SceneModel.find_by_id(@scene_id)
        return nil unless p
        res = Core::Layers.add_layer_visible_only_in(p)
        return nil unless res
        warn_unconstrained_scenes(res['unconstrained'])
        res['name']
      end

      # Sposta la selezione del viewport sul layer, previa conferma.
      #
      # La conferma non e' negoziabile: la freccia sta in una riga fitta di
      # controlli, il click parte facile, e cambiare layer a geometria gia'
      # modellata e' un'operazione che si nota solo molto dopo (specie se il
      # layer di destinazione e' spento e la geometria "sparisce"). Il
      # messagebox elenca cosa verra' spostato PRIMA di toccare il modello.
      def assign_selection_status(name)
        sum = Core::Layers.selection_summary(name)
        return 'Layer not found' unless sum
        return 'Select something in the model first' if sum['total'].to_i.zero?
        return 'Move cancelled' unless confirm_assign_selection(name, sum)

        res = Core::Layers.assign_selection(name)
        return 'Layer not found' unless res
        parts = ["#{res['moved']} moved to \"#{name}\""]
        parts << "#{res['already']} already there" if res['already'].to_i > 0
        parts << "#{res['skipped']} skipped"       if res['skipped'].to_i > 0
        parts.join(', ')
      end

      def confirm_assign_selection(name, sum)
        breakdown = (sum['counts'] || {})
                    .sort_by { |k, v| [-v.to_i, k.to_s] }
                    .map { |k, v| Core::Layers.count_label(v, k) }
                    .join(', ')
        msg = "Move the current selection to layer \"#{name}\"?\n\n" \
              "#{sum['total']} selected: #{breakdown}"
        if sum['already'].to_i > 0
          msg += "\n#{sum['already']} of them are already on this layer."
        end
        # Spostare su un layer spento fa sparire la geometria dal viewport:
        # senza questo avviso sembra di averla cancellata.
        l = Core::Layers.find(name)
        if l && !(l.visible? rescue true)
          msg += "\n\nWarning: this layer is hidden in the model, so the moved " \
                 'entities will disappear from the viewport.'
        end
        msg += "\n\nGroups and components move as a whole, like Entity Info."
        ::UI.messagebox(msg, MB_OKCANCEL) == IDOK
      end

      def warn_unconstrained_scenes(names)
        return if names.nil? || names.empty?
        shown = names.first(8).join(', ')
        more  = names.size > 8 ? " (and #{names.size - 8} more)" : ''
        ::UI.messagebox(
          "The layer was created, but #{names.size} scene(s) do not save layer " \
          "visibility (their \"Visible Layers\" property is off), so they will " \
          "show it anyway:\n\n#{shown}#{more}"
        )
      end

      def rename_error_message(err, attempted)
        case err
        when 'exists'    then "A layer named \"#{attempted}\" already exists."
        when 'empty'     then 'Layer name cannot be empty.'
        when 'default'   then 'The default layer (Layer0) cannot be renamed.'
        when 'not_found' then 'Layer not found (it may have been deleted).'
        else                  'Rename failed.'
        end
      end

      # Colore casuale per ogni layer della selezione. Nessuna conferma: e'
      # un'operazione puramente cosmetica, evidente a schermo e in un solo
      # Ctrl+Z (Core::Layers.randomize_colors usa una sola start_operation).
      def randomize_colors_status(names)
        list = clean_names(names)
        return 'Select one or more layers first' if list.empty?
        n = Core::Layers.randomize_colors(list)
        return 'Layer not found' if n.zero?
        "Random color assigned to #{n} layer#{n == 1 ? '' : 's'} (Ctrl+Z to undo)"
      end

      def clean_names(names)
        Array(names).map { |n| n.to_s }.reject { |n| n.empty? }.uniq
      end

      # Replica la domanda del pannello nativo su cosa fare della geometria.
      # UI.messagebox espone solo YES/NO/CANCEL, quindi mappiamo i due esiti
      # utili del nativo (sposta / cancella) su YES e NO.
      #
      # Una sola domanda per l'intera selezione (e una sola operazione lato
      # Core): con 5 layer selezionati, 5 messagebox in fila sarebbero solo un
      # modo per farli confermare senza leggere.
      def delete_layers_interactive(names)
        list = clean_names(names)
        return if list.empty?
        res = ::UI.messagebox(delete_layers_question(list), MB_YESNOCANCEL)
        return if res == IDCANCEL
        out = Core::Layers.delete_layers(list, res == IDYES ? 'move' : 'erase')
        report_delete_errors(out)
      end

      def delete_layers_question(list)
        if list.size == 1
          "Delete layer \"#{list.first}\"?\n\n" \
          "YES — delete the layer, KEEP its entities (moved to Layer0)\n" \
          "NO — delete the layer AND all entities on it\n" \
          "CANCEL — do nothing"
        else
          shown = list.first(12).join(', ')
          more  = list.size > 12 ? " (and #{list.size - 12} more)" : ''
          "Delete #{list.size} layers?\n\n#{shown}#{more}\n\n" \
          "YES — delete them, KEEP their entities (moved to Layer0)\n" \
          "NO — delete them AND all entities on them\n" \
          "CANCEL — do nothing"
        end
      end

      # Un layer per riga: i motivi di scarto sono diversi fra loro (default,
      # sparito, rifiutato) e un messaggio unico non direbbe quale layer e' quale.
      def report_delete_errors(out)
        errs = out['errors'] || {}
        return if errs.empty?
        done  = (out['deleted'] || []).size
        head  = done.zero? ? 'Nothing was deleted.'
                           : "#{done} layer(s) deleted. The rest was skipped:"
        lines = errs.map { |n, k| "- #{n}: #{delete_error_text(k)}" }
        ::UI.messagebox("#{head}\n\n#{lines.join("\n")}")
      end

      def delete_error_text(err)
        case err
        when 'default'   then 'the default layer (Layer0) cannot be deleted'
        when 'last'      then 'cannot delete the only layer in the model'
        when 'not_found' then 'not found (it may have been deleted already)'
        else                  'delete failed'
        end
      end

      # `focus_layer`: nome del layer appena creato — il JS ci apre sopra il
      # rename inline, come fa il pannello nativo dopo il "+".
      def push_state(focus_layer: nil, status: nil)
        return unless @dialog && @dialog.visible?
        scene = scene_payload(@scene_id)
        preview = @scene_id ? Core::Previews.url_map[@scene_id] : nil
        state = {
          scene:       scene,
          flag_keys:   Core::SceneModel::FLAG_KEYS,
          preview_url: preview,
          focus_layer: focus_layer,
          status:      status
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
          'fog'          => read_fog,
          'layers'       => Core::Layers.payload_for_page(p)
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
