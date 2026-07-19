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
    module VariantDialog
      module_function

      @dialog   = nil
      @scene_id = nil

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
          height:          480,
          min_width:       340,
          min_height:      320,
          style:           ::UI::HtmlDialog::STYLE_DIALOG
        )

        register_callbacks(@dialog)
        @dialog.set_on_closed { @dialog = nil }
        @dialog.set_file(prepare_index)
        @dialog.show
        @dialog
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
          puts "[SM+ Variant UI] #{msg}"
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
        state = {
          scene_id:   @scene_id,
          scene_name: page.name.to_s,
          is_active:  active == page,
          materials:  mats,
          overrides:  rows,
          sel_count:  m.selection.length
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
