module SceneManagerPlus
  module Core
    # Batch export delle scene del modello in PNG o JPG, con watermark
    # opzionale composto via Sketchup::ImageRep (SU 2018+).
    #
    # Esecuzione asincrona tramite catena di UI.start_timer (come Previews),
    # così CEF può ridipingere la progress bar tra un frame e l'altro.
    module Exporter
      module_function

      EXTS = { 'png' => '.png', 'jpg' => '.jpg', 'jpeg' => '.jpg' }.freeze

      @cancel  = false
      @running = false

      def request_cancel!
        @cancel = true if @running
      end

      def cancelled?
        @cancel
      end

      def running?
        @running
      end

      # Scope:
      #   'all'      → tutte le scene in ordine logico (cartelle espanse)
      #   'selected' → solo gli uid passati in `selected_ids`
      #   'folders'  → solo le scene dei folder_id passati in `folder_ids`
      #
      # on_progress: lambda (done, total, current_name)
      # on_done:     lambda (count, output_dir, errors[])
      def export(scope:, selected_ids: nil, folder_ids: nil,
                 on_progress: nil, on_done: nil)
        if @running
          warn '[SM+] Export already running, ignoring second call'
          return on_done&.call(0, nil, ['An export is already running'], false)
        end
        model = Sketchup.active_model
        return on_done&.call(0, nil, ['No active model'], false) unless model

        settings_all  = Settings.all
        export_cfg    = settings_all['export'] || {}
        logo_cfg      = settings_all['logo']   || {}
        naming_cfg    = settings_all['naming'] || {}

        out_dir, dir_notes, dir_err = resolve_output_dir(export_cfg['output_dir'], model.path.to_s)
        unless out_dir
          # Path esplicito non valido o modello non salvato: chiedi all'utente
          warn "[SM+] resolve_output_dir: #{dir_err}" if dir_err
          chosen = ::UI.select_directory(title: 'Choose export folder')
          return on_done&.call(0, nil, ['Export cancelled'], true) unless chosen
          out_dir = chosen
          dir_notes = []
        end

        targets = collect_targets(scope, selected_ids, folder_ids)
        if targets.empty?
          on_done&.call(0, out_dir, ['No scenes to export'], false)
          return
        end

        fmt   = (export_cfg['format'] || 'png').to_s.downcase
        fmt   = 'png' unless EXTS.key?(fmt)
        ext   = EXTS[fmt]
        wpx   = (export_cfg['width']  || 1920).to_i
        hpx   = (export_cfg['height'] || 1080).to_i
        aa    = !!export_cfg['antialias']
        transp = !!export_cfg['transparent'] && fmt == 'png'
        line_scale = (export_cfg['line_scale_multiplier'] || 1.0).to_f
        line_scale = 1.0 if line_scale <= 0

        skp_title = model.title.to_s

        view  = model.active_view
        pages = model.pages
        prev_page   = pages.selected_page
        prev_camera = view.camera

        # Pre-load logo image se attivo (rispetta use_default)
        logo_img = nil
        logo_warn = nil
        puts "[SM+] logo cfg: #{logo_cfg.inspect}"
        if logo_cfg['enabled']
          logo_path = Settings.effective_logo_path.to_s
          puts "[SM+] logo effective_path=#{logo_path.inspect} exists=#{File.file?(logo_path)}"
          if logo_path.empty?
            logo_warn = 'Watermark enabled but no logo path set (default logo not found either).'
          elsif File.file?(logo_path)
            begin
              logo_img = Sketchup::ImageRep.new
              logo_img.load_file(logo_path)
              puts "[SM+] logo loaded: #{logo_img.width}x#{logo_img.height} bpp=#{logo_img.bits_per_pixel}"
            rescue => e
              logo_warn = "Could not load logo: #{e.message}"
              warn "[SM+] logo load failed: #{e.class}: #{e.message}"
            end
          else
            logo_warn = "Logo file not found: #{logo_path}"
          end
        else
          puts "[SM+] watermark DISABLED in settings (logo.enabled=false)"
        end

        errors = []
        errors.concat(Array(dir_notes))
        errors << logo_warn if logo_warn

        puts "[SM+] export start: out=#{out_dir} fmt=#{fmt} size=#{wpx}x#{hpx} aa=#{aa} " \
             "transp=#{transp} line_scale=#{line_scale} " \
             "logo_enabled=#{logo_cfg['enabled'].inspect} logo_img=#{logo_img ? 'loaded' : 'no'}"

        # SU 2019: write_image non supporta :scale_factor (aggiunto in SU 2020).
        # Fallback: prima del render aumentiamo temporaneamente RenderingOptions
        # 'EdgeWidth' del moltiplicatore, e lo ripristiniamo dopo. Funziona solo
        # se lo stile attivo ha edges visibili.
        ropts = model.rendering_options
        prev_edge_width   = ropts['EdgeWidth']
        prev_profile_widt = ropts['ProfileWidth'] rescue nil
        apply_edge_scale = line_scale != 1.0 && prev_edge_width.is_a?(Numeric)
        if apply_edge_scale
          new_ew = [(prev_edge_width * line_scale).round, 1].max
          new_pw = (prev_profile_widt.is_a?(Numeric) ? [(prev_profile_widt * line_scale).round, 1].max : nil)
          begin
            ropts['EdgeWidth']    = new_ew
            ropts['ProfileWidth'] = new_pw if new_pw
            puts "[SM+] line scale: EdgeWidth #{prev_edge_width}→#{new_ew}" +
                 (new_pw ? ", ProfileWidth #{prev_profile_widt}→#{new_pw}" : '')
          rescue => e
            warn "[SM+] could not apply edge scale: #{e.message}"
            apply_edge_scale = false
          end
        end

        i     = 0
        count = 0
        total = targets.size
        @cancel = false
        # Guard: on_done deve essere chiamato UNA volta sola per export run.
        # Senza questo, eventuali timer in coda + cancel possono produrre
        # più messagebox finali.
        done_fired = false
        stopped    = false

        finish = lambda do |cancelled|
          next if done_fired
          done_fired = true
          stopped    = true
          # Ripristina rendering options modificate per il line scale
          if apply_edge_scale
            begin
              ropts['EdgeWidth']    = prev_edge_width
              ropts['ProfileWidth'] = prev_profile_widt if prev_profile_widt.is_a?(Numeric)
            rescue
            end
          end
          begin
            if prev_page
              pages.selected_page = prev_page
            else
              view.camera = prev_camera
            end
          rescue
          end
          errors << 'Cancelled by user' if cancelled
          @cancel  = false
          @running = false
          puts "[SM+] export finish: count=#{count}/#{total} cancelled=#{cancelled} errors=#{errors.size}"
          on_done&.call(count, out_dir, errors, cancelled)
        end

        step = lambda do
          next if stopped
          if @cancel
            finish.call(true); next
          end
          if i >= total
            finish.call(false); next
          end

          page, idx_for_name = targets[i]
          i += 1
          name_out = if naming_cfg['enabled']
                       Naming.format(idx_for_name, page.name.to_s, skp_title, naming_cfg)
                     else
                       page.name.to_s
                     end
          name_out = page.name.to_s if name_out.to_s.strip.empty?
          fname    = sanitize_filename(name_out) + ext
          fpath    = unique_path(File.join(out_dir, fname))

          begin
            pages.selected_page = page
            write_args = {
              filename:     fpath,
              width:        wpx,
              height:       hpx,
              antialias:    aa,
              transparent:  transp,
              scale_factor: line_scale # SU 2020+: line scale multiplier
            }
            # Per JPG passa compression esplicito così SU non apre la sua
            # dialog "JPG Image Options".
            write_args[:compression] = 0.9 if fmt != 'png'
            view.write_image(write_args)
            if logo_img
              begin
                apply_watermark(fpath, logo_img, logo_cfg, fmt)
              rescue => e
                errors << "Watermark failed on '#{page.name}': #{e.message}"
                warn "[SM+] apply_watermark failed on '#{page.name}': #{e.class}: #{e.message}"
                warn e.backtrace.first(3).join("\n") if e.backtrace
              end
            end
            count += 1
          rescue => e
            errors << "Export failed on '#{page.name}': #{e.class}: #{e.message}"
          end

          on_progress&.call(i, total, page.name.to_s)
          ::UI.start_timer(0.01, false) { step.call } unless stopped
        end

        @running = true
        on_progress&.call(0, total, '')
        step.call
      end

      # Compone il logo sull'immagine appena scritta (in-place).
      # Per JPG, ImageRep.save_file scrive secondo l'estensione di destinazione.
      def apply_watermark(image_path, logo_img, logo_cfg, fmt)
        base = Sketchup::ImageRep.new
        base.load_file(image_path)
        bw = base.width
        bh = base.height
        puts "[SM+] watermark on #{File.basename(image_path)}: base=#{bw}x#{bh} bpp=#{base.bits_per_pixel}"

        width_pct = (logo_cfg['width_pct'] || 15).to_f
        width_pct = 1.0 if width_pct < 1
        width_pct = 100.0 if width_pct > 100
        target_w  = [(bw * width_pct / 100.0).round, 1].max
        scale     = target_w.to_f / logo_img.width
        target_h  = [(logo_img.height * scale).round, 1].max

        off_x = (logo_cfg['offset_x'] || 20).to_i
        off_y = (logo_cfg['offset_y'] || 20).to_i
        opacity = (logo_cfg['opacity'] || 100).to_f / 100.0
        opacity = 0.0 if opacity < 0
        opacity = 1.0 if opacity > 1

        # Logo position: bottom-right by default (più comune per watermark);
        # offset_x/offset_y sono margini dal bordo destro/inferiore.
        x0 = bw - target_w - off_x
        y0 = bh - target_h - off_y
        x0 = 0 if x0 < 0
        y0 = 0 if y0 < 0

        puts "[SM+] watermark place: target=#{target_w}x#{target_h} at (#{x0},#{y0}) opacity=#{opacity}"
        composite_bilinear!(base, logo_img, x0, y0, target_w, target_h, opacity)

        # save_file usa l'estensione per determinare il formato
        ok = base.save_file(image_path)
        puts "[SM+] watermark save_file ok=#{ok.inspect} → #{image_path}"
      end

      # Composita logo_img scalato a (tw,th) sopra base partendo da (x0,y0)
      # con `opacity` applicata al canale alpha del logo.
      #
      # Byte layout: ImageRep#set_data su Windows con 32 bpp si aspetta
      # pixel data in ordine BGRA (DIB top-down), NON RGBA. Inoltre
      # color_at_uv usa convenzione OpenGL: v=0 in basso, v=1 in alto;
      # noi indicizziamo top-down quindi flippiamo v.
      #
      # Performance: pre-alloca un buffer binario di bw*bh*4 byte con setbyte
      # (molto più veloce di String#<< o Array#pack per immagine grande).
      # Il logo viene pre-campionato una volta sulla griglia (tw,th).
      def composite_bilinear!(base, logo, x0, y0, tw, th, opacity)
        bw = base.width
        bh = base.height
        base_colors = base.colors

        # Pre-alloca buffer BGRA. "\0" * N è veloce in Ruby.
        buf = ("\0" * (bw * bh * 4)).force_encoding(Encoding::BINARY)

        # Pass 1: scrivi tutta la base nel buffer (BGRA order).
        i = 0
        base_colors.each do |c|
          buf.setbyte(i,     c.blue)
          buf.setbyte(i + 1, c.green)
          buf.setbyte(i + 2, c.red)
          buf.setbyte(i + 3, 255)
          i += 4
        end

        # Clamp bbox
        x1 = [x0 + tw, bw].min
        y1 = [y0 + th, bh].min
        x0c = [x0, 0].max
        y0c = [y0, 0].max
        if x1 > x0c && y1 > y0c
          # Pass 2: pre-campiona il logo sulla griglia (tw,th).
          # FLIP v: il logo ha origine in alto (immagine), color_at_uv usa
          # origine in basso, quindi dy=0 (top bbox) ↔ v ~1.0 (top logo).
          logo_rgba = Array.new(tw * th)
          th.times do |dy|
            v = 1.0 - (dy + 0.5) / th.to_f
            tw.times do |dx|
              u = (dx + 0.5) / tw.to_f
              c = logo.color_at_uv(u, v, true)
              logo_rgba[dy * tw + dx] = [c.red, c.green, c.blue, c.alpha]
            end
          end

          # Pass 3: blend solo nella bbox (BGRA order)
          (y0c...y1).each do |y|
            dy = y - y0
            base_row = y * bw
            (x0c...x1).each do |x|
              dx = x - x0
              lr, lg, lb, lalpha = logo_rgba[dy * tw + dx]
              la = (lalpha.to_f / 255.0) * opacity
              next if la <= 0.001
              j = (base_row + x) * 4
              bb = buf.getbyte(j)     # base Blue
              bgc = buf.getbyte(j + 1) # base Green
              br = buf.getbyte(j + 2)  # base Red
              inv = 1.0 - la
              buf.setbyte(j,     (lb * la + bb  * inv).round)
              buf.setbyte(j + 1, (lg * la + bgc * inv).round)
              buf.setbyte(j + 2, (lr * la + br  * inv).round)
            end
          end
        end

        base.set_data(bw, bh, 32, 0, buf)
      end

      # Lista [page, name_index] dove name_index è la posizione 1-based in
      # ordine logico globale (così il pattern di naming numera in modo
      # coerente anche se filtriamo per scope).
      def collect_targets(scope, selected_ids, folder_ids)
        ordered = Naming.ordered_scene_pairs # [[page, name], ...]
        sel = Array(selected_ids)
        fids = Array(folder_ids)
        folders_by_id = Folders.all.each_with_object({}) { |f, h| h[f['id']] = f }
        uid_in_folder = fids.each_with_object({}) do |fid, h|
          f = folders_by_id[fid]
          next unless f
          Array(f['scene_ids']).each { |sid| h[sid] = true }
        end

        result = []
        ordered.each_with_index do |pair, i|
          page = pair[0]
          uid  = SceneModel.page_id(page)
          keep = case scope.to_s
                 when 'selected' then sel.include?(uid)
                 when 'folders'  then uid_in_folder[uid]
                 else true
                 end
          result << [page, i + 1] if keep
        end
        puts "[SM+] export collect_targets: scope=#{scope.inspect} " \
             "selected=#{sel.size} folders=#{fids.size} → #{result.size} target(s)"
        result
      end

      # Risolve la cartella di output secondo le regole:
      #  - se `explicit_dir` non vuoto e directory esistente → usa quella
      #  - altrimenti, usa la regola "Immagini" accanto al .skp:
      #    A) Immagini non esiste → la crea, esporta lì
      #    B) Immagini esiste e contiene file → crea Superate/NN (NN=successivo
      #       a quelli esistenti, padded 2 cifre), sposta i file di Immagini in
      #       Superate/NN, esporta in Immagini ora svuotata
      #    C) Immagini esiste ma vuota → esporta lì
      #  - se il modello non ha un path (untitled) → ritorna [nil, [], err]
      # Ritorna [out_dir|nil, notes[], err|nil].
      def resolve_output_dir(explicit_dir, model_path)
        ed = explicit_dir.to_s
        if !ed.empty? && File.directory?(ed)
          return [ed, [], nil]
        end

        if model_path.nil? || model_path.empty?
          return [nil, [], 'Model not saved yet — cannot use auto Immagini folder.']
        end

        skp_dir = File.dirname(model_path)
        img_dir = File.join(skp_dir, 'Immagini')
        notes = []

        unless File.directory?(img_dir)
          begin
            Dir.mkdir(img_dir)
            notes << 'Created folder: Immagini/'
          rescue => e
            return [nil, [], "Could not create 'Immagini': #{e.message}"]
          end
          return [img_dir, notes, nil]
        end

        existing = Dir.entries(img_dir).reject { |n| n == '.' || n == '..' }
        return [img_dir, notes, nil] if existing.empty? # Case C

        # Case B: archive
        superate_dir = File.join(skp_dir, 'Superate')
        unless File.directory?(superate_dir)
          begin
            Dir.mkdir(superate_dir)
          rescue => e
            return [nil, [], "Could not create 'Superate': #{e.message}"]
          end
        end

        existing_nums = Dir.entries(superate_dir).map do |n|
          next nil unless n =~ /\A(\d{2,})\z/ && File.directory?(File.join(superate_dir, n))
          n.to_i
        end.compact
        next_num = (existing_nums.empty? ? 1 : existing_nums.max + 1)
        archive_label = format('%02d', next_num)
        archive_dir   = File.join(superate_dir, archive_label)
        begin
          Dir.mkdir(archive_dir)
        rescue => e
          return [nil, [], "Could not create 'Superate/#{archive_label}': #{e.message}"]
        end

        moved = 0
        failed = 0
        existing.each do |name|
          src = File.join(img_dir, name)
          dst = File.join(archive_dir, name)
          begin
            File.rename(src, dst)
            moved += 1
          rescue => e
            failed += 1
            notes << "Could not archive '#{name}': #{e.message}"
          end
        end
        notes << "Archived #{moved} file(s) → Superate/#{archive_label}/"
        notes << "(#{failed} failed)" if failed > 0
        [img_dir, notes, nil]
      end

      def sanitize_filename(s)
        s = s.to_s.gsub(/[\\\/\:\*\?\"\<\>\|\r\n\t]/, '_').strip
        s = 'scene' if s.empty?
        s[0, 180]
      end

      # Se il path esiste, aggiunge ` (2)`, ` (3)`... prima dell'estensione.
      def unique_path(path)
        return path unless File.exist?(path)
        dir  = File.dirname(path)
        base = File.basename(path, '.*')
        ext  = File.extname(path)
        n = 2
        loop do
          candidate = File.join(dir, "#{base} (#{n})#{ext}")
          return candidate unless File.exist?(candidate)
          n += 1
        end
      end
    end
  end
end
