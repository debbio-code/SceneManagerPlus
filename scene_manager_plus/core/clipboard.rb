require 'json'

module SceneManagerPlus
  module Core
    # Copia/Incolla scene cross-file (Fase A + B).
    #
    # SU 2019 Windows apre file diversi in PROCESSI separati → una var Ruby
    # module-level non è condivisa tra i due. Quindi la clipboard vive su
    # disco come JSON: ~/.scene_manager_plus/clipboard.json (schema v1,
    # `smp-scene-clipboard/1`).
    #
    # Limiti noti (vedi CLAUDE.md, sezione "Copia/incolla scene"):
    #  - Scene Match Photo escluse (l'API Ruby SU 2019 non espone la foto).
    #  - Section planes / hidden geometry non trasferiti (legati alla
    #    geometria del file sorgente).
    #  - Layer/tag NON ancora trasferiti (Fase C).
    #
    # Cosa viaggia: camera, nome, descrizione, flag use_*, stile (snapshot
    # rendering_options → slot del pool in destinazione), fog (dentro le RO),
    # colore scena.
    module Clipboard
      module_function

      SCHEMA = 'smp-scene-clipboard/1'.freeze

      def clipboard_path
        File.join(Dir.home, '.scene_manager_plus', 'clipboard.json')
      end

      def model
        Sketchup.active_model
      end

      # ── Copy ──────────────────────────────────────────────────────────

      # Serializza le scene `uids` (selezione main window) nel clipboard.json.
      # Ritorna un hash report: { copied:, skipped_mp: [names], styles: n }
      # oppure nil se niente da copiare / nessun modello.
      def copy(uids)
        m = model
        return nil unless m
        ids = Array(uids).compact
        return { copied: 0, skipped_mp: [], styles: 0, two_point: [] } if ids.empty?

        skipped_mp = []
        two_point  = []
        pages = []
        ids.each do |uid|
          p = Core::SceneModel.find_by_id(uid)
          next unless p
          if Core::SceneModel.matchphoto?(p)
            skipped_mp << p.name.to_s
            next
          end
          # Two-point perspective: la scena si copia, ma il 2d non è
          # ricostruibile in paste (API SU 2019). Segnaliamo nel report.
          two_point << p.name.to_s if two_point?(p)
          pages << [uid, p]
        end

        # Stili distinti usati dalle scene copiate (dedup).
        # style_key locale = "src-style-<n>" stabile per nome stile sorgente.
        style_names = pages.map { |(_uid, p)| Core::SceneModel.page_style_name(p) }
                           .compact.uniq
        style_key_by_name = {}
        style_names.each_with_index { |sn, i| style_key_by_name[sn] = "src-style-#{i}" }

        styles_payload = read_styles_snapshot(m, style_names, style_key_by_name)

        scenes_payload = pages.map do |(uid, p)|
          sn = Core::SceneModel.page_style_name(p)
          {
            'name'        => p.name.to_s,
            'description' => p.description.to_s,
            'scene_color' => (Core::SceneModel.get_scene_color(uid) || ''),
            'style_key'   => (sn ? style_key_by_name[sn] : nil),
            'flags'       => flags_of(p),
            'camera'      => camera_of(p),
            'is_matchphoto' => false
          }
        end

        doc = {
          'schema'            => SCHEMA,
          'created_at'        => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
          'source_model'      => (File.basename(m.path) rescue '').to_s,
          'source_model_guid' => (m.guid rescue '').to_s,
          'styles'            => styles_payload,
          'scenes'            => scenes_payload
        }

        write_doc(doc)
        { copied: scenes_payload.size, skipped_mp: skipped_mp, styles: styles_payload.size, two_point: two_point }
      rescue => e
        warn "[SM+] Clipboard.copy: #{e.class}: #{e.message}"
        warn e.backtrace.first(4).join("\n")
        nil
      end

      # Attiva ogni stile distinto per leggerne le rendering_options. Muta il
      # viewport temporaneamente → salva/ripristina selected_style. Wrappato in
      # un'operazione transparent (disable_ui) per non sporcare l'undo né
      # rinfrescare gli inspector.
      def read_styles_snapshot(m, style_names, style_key_by_name)
        return [] if style_names.empty?
        out = []
        prev_style = (m.styles.selected_style rescue nil)
        # Salva la vista: attivare stili + commit può far snappare il viewport.
        # La copy deve essere invisibile sul viewport → ripristiniamo a fine.
        # Ripristino preferito via selected_page (ricarica la camera salvata
        # COMPLETA, two-point + pan inclusi); Camera.new è solo fallback per
        # camera libera (nessuna scena attiva) e PERDE il two-point/pan, quindi
        # va usato solo quando non c'è scena da riattivare.
        prev_page = m.pages.selected_page
        prev_cam = begin
                     c = m.active_view.camera
                     Sketchup::Camera.new(c.eye, c.target, c.up, c.perspective?).tap do |nc|
                       c.perspective? ? (nc.fov = c.fov) : (nc.height = c.height)
                     end
                   rescue
                     nil
                   end
        began = false
        begin
          m.start_operation('SM+ Read styles for copy', true, false, true)
          began = true
          style_names.each do |sn|
            st = m.styles.find { |s| s.name.to_s == sn }
            next unless st
            m.styles.selected_style = st
            ro_snapshot = {}
            m.rendering_options.each_pair do |k, v|
              sv = serialize_ro_value(v)
              ro_snapshot[k] = sv unless sv == :skip
            end
            out << {
              'key'               => style_key_by_name[sn],
              'native_name'       => sn,
              # Nome che l'utente vede: sui file nuovi è il nome nativo, sui
              # legacy non ancora migrati è il nickname. In paste diventa il
              # nome vero dello stile creato.
              'style_name'        => Core::Styles.display_name(sn),
              # 'nickname' resta per i clipboard.json scritti da versioni
              # precedenti (letto in fallback dal paste).
              'nickname'          => (Core::Styles.get_nickname(sn) || ''),
              'badge_color'       => (Core::Styles.get_color(sn) || ''),
              'rendering_options' => ro_snapshot
            }
          end
          m.styles.selected_style = prev_style if prev_style
          m.commit_operation
        rescue => e
          m.abort_operation if began
          warn "[SM+] Clipboard.read_styles_snapshot: #{e.class}: #{e.message}"
        end
        # Ripristina la vista pre-copy (viewport invisibile alla copy).
        # selected_page ricarica la camera completa (two-point + pan); Camera.new
        # è fallback lossy solo se non eravamo su una scena.
        # MP guard: in copy prev_page è la STESSA pagina già attiva (la copy non
        # cambia pagina, snappa solo la camera). Ri-selezionare la stessa pagina
        # Match Photo con eventuale state dirty può scatenare un BugSplat
        # (vedi CLAUDE.md). Per le MP NON ri-selezioniamo: lo snap della copy ha
        # già ripristinato la loro camera (two-point inclusa).
        begin
          if prev_page && prev_page.valid? && !Core::SceneModel.matchphoto?(prev_page)
            m.pages.selected_page = prev_page
          elsif prev_page.nil? && prev_cam
            m.active_view.camera = prev_cam
          end
        rescue => e
          warn "[SM+] Clipboard.read_styles_snapshot: view restore failed: #{e.message}"
        end
        out
      end

      # Valori RO serializzabili in JSON. Color → hex; primitivi passati così
      # come sono; tutto il resto → :skip (omesso dallo snapshot).
      def serialize_ro_value(v)
        return Core::Styles.color_to_hex(v) if v.is_a?(Sketchup::Color)
        case v
        when Numeric, String, true, false, nil then v
        else :skip
        end
      end

      def flags_of(page)
        Core::SceneModel::FLAG_KEYS.each_with_object({}) do |k, h|
          h[k] = page.send("#{k}?") ? true : false
        end
      end

      def camera_of(page)
        c = page.camera
        persp = c.perspective?
        {
          'perspective'  => persp,
          'eye'          => c.eye.to_a,
          'target'       => c.target.to_a,
          'up'           => c.up.to_a,
          'fov'          => (persp ? (c.fov rescue nil) : nil),
          'height'       => (persp ? nil : (c.height rescue nil)),
          'aspect_ratio' => (c.aspect_ratio rescue 0.0),
          # Two-point perspective: registrato per record/detection ma NON
          # ricostruibile in paste — SU 2019 non espone setter per
          # center_2d/scale_2d/is_2d e Camera#copy azzera il 2d. La scena
          # incollata sarà in prospettiva normale (vedi warning in copy).
          'is_2d'        => (c.is_2d? rescue false),
          'center_2d'    => (c.center_2d.to_a rescue nil),
          'scale_2d'     => (c.scale_2d rescue nil)
        }
      end

      # True se la scena è in Two Point Perspective (camera raddrizzata).
      def two_point?(page)
        page.camera.is_2d? rescue false
      end

      def write_doc(doc)
        path = clipboard_path
        dir = File.dirname(path)
        require 'fileutils'
        FileUtils.mkdir_p(dir) unless File.directory?(dir)
        tmp = "#{path}.tmp"
        File.open(tmp, 'w') { |f| f.write(JSON.pretty_generate(doc)) }
        File.delete(path) if File.exist?(path)
        File.rename(tmp, path)
      end

      # ── Read / peek ───────────────────────────────────────────────────

      # Documento clipboard completo, o nil se assente/illeggibile/schema errato.
      def read
        path = clipboard_path
        return nil unless File.exist?(path)
        doc = JSON.parse(File.read(path))
        return nil unless doc.is_a?(Hash) && doc['schema'] == SCHEMA
        doc
      rescue => e
        warn "[SM+] Clipboard.read: #{e.class}: #{e.message}"
        nil
      end

      # Metadata leggeri per la UI: { source_model, scene_count, style_count,
      # created_at, scene_names: [...] }. nil se clipboard vuota.
      def peek
        doc = read
        return nil unless doc
        scenes = Array(doc['scenes'])
        {
          'source_model' => doc['source_model'].to_s,
          'scene_count'  => scenes.size,
          'style_count'  => Array(doc['styles']).size,
          'created_at'   => doc['created_at'].to_s,
          'scene_names'  => scenes.map { |s| s['name'].to_s }
        }
      end

      # ── Paste ─────────────────────────────────────────────────────────

      # Ricrea nel modello corrente le scene salvate nel clipboard.json.
      # Ritorna un hash report o nil se niente da incollare.
      def paste
        m = model
        return nil unless m
        doc = read
        if doc.nil? || Array(doc['scenes']).empty?
          ::UI.messagebox("Clipboard is empty.\nCopy some scenes first.")
          return nil
        end

        scenes = Array(doc['scenes'])
        styles = Array(doc['styles'])

        # 1) Crea uno stile nativo per ogni stile sorgente (dedup per key).
        #    Ogni create apre la propria operazione (come "+ New style").
        style_map = {}   # key → Sketchup::Style
        styles.each do |sh|
          key = sh['key'].to_s
          # 'style_name' è la chiave corrente; 'nickname'/'native_name' sono
          # il fallback per i clipboard.json scritti da versioni precedenti.
          want = sh['style_name'].to_s.strip
          want = sh['nickname'].to_s.strip    if want.empty?
          want = sh['native_name'].to_s.strip if want.empty?
          # create_style_from_ro_hash rende il nome unico da solo (suffisso
          # numerico), quindi qui non serve validare: incollare due volte lo
          # stesso stile dà "Vista notturna" e "Vista notturna 2".
          st = Core::Styles.create_style_from_ro_hash(
            sh['rendering_options'] || {}, name: want
          )
          unless st
            # errore → la primitiva ha già mostrato il messagebox se serviva
            ::UI.messagebox("Paste aborted: could not create a style.")
            return nil
          end
          bc = sh['badge_color'].to_s.strip
          Core::Styles.set_color(st.name, bc) unless bc.empty?
          style_map[key] = st
        end

        # 2) Crea le scene in una sola operazione (1 Ctrl+Z per le pagine).
        # Salva la vista corrente: pages.add + apply_camera muovono il viewport
        # (ogni nuova scena diventa selected_page con la sua camera). A fine
        # paste ripristiniamo, così l'utente NON viene catapultato sull'ultima
        # scena incollata — resta dov'era a navigare.
        prev_page = m.pages.selected_page
        prev_cam  = begin
                      c = m.active_view.camera
                      Sketchup::Camera.new(c.eye, c.target, c.up, c.perspective?).tap do |nc|
                        c.perspective? ? (nc.fov = c.fov) : (nc.height = c.height)
                      end
                    rescue
                      nil
                    end
        existing_names = m.pages.map { |p| p.name.to_s }
        created = []
        m.start_operation('SM+ Paste scenes', true)
        begin
          scenes.each do |sc|
            name = dedup_name(sc['name'].to_s, existing_names)
            existing_names << name

            apply_camera(m, sc['camera'])

            stkey = sc['style_key']
            if stkey && (st = style_map[stkey.to_s])
              m.styles.selected_style = st
            end

            page = m.pages.add(name)
            page.description = sc['description'].to_s

            apply_flags(page, sc['flags'])

            uid = Core::SceneModel.page_id(page)
            scolor = sc['scene_color'].to_s.strip
            Core::SceneModel.set_scene_color(uid, scolor) unless scolor.empty?

            created << uid
          end
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] Clipboard.paste: #{e.class}: #{e.message}"
          warn e.backtrace.first(5).join("\n")
          ::UI.messagebox("Paste failed: #{e.message}")
          return nil
        end

        # 3) Persisti/locka l'ordine logico (le nuove scene sono già in coda).
        begin
          Core::SceneModel.set_logical_order(Core::SceneModel.logical_order)
        rescue => e
          warn "[SM+] Clipboard.paste: set_logical_order failed: #{e.message}"
        end

        # 4) Ripristina la vista pre-paste: se eravamo su una scena, riattivala
        # (ripristina camera/stile/layer); altrimenti rimetti la camera libera.
        begin
          if prev_page && prev_page.valid?
            m.pages.selected_page = prev_page
          elsif prev_cam
            m.active_view.camera = prev_cam
          end
        rescue => e
          warn "[SM+] Clipboard.paste: view restore failed: #{e.message}"
        end

        {
          pasted:      created.size,
          styles:      style_map.size,
          source:      doc['source_model'].to_s,
          same_model:  (doc['source_model_guid'].to_s == (m.guid rescue '').to_s)
        }
      rescue => e
        warn "[SM+] Clipboard.paste(outer): #{e.class}: #{e.message}"
        warn e.backtrace.first(4).join("\n")
        nil
      end

      def apply_camera(m, c)
        return unless c.is_a?(Hash) && c['eye'] && c['target'] && c['up']
        eye    = Geom::Point3d.new(*Array(c['eye']))
        target = Geom::Point3d.new(*Array(c['target']))
        up     = Geom::Vector3d.new(*Array(c['up']))
        persp  = c['perspective'] ? true : false
        cam = Sketchup::Camera.new(eye, target, up, persp)
        if persp
          cam.fov = c['fov'] if c['fov']
        elsif c['height']
          cam.height = c['height']
        end
        m.active_view.camera = cam
      rescue => e
        warn "[SM+] Clipboard.apply_camera: #{e.message}"
      end

      # Forza i flag use_* dallo schema con diff current != v (regola
      # anti-crash MP + perf observer terzi, cfr. CLAUDE.md).
      def apply_flags(page, flags)
        return unless flags.is_a?(Hash)
        Core::SceneModel::FLAG_KEYS.each do |k|
          next unless flags.key?(k)
          setter = "#{k}="
          next unless page.respond_to?(setter)
          want = flags[k] ? true : false
          cur  = page.send("#{k}?") ? true : false
          page.send(setter, want) if cur != want
        rescue => e
          warn "[SM+] apply_flags #{k}: #{e.message}"
        end
      end

      def dedup_name(base, existing)
        base = 'Scene' if base.nil? || base.empty?
        return base unless existing.include?(base)
        i = 2
        i += 1 while existing.include?("#{base} (#{i})")
        "#{base} (#{i})"
      end
    end
  end
end
