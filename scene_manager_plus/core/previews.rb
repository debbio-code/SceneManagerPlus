module SceneManagerPlus
  module Core
    # Cache di anteprime PNG per le scene. Le immagini vengono generate
    # esplicitamente dall'utente (bottone toolbar) e non si rigenerano in
    # automatico al cambiare del modello — restano in cache finché l'utente
    # non rigenera.
    module Previews
      module_function

      WIDTH        = 300
      HEIGHT       = 150

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
        # 'no_model' è uno stato transitorio (callback Ruby con active_model
        # momentaneamente nil): non azzeriamo la cache valida, altrimenti le
        # preview spariscono "a tratti" durante operazioni concorrenti.
        return if key == 'no_model'
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

      # Encoding file:/// per CEF: spazi e caratteri non-ASCII nei path
      # (es. utente con accenti in C:\Users\...) facevano fallire il load
      # dell'immagine in modo intermittente. Encodiamo tutto tranne i char
      # safe e i separatori di path.
      def file_url(path)
        normalized = path.to_s.gsub('\\', '/')
        encoded = normalized.gsub(/([^A-Za-z0-9_\-.\/:~])/) { |c|
          c.bytes.map { |b| '%%%02X' % b }.join
        }
        'file:///' + encoded
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
          h[uid] = file_url(p)
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

        # Disabilita l'animazione di transizione tra scene durante la
        # generazione: di default SU anima ogni `pages.selected_page=` (in
        # genere ~1s/scena), che è il collo di bottiglia principale. Salviamo
        # i valori originali per ripristinarli a fine generazione.
        page_opts        = model.options['PageOptions']
        saved_trans_time = page_opts ? page_opts['TransitionTime'] : nil
        saved_show_trans = page_opts ? page_opts['ShowTransition'] : nil
        if page_opts
          page_opts['TransitionTime'] = 0
          page_opts['ShowTransition'] = false unless saved_show_trans.nil?
        end

        finish = lambda do
          begin
            if prev_page
              pages.selected_page = prev_page
            else
              view.camera = prev_camera
            end
          rescue => e
            warn "[SM+] Preview restore context failed: #{e.message}"
          end
          if page_opts
            page_opts['TransitionTime'] = saved_trans_time unless saved_trans_time.nil?
            page_opts['ShowTransition'] = saved_show_trans unless saved_show_trans.nil?
          end
          on_done&.call(count)
        end

        # Aggiorna la progress bar in CEF ogni PROGRESS_EVERY scene, non a
        # ogni iterazione: lo `execute_script` su HtmlDialog ha overhead
        # apprezzabile su batch grandi. La prima/ultima scena le riportiamo
        # sempre.
        progress_every = [1, (total / 25.0).ceil].max

        step = lambda do
          if i >= total
            finish.call
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
              antialias:   false, # thumbnail piccola: l'AA fa poca differenza
              transparent: false
            )
            @cache[uid] = path
            count += 1
          rescue => e
            warn "[SM+] Preview generate failed for #{uid}: #{e.class}: #{e.message}"
          end

          if i == 1 || i == total || (i % progress_every).zero?
            on_progress&.call(i, total, uid)
            # Cedi il controllo a CEF SOLO quando aggiorniamo la progress:
            # un UI.start_timer per ogni scena aggiungeva ~10ms × N scene.
            ::UI.start_timer(0, false) { step.call }
          else
            step.call # prosegui sincrono, niente yield
          end
        end

        step.call
      end
    end
  end
end
