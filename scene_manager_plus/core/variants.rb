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
    #   { "v": 2,
    #     "overrides": [ { "pid": 9591,
    #                      "mat":  "Antracite",   # null = rimuovi materiale
    #                      "base": "Bianco" } ],  # null = nessun materiale
    #     "materials": [ { "name":  "Alba Butterfly - Struttura #383E42",
    #                      "color": "#F1EDE1",
    #                      "alpha": 1.0 } ] }     # null = non toccare
    # ("v": 1 = solo "overrides": si scrive ancora così quando "materials" è
    # vuota, e una build vecchia che riscrive una variante v2 ne perde i
    # "materials".)
    #
    # Due tipi di override nella stessa variante:
    # - "overrides": per PEZZO (pid → materiale). Per le eccezioni: geometria
    #   disegnata a mano, "solo questo pannello".
    # - "materials": per MATERIALE ("in questa scena X appare con questo
    #   colore"). Cambia l'aspetto del materiale, non tocca i pezzi: è il
    #   tipo che regge sui componenti che rigenerano la geometria. Vedi la
    #   sezione "Override di materiale" più sotto.
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
      #   { model_oid:, uid:,
      #     snapshot:     { pid(int) => base_mat_name|nil },
      #     mat_snapshot: { mat_name => { 'color' => [r,g,b], 'alpha' => f } } }
      # In mat_snapshot c'è solo quello che abbiamo toccato ('alpha' manca se
      # l'override non la cambia).
      #
      # `unless defined?` su tutto lo stato del modulo: un `load` a caldo di
      # questo file NON deve azzerarlo. Con una variante applicata si
      # perderebbe lo snapshot, e al salvataggio i colori della variante
      # finirebbero nel .skp come base.
      @applied = nil unless defined?(@applied)
      @last_report = [] unless defined?(@last_report)

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

      # Variante della pagina, sempre nella forma
      #   { 'overrides' => [ { 'pid'=>int, 'mat'=>str|nil, 'base'=>str|nil } ],
      #     'materials' => [ { 'name'=>str, 'color'=>'#RRGGBB', 'alpha'=>f|nil } ] }
      # con le liste vuote se la scena non ne ha.
      def read_variant(page)
        empty = { 'overrides' => [], 'materials' => [] }
        return empty unless page
        raw = page.get_attribute(PLUGIN_ID, VARIANT_KEY, nil)
        return empty if raw.nil? || raw.to_s.empty?
        data = JSON.parse(raw) rescue nil
        return empty unless data.is_a?(Hash)
        ovs  = data['overrides'].is_a?(Array) ? data['overrides'] : []
        mats = data['materials'].is_a?(Array) ? data['materials'] : []
        { 'overrides' => ovs.select { |o| o.is_a?(Hash) && o['pid'].to_i > 0 },
          'materials' => mats.map { |o| clean_material(o) }.compact }
      rescue => e
        warn "[SM+] Variants.read_variant: #{e.class}: #{e.message}"
        { 'overrides' => [], 'materials' => [] }
      end

      # Override per pezzo della pagina. [] se non ne ha.
      def overrides_for(page)
        read_variant(page)['overrides']
      end

      # Override di materiale della pagina. [] se non ne ha.
      def material_overrides_for(page)
        read_variant(page)['materials']
      end

      def has_variant?(page)
        v = read_variant(page)
        !(v['overrides'].empty? && v['materials'].empty?)
      end

      # Scrive la variante intera sulla pagina (usata da paste, clear e dai
      # test). Tutto vuoto = rimuove la variante. Un solo page attribute
      # write per chiamata (regola observer terzi). Operazione NON transparent:
      # definire/cancellare una variante è un'azione esplicita dell'utente,
      # deve essere undoable.
      def set_variant(page, overrides, materials)
        m = model
        return false unless m && page
        m.start_operation('SM+ Edit color variant', true)
        begin
          write_variant_raw(page, overrides, materials)
          m.commit_operation
          true
        rescue => e
          m.abort_operation
          warn "[SM+] Variants.set_variant: #{e.class}: #{e.message}"
          false
        end
      end

      # Sostituisce i soli override per pezzo (quelli di materiale restano).
      def set_overrides(page, list)
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
        set_variant(page, clean, material_overrides_for(page))
      end

      # Sostituisce i soli override di materiale (quelli per pezzo restano).
      def set_material_overrides(page, list)
        clean = Array(list).map { |o| clean_material(o) }.compact
        set_variant(page, overrides_for(page), clean)
      end

      # Write raw del page attribute (nessuna start_operation: il chiamante
      # wrappa). Un solo set_attribute per chiamata (regola observer terzi).
      def write_variant_raw(page, overrides, materials)
        payload =
          if overrides.empty? && materials.empty?
            ''
          elsif materials.empty?
            JSON.generate({ 'v' => 1, 'overrides' => overrides })
          else
            JSON.generate({ 'v' => 2, 'overrides' => overrides, 'materials' => materials })
          end
        page.set_attribute(PLUGIN_ID, VARIANT_KEY, payload)
      end

      def write_overrides_raw(page, list)
        write_variant_raw(page, list, material_overrides_for(page))
      end

      def write_materials_raw(page, list)
        write_variant_raw(page, overrides_for(page), list)
      end

      def clear_variant(page)
        set_variant(page, [], [])
      end

      # Normalizza un override di materiale; nil se non è valido.
      def clean_material(o)
        return nil unless o.is_a?(Hash)
        name  = (o['name'] || o[:name]).to_s
        color = normalize_hex(o['color'] || o[:color])
        return nil if name.empty? || color.nil?
        alpha = o.key?('alpha') ? o['alpha'] : o[:alpha]
        alpha = [[alpha.to_f, 0.0].max, 1.0].min unless alpha.nil?
        { 'name' => name, 'color' => color, 'alpha' => alpha }
      end

      # '#RRGGBB' maiuscolo, o nil.
      def normalize_hex(v)
        h = v.to_s.strip.sub(/\A#/, '')
        h =~ /\A[0-9a-fA-F]{6}\z/ ? "##{h.upcase}" : nil
      end

      def hex_to_rgb(hex)
        h = hex.to_s.sub('#', '')
        [h[0, 2].to_i(16), h[2, 2].to_i(16), h[4, 2].to_i(16)]
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
          mat_snapshot = @applied ? applied_mat_snapshot : {}
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
          @applied = { model_oid: m.object_id, uid: uid,
                       snapshot: snapshot, mat_snapshot: mat_snapshot }
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
            @applied = nil if @applied[:snapshot].empty? && applied_mat_snapshot.empty? &&
                              keep.empty? && material_overrides_for(page).empty?
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
      # Override di MATERIALE (2026-10-10)
      # ===========================================================
      #
      # "In questa scena il materiale X appare con questo colore": la variante
      # cambia l'ASPETTO del materiale (color/alpha) e lo rimette uscendo
      # dalla scena. Niente persistent_id, quindi regge sui componenti che
      # rigenerano la geometria: Componenti parametrici a ogni "Applica"
      # svuota e ricostruisce la definizione, e gli override per-pid dei pezzi
      # interni restano orfani (visto sul modello di prova: 13 su 14).
      #
      # Verificato via MCP su SU 2019 (19.0.685), 2026-10-10:
      # - Material#color= / #alpha= si vedono subito, anche in write_image;
      #   ~2 ms a materiale; il nome non cambia; abort_operation li annulla.
      # - color= su un materiale CON TEXTURE lo tinge (materialType 2), non
      #   la sostituisce → i materiali con texture si saltano con report.
      #   (Togliere e rimettere la texture si può — `texture = nil`, poi
      #   `texture = image_rep` + `texture.size=`, pixel identici — ma si
      #   perde `texture.filename`: non implementato.)
      # - I generatori di Componenti parametrici a ogni rigenerazione fanno
      #   `m.color = <colore base>`: con una variante attiva la cancellano dal
      #   viewport → `reapply!`, che Componenti chiama a fine callback.
      #
      # Limite noto: quei generatori mettono il colore nel NOME del materiale
      # ("... Struttura #383E42"). Cambiando il colore base del componente
      # nasce un materiale nuovo e l'override resta puntato su quello vecchio.

      # Registra/aggiorna l'override di un materiale. Se la scena è quella
      # nel viewport lo applica subito (feedback live); altrimenti lo salva e
      # basta. color: '#RRGGBB'; alpha: 0..1, nil = non toccare.
      # merge: true = transparent op, si fonde con l'operazione precedente
      # (la finestra lo usa per chiudere un giro di anteprime in 1 Ctrl+Z).
      # Ritorna [ok, report].
      def record_material(page, name, color, alpha = nil, merge: false)
        m = model
        return [false, ['no model']] unless m && page
        entry = clean_material('name' => name, 'color' => color, 'alpha' => alpha)
        return [false, ["Invalid color '#{color}'."]] unless entry
        mat = m.materials[entry['name']]
        return [false, ["Material '#{name}' not found in model."]] unless mat
        return [false, ["Material '#{name}' has a texture: not supported."]] if mat.texture
        uid  = SceneModel.page_id(page)
        list = material_overrides_for(page).reject { |o| o['name'] == entry['name'] }
        list << entry
        live = m.pages.selected_page == page
        same = !!(@applied && @applied[:model_oid] == m.object_id && @applied[:uid] == uid)
        report = []
        m.start_operation('SM+ Color variant edit', true, false, merge)
        begin
          apply_materials!(m, [entry], report, applied_mat_snapshot) if live && same
          write_materials_raw(page, list)
          m.commit_operation
        rescue => e
          # Mai abort su una transparent op (vedi on_scene_activated).
          merge ? m.commit_operation : m.abort_operation
          warn "[SM+] Variants.record_material: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          return [false, ["error: #{e.message}"]]
        end
        # Scena nel viewport ma variante non (ancora) applicata: giro completo
        # (ripristina l'eventuale variante di un'altra scena, applica questa).
        # È una transparent op: si aggancia a quella qui sopra, 1 Ctrl+Z.
        on_scene_activated(page) if live && !same
        @last_report = report
        [true, report]
      end

      # Rimuove l'override di un materiale: gli rimette l'aspetto base (se la
      # variante è attualmente applicata) e aggiorna storage + snapshot.
      def remove_material_override(page, name, merge: false)
        m = model
        name = name.to_s
        return false unless m && page
        list = material_overrides_for(page)
        keep = list.reject { |o| o['name'] == name }
        return false if keep.length == list.length
        uid = SceneModel.page_id(page)
        report = []
        m.start_operation('SM+ Remove variant override', true, false, merge)
        begin
          if @applied && @applied[:model_oid] == m.object_id &&
             @applied[:uid] == uid && applied_mat_snapshot.key?(name)
            restore_materials!(m, { name => applied_mat_snapshot.delete(name) }, report)
            @applied = nil if @applied[:snapshot].empty? && applied_mat_snapshot.empty? &&
                              keep.empty? && overrides_for(page).empty?
          end
          write_materials_raw(page, keep)
          m.commit_operation
        rescue => e
          # Mai abort su una transparent op (vedi on_scene_activated).
          merge ? m.commit_operation : m.abort_operation
          warn "[SM+] Variants.remove_material_override: #{e.class}: #{e.message}"
          return false
        end
        @last_report = report
        true
      end

      # Anteprima dal vivo mentre si sceglie il colore nella finestra: cambia
      # l'aspetto del materiale e basta. Niente page attribute: un write per
      # ogni movimento del mouse costa caro sui modelli con observer terzi;
      # lo scrive record_material alla conferma. Lo snapshot ricorda il base,
      # quindi anche un'anteprima mai confermata torna a posto al cambio
      # scena o al salvataggio (o subito, con resync_materials!).
      # Solo sulla scena nel viewport. merge: vedi record_material.
      def preview_material(page, name, color, alpha = nil, merge: false)
        m = model
        return false unless m && page && m.pages.selected_page == page
        entry = clean_material('name' => name, 'color' => color, 'alpha' => alpha)
        return false unless entry
        mat = m.materials[entry['name']]
        return false unless mat && !mat.texture
        uid = SceneModel.page_id(page)
        @applied = nil if @applied && @applied[:model_oid] != m.object_id
        # Applicata la variante di un'altra scena: non dovrebbe succedere (la
        # finestra attiva la scena), e qui non è il posto per rimetterla.
        return false if @applied && @applied[:uid] != uid
        @applied ||= { model_oid: m.object_id, uid: uid, snapshot: {}, mat_snapshot: {} }
        ok = true
        m.start_operation('SM+ Color variant edit', true, false, merge)
        begin
          apply_materials!(m, [entry], [], applied_mat_snapshot)
          m.commit_operation
        rescue => e
          merge ? m.commit_operation : m.abort_operation
          warn "[SM+] Variants.preview_material: #{e.class}: #{e.message}"
          ok = false
        end
        ok
      end

      # Riallinea i materiali della variante applicata a quello che è SALVATO
      # nella scena: un'anteprima mai confermata torna al colore salvato, o
      # al base se per quel materiale non c'è override.
      def resync_materials!(page)
        m = model
        return false unless m && page && @applied && @applied[:model_oid] == m.object_id
        return false unless @applied[:uid] == SceneModel.page_id(page)
        stored = material_overrides_for(page)
        snap = applied_mat_snapshot
        orphans = snap.keys - stored.map { |o| o['name'] }
        report = []
        m.start_operation('SM+ Color variant', true, false, true)
        begin
          apply_materials!(m, stored, report, snap)
          unless orphans.empty?
            back = {}
            orphans.each { |n| back[n] = snap.delete(n) }
            restore_materials!(m, back, report)
          end
        rescue => e
          warn "[SM+] Variants.resync_materials!: #{e.class}: #{e.message}"
        ensure
          # Mai abort su una transparent op (vedi on_scene_activated).
          m.commit_operation
        end
        @applied = nil if @applied[:snapshot].empty? && snap.empty? &&
                          stored.empty? && overrides_for(page).empty?
        true
      end

      # Colore base (quello vero) di un materiale, '#RRGGBB' o nil se non
      # c'è: se una variante applicata l'ha toccato è quello dello snapshot,
      # altrimenti quello che ha adesso.
      def base_color(name)
        m = model
        return nil unless m
        if @applied && @applied[:model_oid] == m.object_id
          was = applied_mat_snapshot[name.to_s]
          return rgb_to_hex(was['color']) if was && was['color']
        end
        mat = m.materials[name.to_s]
        mat ? rgb_to_hex(mat.color.to_a[0, 3]) : nil
      end

      def rgb_to_hex(rgb)
        format('#%02X%02X%02X', *rgb)
      end

      # Ri-afferma gli override di materiale della variante applicata. Serve
      # a chi riscrive i colori dei materiali mentre una variante è attiva (i
      # generatori di Componenti parametrici, a ogni rigenerazione). Quello
      # che trova diverso lo prende come nuovo aspetto base. Zero-write se
      # niente è cambiato. Ritorna il numero di materiali riallineati.
      def reapply!
        m = model
        return 0 unless m && @applied && @applied[:model_oid] == m.object_id
        page = m.pages.find { |p| SceneModel.page_id(p) == @applied[:uid] }
        return 0 unless page
        drift = material_overrides_for(page).select { |o| material_drifted?(m, o) }
        return 0 if drift.empty?
        report = []
        ok = true
        m.start_operation('SM+ Color variant', true, false, true)
        begin
          apply_materials!(m, drift, report, applied_mat_snapshot, true)
        rescue => e
          warn "[SM+] Variants.reapply!: #{e.class}: #{e.message}"
          ok = false
        ensure
          # Mai abort su una transparent op (vedi on_scene_activated).
          m.commit_operation
        end
        return 0 unless ok
        @last_report = report
        report.each { |r| puts "[SM+] Variants: #{r}" }
        drift.length
      end

      # ===========================================================
      # Copy / paste variante tra scene (stesso modello)
      # ===========================================================
      #
      # Clipboard RAM di sessione (module var). Volutamente NON cross-file:
      # gli override per pezzo referenziano persistent_id di entità di QUESTO
      # modello, in un altro file non significherebbero nulla. (Quelli di
      # materiale vanno per nome e si potrebbero portare: non ancora fatto.)
      # { model_oid:, overrides: [...], materials: [...] }
      @clipboard = nil unless defined?(@clipboard)

      def copy_variant(page)
        v = read_variant(page)
        return 0 if v['overrides'].empty? && v['materials'].empty?
        m = model
        return 0 unless m
        @clipboard = { model_oid: m.object_id,
                       overrides: v['overrides'].map { |o| o.dup },
                       materials: v['materials'].map { |o| o.dup } }
        v['overrides'].length + v['materials'].length
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
        ok = set_variant(page,
                         @clipboard[:overrides].map { |o| o.dup },
                         Array(@clipboard[:materials]).map { |o| o.dup })
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
          @applied = nil if @applied[:snapshot].empty? && applied_mat_snapshot.empty? &&
                            keep.empty? && material_overrides_for(page).empty?
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
          write_variant_raw(page, [], [])
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
            # Stessa scena riattivata: variante già applicata.
            # NON ricatturiamo lo snapshot: conterrebbe i colori variante
            # come "base" (snapshot pollution). Solo i materiali a cui
            # qualcuno ha riscritto il colore (un Ctrl+Z che si è portato
            # via l'apply, un generatore) si riallineano: zero-write se sono
            # a posto.
            reapply!
            return
          end
        end
        v = read_variant(page)
        ovs  = v['overrides']
        movs = v['materials']
        if ovs.empty? && movs.empty?
          restore_applied!
          return
        end
        report = []
        snapshot = {}
        mat_snapshot = {}
        m.start_operation('SM+ Color variant', true, false, true)
        begin
          restore_pairs!(m, report)
          apply_pairs!(m, ovs, report, snapshot)
          apply_materials!(m, movs, report, mat_snapshot)
        rescue => e
          warn "[SM+] Variants.on_scene_activated: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
        ensure
          # MAI abort_operation su una transparent op: annulla anche
          # l'operazione PRECEDENTE, cioè l'ultima cosa fatta dall'utente
          # (verificato 2026-10-10). Si chiude tenendo quello che è stato
          # fatto: gli snapshot lo ricordano, quindi il ripristino funziona.
          m.commit_operation
          @applied = { model_oid: m.object_id, uid: uid,
                       snapshot: snapshot, mat_snapshot: mat_snapshot }
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
        ok = true
        m.start_operation('SM+ Color variant restore', true, false, true)
        begin
          restore_pairs!(m, report)
        rescue => e
          warn "[SM+] Variants.restore_applied!: #{e.class}: #{e.message}"
          @applied = nil
          ok = false
        ensure
          # Mai abort su una transparent op (vedi on_scene_activated).
          m.commit_operation
        end
        return false unless ok
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

      @save_observers = {}  unless defined?(@save_observers)
      @app_observer   = nil unless defined?(@app_observer)
      @resume_uid     = nil unless defined?(@resume_uid)

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
      def apply_pairs!(m, ovs, report, snapshot = {})
        # Una variante può avere solo override di materiale, e
        # find_entity_by_persistent_id([]) solleva ArgumentError.
        return snapshot if ovs.empty?
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

      # Snapshot dei materiali della variante applicata (stato creato da una
      # build precedente al 2026-10-10, sopravvissuto a un load a caldo, non
      # ha la chiave).
      def applied_mat_snapshot
        @applied[:mat_snapshot] ||= {}
      end

      # Applica gli override di materiale e ritorna lo snapshot
      # { name => { 'color' => [r,g,b], 'alpha' => f } } dell'aspetto che i
      # materiali avevano PRIMA. In `snapshot` una entry esistente non si
      # sovrascrive (contiene il vero pre-apply). Con `refresh` (reapply!)
      # un valore trovato diverso da quello della variante l'ha scritto
      # qualcun altro: è il nuovo base, e sostituisce quello ricordato.
      def apply_materials!(m, movs, report, snapshot = {}, refresh = false)
        movs.each do |o|
          name = o['name']
          mat = m.materials[name]
          unless mat
            report << "material '#{name}': not found, skipped"
            next
          end
          if mat.texture
            report << "material '#{name}': has a texture (not supported), skipped"
            next
          end
          rgb = hex_to_rgb(o['color'])
          cur = mat.color.to_a[0, 3]
          was = (snapshot[name] ||= {})
          was['color'] = cur if !was.key?('color') || (refresh && cur != rgb)
          # alpha: si tocca (e si ricorda) solo se l'override la cambia; se
          # non la cambia più, torna quella di prima.
          alpha = o['alpha']
          if alpha.nil?
            alpha = was.delete('alpha')
          elsif !was.key?('alpha') || (refresh && (mat.alpha - alpha).abs > 0.001)
            was['alpha'] = mat.alpha
          end
          write_appearance!(mat, rgb, alpha)
        end
        snapshot
      end

      def restore_materials!(m, snap, report)
        snap.each do |name, was|
          mat = m.materials[name]
          unless mat
            report << "restore material '#{name}': not found (purged/renamed?), skipped"
            next
          end
          if mat.texture
            # Gli hanno dato una texture mentre la variante era attiva:
            # color= la tingerebbe.
            report << "restore material '#{name}': has a texture now, left as-is"
            next
          end
          write_appearance!(mat, was['color'], was['alpha'])
        end
      end

      # Diff-write (regola anti write-spuri): nil = non toccare.
      def write_appearance!(mat, rgb, alpha)
        mat.color = Sketchup::Color.new(*rgb) if rgb && mat.color.to_a[0, 3] != rgb
        mat.alpha = alpha if alpha && (mat.alpha - alpha).abs > 0.001
      end

      def material_drifted?(m, o)
        mat = m.materials[o['name']]
        return false unless mat && !mat.texture
        return true if mat.color.to_a[0, 3] != hex_to_rgb(o['color'])
        !o['alpha'].nil? && (mat.alpha - o['alpha']).abs > 0.001
      end

      # Ripristina lo snapshot RAM corrente (se c'è) e lo azzera.
      def restore_pairs!(m, report)
        return unless @applied && @applied[:model_oid] == m.object_id
        snap = @applied[:snapshot]
        mat_snap = @applied[:mat_snapshot]
        @applied = nil
        restore_materials!(m, mat_snap, report) unless mat_snap.nil? || mat_snap.empty?
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
