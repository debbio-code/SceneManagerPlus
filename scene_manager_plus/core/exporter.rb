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

        # Flush dei settings RAM → disco prima di leggere: se l'utente
        # ha modificato width/height/ecc. nel Settings dialog senza
        # chiuderlo, i valori sono in RAM (vedi Core::Settings cache).
        # Settings.get() li ritorna comunque (RAM > disco), ma flusha
        # qui garantisce coerenza per export futuri e per il file SKP.
        Settings.flush!(model)

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

        # Pre-renderizza il logo come "stamp" BGRA ridimensionato alle
        # dimensioni finali UNA sola volta per export. Prima veniva
        # ri-sampled per ogni scena con `color_at_uv` per-pixel.
        logo_stamp = nil
        if logo_img
          pct = (logo_cfg['width_pct'] || 15).to_f
          pct = 1.0   if pct < 1
          pct = 100.0 if pct > 100
          lw = [(wpx * pct / 100.0).round, 1].max
          lh = [(logo_img.height.to_f * lw / logo_img.width).round, 1].max
          lbgra = if lw == logo_img.width && lh == logo_img.height
                    imagerep_to_bgra(logo_img)
                  else
                    resample_imagerep_to_bgra(logo_img, lw, lh)
                  end
          ox = (logo_cfg['offset_x'] || 20).to_i
          oy = (logo_cfg['offset_y'] || 20).to_i
          lx = wpx - lw - ox
          ly = hpx - lh - oy
          lx = 0 if lx < 0
          ly = 0 if ly < 0
          lop = ((logo_cfg['opacity'] || 100).to_f / 100.0)
          lop = 0.0 if lop < 0
          lop = 1.0 if lop > 1
          logo_stamp = { bgra: lbgra, w: lw, h: lh, x: lx, y: ly, opacity: lop }
          puts "[SM+] logo stamp prerendered: #{lw}x#{lh} at (#{lx},#{ly}) op=#{lop}"
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

            # Compone logo + filename label + titleblock in UN solo
            # load/set_data/save. Prima erano 2 load+2 save quando
            # overlays e TB erano entrambi attivi (= doppia ri-codifica
            # JPG per scena).
            overlays = []
            overlays << logo_stamp if logo_stamp

            if label_pngs && (label_png = label_pngs[uid]) && File.file?(label_png)
              begin
                label_img = Sketchup::ImageRep.new
                label_img.load_file(label_png)
                llw = label_img.width
                llh = label_img.height
                llbgra = imagerep_to_bgra(label_img)
                lox = (label_cfg['offset_x'] || 20).to_i
                loy = (label_cfg['offset_y'] || 20).to_i
                llx = lox
                lly = hpx - llh - loy
                llx = 0 if llx < 0
                lly = 0 if lly < 0
                llop = ((label_cfg['opacity'] || 100).to_f / 100.0)
                llop = 0.0 if llop < 0
                llop = 1.0 if llop > 1
                overlays << { bgra: llbgra, w: llw, h: llh, x: llx, y: lly, opacity: llop }
              rescue => e
                errors << "Filename label load failed on '#{page.name}': #{e.message}"
              end
            end

            tb_bgra_scene = nil
            tb_h_scene = 0
            if tb_pngs && (tb_png_path = tb_pngs[uid]) && File.file?(tb_png_path)
              begin
                tb_bgra_scene, tb_h_scene = load_tb_as_bgra(tb_png_path, wpx)
              rescue => e
                errors << "Title block load failed on '#{page.name}': #{e.message}"
                warn "[SM+] load_tb_as_bgra failed on '#{page.name}': #{e.class}: #{e.message}"
              end
            end

            if !overlays.empty? || tb_bgra_scene
              begin
                composite_to_file(fpath, overlays, tb_bgra_scene, tb_h_scene)
              rescue => e
                errors << "Composite failed on '#{page.name}': #{e.class}: #{e.message}"
                warn "[SM+] composite_to_file failed on '#{page.name}': #{e.class}: #{e.message}"
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

      # ============================================================
      # Helpers BGRA — vedi docs/SU2019-LESSONS.md "ImageRep#set_data"
      # ============================================================

      # Estrae i pixel di un ImageRep come buffer BGRA top-down (formato
      # accettato da set_data su Windows). Quando bpp=32 e nessun row
      # padding (caso PNG/JPG di SU 2019 su Windows), `ImageRep#data`
      # ritorna già i byte nel formato giusto in una sola chiamata C:
      # ~10-20x più veloce di `colors.each` che alloca 1 Sketchup::Color
      # per pixel (≈2M oggetti per un 1920x1080). Per 24bpp con padding
      # (raro, capita su JPG di larghezza non multiple di 4) facciamo
      # byte-copy row-by-row senza colors.each. La fallback finale è
      # ridondante in pratica ma protegge da formati inattesi.
      def imagerep_to_bgra(img)
        bw = img.width
        bh = img.height
        bpp = (img.bits_per_pixel rescue 32)
        pad = (img.row_padding rescue 0)
        raw = nil
        begin
          raw = img.data
        rescue
          raw = nil
        end

        if raw && bpp == 32 && pad == 0 && raw.bytesize == bw * bh * 4
          # Già BGRA top-down. Dup così il caller può mutare in place
          # senza toccare lo stato interno di ImageRep.
          return raw.dup.force_encoding(Encoding::BINARY)
        end

        if raw && bpp == 24
          buf = ("\0" * (bw * bh * 4)).force_encoding(Encoding::BINARY)
          src_idx = 0
          dst_idx = 0
          bh.times do
            bw.times do
              buf.setbyte(dst_idx,     raw.getbyte(src_idx))
              buf.setbyte(dst_idx + 1, raw.getbyte(src_idx + 1))
              buf.setbyte(dst_idx + 2, raw.getbyte(src_idx + 2))
              buf.setbyte(dst_idx + 3, 255)
              src_idx += 3
              dst_idx += 4
            end
            src_idx += pad
          end
          return buf
        end

        # Fallback: path lento originale (colors.each). Non dovrebbe
        # servire mai su SU 2019 Windows, è un safety net.
        buf = ("\0" * (bw * bh * 4)).force_encoding(Encoding::BINARY)
        i = 0
        img.colors.each do |c|
          buf.setbyte(i,     c.blue)
          buf.setbyte(i + 1, c.green)
          buf.setbyte(i + 2, c.red)
          alpha = (c.alpha rescue 255)
          buf.setbyte(i + 3, alpha || 255)
          i += 4
        end
        buf
      end

      # Ri-campiona un ImageRep a (tw, th) restituendo un buffer BGRA.
      # Usa color_at_uv (lento, ma) — chiamato UNA volta per export sul
      # logo, non più per scena come faceva il vecchio
      # blend_into_buffer!.
      def resample_imagerep_to_bgra(img, tw, th)
        buf = ("\0" * (tw * th * 4)).force_encoding(Encoding::BINARY)
        j = 0
        th.times do |dy|
          v = 1.0 - (dy + 0.5) / th.to_f
          tw.times do |dx|
            u = (dx + 0.5) / tw.to_f
            c = img.color_at_uv(u, v, true)
            buf.setbyte(j,     c.blue)
            buf.setbyte(j + 1, c.green)
            buf.setbyte(j + 2, c.red)
            alpha = (c.alpha rescue 255)
            buf.setbyte(j + 3, alpha || 255)
            j += 4
          end
        end
        buf
      end

      # Carica un PNG titleblock come buffer BGRA. Se la larghezza è
      # diversa da target_w, ricampiona (caso difensivo: TB è normalmente
      # generato a width=wpx, quindi il fast path scatta sempre).
      def load_tb_as_bgra(tb_png_path, target_w)
        tb = Sketchup::ImageRep.new
        tb.load_file(tb_png_path)
        if tb.width == target_w
          [imagerep_to_bgra(tb), tb.height]
        else
          [resample_imagerep_to_bgra(tb, target_w, tb.height), tb.height]
        end
      end

      # Blenda uno stamp BGRA (sw×sh) in buf (BGRA bw×bh, top-down) alla
      # posizione (x0,y0). Stesso pattern del vecchio blend_into_buffer!,
      # ma legge i pixel direttamente dal buffer BGRA dello stamp invece
      # di chiamare color_at_uv per pixel. Fast-path per pixel completamente
      # opachi: pure byte copy senza math floating point.
      def blend_stamp!(buf, bw, bh, stamp_bgra, sw, sh, x0, y0, opacity)
        x1 = [x0 + sw, bw].min
        y1 = [y0 + sh, bh].min
        x0c = [x0, 0].max
        y0c = [y0, 0].max
        return if x1 <= x0c || y1 <= y0c

        fully_opaque = opacity >= 0.999

        (y0c...y1).each do |y|
          dy = y - y0
          base_row = y * bw
          stamp_row = dy * sw
          (x0c...x1).each do |x|
            dx = x - x0
            si = (stamp_row + dx) * 4
            la_byte = stamp_bgra.getbyte(si + 3)
            next if la_byte == 0
            j = (base_row + x) * 4
            if la_byte == 255 && fully_opaque
              buf.setbyte(j,     stamp_bgra.getbyte(si))
              buf.setbyte(j + 1, stamp_bgra.getbyte(si + 1))
              buf.setbyte(j + 2, stamp_bgra.getbyte(si + 2))
              next
            end
            la = (la_byte / 255.0) * opacity
            next if la <= 0.001
            lb = stamp_bgra.getbyte(si)
            lg = stamp_bgra.getbyte(si + 1)
            lr = stamp_bgra.getbyte(si + 2)
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

      # Compone overlays (logo + label come BGRA stamp pre-renderizzati)
      # e titleblock (BGRA bw×tb_h, append in basso) in UN SOLO
      # load → blend → set_data → save_file. Sostituisce il vecchio
      # combo apply_overlays + append_titleblock che faceva 2 load+2
      # save (= doppia ri-codifica JPG) quando entrambi erano attivi.
      #
      # overlays: array di { bgra:, w:, h:, x:, y:, opacity: }
      #   x,y sono in coordinate (0,0)=top-left della BASE image, NON
      #   del canvas finale espanso col TB. Così gli overlays restano
      #   confinati nell'area immagine (il cartiglio non li copre).
      # tb_bgra: BGRA top-down a larghezza bw, oppure nil.
      # tb_h: altezza del cartiglio in px (0 se tb_bgra nil).
      def composite_to_file(image_path, overlays, tb_bgra, tb_h)
        base = Sketchup::ImageRep.new
        base.load_file(image_path)
        bw = base.width
        bh = base.height

        buf = imagerep_to_bgra(base)
        # Concatena il TB BGRA in coda (top-down → il TB finisce sotto
        # l'immagine base). Niente alloc separata di buffer finale +
        # double copy: append diretto allo string buf.
        buf << tb_bgra if tb_bgra && tb_h > 0

        overlays.each do |ov|
          blend_stamp!(buf, bw, bh,
                       ov[:bgra], ov[:w], ov[:h],
                       ov[:x], ov[:y], ov[:opacity])
        end

        final_h = bh + ((tb_bgra && tb_h > 0) ? tb_h : 0)
        base.set_data(bw, final_h, 32, 0, buf)
        ok = base.save_file(image_path)
        puts "[SM+] composite save_file ok=#{ok.inspect} → #{File.basename(image_path)} " \
             "(#{bw}x#{final_h} overlays=#{overlays.size} tb=#{tb_bgra ? 'y' : 'n'})"
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
      #    B) Immagini esiste e contiene file (oltre alla sotto-cartella
      #       Superate) → crea Immagini/Superate/NN (NN successivo a quelli
      #       esistenti, padded 2 cifre), sposta tutti i file di Immagini lì
      #       (skippando Superate stesso), esporta in Immagini ora svuotata
      #    C) Immagini esiste ma vuota (o contiene solo Superate) → esporta lì
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

        # Lista contenuto di Immagini escludendo "." ".." e la sotto-cartella
        # Superate stessa (che ospita gli archivi precedenti).
        existing = Dir.entries(img_dir).reject do |n|
          n == '.' || n == '..' || n == 'Superate'
        end
        return [img_dir, notes, nil] if existing.empty? # Case C

        # Case B: archive — Superate vive DENTRO Immagini/
        superate_dir = File.join(img_dir, 'Superate')
        unless File.directory?(superate_dir)
          begin
            Dir.mkdir(superate_dir)
          rescue => e
            return [nil, [], "Could not create 'Immagini/Superate': #{e.message}"]
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
          return [nil, [], "Could not create 'Immagini/Superate/#{archive_label}': #{e.message}"]
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
        notes << "Archived #{moved} file(s) → Immagini/Superate/#{archive_label}/"
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
