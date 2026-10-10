require 'json'

module SceneManagerPlus
  module UI
    # Schermata "Color variant" (Fase V2): registra override materiale
    # per-scena. Aperta dal badge variante nella row o dal context menu.
    #
    # Flusso: l'utente seleziona entità nel viewport, sceglie un materiale
    # nel dropdown, clicca "Assign to selection" → l'override viene
    # registrato sulla scena (page attribute) e applicato subito (feedback
    # live). Le modifiche passano SEMPRE da questa schermata: il secchiello
    # nativo usato con una variante attiva NON entra nella variante (scelta
    # di design — niente observer fragili sul paint nativo).
    #
    # All'apertura la scena di contesto viene attivata (come StyleDialog):
    # così il motore Variants ha lo stato coerente (@applied = questa scena
    # o nil) e l'utente vede la variante mentre la edita.
    #
    # Sezione "Materials" (2026-10-10): override di MATERIALE ("in questa
    # scena X appare con questo colore", vedi Core::Variants). Elenca i
    # materiali che la scena già cambia più quelli usati dalla selezione nel
    # viewport, quindi segue la selezione (SelObserver, solo a finestra
    # aperta). Il colore si sceglie col selettore condiviso: mentre lo si
    # muove arrivano le anteprime (sm_variant_mat_preview, niente scrittura
    # sulla scena), alla chiusura la conferma (sm_variant_mat_set).
    module VariantDialog
      module_function

      # Oltre questi numeri di entità la scansione si ferma: la lista può
      # essere incompleta (selezione) o il "not in use" non si calcola.
      SEL_BUDGET   = 100_000
      MODEL_BUDGET = 400_000

      @dialog       = nil
      @scene_id     = nil
      @previewing   = nil  # materiale con un'anteprima non ancora confermata
      @sel_observer = nil
      @watched      = nil
      @sel_queued   = false
      @used_cache   = nil  # { model_oid:, names: {nome=>true}|nil, at:, cost: }
      @last_log     = nil  # ultimo messaggio arrivato dalla pagina

      class SelObserver < ::Sketchup::SelectionObserver
        def onSelectionBulkChange(_sel);  VariantDialog.selection_changed; end
        def onSelectionCleared(_sel);     VariantDialog.selection_changed; end
        def onSelectionAdded(_sel, _e);   VariantDialog.selection_changed; end
        def onSelectionRemoved(_sel, _e); VariantDialog.selection_changed; end
      end

      def html_dir
        File.join(PLUGIN_DIR, 'ui', 'html')
      end

      def prepare_index
        src = File.join(html_dir, 'variant.html')
        ts  = Time.now.to_i.to_s
        begin
          html = File.read(src)
          html = html.gsub(/(<script\s+src=")([^"]+)(")/)                   { "#{$1}#{$2}?v=#{ts}#{$3}" }
          html = html.gsub(/(<link\s+rel="stylesheet"\s+href=")([^"]+)(")/) { "#{$1}#{$2}?v=#{ts}#{$3}" }
          dst  = File.join(html_dir, 'variant.cb.html')
          File.write(dst, html)
          dst
        rescue => e
          warn "[SM+] variant prepare_index failed: #{e.class}: #{e.message}"
          src
        end
      end

      def show_for(scene_id)
        return unless scene_id
        @scene_id = scene_id
        # Attiva la scena di contesto (passa da on_scene_activated → variante
        # applicata / precedente ripristinata). In defer mode select_page è
        # comunque immediato (navigazione).
        Core::SceneModel.select_page(scene_id)
        @used_cache = nil # il "not in use" si ricalcola a ogni apertura

        if @dialog && @dialog.visible?
          @dialog.bring_to_front
          push_state
          return @dialog
        end

        @dialog = ::UI::HtmlDialog.new(
          dialog_title:    "#{PLUGIN_NAME} — Color variant",
          preferences_key: 'SceneManagerPlus.VariantDialog',
          scrollable:      true,
          resizable:       true,
          width:           400,
          height:          560,
          min_width:       340,
          min_height:      320,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_on_closed { on_closed }
        @dialog.set_file(prepare_index)
        @dialog.show
        watch_selection
        @dialog
      end

      def on_closed
        unwatch_selection
        # Finestra chiusa col selettore colore aperto: l'anteprima non è mai
        # stata confermata, il materiale torna a quello che la scena salva.
        if @previewing
          page = current_page
          Core::Variants.resync_materials!(page) if page
          @previewing = nil
        end
        @dialog = nil
      rescue => e
        warn "[SM+] variant on_closed: #{e.class}: #{e.message}"
        @dialog = nil
      end

      # La lista dei materiali segue la selezione nel viewport.
      def watch_selection
        unwatch_selection
        m = Sketchup.active_model
        return unless m
        @sel_observer ||= SelObserver.new
        @watched = m.selection
        @watched.add_observer(@sel_observer)
      rescue => e
        warn "[SM+] variant watch_selection: #{e.class}: #{e.message}"
      end

      def unwatch_selection
        @watched.remove_observer(@sel_observer) if @watched && @sel_observer
      rescue
        nil
      ensure
        @watched = nil
      end

      # Un clic nel modello dà più eventi (svuota + aggiungi): la selezione
      # si guarda una volta sola, a eventi finiti.
      def selection_changed
        return if @sel_queued || !(@dialog && @dialog.visible?)
        @sel_queued = true
        ::UI.start_timer(0, false) do
          @sel_queued = false
          begin
            push_state
          rescue => e
            warn "[SM+] variant selection_changed: #{e.class}: #{e.message}"
          end
        end
      end

      def register_callbacks(dlg)
        dlg.add_action_callback('sm_variant_ready') do |_ctx|
          push_state
        end

        # Assegna il materiale scelto alla selezione viewport corrente.
        # payload: { mat: 'name' | null }  (null = rimuovi materiale)
        dlg.add_action_callback('sm_variant_assign') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          if page
            count, report = Core::Variants.record_from_selection(page, data['mat'])
            set_status(count > 0 ? "#{count} override(s) recorded." : report.join(' '))
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Cambia il materiale di un singolo override esistente.
        # payload: { pid: int, mat: 'name' | null }
        dlg.add_action_callback('sm_variant_set_mat') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          if page && data['pid']
            _count, report = Core::Variants.record_pids(page, [data['pid']], data['mat'])
            set_status(report.empty? ? 'Override updated.' : report.join(' '))
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Rimuove un override (ripristina il base).
        dlg.add_action_callback('sm_variant_remove') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          if page && data['pid']
            Core::Variants.remove_override(page, data['pid'])
            set_status('Override removed.')
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Rimuove l'intera variante (con conferma).
        dlg.add_action_callback('sm_variant_clear') do |_ctx|
          page = current_page
          if page
            mb_yesno = Object.const_defined?(:MB_YESNO) ? MB_YESNO : 4
            id_yes   = Object.const_defined?(:IDYES)    ? IDYES   : 6
            answer = ::UI.messagebox(
              "Remove ALL overrides of this scene's color variant\n" \
              "and restore the base materials?",
              mb_yesno
            )
            if answer == id_yes
              Core::Variants.clear_and_restore(page)
              set_status('Variant cleared.')
            end
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Rimuove tutti gli override orfani (entità non più nel modello).
        dlg.add_action_callback('sm_variant_clean_missing') do |_ctx|
          page = current_page
          if page
            n = Core::Variants.prune_missing(page)
            set_status(n > 0 ? "#{n} orphan override(s) removed." : 'Nothing to clean.')
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Evidenzia un'entità override nel viewport (select).
        dlg.add_action_callback('sm_variant_pick') do |_ctx, payload|
          data = parse(payload)
          pid = data['pid'].to_i
          m = Sketchup.active_model
          if m && pid > 0
            e = m.find_entity_by_persistent_id(pid)
            if e && !e.deleted?
              m.selection.clear
              m.selection.add(e)
            else
              set_status("Entity pid=#{pid} not found in model.")
            end
          end
        end

        # Ri-attiva la scena di contesto (se l'utente ha navigato altrove).
        dlg.add_action_callback('sm_variant_activate') do |_ctx|
          Core::SceneModel.select_page(@scene_id) if @scene_id
          push_state
        end

        dlg.add_action_callback('sm_variant_log') do |_ctx, msg|
          @last_log = msg.to_s
          puts "[SM+ Variant UI] #{msg}"
        end

        # --- override di materiale ---

        # Anteprima mentre si muove il selettore colore. La prima di un giro
        # è un'operazione normale, le altre (e la conferma) si fondono con
        # lei: un Ctrl+Z annulla tutta la scelta. payload: { name, color }
        dlg.add_action_callback('sm_variant_mat_preview') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          name = data['name'].to_s
          if page && !name.empty?
            ok = Core::Variants.preview_material(page, name, data['color'], stored_alpha(page, name),
                                                 merge: @previewing == name)
            @previewing = name if ok
          end
        end

        # Conferma (chiusura del selettore). payload: { name, color }
        dlg.add_action_callback('sm_variant_mat_set') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          name = data['name'].to_s
          if page && !name.empty?
            ok, report = Core::Variants.record_material(page, name, data['color'], stored_alpha(page, name),
                                                        merge: @previewing == name)
            @previewing = nil
            set_status(ok ? 'Material color recorded.' : report.join(' '))
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Prende il colore (base) di un altro materiale. payload: { name, from }
        dlg.add_action_callback('sm_variant_mat_copy') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          name = data['name'].to_s
          color = Core::Variants.base_color(data['from'])
          if page && !name.empty? && color
            ok, report = Core::Variants.record_material(page, name, color, stored_alpha(page, name))
            set_status(ok ? "Color copied from '#{data['from']}'." : report.join(' '))
          elsif page
            set_status("Material '#{data['from']}' not found in model.")
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Toglie l'override (il materiale torna al colore base). payload: { name }
        dlg.add_action_callback('sm_variant_mat_remove') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          if page && data['name']
            Core::Variants.remove_material_override(page, data['name'])
            set_status('Material override removed.')
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end

        # Sposta un override su un altro materiale: serve quando quello di
        # partenza non è più in uso (il componente ha cambiato colore base e
        # ne usa uno nuovo). payload: { from, to }
        dlg.add_action_callback('sm_variant_mat_move') do |_ctx, payload|
          data = parse(payload)
          page = current_page
          from = data['from'].to_s
          o = page && Core::Variants.material_overrides_for(page).find { |x| x['name'] == from }
          if o && !data['to'].to_s.empty?
            ok, report = Core::Variants.record_material(page, data['to'], o['color'], o['alpha'])
            if ok
              Core::Variants.remove_material_override(page, from, merge: true)
              set_status("Override moved to '#{data['to']}'.")
            else
              set_status(report.join(' '))
            end
          end
          push_state
          Dialog.push_state if defined?(Dialog)
        end
      end

      # La finestra non ha un campo per la trasparenza: cambiando il colore
      # si tiene quella che l'override ha già (nil = non toccarla).
      def stored_alpha(page, name)
        o = Core::Variants.material_overrides_for(page).find { |x| x['name'] == name }
        o ? o['alpha'] : nil
      end

      # Righe della sezione Materials: i materiali che la scena già cambia
      # più quelli usati dalla selezione nel viewport.
      # Ritorna [rows, truncated].
      def material_rows(m, page)
        by_name = {}
        Core::Variants.material_overrides_for(page).each { |o| by_name[o['name']] = o }
        in_sel = {}
        budget = [SEL_BUDGET]
        collect_materials(m.selection, in_sel, {}, budget)
        used = by_name.empty? ? nil : used_material_names(m)
        names = (by_name.keys + in_sel.keys).uniq.sort_by(&:downcase)
        rows = names.map do |n|
          mat = m.materials[n]
          o = by_name[n]
          { name:     n,
            base:     Core::Variants.base_color(n),
            color:    o ? o['color'] : nil,
            in_sel:   in_sel.key?(n),
            missing:  mat.nil?,
            textured: !!(mat && mat.texture),
            unused:   !!(o && mat && used && !used.key?(n)) }
        end
        [rows, budget[0] < 0]
      end

      # Nomi dei materiali usati da quello che si vede nel modello, o nil se
      # il modello è troppo grande per contarli. Se la scansione è svelta la
      # si rifà quando serve (al più una al secondo); se è lenta resta
      # quella fatta all'apertura della finestra.
      def used_material_names(m)
        c = @used_cache
        if c && c[:model_oid] == m.object_id && (c[:cost] > 0.05 || Time.now - c[:at] < 1.0)
          return c[:names]
        end
        t0 = Time.now
        names = {}
        budget = [MODEL_BUDGET]
        collect_materials(m.entities, names, {}, budget)
        names = nil if budget[0] < 0
        @used_cache = { model_oid: m.object_id, names: names, at: Time.now, cost: Time.now - t0 }
        names
      end

      # Materiali usati da `entities` e da tutto quello che contengono
      # (ogni definizione una volta sola). Si ferma a budget esaurito.
      def collect_materials(entities, into, seen, budget)
        entities.each do |e|
          budget[0] -= 1
          return if budget[0] < 0
          if e.respond_to?(:material)
            mt = e.material
            into[mt.name.to_s] = true if mt
          end
          case e
          when Sketchup::Face
            bm = e.back_material
            into[bm.name.to_s] = true if bm
          when Sketchup::Group, Sketchup::ComponentInstance
            d = e.definition
            next if seen[d]
            seen[d] = true
            collect_materials(d.entities, into, seen, budget)
          end
        end
      end

      def current_page
        return nil unless @scene_id
        Core::SceneModel.find_by_id(@scene_id)
      end

      def push_state
        return unless @dialog && @dialog.visible?
        m = Sketchup.active_model
        return unless m
        page = current_page
        unless page
          # Scena sparita (cancellata?) → chiudi
          @dialog.close rescue nil
          return
        end

        ovs = Core::Variants.overrides_for(page)
        pids = ovs.map { |o| o['pid'] }
        ents = pids.empty? ? [] : Array(m.find_entity_by_persistent_id(pids))
        rows = ovs.each_with_index.map do |o, i|
          e = ents[i]
          found = !!(e && !e.deleted?)
          { pid:   o['pid'],
            mat:   o['mat'],
            base:  o['base'],
            kind:  found ? describe_entity(e) : 'missing',
            found: found }
        end

        mats = m.materials.map { |mt| mt.name.to_s }.sort_by(&:downcase)
        active = m.pages.selected_page
        mat_rows, truncated = material_rows(m, page)
        state = {
          scene_id:      @scene_id,
          scene_name:    page.name.to_s,
          is_active:     active == page,
          materials:     mats,
          overrides:     rows,
          mat_rows:      mat_rows,
          mat_truncated: truncated,
          sel_count:     m.selection.length
        }
        @dialog.execute_script("window.SMV && SMV.setState(#{state.to_json});")
      rescue => e
        warn "[SM+] variant push_state ERROR: #{e.class}: #{e.message}"
        warn e.backtrace.first(3).join("\n")
      end

      def set_status(msg)
        return unless @dialog && @dialog.visible?
        @dialog.execute_script("window.SMV && SMV.setStatus(#{msg.to_s.to_json});")
      rescue
        nil
      end

      def describe_entity(e)
        case e
        when Sketchup::Group
          n = e.name.to_s
          n.empty? ? 'Group' : "Group '#{n}'"
        when Sketchup::ComponentInstance
          "Comp '#{e.definition.name}'" rescue 'Component'
        when Sketchup::Face then 'Face'
        when Sketchup::Edge then 'Edge'
        else e.class.to_s.split('::').last
        end
      rescue
        'Entity'
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
