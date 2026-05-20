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

      # ID stabile della pagina basato su un attributo persistente.
      # Se manca lo crea (UUID semplice basato su time + rand).
      def page_id(page)
        id = page.get_attribute(PLUGIN_ID, 'uid')
        return id if id && !id.empty?
        new_id = "p#{Time.now.to_i}-#{rand(1 << 32).to_s(16)}"
        page.set_attribute(PLUGIN_ID, 'uid', new_id)
        new_id
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

      def set_logical_order(ids)
        if Buffer.deferred?
          Buffer.set_order(ids)
          return
        end
        write_order_raw(ids)
      end

      # Flat list di tutte le scene (root + dentro cartelle) per lookup in UI.
      def list_ordered
        pages.map.with_index do |p, i|
          {
            id:           page_id(p),
            native_index: i,
            name:         p.name.to_s,
            description:  p.description.to_s,
            flags:        flags_hash(p)
          }
        end
      end

      # Albero misto cartelle+scene, in ordine logico per il render UI.
      # In deferred mode, le pagine pending-delete sono nascoste.
      def tree
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
            attrs['flags'].each do |k, v|
              setter = "#{k}="
              p.send(setter, v) if FLAG_KEYS.include?(k) && p.respond_to?(setter)
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
      def update_from_view(id)
        p = find_by_id(id)
        unless p
          warn "[SM+] update_from_view: page not found id=#{id.inspect}"
          return false
        end
        # Page#update accetta una bitmask combinata di costanti PAGE_USE_*.
        # Usiamo i flag attualmente settati sulla pagina (getter con "?").
        # Le costanti PAGE_USE_* variano tra versioni di SketchUp. Faccio un
        # lookup difensivo: prendo il valore se la costante esiste, altrimenti 0.
        # Mappatura logica predicate → flag-name candidato:
        #   use_camera?         → CAMERA
        #   use_axes?           → CAMERA (gli assi seguono camera, no flag dedicato)
        #   use_rendering_options? → RENDERING_OPTIONS
        #   use_style?          → RENDERING_OPTIONS (style fa parte di rendering)
        #   use_shadow_info?    → SHADOWINFO
        #   use_hidden_layers?  → LAYER_VISIBILITY o HIDDEN_LAYERS
        #   use_hidden?         → HIDDEN_GEOMETRY o HIDDEN
        #   use_section_planes? → ACTIVE_SECTION_PLANES o SECTION_PLANES
        sc = lambda do |*names|
          names.each do |n|
            return Object.const_get(n) if Object.const_defined?(n)
          end
          0
        end
        mask = 0
        mask |= sc.call('PAGE_USE_CAMERA')                                  if p.use_camera? || p.use_axes?
        mask |= sc.call('PAGE_USE_RENDERING_OPTIONS')                       if p.use_rendering_options? || p.use_style?
        mask |= sc.call('PAGE_USE_SHADOWINFO')                              if p.use_shadow_info?
        mask |= sc.call('PAGE_USE_LAYER_VISIBILITY', 'PAGE_USE_HIDDEN_LAYERS') if p.use_hidden_layers?
        mask |= sc.call('PAGE_USE_HIDDEN_GEOMETRY', 'PAGE_USE_HIDDEN')       if p.use_hidden?
        mask |= sc.call('PAGE_USE_ACTIVE_SECTION_PLANES', 'PAGE_USE_SECTION_PLANES') if p.use_section_planes?
        if mask == 0
          all_const = sc.call('PAGE_USE_ALL')
          puts "[SM+] update_from_view: no flags resolved on '#{p.name}', fallback PAGE_USE_ALL=#{all_const}"
          mask = all_const
        end
        puts "[SM+] update_from_view: page='#{p.name}' mask=#{mask} flags=#{flags_hash(p).inspect}"
        model.start_operation('SM+ Update from view', true)
        result = p.update(mask)
        model.commit_operation
        puts "[SM+] update_from_view: page.update returned #{result.inspect}"
        true
      end

      # Crea una nuova scena dalla vista corrente (come "Add Scene" nativo).
      # Anche in defer mode crea immediatamente: pages.add è un'operazione SU
      # che dipende dallo stato corrente del modello/camera.
      def add_from_view(name = nil)
        m = model
        return nil unless m
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

        m.start_operation('SM+ New scene', true)
        begin
          page = m.pages.add(name.to_s)

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
          page
        rescue => e
          m.abort_operation
          warn "[SM+] add_from_view: #{e.class}: #{e.message}"
          nil
        end
      end

      def select_page(id)
        p = find_by_id(id)
        return false unless p
        model.pages.selected_page = p
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
