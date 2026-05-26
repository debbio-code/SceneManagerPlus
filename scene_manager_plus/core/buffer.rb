module SceneManagerPlus
  module Core
    # Stato globale del "Deferred edit mode".
    # Quando attivo, le scritture di SceneModel / Folders vengono accumulate
    # in RAM invece di andare su SU. Flush! applica tutto in una sola
    # start_operation undoable.
    #
    # Eccezioni che restano immediate anche con deferred ON:
    # - SceneModel.select_page (navigazione viewport)
    # - SceneModel.update_from_view (cattura viewport at-click-time)
    module Buffer
      module_function

      @deferred       = false
      @page_edits     = {} # uid => { 'name'=>?, 'description'=>?, 'flags'=>{...} }
      @pending_delete = [] # array di uid
      @folders        = nil # snapshot di Folders.all, mutato dalle scritture
      @folders_dirty  = false
      @order          = nil # snapshot di logical_order
      @order_dirty    = false

      def deferred?
        @deferred
      end

      def enable!
        return if @deferred
        @deferred       = true
        @page_edits     = {}
        @pending_delete = []
        @folders        = nil
        @folders_dirty  = false
        @order          = nil
        @order_dirty    = false
      end

      # Esci dal defer mode senza applicare (usato dopo flush).
      def disable!
        @deferred       = false
        @page_edits     = {}
        @pending_delete = []
        @folders        = nil
        @folders_dirty  = false
        @order          = nil
        @order_dirty    = false
      end

      def pending_count
        return 0 unless @deferred
        c = @page_edits.size + @pending_delete.size
        c += 1 if @folders_dirty
        c += 1 if @order_dirty
        c
      end

      # --- page edits ---

      def page_edit(uid)
        @page_edits[uid]
      end

      def stage_page_edit(uid, attrs)
        return unless @deferred
        current = @page_edits[uid] || {}
        if attrs.key?('name') && attrs['name'].to_s.length > 0
          current['name'] = attrs['name'].to_s
        end
        if attrs.key?('description')
          current['description'] = attrs['description'].to_s
        end
        if attrs['flags'].is_a?(Hash)
          current['flags'] = (current['flags'] || {}).merge(attrs['flags'])
        end
        @page_edits[uid] = current
      end

      def page_edited?(uid)
        @page_edits.key?(uid) && !@page_edits[uid].empty?
      end

      def has_page_edits?
        !@page_edits.empty?
      end

      # --- pending deletes ---

      def mark_delete(uids)
        return unless @deferred
        Array(uids).each { |u| @pending_delete << u unless @pending_delete.include?(u) }
        # Se la pagina aveva edit pending, scartali (sarà cancellata)
        Array(uids).each { |u| @page_edits.delete(u) }
      end

      def deleted?(uid)
        @pending_delete.include?(uid)
      end

      def pending_deletes
        @pending_delete.dup
      end

      # --- folders snapshot ---

      def folders
        return nil unless @deferred
        @folders
      end

      # Carica lo snapshot se non già fatto (lazy). Restituisce il riferimento
      # vivo che i caller possono mutare. Chi muta DEVE chiamare mark_folders_dirty!.
      def ensure_folders!
        return nil unless @deferred
        if @folders.nil?
          @folders = Folders.read_raw.map { |f| deep_dup_hash(f) }
        end
        @folders
      end

      def set_folders(list)
        return unless @deferred
        @folders = list
        @folders_dirty = true
      end

      def mark_folders_dirty!
        @folders_dirty = true if @deferred
      end

      def folders_dirty?
        @folders_dirty
      end

      # --- order snapshot ---

      def order
        return nil unless @deferred
        @order
      end

      def ensure_order!
        return nil unless @deferred
        if @order.nil?
          @order = SceneModel.read_order_raw.dup
        end
        @order
      end

      def set_order(arr)
        return unless @deferred
        @order = Array(arr)
        @order_dirty = true
      end

      def order_dirty?
        @order_dirty
      end

      # --- flush ---

      # Applica tutto al modello in un'unica start_operation undoable.
      # Ritorna [edits_applied, deletes_applied].
      def flush!
        return [0, 0] unless @deferred
        m = Sketchup.active_model
        return [0, 0] unless m

        # snapshot dei buffer (li svuoto prima di applicare per evitare loop
        # se i metodi rebbe-aware fossero richiamati)
        edits        = @page_edits
        deletes      = @pending_delete
        folders_snap = @folders
        order_snap   = @order
        folders_d    = @folders_dirty
        order_d      = @order_dirty
        @deferred = false
        @page_edits = {}
        @pending_delete = []
        @folders = nil
        @folders_dirty = false
        @order = nil
        @order_dirty = false

        applied_edits   = 0
        applied_deletes = 0

        m.start_operation('SM+ Apply pending', true)
        begin
          # 1) edit nomi/desc/flag
          edits.each do |uid, attrs|
            page = SceneModel.find_by_id(uid)
            next unless page
            if attrs.key?('name') && !attrs['name'].to_s.empty? && page.name.to_s != attrs['name']
              page.name = attrs['name']
            end
            if attrs.key?('description')
              page.description = attrs['description'].to_s
            end
            if attrs['flags'].is_a?(Hash)
              mp = SceneModel.matchphoto?(page)
              attrs['flags'].each do |k, v|
                next unless SceneModel::FLAG_KEYS.include?(k)
                setter = "#{k}="
                next unless page.respond_to?(setter)
                v_bool  = v ? true : false
                current = page.send("#{k}?") ? true : false
                # MP guard: vedi SceneModel.update_page. use_style /
                # use_rendering_options = true su scena MP crasha
                # all'attivazione successiva.
                if mp && v_bool && %w[use_style use_rendering_options].include?(k)
                  warn "[SM+] Buffer.flush!: skipping #{k}=true on MP scene '#{page.name}'"
                  next
                end
                # Vedi SceneModel.update_page: writes spuri sui flag già
                # allineati crashano le scene Match Photo.
                page.send(setter, v_bool) if current != v_bool
              end
            end
            applied_edits += 1
          end

          # 2) delete pagine
          deletes.each do |uid|
            page = SceneModel.find_by_id(uid)
            next unless page
            m.pages.erase(page)
            applied_deletes += 1
          end

          # 3) folders snapshot (intero array)
          Folders.write_raw(folders_snap) if folders_d && folders_snap

          # 4) logical_order snapshot
          SceneModel.write_order_raw(order_snap) if order_d && order_snap

          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Buffer.flush! ERROR: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).join("\n")
        end

        [applied_edits, applied_deletes]
      end

      def deep_dup_hash(h)
        return h unless h.is_a?(Hash)
        h.each_with_object({}) do |(k, v), acc|
          acc[k] = v.is_a?(Hash) ? deep_dup_hash(v) :
                   v.is_a?(Array) ? v.map { |x| x.is_a?(Hash) ? deep_dup_hash(x) : x } :
                   v
        end
      end
    end
  end
end
