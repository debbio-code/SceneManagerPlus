require 'tmpdir'
require 'json'

module SceneManagerPlus
  module Core
    # Stampa in scala - MOTORE (Fase 1).
    #
    # Principio: in proiezione parallela `camera.height` E' esattamente
    # l'estensione verticale inquadrata (in pollici). Quindi imporre
    #
    #     camera.height = (altezza area di disegno sul foglio) x denominatore
    #
    # rende la scala esatta per costruzione: 1 mm su carta = N mm nel modello.
    #
    # Fatti misurati in Fase 0 (19.3.253, vedi docs/SU2019-LESSONS.md):
    #  - `view.write_image` conserva SEMPRE l'altezza inquadrata e adatta la
    #    larghezza, con pixel quadrati. Quindi NON serve toccare
    #    `camera.aspect_ratio` (che inquinerebbe l'euristica `matchphoto?`).
    #  - Nessun clamp di write_image fino a 14043x9933 (A0@300DPI). Il vero
    #    tetto e' la memoria del composite, non il render.
    #  - Gli spigoli ordinari sono SEMPRE 1 px (non esiste una loro
    #    larghezza): sono i DPI a decidere lo spessore della linea piu'
    #    sottile sulla carta, e alzarli PEGGIORA il tratto. La gerarchia del
    #    disegno va costruita sui profili (`SilhouetteWidth`).
    module PrintScale
      module_function

      MM_PER_INCH = 25.4

      # Formati ISO 216, in mm, orientamento PORTRAIT (larghezza x altezza).
      PAPERS = {
        'A4' => [210.0, 297.0],
        'A3' => [297.0, 420.0],
        'A2' => [420.0, 594.0],
        'A1' => [594.0, 841.0],
        'A0' => [841.0, 1189.0]
      }.freeze

      PAPER_ORDER = %w[A4 A3 A2 A1 A0].freeze

      # Scale normalizzate, per il suggerimento "questa inquadratura che
      # scala e'?". Usate solo come proposta: la scala la impone l'utente.
      NORMALIZED = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000].freeze

      # Cornice attorno all'area di stampa (disegno + fascia cartiglio),
      # stesso spessore del borderPen del cartiglio.
      FRAME_THICKNESS = 2

      # SilhouetteWidth ha round-trip esatto fino a 20 (misurato). Oltre non
      # e' garantito, quindi clampiamo e lo diciamo.
      MAX_LINE_PX = 20

      # Oltre questa soglia chiediamo conferma: il buffer BGRA del foglio vive
      # in una String Ruby (A0@300DPI = ~560 MB solo per il foglio).
      PEAK_MB_WARN = 700

      # =====================================================================
      # Parsing / utility numeriche
      # =====================================================================

      # Accetta Numeric, "50", "1:50", "0,35" (virgola decimale italiana).
      def parse_num(value, default)
        return default if value.nil?
        return value.to_f if value.is_a?(Numeric)
        t = value.to_s.strip.tr(',', '.')
        t = t.split(':').last.to_s.strip if t.include?(':')
        v = (Float(t) rescue nil)
        v.nil? ? default : v
      end

      def cfg_val(cfg, key, default)
        return default unless cfg
        v = cfg[key]
        v = cfg[key.to_sym] if v.nil?
        v.nil? ? default : v
      end

      # Numero leggibile in un campo di testo: "10" invece di "10.0",
      # ma "0.35" resta "0.35".
      def num_str(v)
        f = v.to_f
        (f - f.round).abs < 1e-9 ? f.round.to_s : f.to_s
      end

      # "1:50" / "1:33.3" (niente decimali inutili sugli interi).
      def format_scale(denom)
        return '-' unless denom.is_a?(Numeric) && denom > 0
        r = denom.round
        (denom - r).abs < 0.01 ? "1:#{r}" : format('1:%.1f', denom)
      end

      # Scala normalizzata piu' vicina, su scala logaritmica (1:37 sta piu'
      # vicino a 1:50 che a 1:25 in senso lineare, ma non percettivamente).
      def nearest_normalized(denom)
        return nil unless denom.is_a?(Numeric) && denom > 0
        NORMALIZED.min_by { |c| (Math.log(c.to_f) - Math.log(denom)).abs }
      end

      # Che scala sta inquadrando la camera, data l'altezza dell'area di
      # disegno sul foglio. nil se la camera e' in prospettiva.
      def scale_from_camera(cam, draw_h_mm)
        return nil if cam.nil? || draw_h_mm.nil? || draw_h_mm <= 0
        return nil if cam.perspective?
        (cam.height.to_f * MM_PER_INCH) / draw_h_mm
      end

      # =====================================================================
      # Geometria: foglio -> area di disegno -> pixel -> camera
      # =====================================================================
      #
      # Ordine dei conti (l'ordine conta, per l'esattezza della scala):
      #  1. area di disegno in mm = foglio - margini - fascia cartiglio
      #  2. pixel = mm / 25.4 * DPI, ARROTONDATI
      #  3. l'altezza camera si ricava dai PIXEL arrotondati, non dai mm
      #     nominali: cosi' la scala e' esatta per l'immagine che esce
      #     davvero, invece di esserlo per un'altezza che poi si arrotonda.
      def compute(cfg)
        errors = []

        paper = cfg_val(cfg, 'paper', 'A3').to_s.upcase
        unless PAPERS.key?(paper)
          errors << "Unknown paper size #{paper.inspect}, falling back to A3"
          paper = 'A3'
        end
        landscape = cfg_val(cfg, 'orientation', 'landscape').to_s.downcase != 'portrait'
        pw, ph = PAPERS[paper]
        sheet_w_mm, sheet_h_mm = landscape ? [ph, pw] : [pw, ph]

        margin_mm = parse_num(cfg_val(cfg, 'margin_mm', 10.0), 10.0)
        margin_mm = 0.0 if margin_mm < 0
        band_mm   = parse_num(cfg_val(cfg, 'titleblock_mm', 0.0), 0.0)
        band_mm   = 0.0 if band_mm < 0
        denom     = parse_num(cfg_val(cfg, 'scale_denom', 50.0), 50.0)
        dpi       = parse_num(cfg_val(cfg, 'dpi', 200.0), 200.0)

        errors << 'Scale denominator must be greater than 0' if denom <= 0
        errors << 'DPI must be greater than 0'               if dpi <= 0

        draw_w_mm = sheet_w_mm - 2 * margin_mm
        draw_h_mm = sheet_h_mm - 2 * margin_mm - band_mm
        if draw_w_mm <= 0 || draw_h_mm <= 0
          errors << format('Margins (%.0f mm) and title block band (%.0f mm) leave no drawing area on %s',
                           margin_mm, band_mm, paper)
        end

        return { errors: errors } unless errors.empty?

        draw_w_px = (draw_w_mm / MM_PER_INCH * dpi).round
        draw_h_px = (draw_h_mm / MM_PER_INCH * dpi).round
        draw_w_px = 1 if draw_w_px < 1
        draw_h_px = 1 if draw_h_px < 1
        band_px   = (band_mm / MM_PER_INCH * dpi).round
        band_px   = 0 if band_px < 0

        # Misure effettive dell'immagine una volta stampata ai DPI dichiarati
        # (differiscono dalle nominali per il solo arrotondamento a pixel).
        draw_w_mm_real = draw_w_px * MM_PER_INCH / dpi
        draw_h_mm_real = draw_h_px * MM_PER_INCH / dpi

        # L'estensione verticale che la camera deve inquadrare, in POLLICI
        # (unita' interna di SketchUp): pixel / DPI = pollici su carta,
        # x denominatore = pollici nel modello.
        camera_height_in = draw_h_px.to_f / dpi * denom

        cover_h_mm = draw_h_mm_real * denom
        cover_w_mm = draw_w_mm_real * denom

        # Spessori: 1 px = 25.4/DPI mm sulla carta. Gli spigoli ordinari sono
        # sempre 1 px, quindi edge_mm e' il tratto piu' sottile ottenibile.
        mm_per_px = MM_PER_INCH / dpi
        profile_mm = parse_num(cfg_val(cfg, 'profile_mm', 0.0), 0.0)
        section_mm = parse_num(cfg_val(cfg, 'section_mm', 0.0), 0.0)
        profile_px = profile_mm > 0 ? [(profile_mm / mm_per_px).round, 1].max : 0
        section_px = section_mm > 0 ? [(section_mm / mm_per_px).round, 1].max : 0
        notes = []
        if profile_px > MAX_LINE_PX
          notes << format('Profile line clamped to %d px (%.2f mm at %d DPI)',
                          MAX_LINE_PX, MAX_LINE_PX * mm_per_px, dpi.round)
          profile_px = MAX_LINE_PX
        end
        if section_px > MAX_LINE_PX
          notes << format('Section cut line clamped to %d px (%.2f mm at %d DPI)',
                          MAX_LINE_PX, MAX_LINE_PX * mm_per_px, dpi.round)
          section_px = MAX_LINE_PX
        end

        full_sheet = cfg_val(cfg, 'sheet_mode', 'full_sheet').to_s != 'drawing_only'
        print_w_px = draw_w_px
        print_h_px = draw_h_px + band_px
        if full_sheet
          canvas_w_px = (sheet_w_mm / MM_PER_INCH * dpi).round
          canvas_h_px = (sheet_h_mm / MM_PER_INCH * dpi).round
          # Centrato: i margini sono uguali per costruzione, e cosi'
          # l'arrotondamento a pixel si distribuisce invece di accumularsi
          # tutto su un lato.
          offset_x_px = ((canvas_w_px - print_w_px) / 2.0).round
          offset_y_px = ((canvas_h_px - print_h_px) / 2.0).round
          offset_x_px = 0 if offset_x_px < 0
          offset_y_px = 0 if offset_y_px < 0
        else
          canvas_w_px = print_w_px
          canvas_h_px = print_h_px
          offset_x_px = 0
          offset_y_px = 0
        end

        # Picco di memoria: buffer del foglio + buffer del render, vivi
        # insieme durante il composite.
        peak_mb = ((canvas_w_px.to_f * canvas_h_px + draw_w_px.to_f * draw_h_px) * 4) / (1024.0 * 1024.0)

        {
          errors:            [],
          notes:             notes,
          paper:             paper,
          landscape:         landscape,
          sheet_w_mm:        sheet_w_mm,
          sheet_h_mm:        sheet_h_mm,
          margin_mm:         margin_mm,
          band_mm:           band_mm,
          band_px:           band_px,
          denom:             denom,
          dpi:               dpi,
          draw_w_mm:         draw_w_mm,
          draw_h_mm:         draw_h_mm,
          draw_w_mm_real:    draw_w_mm_real,
          draw_h_mm_real:    draw_h_mm_real,
          draw_w_px:         draw_w_px,
          draw_h_px:         draw_h_px,
          print_w_px:        print_w_px,
          print_h_px:        print_h_px,
          canvas_w_px:       canvas_w_px,
          canvas_h_px:       canvas_h_px,
          offset_x_px:       offset_x_px,
          offset_y_px:       offset_y_px,
          full_sheet:        full_sheet,
          camera_height_in:  camera_height_in,
          cover_w_mm:        cover_w_mm,
          cover_h_mm:        cover_h_mm,
          mm_per_px:         mm_per_px,
          edge_mm:           mm_per_px,
          profile_mm:        profile_mm,
          section_mm:        section_mm,
          profile_px:        profile_px,
          section_px:        section_px,
          peak_mb:           peak_mb
        }
      end

      # Riepilogo leggibile dei conti, mostrato prima di renderizzare.
      # Fase 2 mostrera' gli stessi numeri nella finestra, live.
      def summary_text(geo, current_denom = nil)
        return Array(geo[:errors]).join("\n") unless Array(geo[:errors]).empty?
        lines = []
        lines << format('Sheet:          %s %s  (%.0f x %.0f mm)',
                        geo[:paper], geo[:landscape] ? 'landscape' : 'portrait',
                        geo[:sheet_w_mm], geo[:sheet_h_mm])
        lines << format('Drawing area:   %.1f x %.1f mm  (margins %.0f mm, title block %.0f mm)',
                        geo[:draw_w_mm], geo[:draw_h_mm], geo[:margin_mm], geo[:band_mm])
        lines << format('Scale:          %s', format_scale(geo[:denom]))
        lines << format('Model covered:  %.2f x %.2f m', geo[:cover_w_mm] / 1000.0, geo[:cover_h_mm] / 1000.0)
        lines << ''
        lines << format('Resolution:     %d DPI', geo[:dpi].round)
        lines << format('Image:          %d x %d px%s',
                        geo[:canvas_w_px], geo[:canvas_h_px],
                        geo[:full_sheet] ? ' (full sheet)' : ' (drawing area only)')
        lines << format('Peak memory:    ~%d MB', geo[:peak_mb].round)
        lines << ''
        lines << format('Ordinary edges: %.3f mm on paper  <- thinnest line possible', geo[:edge_mm])
        if geo[:profile_px] > 0
          lines << format('Profiles:       %d px = %.3f mm', geo[:profile_px], geo[:profile_px] * geo[:mm_per_px])
        else
          lines << 'Profiles:       left as the style has them'
        end
        if geo[:section_px] > 0
          lines << format('Section cuts:   %d px = %.3f mm', geo[:section_px], geo[:section_px] * geo[:mm_per_px])
        end
        if current_denom
          nearest = nearest_normalized(current_denom)
          lines << ''
          lines << format('Current view is about %s (nearest standard scale: %s)',
                          format_scale(current_denom), format_scale(nearest))
        end
        # Cartiglio acceso ma nessuna fascia riservata: la tavola uscirebbe
        # senza. E' il caso che spinge a ripiegare sull'export a serie, che
        # pero' non e' in scala.
        begin
          if geo[:band_mm] <= 0 && Settings.get('titleblock')['enabled']
            lines << ''
            lines << 'WARNING: the title block is enabled but no band is reserved.'
            lines << 'Set "Title block band" to about 20 mm, or this sheet comes out without it.'
          end
        rescue
        end
        # Si nota solo a stampa fatta, quindi va detto prima: SketchUp misura
        # in pixel il testo "screen size", e qui i pixel sono migliaia.
        lines << ''
        lines << 'Reminder: text and dimensions set to "screen size" come out tiny'
        lines << 'at this resolution. Set them to model size to print them right.'
        Array(geo[:notes]).each { |n| lines << "! #{n}" }
        lines.join("\n")
      end

      # =====================================================================
      # Render
      # =====================================================================
      #
      # `page` puo' essere nil: in quel caso si stampa la vista corrente
      # senza attivare nulla. Ritorna [ok, notes[]].
      def render(page, cfg, out_path)
        model = Sketchup.active_model
        return [false, ['No active model']] unless model

        geo = compute(cfg)
        return [false, geo[:errors]] unless Array(geo[:errors]).empty?

        notes = Array(geo[:notes]).dup
        view  = model.active_view
        pages = model.pages
        prev_page = pages.selected_page

        if page && page != prev_page
          pages.selected_page = page
          begin
            Core::Variants.on_scene_activated(page)
          rescue => e
            warn "[SM+] print_scale: variant apply failed: #{e.class}: #{e.message}"
          end
        end

        cam = view.camera
        if cam.perspective?
          restore_after(model, view, pages, prev_page, nil, nil)
          label = page ? "Scene '#{page.name}'" : 'The current view'
          return [false, ["#{label} is in perspective projection.",
                          'A printed scale does not exist for a perspective view: switch the scene to',
                          'Camera > Parallel Projection, update the scene, then print it again.']]
        end

        ro = model.rendering_options
        prev_ro = {}
        %w[SilhouetteWidth ProfileWidth DrawSilhouettes SectionCutWidth].each do |k|
          prev_ro[k] = (ro[k] rescue nil)
        end
        prev_height = cam.height.to_f

        # Bande grigie: vanno TOLTE prima di renderizzare. Restano solo un
        # aiuto per l'occhio nel viewport; con un aspect impostato SU puo'
        # aggiungere lettering all'immagine se non coincide al pixel con
        # quello richiesto.
        prev_aspect = (cam.aspect_ratio.to_f rescue 0.0)
        clear_bands(view)

        tmp_png = File.join(Dir.tmpdir, "smp_print_#{Process.pid}_#{rand(1_000_000)}.png")
        ok = false
        tb_png = nil
        tb_pngs = nil

        begin
          # Spessori: applicati DOPO l'attivazione della pagina. Se la scena
          # ha PAGE_USE_RENDERING_OPTIONS, attivarla ripristina i valori
          # salvati e sovrascriverebbe quanto scritto prima.
          if geo[:profile_px] > 0
            # SilhouetteWidth e' la chiave canonica; ProfileWidth e' un alias
            # accettato ma ignorato in scrittura. Scriverle entrambe e' la
            # regola del progetto (vedi CLAUDE.md, Mini Style Manager).
            ro['SilhouetteWidth'] = geo[:profile_px]
            begin
              ro['ProfileWidth'] = geo[:profile_px]
            rescue
            end
            # Senza profili accesi, la loro larghezza non si vede.
            ro['DrawSilhouettes'] = true
          end
          if geo[:section_px] > 0
            begin
              ro['SectionCutWidth'] = geo[:section_px]
            rescue
            end
          end

          cam.height = geo[:camera_height_in]
          view.invalidate

          write_args = {
            filename:    tmp_png,
            width:       geo[:draw_w_px],
            height:      geo[:draw_h_px],
            antialias:   !!cfg_val(cfg, 'antialias', true),
            transparent: false
          }
          unless view.write_image(write_args)
            return [false, ["SketchUp could not render the image (#{geo[:draw_w_px]}x#{geo[:draw_h_px]} px)."]]
          end

          # Cartiglio dentro la fascia riservata (nil se la fascia è 0 o il
          # cartiglio è disabilitato: in quel caso la fascia resta bianca).
          tb_png, tb_pngs = render_titleblock(page, geo)
          notes << 'Title block enabled but not produced: the band is left empty.' if geo[:band_px] > 0 && tb_png.nil? && Settings.get('titleblock')['enabled']

          compose_notes = compose_sheet(tmp_png, geo, out_path, tb_png)
          notes.concat(compose_notes)

          stamped = stamp_dpi!(out_path, geo[:dpi])
          unless stamped
            notes << 'Could not write the DPI tag into the file: print it at ' \
                     "#{geo[:canvas_w_px]} x #{geo[:canvas_h_px]} px / #{geo[:dpi].round} DPI, or set the size by hand."
          end
          ok = true
        rescue => e
          warn "[SM+] print_scale render: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).join("\n") if e.backtrace
          notes << "#{e.class}: #{e.message}"
          ok = false
        ensure
          begin
            File.delete(tmp_png) if File.file?(tmp_png)
          rescue
          end
          begin
            TitleBlock.cleanup(tb_pngs) if tb_pngs
          rescue
          end
          restore_after(model, view, pages, prev_page, prev_ro, prev_height, prev_aspect)
        end

        [ok, notes]
      end

      # Ripristina rendering options, altezza camera, bande e scena attiva.
      # Rientrante: i parametri prev_* possono essere nil.
      def restore_after(model, view, pages, prev_page, prev_ro, prev_height, prev_aspect = nil)
        begin
          if prev_ro
            ro = model.rendering_options
            prev_ro.each do |k, v|
              next if v.nil?
              begin
                ro[k] = v
              rescue
              end
            end
          end
          cam = view.camera
          if prev_height && !cam.perspective?
            begin
              cam.height = prev_height
            rescue
            end
          end
          if prev_page && pages.selected_page != prev_page
            pages.selected_page = prev_page
            begin
              Core::Variants.on_scene_activated(prev_page)
            rescue
            end
            # Il cambio scena azzera l'aspect del viewport: le bande della
            # scena ripristinata le rimette il suo stesso hook.
            on_scene_activated(prev_page)
          elsif prev_aspect && prev_aspect != 0.0
            begin
              cam.aspect_ratio = prev_aspect
            rescue
            end
          end
          view.invalidate
        rescue => e
          warn "[SM+] print_scale restore: #{e.class}: #{e.message}"
        end
      end

      # =====================================================================
      # Composite: piazza il render sul foglio bianco e disegna la cornice
      # =====================================================================
      #
      # Riusa `Exporter.imagerep_to_bgra` (estrazione pixel in una sola
      # chiamata C). Il buffer e' BGRA top-down, come vuole
      # `ImageRep#set_data` su Windows.
      def compose_sheet(src_png, geo, out_path, tb_png = nil)
        notes = []
        img = Sketchup::ImageRep.new
        img.load_file(src_png)
        bw = img.width
        bh = img.height
        src = Exporter.imagerep_to_bgra(img)

        cw = geo[:canvas_w_px]
        ch = geo[:canvas_h_px]
        ox = geo[:offset_x_px]
        oy = geo[:offset_y_px]

        # Difensivo: se write_image avesse consegnato dimensioni diverse da
        # quelle chieste, ri-centra invece di scrivere fuori dal buffer.
        if bw != geo[:draw_w_px] || bh != geo[:draw_h_px]
          notes << "SketchUp returned #{bw}x#{bh} px instead of #{geo[:draw_w_px]}x#{geo[:draw_h_px]}: " \
                   'the printed scale may be off.'
          ox = ((cw - bw) / 2.0).round
          oy = ((ch - (bh + geo[:band_px])) / 2.0).round
        end
        if bw > cw || bh + geo[:band_px] > ch
          cw = bw
          ch = bh + geo[:band_px]
          ox = 0
          oy = 0
        end
        ox = 0 if ox < 0
        oy = 0 if oy < 0

        # Foglio bianco opaco: tutti i byte a 255 = BGRA (255,255,255,255).
        buf = ("\xFF".b * (cw * ch * 4))
        row_bytes = bw * 4
        (0...bh).each do |y|
          dst = ((y + oy) * cw + ox) * 4
          buf[dst, row_bytes] = src[y * row_bytes, row_bytes]
        end

        # Cartiglio nella fascia riservata, subito sotto il disegno e alla
        # stessa larghezza: la cornice dell'area di stampa lo racchiude.
        if tb_png && File.file?(tb_png) && geo[:band_px] > 0
          begin
            tb_bgra, tb_h = Exporter.load_tb_as_bgra(tb_png, bw)
            tb_h = geo[:band_px] if tb_h > geo[:band_px]
            row_tb = bw * 4
            (0...tb_h).each do |y|
              dy = oy + bh + y
              next if dy < 0 || dy >= ch
              dst = (dy * cw + ox) * 4
              buf[dst, row_tb] = tb_bgra[y * row_tb, row_tb]
            end
          rescue => e
            notes << "Title block not composited: #{e.message}"
            warn "[SM+] print_scale titleblock composite: #{e.class}: #{e.message}"
          end
        end

        # Cornice attorno all'AREA DI STAMPA (disegno + fascia cartiglio),
        # non attorno al foglio: e' il bordo tavola. Disegnata DOPO il
        # cartiglio cosi' il suo bordo esterno e quello della cornice
        # coincidono invece di sovrapporsi male.
        draw_rect_frame!(buf, cw, ch, ox, oy, bw, bh + geo[:band_px], FRAME_THICKNESS)

        img.set_data(cw, ch, 32, 0, buf)
        # ATTENZIONE: `ImageRep#save_file` ritorna `nil` ANCHE quando riesce
        # (verificato su 19.3.253) e SOLLEVA una RuntimeError quando fallisce.
        # Il suo valore di ritorno non e' un esito: l'unico controllo sensato
        # e' che il file esista e non sia vuoto.
        img.save_file(out_path)
        written = File.file?(out_path) ? File.size(out_path) : 0
        notes << "Could not save #{File.basename(out_path)}" if written.zero?
        puts "[SM+] print_scale composite: #{cw}x#{ch} px, drawing #{bw}x#{bh} at (#{ox},#{oy}), " \
             "band #{geo[:band_px]} px -> #{File.basename(out_path)} (#{written} bytes)"
        notes
      end

      # Rettangolo nero opaco spesso `t` px, disegnato SUI bordi interni del
      # rect (x0,y0,w,h) dentro un buffer BGRA `canvas_w x canvas_h`.
      def draw_rect_frame!(buf, canvas_w, canvas_h, x0, y0, w, h, t)
        t = 1 if t < 1
        x1 = x0 + w - 1
        y1 = y0 + h - 1
        return if x1 < 0 || y1 < 0 || x0 >= canvas_w || y0 >= canvas_h
        x1 = canvas_w - 1 if x1 > canvas_w - 1
        y1 = canvas_h - 1 if y1 > canvas_h - 1
        set_black = lambda do |x, y|
          next if x < 0 || y < 0 || x >= canvas_w || y >= canvas_h
          j = (y * canvas_w + x) * 4
          buf.setbyte(j,     0)
          buf.setbyte(j + 1, 0)
          buf.setbyte(j + 2, 0)
          buf.setbyte(j + 3, 255)
        end
        (0...t).each do |k|
          (x0..x1).each do |x|
            set_black.call(x, y0 + k)
            set_black.call(x, y1 - k)
          end
        end
        ((y0 + t)..(y1 - t)).each do |y|
          (0...t).each do |k|
            set_black.call(x0 + k, y)
            set_black.call(x1 - k, y)
          end
        end
      end

      # =====================================================================
      # DPI dentro il file
      # =====================================================================
      #
      # Ne' write_image ne' ImageRep#save_file scrivono la risoluzione fisica.
      # Senza, ogni programma di stampa inventa la sua (di solito 96 DPI) e la
      # scala salta. Qui la scriviamo a mano: PNG -> chunk pHYs, JPG -> campi
      # densita' dell'header JFIF.
      def stamp_dpi!(path, dpi)
        case File.extname(path.to_s).downcase
        when '.png'          then stamp_png_dpi!(path, dpi)
        when '.jpg', '.jpeg' then stamp_jpg_dpi!(path, dpi)
        else false
        end
      rescue => e
        warn "[SM+] stamp_dpi!: #{e.class}: #{e.message}"
        false
      end

      # Tabella CRC-32 (polinomio PNG). Calcolata in Ruby puro per non
      # dipendere da Zlib: la usiamo su 13 byte, il costo e' nullo.
      CRC_TABLE = (0..255).map do |n|
        c = n
        8.times { c = (c & 1 == 1) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        c
      end.freeze

      def crc32(str)
        c = 0xFFFFFFFF
        str.each_byte { |b| c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >> 8) }
        c ^ 0xFFFFFFFF
      end

      def png_chunk(type, data)
        body = type.b + data.b
        [data.bytesize].pack('N') + body + [crc32(body)].pack('N')
      end

      def stamp_png_dpi!(path, dpi)
        data = File.binread(path)
        return false unless data[0, 8] == "\x89PNG\r\n\x1A\n".b
        # pHYs: pixel per unita' X (4), Y (4), unita' (1). unita' 1 = metro.
        ppm = (dpi.to_f / MM_PER_INCH * 1000.0).round
        chunk = png_chunk('pHYs', [ppm].pack('N') + [ppm].pack('N') + [1].pack('C'))

        out = data[0, 8].b.dup
        pos = 8
        inserted = false
        while pos + 8 <= data.bytesize
          len  = data[pos, 4].unpack('N').first
          type = data[pos + 4, 4]
          total = 12 + len
          break if total <= 0 || pos + total > data.bytesize
          # Un eventuale pHYs preesistente viene sostituito, non duplicato.
          out << data[pos, total] unless type == 'pHYs'
          if type == 'IHDR'
            out << chunk
            inserted = true
          end
          pos += total
          break if type == 'IEND'
        end
        return false unless inserted
        File.binwrite(path, out)
        true
      end

      def stamp_jpg_dpi!(path, dpi)
        data = File.binread(path)
        return false unless data[0, 2] == "\xFF\xD8".b        # SOI
        return false unless data[2, 2] == "\xFF\xE0".b        # APP0
        return false unless data[6, 5] == "JFIF\x00".b
        d = dpi.round
        d = 1     if d < 1
        d = 65535 if d > 65535
        out = data.dup
        out.setbyte(13, 1)                  # unita' = punti per pollice
        out.setbyte(14, (d >> 8) & 0xFF)    # Xdensity
        out.setbyte(15, d & 0xFF)
        out.setbyte(16, (d >> 8) & 0xFF)    # Ydensity
        out.setbyte(17, d & 0xFF)
        File.binwrite(path, out)
        true
      end

      # =====================================================================
      # La scala come PROPRIETA' DELLA SCENA (Fase 2)
      # =====================================================================
      #
      # Modello mentale: una pianta a 1:50 e' a 1:50 sempre, non e'
      # un'impostazione di export. Quindi la configurazione di stampa vive
      # sulla PAGINA (page attribute, viaggia col .skp come le varianti
      # colore) e la vista viene rimessa in scala a ogni attivazione.
      #
      # Si salva la cfg INTERA, non solo il denominatore: "1:200" da solo non
      # vuol dire niente, la scala dipende dal foglio. E anche i DPI contano,
      # perche' l'altezza camera si ricava dai pixel arrotondati.
      SCENE_DICT = 'SceneManagerPlus'.freeze
      SCENE_KEY  = 'print_scale'.freeze

      # Tolleranza nel dire "questa scena e' ancora in scala": 0.2% e' molto
      # sotto il visibile ma molto sopra il rumore dell'arrotondamento.
      SCALE_TOL = 0.002

      SCENE_FIELDS = %w[paper orientation scale_denom dpi margin_mm titleblock_mm
                        profile_mm section_mm antialias format sheet_mode].freeze

      def scene_config(page)
        return nil unless page && page.respond_to?(:get_attribute)
        raw = page.get_attribute(SCENE_DICT, SCENE_KEY, nil)
        return nil if raw.nil? || raw.to_s.strip.empty?
        h = JSON.parse(raw.to_s)
        return nil unless h.is_a?(Hash) && h['scale_denom']
        h
      rescue => e
        warn "[SM+] print_scale scene_config: #{e.class}: #{e.message}"
        nil
      end

      def scene_config?(page)
        !scene_config(page).nil?
      end

      # Scrive la cfg sulla pagina. Una sola `set_attribute` (sui modelli con
      # AttributeObserver di plugin terzi ogni write costa ~5s: per questo la
      # cfg e' UN campo JSON e non undici attributi separati).
      #
      # Forza anche `use_camera = true`: una scena che non salva la propria
      # inquadratura non puo' avere una scala.
      def set_scene_config(page, cfg)
        return false unless page
        m = Sketchup.active_model
        return false unless m
        clean = {}
        SCENE_FIELDS.each { |k| clean[k] = cfg[k] unless cfg[k].nil? }
        clean['v'] = 1
        began = false
        begin
          m.start_operation('SM+ Set print scale', true)
          began = true
          page.set_attribute(SCENE_DICT, SCENE_KEY, JSON.generate(clean))
          page.use_camera = true if page.respond_to?(:use_camera?) && !page.use_camera?
          m.commit_operation
          true
        rescue => e
          m.abort_operation if began
          warn "[SM+] print_scale set_scene_config: #{e.class}: #{e.message}"
          false
        end
      end

      def clear_scene_config(page)
        return false unless page
        m = Sketchup.active_model
        return false unless m
        began = false
        begin
          m.start_operation('SM+ Clear print scale', true)
          began = true
          page.set_attribute(SCENE_DICT, SCENE_KEY, '')
          m.commit_operation
          clear_bands(m.active_view)
          true
        rescue => e
          m.abort_operation if began
          warn "[SM+] print_scale clear_scene_config: #{e.class}: #{e.message}"
          false
        end
      end

      # Geometria della scena (nil se non ha una scala impostata).
      def scene_geo(page)
        cfg = scene_config(page)
        return nil unless cfg
        geo = compute(cfg)
        Array(geo[:errors]).empty? ? geo : nil
      end

      def heights_match?(a, b)
        return false unless a.is_a?(Numeric) && b.is_a?(Numeric) && b > 0
        ((a - b) / b).abs <= SCALE_TOL
      end

      # =====================================================================
      # Bande grigie: l'inquadratura vera del foglio dentro il viewport
      # =====================================================================
      #
      # ⚠️ `view.camera.aspect_ratio` NON sporca la scena: `matchphoto?` legge
      # `page.camera` (camera SALVATA), e SU azzera l'aspect del viewport a
      # ogni cambio scena. Ma un `page.update(PAGE_USE_CAMERA)` fatto MENTRE
      # le bande sono attive lo salverebbe nella pagina — vedi la guardia in
      # `SceneModel.update_from_view` e l'esclusione in `matchphoto?`.
      def bands_enabled?
        cfg = Settings.get('print_scale')
        cfg['viewport_frame'].nil? ? true : !!cfg['viewport_frame']
      end

      def apply_bands(view, geo)
        return unless view && geo
        ratio = geo[:draw_w_px].to_f / geo[:draw_h_px]
        return unless ratio > 0
        view.camera.aspect_ratio = ratio if view.camera.aspect_ratio.to_f != ratio
      rescue => e
        warn "[SM+] print_scale apply_bands: #{e.class}: #{e.message}"
      end

      def clear_bands(view)
        return unless view
        view.camera.aspect_ratio = 0.0 if view.camera.aspect_ratio.to_f != 0.0
      rescue => e
        warn "[SM+] print_scale clear_bands: #{e.class}: #{e.message}"
      end

      # =====================================================================
      # Applicazione della scala alla vista
      # =====================================================================
      #
      # Tocca SOLO lo zoom (`camera.height`): la panoramica fatta a mano
      # dall'utente resta dov'e'. Ritorna true se ha cambiato qualcosa.
      def apply_to_view(page, view = nil)
        geo = scene_geo(page)
        return false unless geo
        m = Sketchup.active_model
        return false unless m
        view ||= m.active_view
        cam = view.camera
        if cam.perspective?
          warn "[SM+] print_scale: '#{page.name}' e' in prospettiva, scala non applicabile"
          return false
        end
        changed = false
        unless heights_match?(cam.height.to_f, geo[:camera_height_in])
          cam.height = geo[:camera_height_in]
          changed = true
        end
        bands_enabled? ? apply_bands(view, geo) : clear_bands(view)
        view.invalidate
        changed
      rescue => e
        warn "[SM+] print_scale apply_to_view: #{e.class}: #{e.message}"
        false
      end

      # Hook di attivazione scena, gemello di `Variants.on_scene_activated`.
      # Zero-write sul modello: legge un attributo e al massimo muove la
      # camera. Chiamato anche dal polling a 250ms, quindi deve restare tale.
      def on_scene_activated(page)
        m = Sketchup.active_model
        return unless m
        view = m.active_view
        if page.nil? || !scene_config?(page)
          clear_bands(view)
          return
        end
        apply_to_view(page, view)
      rescue => e
        warn "[SM+] print_scale on_scene_activated: #{e.class}: #{e.message}"
      end

      # Rimette la scena in scala E la salva nell'inquadratura della scena,
      # cosi' il badge torna verde. Usato dal click sull'icona in lista.
      def reapply_and_store(page)
        geo = scene_geo(page)
        return [false, 'This scene has no print scale set.'] unless geo
        m = Sketchup.active_model
        return [false, 'No active model'] unless m
        pages = m.pages
        pages.selected_page = page if pages.selected_page != page
        view = m.active_view
        return [false, "'#{page.name}' is in perspective: a printed scale does not exist for it."] if view.camera.perspective?
        apply_to_view(page, view)
        store_camera!(page, view)
        [true, nil]
      rescue => e
        warn "[SM+] print_scale reapply_and_store: #{e.class}: #{e.message}"
        [false, "#{e.class}: #{e.message}"]
      end

      # Salva l'inquadratura corrente nella scena SENZA portarsi dietro le
      # bande: `page.update(CAMERA)` con l'aspect attivo lo scriverebbe nella
      # pagina, e da li' in poi il plugin la scambierebbe per una Match Photo
      # (misurato). Le bande si rimettono subito dopo.
      def store_camera!(page, view = nil)
        m = Sketchup.active_model
        return false unless m && page
        view ||= m.active_view
        had_bands = view.camera.aspect_ratio.to_f != 0.0
        clear_bands(view)
        bit = Object.const_defined?(:PAGE_USE_CAMERA) ? PAGE_USE_CAMERA : 1
        began = false
        begin
          m.start_operation('SM+ Store scaled camera', true)
          began = true
          page.use_camera = true if page.respond_to?(:use_camera?) && !page.use_camera?
          page.update(bit)
          m.commit_operation
        rescue => e
          m.abort_operation if began
          warn "[SM+] print_scale store_camera!: #{e.class}: #{e.message}"
          return false
        ensure
          if had_bands && (g = scene_geo(page))
            apply_bands(view, g)
          end
        end
        true
      end

      # Payload per la lista scene. nil se la scena non ha una scala.
      # `ok` = l'inquadratura SALVATA nella scena e' davvero a quella scala.
      def scene_badge(page)
        geo = scene_geo(page)
        return nil unless geo
        saved = begin
          c = page.camera
          (c && !c.perspective?) ? c.height.to_f : nil
        rescue
          nil
        end
        no_camera = page.respond_to?(:use_camera?) && !page.use_camera?
        ok = !no_camera && saved && heights_match?(saved, geo[:camera_height_in])
        {
          label:     format_scale(geo[:denom]),
          paper:     geo[:paper],
          landscape: geo[:landscape],
          sheet:     "#{geo[:paper]} #{geo[:landscape] ? 'landscape' : 'portrait'}",
          ok:        !!ok,
          reason:    if no_camera
                       'this scene does not save its camera'
                     elsif saved.nil?
                       'this scene is in perspective'
                     elsif !ok
                       'the saved view is no longer at this scale'
                     end
        }
      rescue => e
        warn "[SM+] print_scale scene_badge: #{e.class}: #{e.message}"
        nil
      end

      # =====================================================================
      # Cartiglio dentro la fascia riservata (Fase 3)
      # =====================================================================
      #
      # Riusa `TitleBlock.render_batch`, lo stesso dell'export a serie, con in
      # piu' il box SCALA. La differenza sostanziale rispetto all'export e'
      # che qui larghezza e altezza vengono dal FOGLIO (area di stampa x
      # fascia), non da `export.width/height`: e' questo che rende la tavola
      # coerente con l'inquadratura che si vede nel viewport.
      #
      # Ritorna il path del PNG (piu' l'hash da ripulire), oppure nil.
      def render_titleblock(page, geo)
        return [nil, nil] if geo[:band_px] <= 0
        tb_cfg = Settings.get('titleblock')
        return [nil, nil] unless tb_cfg['enabled']
        naming_cfg = Settings.get('naming')
        model = Sketchup.active_model
        skp_title = model ? model.title.to_s : ''

        date_str = if (ov = tb_cfg['date_override'].to_s).strip.empty?
                     Time.now.strftime('%d/%m/%Y')
                   else
                     ov
                   end
        pad = [(naming_cfg['pad'] || 2).to_i, 1].max
        num_str = tavola_number(page).to_s.rjust(pad, '0')
        logo = Settings.titleblock_logo_path
        logo = '' unless File.file?(logo)

        items = [{
          uid:        'print_scale',
          client:     Naming.prefix_for(naming_cfg, skp_title),
          tavola:     num_str,
          scene_name: page ? page.name.to_s : ''
        }]
        pngs = TitleBlock.render_batch(items,
          width:              geo[:print_w_px],
          height:             geo[:band_px],
          font_family:        (tb_cfg['font_family'] || 'Century Gothic'),
          date:               date_str,
          project_by:         (tb_cfg['project_by'] || ''),
          designer:           (tb_cfg['designer'] || ''),
          project_phase:      (tb_cfg['project_phase'] || 'Definitivo'),
          company_lines:      TitleBlock.load_company_lines,
          logo_path:          logo,
          tavola_placeholder: '0' * pad,
          # I due campi nuovi: la tavola dice da sé a che scala è e a quale
          # condizione quella scala vale.
          scala_value:        format_scale(geo[:denom]),
          stampa_value:       format('%s %s al 100%%', geo[:paper],
                                     geo[:landscape] ? 'orizz.' : 'vert.')
        )
        [pngs['print_scale'], pngs]
      rescue => e
        warn "[SM+] print_scale titleblock: #{e.class}: #{e.message}"
        [nil, nil]
      end

      # Numero tavola = stessa posizione 1-based dell'ordine logico usata dal
      # naming e dall'export, così la stessa scena porta lo stesso numero da
      # qualunque strada esca.
      def tavola_number(page)
        return 1 unless page
        pairs = Naming.ordered_scene_pairs
        idx = pairs.index { |pair| pair[0] == page }
        idx ? idx + 1 : 1
      rescue
        1
      end

      # Refresh della lista scene, se la finestra principale e' aperta.
      # Guardato: il Core non deve dipendere dalla UI per funzionare.
      def refresh_main_dialog
        return unless defined?(SceneManagerPlus::UI::Dialog)
        SceneManagerPlus::UI::Dialog.push_state
      rescue => e
        warn "[SM+] print_scale refresh_main_dialog: #{e.class}: #{e.message}"
      end

      # =====================================================================
      # Harness interattivo (SOLO Fase 1)
      # =====================================================================
      #
      # Serve a collaudare il motore col metro sul foglio. In Fase 2 lo
      # sostituisce la finestra "Print to scale" vera, che leggera' e
      # scrivera' lo stesso gruppo di settings 'print_scale'.
      def run_interactive(target_page = nil)
        model = Sketchup.active_model
        return ::UI.messagebox('No active model.') unless model

        page = target_page || model.pages.selected_page
        # Se la scena ha gia' una scala si riparte da quella, altrimenti dai
        # default di progetto: cosi' riaprire la finestra su una tavola
        # mostra com'e' impostata, non i default.
        cfg = (page && scene_config(page)) || Settings.get('print_scale')

        prompts = ['Paper', 'Orientation', 'Scale  1 :', 'Resolution (DPI)',
                   'Margins (mm)', 'Title block band (mm)',
                   'Profile line (mm, 0 = leave)', 'Sheet', 'Format']
        defaults = [
          cfg['paper'],
          cfg['orientation'].to_s == 'portrait' ? 'Portrait' : 'Landscape',
          num_str(cfg['scale_denom']),
          num_str(cfg['dpi']),
          num_str(cfg['margin_mm']),
          num_str(cfg['titleblock_mm']),
          num_str(cfg['profile_mm']),
          cfg['sheet_mode'].to_s == 'drawing_only' ? 'Drawing area only' : 'Full sheet',
          cfg['format'].to_s.upcase
        ]
        lists = [PAPER_ORDER.join('|'), 'Landscape|Portrait', '', '', '', '', '',
                 'Full sheet|Drawing area only', 'PNG|JPG']

        res = ::UI.inputbox(prompts, defaults, lists, 'Print to scale')
        return unless res

        new_cfg = {
          'paper'         => res[0].to_s,
          'orientation'   => res[1].to_s.downcase.start_with?('p') ? 'portrait' : 'landscape',
          'scale_denom'   => parse_num(res[2], cfg['scale_denom']),
          'dpi'           => parse_num(res[3], cfg['dpi']),
          'margin_mm'     => parse_num(res[4], cfg['margin_mm']),
          'titleblock_mm' => parse_num(res[5], cfg['titleblock_mm']),
          'profile_mm'    => parse_num(res[6], cfg['profile_mm']),
          'section_mm'    => cfg['section_mm'],
          'sheet_mode'    => res[7].to_s.start_with?('D') ? 'drawing_only' : 'full_sheet',
          'format'        => res[8].to_s.downcase,
          'antialias'     => cfg['antialias']
        }
        Settings.set('print_scale', new_cfg)
        Settings.flush!(model)

        geo = compute(new_cfg)
        unless Array(geo[:errors]).empty?
          return ::UI.messagebox(Array(geo[:errors]).join("\n"))
        end

        current = scale_from_camera(model.active_view.camera, geo[:draw_h_mm])
        msg = summary_text(geo, current)
        msg += "\n\nScene: #{page ? page.name : '(current view, no scene active)'}"
        if geo[:peak_mb] > PEAK_MB_WARN
          msg += format("\n\nWARNING: this needs about %d MB of memory. SketchUp may run out.",
                        geo[:peak_mb].round)
        end
        if page
          msg += "\n\nYES     set this scale on the scene AND render it now" \
                 "\nNO      only set the scale on the scene (render later)" \
                 "\nCANCEL  do nothing"
          mb_kind = Object.const_defined?(:MB_YESNOCANCEL) ? MB_YESNOCANCEL : 3
        else
          msg += "\n\nRender now?"
          mb_kind = Object.const_defined?(:MB_OKCANCEL) ? MB_OKCANCEL : 1
        end
        answer = ::UI.messagebox(msg, mb_kind)
        id_yes    = Object.const_defined?(:IDYES)    ? IDYES    : 6
        id_no     = Object.const_defined?(:IDNO)     ? IDNO     : 7
        id_ok     = Object.const_defined?(:IDOK)     ? IDOK     : 1
        if page
          return unless [id_yes, id_no].include?(answer)
          # La scala diventa memoria della scena: si salva la cfg, si rimette
          # la vista in scala e si salva l'inquadratura NELLA scena, cosi'
          # riattivandola in futuro e' gia' giusta (badge verde).
          set_scene_config(page, new_cfg)
          model.pages.selected_page = page if model.pages.selected_page != page
          apply_to_view(page)
          store_camera!(page)
          refresh_main_dialog
          if answer == id_no
            Sketchup.status_text = "Print scale #{format_scale(geo[:denom])} set on '#{page.name}'"
            return
          end
        else
          return unless answer == id_ok
        end

        ext = new_cfg['format'] == 'jpg' ? '.jpg' : '.png'
        base = Exporter.sanitize_filename(
          "#{page ? page.name : 'view'}_#{geo[:paper]}_1-#{geo[:denom].round}"
        )
        dir = model.path.to_s.empty? ? nil : File.dirname(model.path)
        chosen = ::UI.savepanel('Save the print to scale', dir, base + ext)
        return unless chosen
        chosen += ext unless File.extname(chosen).downcase == ext

        Sketchup.status_text = 'Scene Manager+: rendering print to scale...'
        t0 = Time.now
        ok, notes = render(page, new_cfg, chosen)
        Sketchup.status_text = ''

        if ok
          out = ["Saved: #{chosen}", '',
                 format('%d x %d px at %d DPI = %.1f x %.1f mm on paper',
                        geo[:canvas_w_px], geo[:canvas_h_px], geo[:dpi].round,
                        geo[:canvas_w_px] * MM_PER_INCH / geo[:dpi],
                        geo[:canvas_h_px] * MM_PER_INCH / geo[:dpi]),
                 format('Scale %s - print at 100%% (no "fit to page")', format_scale(geo[:denom])),
                 format('Rendered in %.1f s', Time.now - t0)]
          out += ['', 'Notes:'] + Array(notes).map { |n| "- #{n}" } unless Array(notes).empty?
          ::UI.messagebox(out.join("\n"))
        else
          ::UI.messagebox((['Print to scale failed.', ''] + Array(notes)).join("\n"))
        end
      end
    end
  end
end
