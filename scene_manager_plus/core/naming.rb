module SceneManagerPlus
  module Core
    # Generazione nomi/numerazione scene secondo pattern utente.
    # Pattern: {prefix}{sep}{nnn}{sep}{scene_name}
    # Parti opzionali: prefix (mode=none) e scene_name (include_scene_name=false).
    # Il numero è sempre presente.
    module Naming
      module_function

      # Costruisce il nome per la scena `idx` (1-based) con il dato pattern.
      # `original_name` viene usato solo se include_scene_name è true.
      # `skp_title` viene usato se prefix_mode == 'skp_name'.
      def format(idx, original_name, skp_title, settings)
        pad      = (settings['pad'] || 2).to_i
        pad      = 0 if pad < 0
        pad      = 6 if pad > 6
        sep      = (settings['separator'] || '_').to_s
        number   = idx.to_s.rjust(pad, '0')

        prefix = case settings['prefix_mode']
                 when 'custom'   then (settings['prefix_custom'] || '').to_s.strip
                 when 'skp_name' then sanitize(skp_title.to_s)
                 else ''
                 end

        parts = []
        parts << prefix unless prefix.empty?
        parts << number
        parts << original_name.to_s if settings['include_scene_name'] && !original_name.to_s.empty?
        parts.join(sep)
      end

      # Rimuove caratteri non adatti a nomi scena/file dal titolo SKP.
      def sanitize(s)
        s = s.to_s.gsub(/\.skp\z/i, '')
        s.gsub(/[\\\/\:\*\?\"\<\>\|\r\n\t]/, '').strip
      end

      # Restituisce un array di sample [{old:, new:}] usando le scene
      # del modello in ordine logico, espandendo le cartelle.
      def preview(settings, limit: 5)
        scenes = ordered_scene_pairs
        skp    = Sketchup.active_model ? Sketchup.active_model.title.to_s : ''
        scenes.first(limit).map.with_index(1) do |pair, i|
          { 'old' => pair[1], 'new' => format(i, pair[1], skp, settings) }
        end
      end

      # Applica il pattern a tutte le scene del modello (rinomina page.name).
      # Numerazione 1-based seguendo logical_order (cartelle espanse in ordine).
      # Defer-aware: in Buffer.deferred? va a buffer; altrimenti scrive subito.
      def apply_rename(settings)
        pairs = ordered_scene_pairs
        return 0 if pairs.empty?
        skp = Sketchup.active_model.title.to_s

        if Buffer.deferred?
          pairs.each_with_index do |(page, original_name), i|
            new_name = format(i + 1, original_name, skp, settings)
            next if new_name.empty? || new_name == page.name
            uid = SceneModel.page_id(page)
            Buffer.stage_page_edit(uid, 'name' => new_name)
          end
          return pairs.size
        end

        m = Sketchup.active_model
        m.start_operation('SM+ Rename to pattern', true)
        begin
          pairs.each_with_index do |(page, original_name), i|
            new_name = format(i + 1, original_name, skp, settings)
            next if new_name.empty?
            page.name = new_name unless page.name == new_name
          end
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] apply_rename: #{e.class}: #{e.message}"
          return 0
        end
        pairs.size
      end

      # Array di [page, name_at_apply_time] in ordine: ordine logico, ma
      # quando incontra una cartella ne emette i contenuti.
      # Salta le pagine pending-delete.
      def ordered_scene_pairs
        page_by_uid = SceneModel.pages.each_with_object({}) { |p, h| h[SceneModel.page_id(p)] = p }
        folders_by_id = Folders.all.each_with_object({}) { |f, h| h[f['id']] = f }
        out = []
        SceneModel.logical_order.each do |id|
          if (f = folders_by_id[id])
            Array(f['scene_ids']).each do |sid|
              next if Buffer.deleted?(sid)
              p = page_by_uid[sid]
              out << [p, p.name.to_s] if p
            end
          elsif (p = page_by_uid[id])
            next if Buffer.deleted?(id)
            out << [p, p.name.to_s]
          end
        end
        out
      end
    end
  end
end
