module SceneManagerPlus
  module Core
    # Cache di anteprime PNG per le scene. Le immagini vengono generate
    # esplicitamente dall'utente (bottone toolbar) e non si rigenerano in
    # automatico al cambiare del modello — restano in cache finché l'utente
    # non rigenera.
    module Previews
      module_function

      WIDTH        = 480
      HEIGHT       = 300

      # Root persistente cross-platform. ~/.scene_manager_plus/previews/<model_guid>/<uid>.png
      ROOT = File.join(Dir.home, '.scene_manager_plus', 'previews').freeze

      @cache       = {} # uid => absolute path
      @cache_model = nil

      # Identificatore stabile del modello. Sketchup::Model ha #guid in SU 2014+.
      def model_key
        m = Sketchup.active_model
        return 'no_model' unless m
        if m.respond_to?(:guid) && m.guid
          m.guid.to_s.gsub(/[^A-Za-z0-9_\-]/, '_')
        elsif m.path && !m.path.empty?
          # Fallback: hash del path
          require 'digest'
          Digest::MD5.hexdigest(m.path)
        else
          'untitled'
        end
      end

      def dir
        d = File.join(ROOT, model_key)
        FileUtils_mkdir_p(d) unless File.directory?(d)
        d
      end

      # Crea la dir e tutte le parent. Evito di richiedere 'fileutils' per
      # rimanere leggero — implementazione minimale.
      def FileUtils_mkdir_p(path)
        return if File.directory?(path)
        parent = File.dirname(path)
        FileUtils_mkdir_p(parent) unless File.directory?(parent) || parent == path
        Dir.mkdir(path) rescue nil
      end

      # Ricarica la cache dal disco se il modello è cambiato o non era stata
      # caricata. Idempotente.
      def refresh_from_disk!
        key = model_key
        return if @cache_model == key && !@cache.empty?
        @cache_model = key
        @cache       = {}
        return unless File.directory?(dir)
        Dir.entries(dir).each do |name|
          next unless name.end_with?('.png')
          uid = name.sub(/\.png\z/, '')
          @cache[uid] = File.join(dir, name)
        end
        puts "[SM+] previews cache loaded from disk: #{@cache.size} entries for model_key=#{key}"
      end

      def path_for(uid)
        refresh_from_disk!
        @cache[uid]
      end

      # Hash JSON-friendly (uid => "file:///..."). Solo entry esistenti.
      def url_map
        refresh_from_disk!
        @cache.each_with_object({}) do |(uid, p), h|
          next unless p && File.file?(p)
          h[uid] = "file:///" + p.gsub('\\', '/')
        end
      end

      def clear
        @cache       = {}
        @cache_model = nil
      end

      # Genera anteprime in modo asincrono usando una catena di UI.start_timer
      # — un timer per scena, così CEF ha tempo di ridipingere la progress UI
      # tra una scena e l'altra.
      #
      # on_progress: lambda chiamata con (done, total, current_uid) dopo ogni scena
      # on_done:     lambda chiamata con (count) alla fine
      #
      # Se vuoto/uids nil → tutte le scene (escludendo pending-delete).
      def generate(uids = nil, on_progress: nil, on_done: nil)
        model = Sketchup.active_model
        return (on_done&.call(0)) unless model
        view  = model.active_view
        pages = model.pages

        targets = if uids.nil? || uids.empty?
                    pages.to_a.reject { |p| Buffer.deleted?(SceneModel.page_id(p)) }
                  else
                    uids.map { |u| SceneModel.find_by_id(u) }.compact
                  end
        if targets.empty?
          on_done&.call(0)
          return
        end

        prev_camera = view.camera
        prev_page   = pages.selected_page
        total       = targets.size
        i           = 0
        count       = 0

        step = lambda do
          if i >= total
            # Ripristina contesto
            begin
              if prev_page
                pages.selected_page = prev_page
              else
                view.camera = prev_camera
              end
            rescue => e
              warn "[SM+] Preview restore context failed: #{e.message}"
            end
            on_done&.call(count)
            next
          end

          page = targets[i]
          i += 1
          uid  = SceneModel.page_id(page)
          path = File.join(dir, "#{uid}.png")
          begin
            pages.selected_page = page
            view.write_image(
              filename:    path,
              width:       WIDTH,
              height:      HEIGHT,
              antialias:   true,
              transparent: false
            )
            @cache[uid] = path
            count += 1
          rescue => e
            warn "[SM+] Preview generate failed for #{uid}: #{e.class}: #{e.message}"
          end

          on_progress&.call(i, total, uid)
          # Cedi il controllo a SU/CEF per ridipingere prima della scena
          # successiva. delay 0 = appena possibile.
          ::UI.start_timer(0.01, false) { step.call }
        end

        step.call
      end
    end
  end
end
