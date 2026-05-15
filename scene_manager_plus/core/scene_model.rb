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

      def logical_order
        stored = model.get_attribute(PLUGIN_ID, ORDER_KEY, nil)
        ids    = stored ? stored.dup : []
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

      def set_logical_order(ids)
        model.set_attribute(PLUGIN_ID, ORDER_KEY, ids)
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
                p = page_by_uid[sid]
                next nil unless p
                scene_hash(p, sid)
              }.compact
            }
          elsif (p = page_by_uid[id])
            scene_hash(p, id).merge(kind: 'scene')
          end
        end.compact
      end

      def scene_hash(page, uid)
        {
          id:          uid,
          name:        page.name.to_s,
          description: page.description.to_s,
          flags:       flags_hash(page)
        }
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
      def update_page(id, attrs)
        p = find_by_id(id)
        return false unless p
        model.start_operation('SM+ Update scene', true)
        begin
          p.name        = attrs['name']        if attrs['name']        && !attrs['name'].empty?
          p.description = attrs['description'] if attrs.key?('description')
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
          warn "[SM+] update_page: #{e.message}"
          false
        end
      end

      # Update scene da viewport corrente (come bottone "Update" nativo).
      def update_from_view(id)
        p = find_by_id(id)
        return false unless p
        # Page#update accetta una bitmask combinata di costanti PAGE_USE_*.
        # Usiamo i flag attualmente settati sulla pagina (getter con "?").
        mask = 0
        mask |= PAGE_USE_CAMERA              if p.use_camera?
        mask |= PAGE_USE_RENDERING_OPTIONS   if p.use_rendering_options?
        mask |= PAGE_USE_SHADOWINFO          if p.use_shadow_info?
        mask |= PAGE_USE_STYLE               if p.use_style?
        mask |= PAGE_USE_AXES                if p.use_axes?
        mask |= PAGE_USE_HIDDEN              if p.use_hidden?
        mask |= PAGE_USE_HIDDEN_LAYERS       if p.use_hidden_layers?
        mask |= PAGE_USE_SECTION_PLANES      if p.use_section_planes?
        mask = PAGE_USE_ALL if mask == 0
        model.start_operation('SM+ Update from view', true)
        p.update(mask)
        model.commit_operation
        true
      end

      def select_page(id)
        p = find_by_id(id)
        return false unless p
        model.pages.selected_page = p
        true
      end

      def delete_pages(ids)
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
