module SceneManagerPlus
  module Core
    # Wrapper sulle scene (Sketchup::Page) del modello attivo.
    # In Fase 1 espone solo lettura, riordino e proprietà di base.
    module SceneModel
      module_function

      def model
        Sketchup.active_model
      end

      def pages
        model.pages
      end

      # Restituisce array di hash serializzabili in JSON per la UI.
      def list
        ensure_all_uids(pages)
        pages.map.with_index do |p, i|
          {
            id:          page_id(p),
            index:       i,
            name:        p.name.to_s,
            description: p.description.to_s,
            flags:       flags_hash(p)
          }
        end
      end

      # ===========================================================
      # UID per Sketchup::Page — cache transient + persist lazy
      # ===========================================================
      #
      # Storia: i file con AttributeObserver di plugin terzi (es. Layers
      # Manager, plugin BIM, ecc.) pagano ~5s per ogni `set_attribute`
      # sul modello. Scrivere N uid all'apertura del file = 5N s di
      # freeze, anche batchando in start_operation: l'observer terzo
      # gira comunque per ogni write.
      #
      # Strategia attuale:
      # 1. `page_id(page)` legge l'attribute persistente. Se assente,
      #    usa una cache transient in RAM (sessione corrente). NESSUNA
      #    write avviene all'apertura del file.
      # 2. `persist_uids_for_ids(ids)` viene chiamato SOLO quando un
      #    uid deve sopravvivere a chiusura/riapertura del file: prima
      #    di scrivere `logical_order` (write_order_raw) o `folders`
      #    (Folders.write_raw). Persiste in batch (1 start_operation).
      # 3. Le interazioni read-only (visualizzazione lista, polling,
      #    export, properties dialog, ecc.) NON triggherano persistenza.
      #
      # Conseguenza UX: aprire un file su cui non si è mai interagito
      # col plugin → zero costo extra. Prima azione che modifica
      # folder/ordine → 1 freeze batch (~5s su file pesanti). Azioni
      # successive non triggerano altri freeze (uid già persistente).
      #
      # Cache leak: voci vecchie restano in RAM finché SU non chiude.
      # Su utenti che aprono molti modelli in sequenza la cache cresce.
      # Per N pagine totali nella vita SU è negligibile (stringa breve
      # per voce).
      @transient_uids = {}

      def page_id(page)
        id = page.get_attribute(PLUGIN_ID, 'uid')
        return id if id && !id.empty?
        m = (page.model rescue nil)
        # Senza un model di riferimento non possiamo dedup la cache
        # (page.object_id può collidere cross-model). Generiamo
        # transient one-shot non-cached.
        return generate_uid unless m
        k = [m.object_id, page.object_id]
        @transient_uids[k] ||= generate_uid
      end

      def generate_uid
        "p#{Time.now.to_i}-#{rand(1 << 32).to_s(16)}"
      end

      # Popola la cache transient per tutte le pagine prive di uid
      # persistente. NIENTE write su disco (vecchio comportamento
      # rimosso). Idempotente, gratis per le pagine già coperte da
      # persistent o cache.
      def ensure_all_uids(pages_iter = nil)
        m = model
        return unless m
        pages_iter ||= m.pages
        m_oid = m.object_id
        filled = 0
        pages_iter.each do |p|
          persistent = p.get_attribute(PLUGIN_ID, 'uid')
          next if persistent && !persistent.empty?
          k = [m_oid, p.object_id]
          next if @transient_uids[k]
          @transient_uids[k] = generate_uid
          filled += 1
        end
        puts "[SM+] ensure_all_uids: cached #{filled} transient uid(s) in RAM" if filled > 0
      end

      # Persistenza lazy: per ogni uid in `uids` cerca la page con
      # quell'uid (persistente o transient) e ci scrive l'attributo se
      # mancante. Tutto in 1 start_operation. Da chiamare prima di
      # scritture su disco che usano uid come chiave di riferimento
      # (logical_order, folder.scene_ids).
      def persist_uids_for_ids(uids)
        return if uids.nil?
        m = model
        return unless m
        wanted = uids.compact.reject { |s| s.respond_to?(:empty?) && s.empty? }
        return if wanted.empty?
        wanted_set = {}
        wanted.each { |u| wanted_set[u] = true }
        m_oid = m.object_id
        to_persist = []
        m.pages.each do |p|
          persistent = p.get_attribute(PLUGIN_ID, 'uid')
          next if persistent && !persistent.empty? # già persistito
          # Determina l'uid corrente (transient se c'è, sennò genera)
          k = [m_oid, p.object_id]
          current = @transient_uids[k] ||= generate_uid
          to_persist << [p, current] if wanted_set[current]
        end
        return if to_persist.empty?
        began = false
        begin
          m.start_operation('SM+ Persist page uids', true, false, true)
          began = true
          to_persist.each { |p, uid| p.set_attribute(PLUGIN_ID, 'uid', uid) }
          m.commit_operation
          puts "[SM+] persist_uids_for_ids: persisted #{to_persist.size} uid(s) in 1 op"
        rescue => e
          m.abort_operation if began
          warn "[SM+] persist_uids_for_ids failed: #{e.class}: #{e.message}"
        end
      end

      def find_by_id(id)
        pages.find { |p| page_id(p) == id }
      end

      FLAG_KEYS = %w[
        use_camera use_hidden use_hidden_layers use_style
        use_shadow_info use_axes use_section_planes use_rendering_options
      ].freeze

      def flags_hash(page)
        # API SketchUp: i getter dei flag finiscono con "?" (use_camera?),
        # i setter no (use_camera=). Vedi Sketchup::Page docs.
        FLAG_KEYS.each_with_object({}) { |k, h| h[k] = page.send("#{k}?") }
      end

      # Mapping stili del modello → lettera A,B,C... in ordine alfabetico.
      # Include TUTTI gli stili del modello (anche quelli non usati da scene).
      # Oltre la Z continua con AA, AB, ... ma in pratica un modello con >26
      # stili è patologico.
      def styles_map
        m = model
        return [] unless m && m.respond_to?(:styles) && m.styles
        # Ordiniamo per display_name (nickname o nativo) così la lettera
        # rispecchia ciò che l'utente vede nel plugin. Stabile a parità di
        # nome (rare).
        nick_dict  = m.attribute_dictionary(Core::Styles::NICKNAMES_DICT, false) rescue nil
        color_dict = m.attribute_dictionary(Core::Styles::COLORS_DICT, false)    rescue nil
        pairs = m.styles.map do |s|
          name = s.name.to_s
          nick = nick_dict ? nick_dict[name].to_s : ''
          [name, nick.empty? ? name : nick]
        end
        pairs.sort_by! { |(_, disp)| disp.downcase }
        pairs.each_with_index.map do |(name, disp), i|
          nick = nick_dict ? nick_dict[name].to_s : ''
          nick = nil if nick.empty?
          color = color_dict ? color_dict[name].to_s : ''
          color = nil if color.empty?
          { name: name, display_name: disp, nick: nick, color: color, letter: letter_for_index(i) }
        end
      rescue => e
        warn "[SM+] styles_map: #{e.class}: #{e.message}"
        []
      end

      def letter_for_index(i)
        s = ''
        i += 1
        while i > 0
          i -= 1
          s = ((('A'.ord) + (i % 26)).chr) + s
          i /= 26
        end
        s
      end

      # Nome dello stile assegnato alla scena, o nil se la pagina non espone
      # uno stile (raro su SU 2019, ma defensivo).
      def page_style_name(page)
        return nil unless page.respond_to?(:style)
        st = page.style
        st ? st.name.to_s : nil
      rescue
        nil
      end

      # True se la pagina è una scena Match Photo. SU 2019 Ruby API NON espone
      # Page#matchphoto? né Page#matchphoto, ma le camere Match Photo hanno
      # aspect_ratio != 0 perché il valore è esplicitamente settato per
      # matchare l'aspect della foto di sfondo. Le camere normali hanno
      # aspect_ratio = 0 (significa "usa aspect del viewport").
      # Verificato empiricamente: in un model con scene miste, solo la scena
      # MP aveva aspect_ratio != 0 — tutte le altre 0.0.
      def matchphoto?(page)
        return false unless page && page.respond_to?(:camera)
        c = page.camera
        return false unless c
        ratio = c.aspect_ratio.to_f rescue 0.0
        ratio != 0.0
      rescue
        false
      end

      # Sposta la pagina con uid `id` all'indice `target_index` (0-based).
      # Usa l'API ufficiale: pages.add_matchphoto/erase non vanno bene,
      # usiamo invece swap iterativo perché Pages non ha move diretto.
      # In SU 2019: Sketchup::Pages non ha #move. Workaround:
      #  1. ricordiamo proprietà della pagina, la cancelliamo
      #  2. la ricreiamo nella posizione voluta
      # Più pratico: ricostruiamo l'ordine con add/erase è invasivo.
      # SOLUZIONE: usiamo l'API model.pages.each con un riordino via
      # selected_page e... in realtà Pages NON espone un reorder pubblico.
      # Plan: implementiamo un "logical order" salvato negli attributi,
      # e applichiamo l'ordine reale solo quando l'utente preme "Sync to SketchUp".
      # Sync userà il trick: cancellare e ricreare le pagine nell'ordine voluto.
      # Per la Fase 1 lavoriamo solo sull'ordine logico.

      # Ordine logico salvato come array di id misti (scene uids + folder ids) nel modello.
      # Le scene dentro una cartella NON sono in logical_order: sono in folder['scene_ids'].
      ORDER_KEY = 'logical_order'.freeze

      # Raw read da SU (bypass buffer)
      def read_order_raw
        stored = model.get_attribute(PLUGIN_ID, ORDER_KEY, nil)
        stored ? stored.dup : []
      end

      # Raw write su SU (bypass buffer). Usato da Buffer.flush!
      def write_order_raw(ids)
        # Persiste eventuali uid transient referenziati: senza questo,
        # al riavvio del file gli ID nel logical_order non matchano
        # alcuna page (gli uid transient muoiono con la sessione SU).
        persist_uids_for_ids(ids)
        model.set_attribute(PLUGIN_ID, ORDER_KEY, ids)
      end

      def logical_order
        ids = if Buffer.deferred?
                Buffer.ensure_order!.dup
              else
                read_order_raw
              end
        actual_scene_ids = pages.map { |p| page_id(p) }
        folder_ids       = Core::Folders.all.map { |f| f['id'] }
        in_folder        = Core::Folders.scene_parent_map.keys
        # ids "validi" da avere in root: scene non in cartella + tutte le cartelle
        valid = (actual_scene_ids - in_folder) + folder_ids
        # rimuovi obsoleti, aggiungi nuovi in coda
        ids &= valid
        valid.each { |id| ids << id unless ids.include?(id) }
        ids
      end

      # Ordine "flat" delle scene come visualizzate dal plugin: espande le
      # cartelle nell'ordine logico. Usato per confronto con l'ordine nativo
      # dei tab SU (vedi native_order_divergent?).
      def flat_scene_order
        folders_by_id = Core::Folders.all.each_with_object({}) { |f, h| h[f['id']] = f }
        result = []
        logical_order.each do |id|
          if (f = folders_by_id[id])
            Array(f['scene_ids']).each { |sid| result << sid }
          else
            result << id
          end
        end
        result
      end

      # True se l'ordine delle pagine native SU diverge dall'ordine flat
      # mostrato dal plugin. In SU 2019 non c'è API per riordinare Pages,
      # quindi i tab nativi restano nell'ordine di creazione e questa
      # condizione si attiva non appena l'utente riordina nel plugin.
      # In defer mode evitiamo il check per non mostrare divergenze
      # transitorie su edit non ancora flushati.
      def native_order_divergent?
        return false if Buffer.deferred?
        native = pages.map { |p| page_id(p) }
        native != flat_scene_order
      rescue => e
        warn "[SM+] native_order_divergent?: #{e.class}: #{e.message}"
        false
      end

      # Snapshot unico per la main UI. Evita il percorso push_state storico
      # che ricostruiva list_ordered, tree, folders e native_order_divergent
      # con piu passaggi separati su pagine/cartelle/ordine.
      def ui_payload(show_order_banner: true)
        m = model
        return {
          scenes: [], tree: [], folders: [], active_id: nil,
          native_order_divergent: false,
          variant_clipboard: false,
          model_info: { title: '', pages_count: 0 }
        } unless m

        pages_arr = m.pages.to_a
        ensure_all_uids(pages_arr)

        folders_list = Core::Folders.all
        folders_by_id = {}
        in_folder = {}
        folders_list.each do |f|
          folders_by_id[f['id']] = f
          Array(f['scene_ids']).each { |sid| in_folder[sid] = f['id'] }
        end

        page_by_uid = {}
        scene_by_uid = {}
        scenes = []
        pages_arr.each_with_index do |p, i|
          uid = page_id(p)
          page_by_uid[uid] = p
          h = scene_hash(p, uid)
          scene_by_uid[uid] = h
          scenes << h.merge(native_index: i)
        end

        order = logical_order_from(
          read_order: Buffer.deferred? ? Buffer.ensure_order!.dup : read_order_raw,
          scene_ids: page_by_uid.keys,
          folders: folders_list,
          in_folder: in_folder
        )

        tree = order.map do |id|
          if (f = folders_by_id[id])
            {
              kind:     'folder',
              id:       id,
              name:     f['name'].to_s,
              color:    f['color'].to_s,
              expanded: !!f['expanded'],
              scenes:   Array(f['scene_ids']).map { |sid|
                next nil if Buffer.deleted?(sid)
                next nil unless page_by_uid[sid]
                scene_by_uid[sid]
              }.compact
            }
          elsif page_by_uid[id]
            next nil if Buffer.deleted?(id)
            scene_by_uid[id].merge(kind: 'scene')
          end
        end.compact

        active_pg = m.pages.selected_page
        active_id = active_pg ? page_id(active_pg) : nil
        divergent = false
        if show_order_banner && !Buffer.deferred?
          flat = []
          order.each do |id|
            if (f = folders_by_id[id])
              Array(f['scene_ids']).each { |sid| flat << sid }
            else
              flat << id
            end
          end
          divergent = page_by_uid.keys != flat
        end

        {
          scenes: scenes,
          tree: tree,
          folders: folders_list,
          active_id: active_id,
          native_order_divergent: divergent,
          variant_clipboard: Core::Variants.clipboard?,
          model_info: {
            title:       m.title.to_s,
            pages_count: pages_arr.length
          }
        }
      end

      def logical_order_from(read_order:, scene_ids:, folders:, in_folder:)
        ids = Array(read_order).dup
        folder_ids = folders.map { |f| f['id'] }
        valid = (scene_ids - in_folder.keys) + folder_ids
        ids &= valid
        valid.each { |id| ids << id unless ids.include?(id) }
        ids
      end

      def set_logical_order(ids)
        if Buffer.deferred?
          Buffer.set_order(ids)
          return
        end
        write_order_raw(ids)
      end

      # Flat list di tutte le scene (root + dentro cartelle) per lookup in UI.
      def list_ordered
        ensure_all_uids(pages)
        pages.map.with_index do |p, i|
          {
            id:              page_id(p),
            native_index:    i,
            name:            p.name.to_s,
            description:     p.description.to_s,
            flags:           flags_hash(p),
            export_included: export_included?(p),
            style_name:      page_style_name(p),
            color:           get_scene_color(page_id(p)),
            is_matchphoto:   matchphoto?(p),
            has_variant:     Core::Variants.has_variant?(p)
          }
        end
      end

      # Albero misto cartelle+scene, in ordine logico per il render UI.
      # In deferred mode, le pagine pending-delete sono nascoste.
      def tree
        ensure_all_uids(pages)
        folders_by_id = Core::Folders.all.each_with_object({}) { |f, h| h[f['id']] = f }
        page_by_uid   = pages.each_with_object({}) { |p, h| h[page_id(p)] = p }

        logical_order.map do |id|
          if (f = folders_by_id[id])
            {
              kind:     'folder',
              id:       id,
              name:     f['name'].to_s,
              color:    f['color'].to_s,
              expanded: !!f['expanded'],
              scenes:   Array(f['scene_ids']).map { |sid|
                next nil if Buffer.deleted?(sid)
                p = page_by_uid[sid]
                next nil unless p
                scene_hash(p, sid)
              }.compact
            }
          elsif (p = page_by_uid[id])
            next nil if Buffer.deleted?(id)
            scene_hash(p, id).merge(kind: 'scene')
          end
        end.compact
      end

      # Flag "include in batch export ALL" (default true). Vive come page
      # attribute → persiste nel .skp. Indipendente dai FLAG_KEYS nativi SU.
      EXPORT_INCLUDED_KEY = 'export_included'.freeze

      # Colore per-scena: mostrato come swatch a destra del nome e applicato
      # come background della row (sostituisce la selezione azzurra quando
      # impostato). Storage: dict 'SMP_scene_colors' su Sketchup.active_model,
      # key = uid scena, value = '#rrggbb'. Pattern allineato a Core::Styles
      # (get/set_color): un solo write per cambio = un solo hit
      # AttributeObserver, e nessuna scrittura per-page sotto polling.
      SCENE_COLORS_DICT = 'SMP_scene_colors'.freeze

      def get_scene_color(uid)
        m = model
        return nil unless m && uid
        v = m.get_attribute(SCENE_COLORS_DICT, uid.to_s, nil)
        return nil if v.nil?
        s = v.to_s.strip
        return nil if s.empty?
        s =~ /^#?[0-9a-fA-F]{6}$/ ? (s.start_with?('#') ? s.downcase : "##{s.downcase}") : nil
      end

      def set_scene_color(uid, hex)
        m = model
        return false unless m && uid
        key = uid.to_s
        s   = hex.to_s.strip
        if s.empty?
          m.set_attribute(SCENE_COLORS_DICT, key, '')
          return true
        end
        s = s.sub(/^#/, '')
        return false unless s =~ /^[0-9a-fA-F]{6}$/
        m.set_attribute(SCENE_COLORS_DICT, key, "##{s.downcase}")
        true
      end

      def export_included?(page)
        v = page.get_attribute(PLUGIN_ID, EXPORT_INCLUDED_KEY, true)
        v != false
      end

      def set_export_included(id, included)
        set_export_included_bulk([id], included)
      end

      def set_export_included_bulk(ids, included)
        targets = Array(ids).map { |i| find_by_id(i) }.compact
        return 0 if targets.empty?
        val = !!included
        model.start_operation('SM+ Toggle export include', true)
        begin
          targets.each { |p| p.set_attribute(PLUGIN_ID, EXPORT_INCLUDED_KEY, val) }
          model.commit_operation
          targets.size
        rescue => e
          model.abort_operation
          warn "[SM+] set_export_included_bulk: #{e.class}: #{e.message}"
          0
        end
      end

      def scene_hash(page, uid)
        h = {
          id:              uid,
          name:            page.name.to_s,
          description:     page.description.to_s,
          flags:           flags_hash(page),
          export_included: export_included?(page),
          style_name:      page_style_name(page),
          color:           get_scene_color(uid),
          is_matchphoto:   matchphoto?(page),
          has_variant:     Core::Variants.has_variant?(page),
          pending:         false
        }
        # Overlay buffer edits
        if (edit = Buffer.page_edit(uid))
          h[:name]        = edit['name']        if edit.key?('name')
          h[:description] = edit['description'] if edit.key?('description')
          h[:flags]       = h[:flags].merge(edit['flags']) if edit['flags'].is_a?(Hash)
          h[:pending]     = true
        end
        h
      end

      # Sposta `moving_ids` davanti a `before_id` nella destinazione `dest_folder_id`.
      # - moving_ids: array di uid scene e/o id cartelle
      # - before_id: id davanti al quale inserire (nella destinazione), oppure nil = in coda
      # - dest_folder_id: nil = root, altrimenti id cartella
      # Le cartelle non possono finire dentro un'altra cartella: vengono filtrate.
      def reorder(moving_ids, before_id, dest_folder_id)
        moving_ids = Array(moving_ids).uniq
        return if moving_ids.empty?

        folders_list = Core::Folders.all
        folder_id_set = folders_list.map { |f| f['id'] }

        # Se la destinazione è una cartella, scarta eventuali cartelle dal moving set
        if dest_folder_id
          moving_ids = moving_ids.reject { |id| folder_id_set.include?(id) }
          return if moving_ids.empty?
        end

        # 1) Rimuovi moving_ids ovunque siano (root + tutte le cartelle)
        order = logical_order - moving_ids
        folders_list.each do |f|
          f['scene_ids'] = Array(f['scene_ids']) - moving_ids
        end

        # 2) Inserisci nella destinazione
        if dest_folder_id.nil?
          idx = before_id ? (order.index(before_id) || order.length) : order.length
          order.insert(idx, *moving_ids)
        else
          dest = folders_list.find { |f| f['id'] == dest_folder_id }
          if dest
            sids = Array(dest['scene_ids'])
            idx = before_id ? (sids.index(before_id) || sids.length) : sids.length
            sids.insert(idx, *moving_ids)
            dest['scene_ids'] = sids
          else
            # destinazione inesistente: fallback a root
            order.concat(moving_ids)
          end
        end

        set_logical_order(order)
        Core::Folders.save(folders_list)
      end

      # Aggiorna proprietà page (rename / desc / flags).
      # In Buffer.deferred?: stage e basta. Altrimenti scrive su SU.
      def update_page(id, attrs)
        if Buffer.deferred?
          Buffer.stage_page_edit(id, attrs)
          return true
        end
        p = find_by_id(id)
        unless p
          warn "[SM+] update_page: page not found for id=#{id.inspect}"
          return false
        end
        old_name = p.name.to_s
        model.start_operation('SM+ Update scene', true)
        begin
          if attrs['name'] && !attrs['name'].to_s.empty? && attrs['name'].to_s != old_name
            p.name = attrs['name'].to_s
          end
          if attrs.key?('description')
            p.description = attrs['description'].to_s
          end
          if attrs['flags'].is_a?(Hash)
            mp = matchphoto?(p)
            attrs['flags'].each do |k, v|
              next unless FLAG_KEYS.include?(k)
              setter = "#{k}="
              next unless p.respond_to?(setter)
              v_bool  = v ? true : false
              current = p.send("#{k}?") ? true : false
              # MP guard: enabling use_style/use_rendering_options ("Style
              # and Fog") on a Match Photo scene puts MP into a state that
              # crashes SU on the next pages.selected_page = page. MP scene
              # owns its internal style (background photo) — toggling those
              # flags means "use the saved style", which on MP means trying
              # to override the MP style → corruption.
              if mp && v_bool && %w[use_style use_rendering_options].include?(k)
                warn "[SM+] update_page: skipping #{k}=true on Match Photo scene '#{p.name}' (would crash on activation)"
                next
              end
              # Scrivere flag già allineati corrompe le scene Match Photo
              # (writes spuri svegliano il subsystem C++; al successivo
              # pages.selected_page = page → BugSplat). Idem benefit lato
              # modelli con AttributeObserver di plugin terzi.
              p.send(setter, v_bool) if current != v_bool
            end
          end
          model.commit_operation
          true
        rescue => e
          model.abort_operation
          warn "[SM+] update_page: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          false
        end
      end

      # Update scene da viewport corrente (come bottone "Update" nativo).
      # only_keys: nil       → comportamento standard (tutti i flag use_*? attivi
      #                        sulla pagina vengono catturati).
      # only_keys: [keys...] → modalità "parziale": cattura solo le property
      #                        elencate (sottoinsieme di FLAG_KEYS). Ignora lo
      #                        stato corrente dei use_*? sulla pagina.
      def update_from_view(id, only_keys: nil)
        p = find_by_id(id)
        unless p
          warn "[SM+] update_from_view: page not found id=#{id.inspect}"
          return false
        end
        # Page#update accetta una bitmask combinata di costanti PAGE_USE_*.
        # Le costanti PAGE_USE_* variano tra versioni di SketchUp. Faccio un
        # lookup difensivo: prendo il valore se la costante esiste, altrimenti 0.
        # Mappatura verificata su SU 2019 19.3.253 (tools/dump-page-use.rb):
        #   use_camera?         → PAGE_USE_CAMERA (1)
        #   use_axes?           → PAGE_USE_CAMERA (1) — no costante dedicata in 2019
        #   use_rendering_options? → PAGE_USE_RENDERING_OPTIONS (2)
        #   use_style?          → PAGE_USE_SKETCHCS (8) — bit DEDICATO, non parte di RO
        #   use_shadow_info?    → PAGE_USE_SHADOWINFO (4)
        #   use_hidden_layers?  → PAGE_USE_LAYER_VISIBILITY (32)
        #   use_hidden?         → PAGE_USE_HIDDEN (16)
        #   use_section_planes? → PAGE_USE_SECTION_PLANES (64)
        sc = lambda do |*names|
          names.each do |n|
            return Object.const_get(n) if Object.const_defined?(n)
          end
          0
        end

        if only_keys.nil?
          keys = []
          keys << 'use_camera'             if p.use_camera?
          keys << 'use_axes'               if p.use_axes?
          keys << 'use_rendering_options'  if p.use_rendering_options?
          keys << 'use_style'              if p.use_style?
          keys << 'use_shadow_info'        if p.use_shadow_info?
          keys << 'use_hidden_layers'      if p.use_hidden_layers?
          keys << 'use_hidden'             if p.use_hidden?
          keys << 'use_section_planes'     if p.use_section_planes?
        else
          keys = only_keys.map(&:to_s)
        end

        mask = 0
        mask |= sc.call('PAGE_USE_CAMERA')                                  if keys.include?('use_camera')
        # Axes: tenta costante dedicata, se assente piggyback su CAMERA.
        mask |= sc.call('PAGE_USE_AXES', 'PAGE_USE_CAMERA')                 if keys.include?('use_axes')
        mask |= sc.call('PAGE_USE_RENDERING_OPTIONS')                       if keys.include?('use_rendering_options')
        # Style: tenta costanti dedicate (PAGE_USE_STYLE su SU recenti,
        # PAGE_USE_SKETCHCS su 2019). Se nessuna esiste, piggyback su
        # RENDERING_OPTIONS. Lo script tools/dump-page-use.rb permette di
        # verificare quali costanti esistono realmente nella versione SU.
        mask |= sc.call('PAGE_USE_STYLE', 'PAGE_USE_SKETCHCS', 'PAGE_USE_RENDERING_OPTIONS') if keys.include?('use_style')
        mask |= sc.call('PAGE_USE_SHADOWINFO')                              if keys.include?('use_shadow_info')
        mask |= sc.call('PAGE_USE_LAYER_VISIBILITY', 'PAGE_USE_HIDDEN_LAYERS') if keys.include?('use_hidden_layers')
        mask |= sc.call('PAGE_USE_HIDDEN_GEOMETRY', 'PAGE_USE_HIDDEN')       if keys.include?('use_hidden')
        mask |= sc.call('PAGE_USE_ACTIVE_SECTION_PLANES', 'PAGE_USE_SECTION_PLANES') if keys.include?('use_section_planes')
        if mask == 0
          if only_keys.nil?
            all_const = sc.call('PAGE_USE_ALL')
            puts "[SM+] update_from_view: no flags resolved on '#{p.name}', fallback PAGE_USE_ALL=#{all_const}"
            mask = all_const
          else
            puts "[SM+] update_from_view: partial mode with empty/unknown keys=#{only_keys.inspect}, nothing to do"
            return false
          end
        end

        # === Style "dirty" handling ===
        # In modalità standard scatta se la pagina ha use_style?; in modalità
        # parziale scatta se l'utente ha esplicitamente chiesto di aggiornare
        # 'use_style' (intent diretto, non gated dallo state della pagina).
        wants_style = keys.include?('use_style')
        style_bit = sc.call('PAGE_USE_STYLE', 'PAGE_USE_SKETCHCS')
        styles    = model.styles
        if wants_style && style_bit != 0 \
           && styles.respond_to?(:active_style_changed) \
           && styles.active_style_changed
          style_name = (styles.active_style.name rescue 'current')
          # MB_YESNOCANCEL=3, IDYES=6, IDNO=7, IDCANCEL=2 (costanti SU top-level).
          mb_const  = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
          id_yes    = Object.const_defined?(:IDYES) ? IDYES : 6
          id_no     = Object.const_defined?(:IDNO)  ? IDNO  : 7
          id_cancel = Object.const_defined?(:IDCANCEL) ? IDCANCEL : 2
          choice = ::UI.messagebox(
            "Style '#{style_name}' has unsaved changes.\n\n" \
            "YES = Update the selected style with the current modifications.\n" \
            "NO  = Save as a new style (you'll be prompted for a nickname).\n" \
            "CANCEL = Don't touch the style (scene captures other properties only).",
            mb_const
          )
          case choice
          when id_yes
            puts "[SM+] update_from_view: user chose 'Update selected style' for '#{style_name}'"
            begin
              styles.update_selected_style
            rescue => e
              warn "[SM+] update_selected_style failed: #{e.class}: #{e.message}"
            end
          when id_no
            puts "[SM+] update_from_view: user chose 'Save as new style' for '#{style_name}'"
            result = Core::Styles.prompt_nickname_loop(
              title: 'Scene Manager+ — Save as new style',
              label: 'Nickname (vuoto = usa nome nativo "SM+ Slot NN"):'
            )
            if result == :aborted
              puts "[SM+] update_from_view: save-as-new aborted by user"
              return false
            end
            new_style = Core::Styles.allocate_new_slot_from_viewport(
              nickname: (result.empty? ? nil : result)
            )
            unless new_style
              puts "[SM+] update_from_view: save-as-new failed (pool esaurito o errore)"
              return false
            end
            # Riassegna la scena al nuovo stile. assign_style già forza
            # use_style/use_rendering_options + page.update con i bit STYLE+RO,
            # quindi togliamo quei bit dal mask per evitare doppi update redondanti.
            assign_style(page_id(p), new_style.name)
            mask &= ~style_bit
            ro_bit = sc.call('PAGE_USE_RENDERING_OPTIONS')
            mask &= ~ro_bit if ro_bit != 0
          else
            # Cancel / chiusura dialog → preserva lo stile della scena come prima.
            # Rimuoviamo il bit di style dal mask: gli altri property si aggiornano,
            # lo stile no.
            puts "[SM+] update_from_view: user chose 'Don't touch style' — skipping style bit"
            mask &= ~style_bit
          end
        end

        puts "[SM+] update_from_view: page='#{p.name}' mask=#{mask} flags=#{flags_hash(p).inspect}"
        model.start_operation('SM+ Update from view', true)
        result = p.update(mask)
        model.commit_operation
        puts "[SM+] update_from_view: page.update returned #{result.inspect}"
        true
      end

      # Command ID Windows di "View > Animation > Add Scene", individuato con
      # tools/dump-su-menu.ps1. Override persistente:
      #   Sketchup.write_default('SceneManagerPlus', 'add_scene_cmd_id', N)
      WIN_ADD_SCENE_CMD_ID = 21067

      # Polling per attendere la pagina creata dal comando nativo (async).
      NATIVE_ADD_POLL_S    = 0.05
      NATIVE_ADD_MAX_TRIES = 60

      def add_scene_cmd_id
        Sketchup.read_default(
          'SceneManagerPlus', 'add_scene_cmd_id', WIN_ADD_SCENE_CMD_ID
        ).to_i
      end

      # Crea una nuova scena dalla vista corrente (come "Add Scene" nativo).
      # Anche in defer mode crea immediatamente: pages.add è un'operazione SU
      # che dipende dallo stato corrente del modello/camera.
      #
      # Il blocco opzionale riceve la Page creata (o nil se abortito/fallito).
      # Serve perche' il ramo Match Photo e' ASINCRONO: send_action accoda il
      # comando e la pagina non esiste ancora al ritorno di questo metodo.
      # Il valore di ritorno resta la Page solo nel ramo sincrono.
      def add_from_view(name = nil, &on_created)
        m = model
        finish = lambda { |pg| on_created.call(pg) if on_created; pg }
        return finish.call(nil) unless m

        # === Match Photo ===
        # pages.add() NON copia la foto Match Photo sulla nuova pagina: e' il
        # SOLO percorso che la perde. Il comando nativo "Add Scene" invece la
        # conserva, e -- verificato live su SU 19.3.253 il 2026-07-31 --
        # Sketchup.send_action(21067) colpisce lo stesso handler nativo del
        # click a mano sul menu: scena clone pixel-identica all'originale
        # (0 differenze su 47.000 campioni, foto ancora presente dopo essere
        # usciti e rientrati nella scena). La vecchia teoria dei "due binari
        # diversi" tra menu e send_action era sbagliata, e il messagebox di
        # rinuncia che stava qui non aveva ragione di esistere.
        # Vedi docs/SU2019-LESSONS.md, sezione "Match Photo".
        #
        # Detection euristica via Page#camera#aspect_ratio (vedi matchphoto?).
        active = m.pages.selected_page
        is_mp  = matchphoto?(active)

        # === Style "dirty" handling ===
        # Stesso dialog di update_from_view: se lo stile attivo ha modifiche
        # pending, pages.add cattura il riferimento allo stile ma le pending
        # restano in memoria dirty (non vengono persistite). Diamo all'utente
        # la stessa scelta del flusso nativo "Warning - Scenes and Styles".
        # Su scena Match Photo il dialog e' saltato di proposito: il ramo
        # "Save as new style" chiama allocate_new_slot_from_viewport, che fa
        # styles.selected_style = <nuovo slot> e cosi' sostituirebbe lo stile
        # interno che porta la foto (stessa ragione per cui assign_style ha un
        # guard MP). Il comando nativo gestisce lo stile MP per conto suo.
        styles = m.styles
        if !is_mp && styles.respond_to?(:active_style_changed) && styles.active_style_changed
          style_name = (styles.active_style.name rescue 'current')
          mb_const  = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
          id_yes    = Object.const_defined?(:IDYES) ? IDYES : 6
          id_no     = Object.const_defined?(:IDNO)  ? IDNO  : 7
          choice = ::UI.messagebox(
            "Style '#{style_name}' has unsaved changes.\n\n" \
            "YES = Update the selected style with the current modifications.\n" \
            "NO  = Save as a new style (you'll be prompted for a nickname).\n" \
            "CANCEL = Don't touch the style (new scene captures the saved style only).",
            mb_const
          )
          case choice
          when id_yes
            puts "[SM+] add_from_view: user chose 'Update selected style' for '#{style_name}'"
            begin
              styles.update_selected_style
            rescue => e
              warn "[SM+] update_selected_style failed: #{e.class}: #{e.message}"
            end
          when id_no
            puts "[SM+] add_from_view: user chose 'Save as new style' for '#{style_name}'"
            result = Core::Styles.prompt_nickname_loop(
              title: 'Scene Manager+ — Save as new style',
              label: 'Nickname (vuoto = usa nome nativo "SM+ Slot NN"):'
            )
            if result == :aborted
              puts "[SM+] add_from_view: save-as-new aborted by user"
              return finish.call(nil)
            end
            new_style = Core::Styles.allocate_new_slot_from_viewport(
              nickname: (result.empty? ? nil : result)
            )
            unless new_style
              puts "[SM+] add_from_view: save-as-new failed (pool esaurito o errore)"
              return finish.call(nil)
            end
            # Il nuovo slot è già selected_style (lo fa allocate_new_slot_from_viewport).
            # Procediamo con pages.add → la nuova page cattura selected_style =
            # new_style, quindi nasce legata al nuovo stile pulito.
            puts "[SM+] add_from_view: continuing with new style #{new_style.name.inspect}"
          else
            # Cancel → procediamo: la nuova scena cattura lo stile salvato
            # (le pending edit restano in memoria dirty, ignorate).
            puts "[SM+] add_from_view: user chose 'Don't touch style' — proceeding"
          end
        end

        active = m.pages.selected_page
        # Snapshot di layer.visible? PRIMA di pages.add. SU 2019 + Layers
        # Manager observer durante pages.add mutano il model: per i layer
        # "Add visible tag" (globally visible col tag attivo sulla active
        # page) l'observer li riporta a globally-hidden + li aggiunge alla
        # hidden list della nuova scena. Senza snapshot perderemmo lo stato
        # che il viewport sta effettivamente mostrando.
        # Vedi docs/SU2019-LESSONS.md, sezione "pages.add muta il model".
        pre_visible = {}
        m.layers.each { |l| pre_visible[l] = l.visible? }

        # Ramo Match Photo: delega al comando nativo, che e' l'unico a portarsi
        # dietro la foto. E' asincrono, quindi da qui in poi il lavoro prosegue
        # nel timer di add_from_view_native e questo metodo ritorna nil: la
        # Page arriva al chiamante solo attraverso il blocco on_created.
        return add_from_view_native(name, pre_visible, &on_created) if is_mp

        m.start_operation('SM+ New scene', true)
        begin
          page = m.pages.add(name.to_s)

          # Forza tutti i flag use_* a true sulla nuova page. pages.add
          # rispetta i "Default Scene Properties" globali di SU: se l'utente
          # li ha personalizzati (es. Style and Fog disattivato), la nuova
          # scena nascerebbe con quei flag OFF e SU non salverebbe quelle
          # parti di state. Forziamo tutto ON così la scena cattura
          # l'intero state del viewport.
          FLAG_KEYS.each do |k|
            setter = "#{k}="
            page.send(setter, true) if page.respond_to?(setter)
          rescue => e
            warn "[SM+] add_from_view: setting #{k}=true failed: #{e.message}"
          end

          # Ripristina il model state pre-add (caso AVT: LM observer ha
          # spento dei layer globalmente) e applica lo stesso state alla
          # nuova page tramite override. In caso di mismatch tra page
          # override stale e layer.visible? — drift causato da toggle
          # manuale dal Layer Manager — il viewport mostra layer.visible?,
          # quindi quella è la fonte di verità.
          pre_visible.each do |layer, was_visible|
            begin
              layer.visible = was_visible if layer.visible? != was_visible
            rescue
              # ignore, best-effort
            end
            begin
              page.set_visibility(layer, was_visible)
            rescue => e
              warn "[SM+] add_from_view: set_visibility failed for #{layer.name rescue '?'}: #{e.message}"
            end
          end

          page_id(page) # ensure uid attribute exists
          m.commit_operation
          finish.call(page)
        rescue => e
          m.abort_operation
          warn "[SM+] add_from_view: #{e.class}: #{e.message}"
          finish.call(nil)
        end
      end

      # Ramo Match Photo di add_from_view: invoca "View > Animation > Add
      # Scene" nativo, che e' l'unico percorso che clona anche la foto.
      #
      # ATTENZIONE: send_action e' ASINCRONO. Accoda il comando e ritorna
      # subito; nella stessa chiamata Ruby pages.count e' ancora quello di
      # prima (verificato: send_action ha ritornato true con pages ancora a 31,
      # la pagina e' comparsa solo al giro successivo del message pump). Per
      # questo il post-processing vive in un timer e non qui in linea.
      def add_from_view_native(name, pre_visible, &on_created)
        m = model
        unless m
          on_created.call(nil) if on_created
          return nil
        end

        before_ids = m.pages.map { |p| p.object_id }
        ok = begin
          ::Sketchup.send_action(add_scene_cmd_id)
        rescue => e
          warn "[SM+] add_from_view_native: send_action failed: #{e.class}: #{e.message}"
          false
        end

        unless ok
          warn "[SM+] add_from_view_native: send_action(#{add_scene_cmd_id}) refused"
          on_created.call(nil) if on_created
          return nil
        end

        await_native_page(before_ids, name, pre_visible, 0, &on_created)
        nil
      end

      # Polling della pagina creata dal comando nativo. Catena di timer da
      # NATIVE_ADD_POLL_S, come Previews.generate: un tick per tentativo, cosi'
      # CEF resta reattivo. Nessuna scrittura finche' la pagina non c'e'.
      def await_native_page(before_ids, name, pre_visible, attempt, &on_created)
        m = model
        fresh = m && m.pages.find { |p| !before_ids.include?(p.object_id) }

        if fresh.nil?
          if attempt >= NATIVE_ADD_MAX_TRIES
            warn "[SM+] add_from_view_native: nessuna pagina dopo #{attempt} tentativi"
            on_created.call(nil) if on_created
            return
          end
          ::UI.start_timer(NATIVE_ADD_POLL_S, false) do
            begin
              await_native_page(before_ids, name, pre_visible, attempt + 1, &on_created)
            rescue => e
              warn "[SM+] await_native_page: #{e.class}: #{e.message}"
            end
          end
          return
        end

        finalize_native_page(fresh, name, pre_visible)
        on_created.call(fresh) if on_created
      end

      # Allinea la pagina nata dal comando nativo a quello che il plugin si
      # aspetta da una scena creata da lui: nome, flag use_*, override di
      # visibilita' layer, uid.
      def finalize_native_page(page, name, pre_visible)
        m = model
        return unless m

        # transparent=true -> si aggancia all'operazione nativa "Add Scene",
        # cosi' un solo Ctrl+Z annulla scena e finalizzazione insieme.
        m.start_operation('SM+ New scene (finalize)', true, false, true)
        begin
          unless name.to_s.strip.empty?
            begin
              page.name = name.to_s.strip
            rescue => e
              # SU rifiuta i nomi duplicati: teniamo quello autogenerato.
              warn "[SM+] finalize_native_page: rename failed: #{e.message}"
            end
          end

          # Due precauzioni Match Photo, entrambe documentate:
          # 1) MAI scrivere un flag gia' allineato al valore corrente -> il
          #    subsystem MP marca lo stato dirty e la successiva attivazione
          #    della scena fa BugSplat (vedi CLAUDE.md, "Crash pattern");
          # 2) use_style / use_rendering_options restano fuori: toccarli su
          #    una scena MP sostituisce lo stile che porta la foto. Stessa
          #    esclusione del comando "Save all properties" in main.rb.
          keys = FLAG_KEYS - %w[use_style use_rendering_options]
          keys.each do |k|
            setter = "#{k}="
            next unless page.respond_to?(setter)
            current = page.send("#{k}?") ? true : false
            next if current == true
            begin
              page.send(setter, true)
            rescue => e
              warn "[SM+] finalize_native_page: setting #{k}=true failed: #{e.message}"
            end
          end

          # Stessa logica del ramo sincrono: la fonte di verita' e'
          # layer.visible? PRIMA della creazione della pagina.
          pre_visible.each do |layer, was_visible|
            begin
              layer.visible = was_visible if layer.visible? != was_visible
            rescue
              # ignore, best-effort
            end
            begin
              page.set_visibility(layer, was_visible)
            rescue => e
              warn "[SM+] finalize_native_page: set_visibility failed for #{layer.name rescue '?'}: #{e.message}"
            end
          end

          page_id(page) # ensure uid attribute exists
          m.commit_operation
          puts "[SM+] add_from_view_native: created '#{page.name}' (Match Photo preserved)"
        rescue => e
          m.abort_operation
          warn "[SM+] finalize_native_page: #{e.class}: #{e.message}"
        end
      end

      # Riassegna uno stile a una scena. Anche in defer mode l'operazione è
      # immediata: assegnare uno stile dipende dal qui-e-ora del viewport e
      # cambia model.styles.selected_style come effetto collaterale (come
      # update_from_view).
      #
      # Flusso:
      #   1) ricorda la pagina attualmente selezionata
      #   2) attiva la pagina target (così page.update() captura sul target)
      #   3) cambia model.styles.selected_style allo stile voluto
      #   4) page.update(PAGE_USE_STYLE | PAGE_USE_RENDERING_OPTIONS) cattura
      #   5) ripristina la pagina selezionata originale
      #
      # Side effect noto: se lo stile precedente era dirty, le modifiche
      # pending vengono perse (analogo al comportamento native SU). Per Fase B
      # accettiamo: l'utente che riassegna sa cosa sta facendo.
      def assign_style(page_uid, style_name)
        m = model
        return false unless m
        p = find_by_id(page_uid)
        unless p
          warn "[SM+] assign_style: page not found id=#{page_uid.inspect}"
          return false
        end
        target_style = m.styles.find { |s| s.name.to_s == style_name.to_s }
        unless target_style
          warn "[SM+] assign_style: style '#{style_name}' not found in model"
          return false
        end
        # Match Photo guard: page.update(STYLE|RO) su una scena MP corrompe
        # lo stile interno MP (background foto) → BugSplat. Anche se non
        # crashasse, sovrascrivere lo stile MP con uno normale toglie la
        # foto di sfondo. Blocchiamo con messagebox esplicativo.
        if matchphoto?(p)
          ::UI.messagebox(
            "Scene '#{p.name}' is a Match Photo scene.\n\n" \
            "Reassigning a regular style would remove the photo background " \
            "and can crash SketchUp. Operation cancelled."
          )
          return false
        end
        # Costanti PAGE_USE_* — lookup difensivo come in update_from_view
        sc = lambda do |*names|
          names.each { |n| return Object.const_get(n) if Object.const_defined?(n) }
          0
        end
        style_bit = sc.call('PAGE_USE_STYLE', 'PAGE_USE_SKETCHCS', 'PAGE_USE_RENDERING_OPTIONS')
        ro_bit    = sc.call('PAGE_USE_RENDERING_OPTIONS')
        mask = style_bit | ro_bit
        prev_page = m.pages.selected_page
        m.start_operation('SM+ Assign style', true)
        begin
          m.pages.selected_page = p
          m.styles.selected_style = target_style
          # Forza il flag use_style a true: senza, page.update con STYLE bit
          # non lega effettivamente lo stile alla scena (cfr. PAGE_USE_*).
          p.use_style = true if p.respond_to?(:use_style=)
          p.use_rendering_options = true if p.respond_to?(:use_rendering_options=)
          p.update(mask)
          m.pages.selected_page = prev_page if prev_page && prev_page != p
          m.commit_operation
          puts "[SM+] assign_style: page='#{p.name}' style='#{style_name}'"
          true
        rescue => e
          m.abort_operation
          warn "[SM+] assign_style: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          false
        end
      end

      def select_page(id)
        p = find_by_id(id)
        return false unless p
        # Per scene Match Photo: skip se già attiva — riassegnare la stessa
        # pagina MP con state dirty può scatenare un restore-cycle → BugSplat.
        # Per scene normali: permettiamo il re-assign anche se già attiva,
        # così l'utente può cliccare la scena corrente per ripristinare
        # camera/stile/layers allo stato salvato (= "ri-applica scena").
        return true if model.pages.selected_page == p && matchphoto?(p)
        model.pages.selected_page = p
        # Variante colore: ripristina l'eventuale variante precedente e
        # applica quella della scena attivata (no-op se nessuna delle due).
        Core::Variants.on_scene_activated(p)
        true
      end

      def delete_pages(ids)
        if Buffer.deferred?
          Buffer.mark_delete(ids)
          # Anche in deferred mode rimuoviamo le scene dalle cartelle/ordine
          # in modo che spariscano dalla lista. Le pagine SU restano finché flush.
          flist = Core::Folders.all
          changed = false
          flist.each do |f|
            before = Array(f['scene_ids'])
            after  = before - Array(ids)
            if after.length != before.length
              f['scene_ids'] = after
              changed = true
            end
          end
          Core::Folders.save(flist) if changed
          order = logical_order - Array(ids)
          set_logical_order(order)
          return Array(ids).size
        end
        targets = Array(ids).map { |i| find_by_id(i) }.compact
        return 0 if targets.empty?
        model.start_operation('SM+ Delete scenes', true)
        targets.each { |p| pages.erase(p) }
        model.commit_operation
        targets.size
      end
    end
  end
end
