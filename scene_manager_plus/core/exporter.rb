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
        export_cfg    = settings_all['export']         || {}
        logo_cfg      = settings_all['logo']           || {}
        naming_cfg    = settings_all['naming']         || {}
        label_cfg     = settings_all['filename_label'] || {}
        tb_cfg        = settings_all['titleblock']     || {}

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

        # Pre-computa metadata per ogni target: filename base (senza ext) e uid.
        # Usato sia dal naming sia dal pre-render delle filename label.
        targets_meta = targets.map do |page, idx|
          name_out = if naming_cfg['enabled']
                       Naming.format(idx, page.name.to_s, skp_title, naming_cfg)
                     else
                       page.name.to_s
                     end
          name_out = page.name.to_s if name_out.to_s.strip.empty?
          base_name = sanitize_filename(name_out)
          [page, idx, base_name, SceneModel.page_id(page)]
        end

        # Pre-renderizza tutte le filename label in un'unica chiamata PowerShell
        # (riusa System.Drawing per font/size/colore configurabili).
        label_pngs = nil
        label_warn = nil
        if label_cfg['enabled']
          begin
            items = targets_meta.map { |_p, _i, base_name, uid| [uid, base_name] }
            label_pngs = TextRender.render_batch(items, label_cfg)
            produced = label_pngs.keys.reject { |k| k == '_tmpdir' }.size
            label_warn = "Filename labels: nessuna immagine generata" if produced.zero?
          rescue => e
            label_warn = "Filename label render failed: #{e.message}"
            warn "[SM+] label pre-render error: #{e.class}: #{e.message}"
          end
        end

        # Pre-renderizza titleblock per ogni scena se abilitato. Una sola
        # spawn PowerShell per export (batch). Cliente = naming.prefix_custom
        # (riuso semantico richiesto dall'utente). Tavola nr. = stesso
        # progressivo {nnn} del naming pattern (1-based su targets_meta).
        tb_pngs = nil
        tb_warn = nil
        tb_height = (tb_cfg['height_px'] || 120).to_i
        tb_height = 40 if tb_height < 40
        if tb_cfg['enabled']
          begin
            client_str = (naming_cfg['prefix_custom'] || '').to_s
            date_str   = if (do_str = tb_cfg['date_override'].to_s).strip.empty?
                           Time.now.strftime('%d/%m/%Y')
                         else
                           do_str
                         end
            company_lines = TitleBlock.load_company_lines
            logo_for_tb   = Settings.titleblock_logo_path
            logo_for_tb   = '' unless File.file?(logo_for_tb)

            pad = (naming_cfg['pad'] || 2).to_i
            tb_items = targets_meta.map do |page, idx, _b, uid|
              num_str = idx.to_s.rjust([pad, 1].max, '0')
              { uid: uid, client: client_str, tavola: num_str, scene_name: page.name.to_s }
            end
            tb_pngs = TitleBlock.render_batch(tb_items,
              width:              wpx,
              height:             tb_height,
              font_family:        (tb_cfg['font_family']    || 'Century Gothic'),
              date:               date_str,
              project_by:         (tb_cfg['project_by']     || ''),
              designer:           (tb_cfg['designer']       || ''),
              project_phase:      (tb_cfg['project_phase']  || 'Definitivo'),
              company_lines:      company_lines,
              logo_path:          logo_for_tb,
              tavola_placeholder: '0' * [pad, 1].max
            )
            produced = tb_pngs.keys.reject { |k| k == '_tmpdir' }.size
            tb_warn = 'Title block: nessuna immagine generata' if produced.zero?
          rescue => e
            tb_warn = "Title block render failed: #{e.message}"
            warn "[SM+] titleblock pre-render error: #{e.class}: #{e.message}"
          end
        end

        errors = []
        errors.concat(Array(dir_notes))
        errors << logo_warn  if logo_warn
        errors << label_warn if label_warn
        errors << tb_warn    if tb_warn

        puts "[SM+] export start: out=#{out_dir} fmt=#{fmt} size=#{wpx}x#{hpx} aa=#{aa} " \
             "transp=#{transp} line_scale=#{line_scale} " \
             "logo_enabled=#{logo_cfg['enabled'].inspect} logo_img=#{logo_img ? 'loaded' : 'no'} " \
             "label_enabled=#{label_cfg['enabled'].inspect} labels_ready=#{label_pngs ? label_pngs.keys.size - 1 : 0} " \
             "tb_enabled=#{tb_cfg['enabled'].inspect} tb_ready=#{tb_pngs ? tb_pngs.keys.size - 1 : 0} tb_h=#{tb_height}"

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
          # Pulisci i PNG temporanei delle filename label e dei title block
          TextRender.cleanup(label_pngs) if label_pngs
          TitleBlock.cleanup(tb_pngs)    if tb_pngs
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

          page, _idx_for_name, base_name, uid = targets_meta[i]
          i += 1
          fname = base_name + ext
          fpath = unique_path(File.join(out_dir, fname))

          begin
            pages.selected_page = page
            # Riapplica EdgeWidth/ProfileWidth DOPO pages.selected_page=: se la
            # scena ha PAGE_USE_RENDERING_OPTIONS, SU al cambio pagina ripristina
            # i valori salvati nella scena, sovrascrivendo la nostra modifica
            # fatta prima del loop. Settando qui garantiamo che write_image
            # veda i valori scalati su SU 2019 (dove scale_factor non c'è).
            if apply_edge_scale
              begin
                ropts['EdgeWidth']    = new_ew
                ropts['ProfileWidth'] = new_pw if new_pw
              rescue
              end
            end
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

            # Costruisci la lista di overlay (logo + filename label) per
            # comporli in un solo load/blend/save → niente doppia ri-codifica
            # JPG quando entrambi sono attivi.
            specs = []
            if logo_img
              specs << {
                img:       logo_img,
                width_pct: (logo_cfg['width_pct'] || 15).to_f,
                anchor_x:  :right,
                anchor_y:  :bottom,
                offset_x:  (logo_cfg['offset_x'] || 20).to_i,
                offset_y:  (logo_cfg['offset_y'] || 20).to_i,
                opacity:   ((logo_cfg['opacity'] || 100).to_f / 100.0)
              }
            end
            if label_pngs && (label_png = label_pngs[uid]) && File.file?(label_png)
              begin
                label_img = Sketchup::ImageRep.new
                label_img.load_file(label_png)
                specs << {
                  img:      label_img,
                  # native size: nessuno scale
                  anchor_x: :left,
                  anchor_y: :bottom,
                  offset_x: (label_cfg['offset_x'] || 20).to_i,
                  offset_y: (label_cfg['offset_y'] || 20).to_i,
                  opacity:  ((label_cfg['opacity'] || 100).to_f / 100.0)
                }
              rescue => e
                errors << "Filename label load failed on '#{page.name}': #{e.message}"
              end
            end

            unless specs.empty?
              begin
                apply_overlays(fpath, specs)
              rescue => e
                errors << "Overlay failed on '#{page.name}': #{e.message}"
                warn "[SM+] apply_overlays failed on '#{page.name}': #{e.class}: #{e.message}"
                warn e.backtrace.first(3).join("\n") if e.backtrace
              end
            end

            # Title block: estende il canvas verso il basso e appende il
            # cartiglio. Va DOPO apply_overlays così logo+label restano
            # confinati nell'immagine originale (il cartiglio non li copre).
            if tb_pngs && (tb_png = tb_pngs[uid]) && File.file?(tb_png)
              begin
                append_titleblock(fpath, tb_png)
              rescue => e
                errors << "Title block failed on '#{page.name}': #{e.message}"
                warn "[SM+] append_titleblock failed on '#{page.name}': #{e.class}: #{e.message}"
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

      # Compone una lista di overlay (logo, filename label, ecc.) sopra
      # l'immagine appena scritta. Un solo load + blend + save per gestire
      # N overlay → su JPG niente doppia ri-codifica.
      #
      # Ogni spec è un hash:
      #   img:       Sketchup::ImageRep da sovrapporre (richiesto)
      #   width_pct: % della larghezza base a cui scalare l'overlay (opz.;
      #              se assente → dimensione nativa di img)
      #   anchor_x:  :left | :right    (default :left)
      #   anchor_y:  :top  | :bottom   (default :bottom)
      #   offset_x:  px dal bordo dell'anchor (default 0)
      #   offset_y:  px dal bordo dell'anchor (default 0)
      #   opacity:   0.0..1.0          (default 1.0)
      def apply_overlays(image_path, specs)
        return if specs.nil? || specs.empty?
        base = Sketchup::ImageRep.new
        base.load_file(image_path)
        bw = base.width
        bh = base.height
        puts "[SM+] overlays on #{File.basename(image_path)}: base=#{bw}x#{bh} n=#{specs.size}"

        # Resolve placement (può saltare overlay fuori dalla canvas)
        resolved = specs.map { |s| resolve_overlay(s, bw, bh) }.compact
        return if resolved.empty?

        # Pre-alloca buffer BGRA (DIB top-down, vedi SU2019-LESSONS.md).
        buf = ("\0" * (bw * bh * 4)).force_encoding(Encoding::BINARY)
        i = 0
        base.colors.each do |c|
          buf.setbyte(i,     c.blue)
          buf.setbyte(i + 1, c.green)
          buf.setbyte(i + 2, c.red)
          buf.setbyte(i + 3, 255)
          i += 4
        end

        resolved.each { |ov| blend_into_buffer!(buf, bw, bh, ov) }

        base.set_data(bw, bh, 32, 0, buf)
        ok = base.save_file(image_path)
        puts "[SM+] overlays save_file ok=#{ok.inspect} → #{File.basename(image_path)}"
      end

      def resolve_overlay(spec, bw, bh)
        img = spec[:img]
        return nil unless img

        if spec[:width_pct]
          pct = spec[:width_pct].to_f
          pct = 1.0   if pct < 1
          pct = 100.0 if pct > 100
          tw  = [(bw * pct / 100.0).round, 1].max
          scale = tw.to_f / img.width
          th  = [(img.height * scale).round, 1].max
        else
          tw = img.width
          th = img.height
        end

        ax = spec[:anchor_x] || :left
        ay = spec[:anchor_y] || :bottom
        ox = (spec[:offset_x] || 0).to_i
        oy = (spec[:offset_y] || 0).to_i

        x0 = (ax == :right)  ? (bw - tw - ox) : ox
        y0 = (ay == :bottom) ? (bh - th - oy) : oy
        x0 = 0 if x0 < 0
        y0 = 0 if y0 < 0

        opacity = (spec[:opacity] || 1.0).to_f
        opacity = 0.0 if opacity < 0
        opacity = 1.0 if opacity > 1

        puts "[SM+]   overlay: #{tw}x#{th} at (#{x0},#{y0}) anchor=#{ax}/#{ay} opacity=#{opacity}"
        { img: img, x: x0, y: y0, w: tw, h: th, opacity: opacity }
      end

      # Pre-campiona overlay su griglia (tw,th) e blenda nella bbox del buf
      # (BGRA, top-down). FLIP v: color_at_uv usa origine in basso, noi
      # indicizziamo top-down quindi v = 1 - (dy+0.5)/th.
      def blend_into_buffer!(buf, bw, bh, ov)
        img = ov[:img]; x0 = ov[:x]; y0 = ov[:y]
        tw  = ov[:w];   th = ov[:h]; opacity = ov[:opacity]

        x1 = [x0 + tw, bw].min
        y1 = [y0 + th, bh].min
        x0c = [x0, 0].max
        y0c = [y0, 0].max
        return unless x1 > x0c && y1 > y0c

        img_rgba = Array.new(tw * th)
        th.times do |dy|
          v = 1.0 - (dy + 0.5) / th.to_f
          tw.times do |dx|
            u = (dx + 0.5) / tw.to_f
            c = img.color_at_uv(u, v, true)
            img_rgba[dy * tw + dx] = [c.red, c.green, c.blue, c.alpha]
          end
        end

        (y0c...y1).each do |y|
          dy = y - y0
          base_row = y * bw
          (x0c...x1).each do |x|
            dx = x - x0
            lr, lg, lb, lalpha = img_rgba[dy * tw + dx]
            la = (lalpha.to_f / 255.0) * opacity
            next if la <= 0.001
            j = (base_row + x) * 4
            bb  = buf.getbyte(j)
            bgc = buf.getbyte(j + 1)
            br  = buf.getbyte(j + 2)
            inv = 1.0 - la
            buf.setbyte(j,     (lb * la + bb  * inv).round)
            buf.setbyte(j + 1, (lg * la + bgc * inv).round)
            buf.setbyte(j + 2, (lr * la + br  * inv).round)
          end
        end
      end

      # Estende il canvas verso il basso e appende il cartiglio PNG.
      # Carica l'immagine base (bw×bh) e il cartiglio (tw×th); produce
      # buffer BGRA (bw × (bh + th)) top-down, salva alla stessa path.
      # Se tw ≠ bw, il cartiglio è ri-campionato a larghezza bw mantenendo
      # th (PowerShell l'ha già renderizzato a width = wpx, quindi tw==bw
      # nel caso normale; il branch ri-sample è di sicurezza).
      def append_titleblock(image_path, tb_png_path)
        base = Sketchup::ImageRep.new
        base.load_file(image_path)
        bw = base.width
        bh = base.height

        tb = Sketchup::ImageRep.new
        tb.load_file(tb_png_path)
        tw = tb.width
        th = tb.height
        resample = (tw != bw)

        nh = bh + th
        buf = ("\0" * (bw * nh * 4)).force_encoding(Encoding::BINARY)

        # Riga superiore: immagine originale (BGRA, top-down)
        i = 0
        base.colors.each do |c|
          buf.setbyte(i,     c.blue)
          buf.setbyte(i + 1, c.green)
          buf.setbyte(i + 2, c.red)
          buf.setbyte(i + 3, 255)
          i += 4
        end

        # Riga inferiore: cartiglio. Se le larghezze coincidono, copy
        # diretto (fast path). Altrimenti UV resample.
        if resample
          th.times do |dy|
            v = 1.0 - (dy + 0.5) / th.to_f
            row_off = ((bh + dy) * bw) * 4
            bw.times do |dx|
              u = (dx + 0.5) / bw.to_f
              c = tb.color_at_uv(u, v, true)
              j = row_off + dx * 4
              buf.setbyte(j,     c.blue)
              buf.setbyte(j + 1, c.green)
              buf.setbyte(j + 2, c.red)
              buf.setbyte(j + 3, 255)
            end
          end
        else
          j = bw * bh * 4
          tb.colors.each do |c|
            buf.setbyte(j,     c.blue)
            buf.setbyte(j + 1, c.green)
            buf.setbyte(j + 2, c.red)
            buf.setbyte(j + 3, 255)
            j += 4
          end
        end

        base.set_data(bw, nh, 32, 0, buf)
        ok = base.save_file(image_path)
        puts "[SM+] titleblock append ok=#{ok.inspect} → #{File.basename(image_path)} (#{bw}x#{nh})"
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
                 else SceneModel.export_included?(page)
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
