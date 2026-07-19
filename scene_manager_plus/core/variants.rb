require 'json'

module SceneManagerPlus
  module Core
    # Varianti colore per-scena (Fase V1 — motore dati, niente UI).
    #
    # Una "variante" è una lista di override materiale registrati dall'utente
    # (via schermata "Variante colore", Fase V2) e salvati come page attribute.
    # All'attivazione della scena il motore applica gli override; quando si
    # attiva una scena senza variante, ripristina i materiali base.
    #
    # Fatti verificati via MCP eval_ruby su SU 2019 (19.3.253), 2026-07-19:
    # - Entity#persistent_id valido su Face/Group/ComponentInstance, anche
    #   annidati; sopravvive a salva/riapri.
    # - Model#find_entity_by_persistent_id accetta array e ritorna nil per i
    #   pid mancanti. MAI lookup con pid <= 0 (ritorna entità arbitrarie).
    # - Material#persistent_id è uno stub (ritorna 0) → materiali SEMPRE
    #   referenziati by-name, con report dei mancanti.
    # - start_operation(transparent=true) sporca comunque model.modified? e
    #   si aggancia all'operazione precedente nell'undo stack (1 Ctrl+Z
    #   utente può portarsi via anche l'apply — il viewport si risistema
    #   alla prossima attivazione scena). Caveat accettato.
    #
    # Schema page attribute PLUGIN_ID/'color_variant' (JSON):
    #   { "v": 1, "overrides": [ { "pid": 9591,
    #                              "mat":  "Antracite",   # null = rimuovi materiale
    #                              "base": "Bianco" } ] } # null = nessun materiale
    #
    # 'base' è lo stato registrato al momento della definizione dell'override
    # (Fase V2): serve come riferimento/recovery. Il RIPRISTINO runtime usa
    # invece lo snapshot RAM catturato all'apply (@applied[:snapshot]), che è
    # sempre "ciò che il modello aveva un istante prima che lo toccassimo" —
    # robusto anche se l'utente ha cambiato i materiali base dopo la
    # registrazione della variante.
    module Variants
      module_function

      VARIANT_KEY = 'color_variant'.freeze

      # Stato RAM della variante attualmente applicata al modello:
      #   { model_oid:, uid:, snapshot: { pid(int) => base_mat_name|nil } }
      @applied = nil
      @last_report = []

      def applied_uid
        @applied ? @applied[:uid] : nil
      end

      def last_report
        @last_report
      end

      def model
        Sketchup.active_model
      end

      # ===========================================================
      # Storage (page attribute)
      # ===========================================================

      # Lista override della pagina: [{ 'pid'=>int, 'mat'=>str|nil,
      # 'base'=>str|nil }, ...]. [] se la scena non ha variante.
      def overrides_for(page)
        return [] unless page
        raw = page.get_attribute(PLUGIN_ID, VARIANT_KEY, nil)
        return [] if raw.nil? || raw.to_s.empty?
        data = JSON.parse(raw) rescue nil
        return [] unless data.is_a?(Hash) && data['overrides'].is_a?(Array)
        data['overrides'].select { |o| o.is_a?(Hash) && o['pid'].to_i > 0 }
      rescue => e
        warn "[SM+] Variants.overrides_for: #{e.class}: #{e.message}"
        []
      end

      def has_variant?(page)
        !overrides_for(page).empty?
      end

      # Scrive la lista override sulla pagina (usata dalla UI Fase V2 e dai
      # test). Lista vuota/nil = rimuove la variante. Un solo page attribute
      # write per chiamata (regola observer terzi). Operazione NON transparent:
      # definire/cancellare una variante è un'azione esplicita dell'utente,
      # deve essere undoable.
      def set_overrides(page, list)
        m = model
        return false unless m && page
        clean = Array(list).map { |o|
          next nil unless o.is_a?(Hash)
          pid = (o['pid'] || o[:pid]).to_i
          next nil unless pid > 0
          mat  = o.key?('mat')  ? o['mat']  : o[:mat]
          base = o.key?('base') ? o['base'] : o[:base]
          { 'pid' => pid,
            'mat'  => mat.nil?  ? nil : mat.to_s,
            'base' => base.nil? ? nil : base.to_s }
        }.compact
        m.start_operation('SM+ Edit color variant', true)
        begin
          write_overrides_raw(page, clean)
          m.commit_operation
          true
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.set_overrides: #{e.class}: #{e.message}"
          false
        end
      end

      # Write raw del page attribute (nessuna start_operation: il chiamante
      # wrappa). Un solo set_attribute per chiamata (regola observer terzi).
      def write_overrides_raw(page, list)
        payload = list.empty? ? '' : JSON.generate({ 'v' => 1, 'overrides' => list })
        page.set_attribute(PLUGIN_ID, VARIANT_KEY, payload)
      end

      def clear_variant(page)
        set_overrides(page, [])
      end

      # ===========================================================
      # Editing (usato dalla schermata "Color variant", Fase V2)
      # ===========================================================
      #
      # Tutte le funzioni qui sotto presuppongono che la scena di contesto
      # sia stata ATTIVATA prima (il dialog lo fa in show_for via select_page,
      # che passa da on_scene_activated): quindi @applied è nil (scena senza
      # variante) oppure punta alla scena stessa. Gestiamo comunque in modo
      # difensivo il caso "variante di un'altra scena applicata".

      # Registra/aggiorna gli override per le entità della selezione viewport
      # corrente e li applica subito (feedback live).
      # mat_name: nome materiale del modello, oppure nil = rimuovi materiale.
      # Ritorna [count, report].
      def record_from_selection(page, mat_name)
        m = model
        return [0, ['no model']] unless m && page
        targets = m.selection.to_a.select do |e|
          e.respond_to?(:material=) && (e.persistent_id.to_i > 0 rescue false)
        end
        return [0, ['Nothing selected in the viewport.']] if targets.empty?
        record_entities(page, targets, mat_name)
      end

      # Come sopra ma partendo da una lista di pid (usato dal cambio materiale
      # per-row nel dialog).
      def record_pids(page, pids, mat_name)
        m = model
        return [0, ['no model']] unless m && page
        clean = Array(pids).map { |p| p.to_i }.select { |p| p > 0 }
        return [0, []] if clean.empty?
        ents = m.find_entity_by_persistent_id(clean)
        targets = Array(ents).compact.select { |e| !e.deleted? && e.respond_to?(:material=) }
        return [0, ['entity not found']] if targets.empty?
        record_entities(page, targets, mat_name)
      end

      def record_entities(page, entities, mat_name)
        m = model
        report = []
        target = nil
        unless mat_name.nil?
          target = m.materials[mat_name.to_s]
          return [0, ["Material '#{mat_name}' not found in model."]] unless target
        end
        uid = SceneModel.page_id(page)
        by_pid = {}
        overrides_for(page).each { |o| by_pid[o['pid']] = o }
        count = 0
        m.start_operation('SM+ Color variant edit', true)
        begin
          # Difensivo: se è applicata la variante di un'ALTRA scena (non
          # dovrebbe succedere col dialog che attiva la scena), ripristinala
          # prima di toccare i materiali, sennò registreremmo i suoi colori
          # come base.
          @applied = nil if @applied && @applied[:model_oid] != m.object_id
          restore_pairs!(m, report) if @applied && @applied[:uid] != uid
          snapshot = @applied ? @applied[:snapshot] : {}
          entities.each do |e|
            pid = (e.persistent_id.to_i rescue 0)
            next if pid <= 0
            existing = by_pid[pid]
            # 'base' persistito: quello registrato la prima volta. Per pid
            # nuovi = materiale corrente (la variante applicata non li ha
            # toccati, quindi il corrente E' il base).
            base = existing ? existing['base']
                            : (e.material ? e.material.name.to_s : nil)
            # Snapshot RAM: mai sovrascrivere una entry esistente (contiene
            # il vero pre-apply); per pid nuovi il corrente è il base.
            unless snapshot.key?(pid)
              snapshot[pid] = e.material ? e.material.name.to_s : nil
            end
            by_pid[pid] = { 'pid' => pid,
                            'mat'  => mat_name.nil? ? nil : mat_name.to_s,
                            'base' => base }
            e.material = target if e.material != target
            count += 1
          end
          write_overrides_raw(page, by_pid.values)
          m.commit_operation
          @applied = { model_oid: m.object_id, uid: uid, snapshot: snapshot }
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.record_entities: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          return [0, ["error: #{e.message}"]]
        end
        @last_report = report
        [count, report]
      end

      # Rimuove un singolo override: ripristina l'entità al base (se la
      # variante è attualmente applicata) e aggiorna storage + snapshot.
      def remove_override(page, pid)
        m = model
        pid = pid.to_i
        return false unless m && page && pid > 0
        ovs = overrides_for(page)
        keep = ovs.reject { |o| o['pid'] == pid }
        return false if keep.length == ovs.length
        uid = SceneModel.page_id(page)
        report = []
        m.start_operation('SM+ Remove variant override', true)
        begin
          # Restore solo se la variante di QUESTA scena è applicata: se non
          # lo è, l'entità è già al base — non toccarla.
          if @applied && @applied[:model_oid] == m.object_id &&
             @applied[:uid] == uid && @applied[:snapshot].key?(pid)
            base_name = @applied[:snapshot].delete(pid)
            e = m.find_entity_by_persistent_id(pid)
            if e && !e.deleted? && e.respond_to?(:material=)
              base = base_name ? m.materials[base_name] : nil
              if base_name && !base
                report << "restore pid=#{pid}: base material '#{base_name}' missing, left as-is"
              else
                e.material = base if e.material != base
              end
            end
            @applied = nil if @applied[:snapshot].empty? && keep.empty?
          end
          write_overrides_raw(page, keep)
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.remove_override: #{e.class}: #{e.message}"
          return false
        end
        @last_report = report
        true
      end

      # ===========================================================
      # Copy / paste variante tra scene (stesso modello)
      # ===========================================================
      #
      # Clipboard RAM di sessione (module var). Volutamente NON cross-file:
      # gli override referenziano persistent_id di entità di QUESTO modello,
      # in un altro file non significherebbero nulla.
      @clipboard = nil # { model_oid:, overrides: [...] }

      def copy_variant(page)
        ovs = overrides_for(page)
        return 0 if ovs.empty?
        m = model
        return 0 unless m
        @clipboard = { model_oid: m.object_id, overrides: ovs.map { |o| o.dup } }
        ovs.length
      end

      def clipboard?
        m = model
        !!(m && @clipboard && @clipboard[:model_oid] == m.object_id)
      end

      # Incolla la variante copiata sulla pagina target (sovrascrive quella
      # eventualmente presente). Se la pagina è quella attiva nel viewport,
      # ri-applica subito.
      def paste_variant(page)
        m = model
        return false unless m && page && clipboard?
        ok = set_overrides(page, @clipboard[:overrides].map { |o| o.dup })
        return false unless ok
        if m.pages.selected_page == page
          # Forza re-apply anche se @applied punta già a questa scena
          # (gli override sono appena cambiati).
          restore_applied!
          on_scene_activated(page)
        end
        true
      end

      # Igiene (Fase V4): rimuove gli override il cui pid non risolve più
      # a un'entità del modello (geometria cancellata/ricreata). Ritorna il
      # numero di override rimossi. Le entry corrispondenti nello snapshot
      # RAM vengono droppate (l'entità non esiste più, non c'è nulla da
      # ripristinare).
      def prune_missing(page)
        m = model
        return 0 unless m && page
        ovs = overrides_for(page)
        return 0 if ovs.empty?
        pids = ovs.map { |o| o['pid'] }
        ents = Array(m.find_entity_by_persistent_id(pids))
        keep = []
        removed_pids = []
        ovs.each_with_index do |o, i|
          e = ents[i]
          if e && !e.deleted?
            keep << o
          else
            removed_pids << o['pid']
          end
        end
        return 0 if removed_pids.empty?
        m.start_operation('SM+ Clean variant overrides', true)
        begin
          write_overrides_raw(page, keep)
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.prune_missing: #{e.class}: #{e.message}"
          return 0
        end
        if @applied && @applied[:model_oid] == m.object_id
          removed_pids.each { |pid| @applied[:snapshot].delete(pid) }
          @applied = nil if @applied[:snapshot].empty? && keep.empty?
        end
        puts "[SM+] Variants.prune_missing: removed #{removed_pids.length} orphan override(s) from '#{page.name}'"
        removed_pids.length
      end

      # Rimuove l'intera variante della scena, ripristinando i base se
      # attualmente applicata.
      def clear_and_restore(page)
        m = model
        return false unless m && page
        uid = SceneModel.page_id(page)
        report = []
        m.start_operation('SM+ Clear color variant', true)
        begin
          if @applied && @applied[:model_oid] == m.object_id && @applied[:uid] == uid
            restore_pairs!(m, report)
          end
          write_overrides_raw(page, [])
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.clear_and_restore: #{e.class}: #{e.message}"
          return false
        end
        @last_report = report
        report.each { |r| puts "[SM+] Variants: #{r}" }
        true
      end

      # ===========================================================
      # Motore apply / restore
      # ===========================================================

      # Entry point unico, chiamato quando una scena viene attivata (per ora
      # solo da SceneModel.select_page; polling/export/save = Fase V3).
      # Ripristina l'eventuale variante precedente e applica quella della
      # nuova scena — tutto in UNA transparent op (meno hit observer, atomico).
      def on_scene_activated(page)
        m = model
        return unless m && page
        uid = SceneModel.page_id(page)
        if @applied
          if @applied[:model_oid] != m.object_id
            # Cambio modello: lo snapshot punta a un modello che non è più
            # attivo — non possiamo ripristinarlo da qui. Drop (il vecchio
            # modello resta com'era; il caso save è Fase V3).
            warn "[SM+] Variants: dropping stale snapshot (model switched)"
            @applied = nil
          elsif @applied[:uid] == uid
            # Stessa scena riattivata: variante già applicata, no-op.
            # NON ricatturiamo lo snapshot: conterrebbe i colori variante
            # come "base" (snapshot pollution).
            return
          end
        end
        ovs = overrides_for(page)
        if ovs.empty?
          restore_applied!
          return
        end
        report = []
        m.start_operation('SM+ Color variant', true, false, true)
        begin
          restore_pairs!(m, report)
          snapshot = apply_pairs!(m, ovs, report)
          m.commit_operation
          @applied = { model_oid: m.object_id, uid: uid, snapshot: snapshot }
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.on_scene_activated: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          @applied = nil
        end
        @last_report = report
        report.each { |r| puts "[SM+] Variants: #{r}" }
        nil
      end

      # Ripristina i materiali base dello snapshot RAM (se presente) e pulisce
      # lo stato applied. Pubblico: servirà anche a pre-save/export (V3) e a
      # un eventuale bottone "Restore base colors".
      def restore_applied!
        return true unless @applied
        m = model
        unless m && @applied[:model_oid] == m.object_id
          @applied = nil
          return false
        end
        report = []
        m.start_operation('SM+ Color variant restore', true, false, true)
        begin
          restore_pairs!(m, report)
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.restore_applied!: #{e.class}: #{e.message}"
          @applied = nil
          return false
        end
        @last_report = report
        report.each { |r| puts "[SM+] Variants: #{r}" }
        true
      end

      # ===========================================================
      # Observer di salvataggio: il .skp salvato è SEMPRE stato "base"
      # ===========================================================
      #
      # Verificato via MCP su SU 2019 (2026-07-19): onPreSaveModel esiste,
      # è sincrono, e le mutazioni fatte lì dentro ENTRANO nel file salvato.
      # Flusso: pre-save → restore dei base (così chi apre il file senza il
      # plugin vede lo stato base, non l'ultima variante); post-save →
      # ri-applica la variante della scena attiva (il modello torna dirty
      # subito dopo il save — costo accettato).
      #
      # NB: in on_pre_save NIENTE start_operation (siamo dentro il save;
      # la mutazione diretta entra nel file comunque, verificato).

      class SaveObserver < ::Sketchup::ModelObserver
        def onPreSaveModel(model)
          Variants.on_pre_save(model)
        end

        def onPostSaveModel(model)
          Variants.on_post_save(model)
        end
      end

      class AppReattachObserver < ::Sketchup::AppObserver
        def onNewModel(model);  Variants.attach_save_observer(model); end
        def onOpenModel(model); Variants.attach_save_observer(model); end
        def expectsStartupModelNotifications; true; end
      end

      @save_observers = {}
      @app_observer   = nil
      @resume_uid     = nil

      # Chiamato una volta da main.rb allo startup. Idempotente.
      def install_observers!
        unless @app_observer
          @app_observer = AppReattachObserver.new
          ::Sketchup.add_observer(@app_observer)
        end
        attach_save_observer(Sketchup.active_model)
      rescue => e
        warn "[SM+] Variants.install_observers!: #{e.class}: #{e.message}"
      end

      def attach_save_observer(model)
        return unless model
        key = model.object_id
        return if @save_observers[key]
        obs = SaveObserver.new
        model.add_observer(obs)
        @save_observers[key] = obs
        puts "[SM+] Variants: save observer attached (model #{key})"
      rescue => e
        warn "[SM+] Variants.attach_save_observer: #{e.class}: #{e.message}"
      end

      def on_pre_save(model)
        return unless @applied && @applied[:model_oid] == model.object_id
        @resume_uid = @applied[:uid]
        report = []
        restore_pairs!(model, report)
        report.each { |r| puts "[SM+] Variants(pre-save): #{r}" }
        puts "[SM+] Variants: base restored before save (will re-apply '#{@resume_uid}')"
      rescue => e
        warn "[SM+] Variants.on_pre_save: #{e.class}: #{e.message}"
      end

      def on_post_save(model)
        uid = @resume_uid
        @resume_uid = nil
        return unless uid
        page = model.pages.find { |p| SceneModel.page_id(p) == uid }
        return unless page
        on_scene_activated(page)
        puts "[SM+] Variants: variant re-applied after save"
      rescue => e
        warn "[SM+] Variants.on_post_save: #{e.class}: #{e.message}"
      end

      # --- interni (nessuna start_operation: il chiamante wrappa) ---

      # Applica gli override e ritorna lo snapshot { pid => base_name|nil }
      # dei materiali che il modello aveva PRIMA dell'apply.
      def apply_pairs!(m, ovs, report)
        snapshot = {}
        pids = ovs.map { |o| o['pid'].to_i }
        ents = m.find_entity_by_persistent_id(pids)
        ovs.each_with_index do |o, i|
          e = ents[i]
          unless e && !e.deleted? && e.respond_to?(:material=)
            report << "override pid=#{pids[i]}: entity not found (deleted?), skipped"
            next
          end
          target = nil
          unless o['mat'].nil?
            target = m.materials[o['mat']]
            unless target
              report << "override pid=#{pids[i]}: material '#{o['mat']}' not found, skipped"
              next
            end
          end
          cur = e.material
          snapshot[pids[i]] = cur ? cur.name.to_s : nil
          # Diff-write (regola anti write-spuri, vedi CLAUDE.md crash MP)
          e.material = target if cur != target
        end
        snapshot
      end

      # Ripristina lo snapshot RAM corrente (se c'è) e lo azzera.
      def restore_pairs!(m, report)
        return unless @applied && @applied[:model_oid] == m.object_id
        snap = @applied[:snapshot]
        @applied = nil
        return if snap.nil? || snap.empty?
        pids = snap.keys
        ents = m.find_entity_by_persistent_id(pids)
        pids.each_with_index do |pid, i|
          e = ents[i]
          unless e && !e.deleted? && e.respond_to?(:material=)
            report << "restore pid=#{pid}: entity not found (deleted?), skipped"
            next
          end
          base_name = snap[pid]
          base = nil
          unless base_name.nil?
            base = m.materials[base_name]
            unless base
              # Il materiale base è sparito (purge?) mentre la variante era
              # attiva: non possiamo ripristinare fedelmente. Meglio lasciare
              # l'entità com'è e segnalare, che azzerarle il materiale.
              report << "restore pid=#{pid}: base material '#{base_name}' missing, left as-is"
              next
            end
          end
          e.material = base if e.material != base
        end
      end
    end
  end
end
