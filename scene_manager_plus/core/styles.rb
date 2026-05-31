module SceneManagerPlus
  module Core
    # Gestione del pool di stili pre-bundlati + nickname per-modello.
    #
    # Pool di slot (assets/styles/slot_NN.style):
    #   25 file .style bundled, ciascuno con nome embedded "SM+ Slot NN".
    #   Allocazione lazy: quando il plugin deve creare un nuovo stile, carica
    #   il primo slot_NN.style il cui nome non è già presente in model.styles
    #   (così supporta file legacy che hanno già usato il plugin, riempie i
    #   buchi se l'utente ha cancellato a mano qualche slot, ecc.).
    #
    # Nickname per-modello:
    #   Mappa native_name → friendly_name salvata come attributo del modello
    #   (dict 'SMP_style_nicks', chiavi = nome stile nativo). Il nickname vale
    #   solo dentro il plugin: il native Styles browser di SU mostra sempre il
    #   nome reale. Travels with the .skp.
    module Styles
      module_function

      SLOT_PREFIX     = 'SM+ Slot '.freeze
      NICKNAMES_DICT  = 'SMP_style_nicks'.freeze
      COLORS_DICT     = 'SMP_style_colors'.freeze
      MAX_SLOT_INDEX  = 25 # vedi tools/generate-slot-styles.rb

      def model
        Sketchup.active_model
      end

      def styles_dir
        File.join(PLUGIN_DIR, 'assets', 'styles')
      end

      def slot_filename(n)
        format('slot_%02d.style', n)
      end

      def slot_name(n)
        format('%s%02d', SLOT_PREFIX, n)
      end

      def slot_path(n)
        File.join(styles_dir, slot_filename(n))
      end

      # Primo indice NN (1..MAX_SLOT_INDEX) il cui name "SM+ Slot NN" non è
      # già presente nel modello. Ritorna nil se il pool è esaurito.
      def next_free_slot_index(m = model)
        return nil unless m && m.respond_to?(:styles) && m.styles
        present = m.styles.map { |s| s.name.to_s }
        (1..MAX_SLOT_INDEX).each do |n|
          return n unless present.include?(slot_name(n))
        end
        nil
      end

      # Carica il prossimo slot libero nel modello (styles.add_style).
      # Ritorna il Sketchup::Style appena aggiunto, o nil se:
      #   - pool esaurito (con messagebox di avviso)
      #   - file .style mancante dal bundle
      #   - add_style fallisce silenziosamente
      # Opzionale: nickname = stringa friendly da associare allo stile appena
      # creato (vedi set_nickname).
      def allocate_new_slot(nickname: nil)
        m = model
        return nil unless m
        n = next_free_slot_index(m)
        unless n
          ::UI.messagebox(
            "Pool di stili esaurito (#{MAX_SLOT_INDEX} slot occupati).\n\n" \
            "Per estendere il pool: rilancia tools/generate-slot-styles.rb\n" \
            "su una postazione dev aumentando NUM_SLOTS, poi commit dei\n" \
            "nuovi assets/styles/slot_NN.style."
          )
          return nil
        end

        path = slot_path(n)
        unless File.exist?(path)
          ::UI.messagebox(
            "File slot mancante: #{path}\n\n" \
            "Asset .style bundled non trovato. Riavvio plugin e/o re-deploy."
          )
          return nil
        end

        name = slot_name(n)
        m.start_operation('SM+ Allocate style slot', true)
        begin
          # add_style(path, activate). Mettiamo activate=false: l'attivazione
          # eventuale la decide il caller (es. assign_style farà il proprio
          # selected_style=). Evitiamo side-effect non richiesti su scena
          # attiva e su style dirty pending.
          m.styles.add_style(path, false)
          loaded = m.styles.find { |s| s.name == name }
          unless loaded
            m.abort_operation
            warn "[SM+] allocate_new_slot: add_style non ha aggiunto '#{name}'"
            return nil
          end
          set_nickname(name, nickname) if nickname && !nickname.to_s.strip.empty?
          m.commit_operation
          loaded
        rescue => e
          m.abort_operation
          warn "[SM+] allocate_new_slot: #{e.class}: #{e.message}"
          nil
        end
      end

      # Variante "save as new style": alloca uno slot dal pool e ci committa
      # dentro le rendering options correnti del viewport. Il risultato è uno
      # stile che, quando applicato a una scena, riproduce esattamente la vista
      # corrente — comprese eventuali modifiche pending non ancora salvate
      # sullo stile attivo (è esattamente lo use case del branch "NO = save as
      # new" del dialog dirty-style).
      #
      # Flusso:
      #   1. Snapshot di tutte le model.rendering_options (= ciò che il
      #      viewport mostra ora, dirty edit inclusi)
      #   2. add_style(slot_path, false) — aggiunge lo slot al modello
      #   3. styles.selected_style = nuovo slot — viewport ora mostra le RO
      #      "template" dello slot; eventuali pending edit sullo stile
      #      precedente vengono droppate silenziosamente (è OK: le abbiamo
      #      nello snapshot e lo stile precedente torna pulito allo state
      #      salvato, comportamento equivalente al "Don't save" nativo)
      #   4. Riapplica snapshot su model.rendering_options
      #   5. styles.update_selected_style — committa le RO restored allo
      #      stile nuovo
      #   6. Set nickname
      #
      # Tutto in 1 start_operation = 1 Ctrl+Z.
      def allocate_new_slot_from_viewport(nickname: nil)
        m = model
        return nil unless m
        n = next_free_slot_index(m)
        unless n
          ::UI.messagebox(
            "Pool di stili esaurito (#{MAX_SLOT_INDEX} slot occupati).\n\n" \
            "Per estendere il pool: rilancia tools/generate-slot-styles.rb\n" \
            "su una postazione dev aumentando NUM_SLOTS, poi commit dei\n" \
            "nuovi assets/styles/slot_NN.style."
          )
          return nil
        end
        path = slot_path(n)
        unless File.exist?(path)
          ::UI.messagebox("File slot mancante: #{path}")
          return nil
        end

        name = slot_name(n)

        # Snapshot rendering options prima di toccare nulla.
        ro = m.rendering_options
        snapshot = {}
        ro.each_pair { |k, v| snapshot[k] = v }

        m.start_operation('SM+ New style from viewport', true)
        begin
          m.styles.add_style(path, false)
          loaded = m.styles.find { |s| s.name == name }
          unless loaded
            m.abort_operation
            warn "[SM+] allocate_new_slot_from_viewport: add_style non ha aggiunto '#{name}'"
            return nil
          end

          # Switching active style: scrive le RO "template" dello slot su
          # model.rendering_options (droppando dirty edit precedenti).
          m.styles.selected_style = loaded

          # Restore snapshot → ora model.rendering_options ricalca il viewport
          # come prima dello switch.
          snapshot.each do |k, v|
            begin
              ro[k] = v
            rescue
              # alcune chiavi possono essere read-only o non riassegnabili al
              # valore corrente — ignoriamo, best-effort.
            end
          end

          # Committa: lo slot 'name' ora contiene esattamente la vista
          # catturata. È persistente sullo stile, non più "dirty".
          m.styles.update_selected_style

          set_nickname(name, nickname) if nickname && !nickname.to_s.strip.empty?

          m.commit_operation
          loaded
        rescue => e
          m.abort_operation
          warn "[SM+] allocate_new_slot_from_viewport: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          nil
        end
      end

      # Come allocate_new_slot_from_viewport ma applica uno snapshot di
      # rendering options ARBITRARIO invece di catturare il viewport corrente.
      # Usato dal paste cross-file (Core::Clipboard): lo snapshot RO arriva
      # dal clipboard.json del file sorgente, con i colori serializzati come
      # stringhe hex "#rrggbb".
      #
      # ro_hash: { 'BackgroundColor' => '#ffffff', 'EdgeColorMode' => 1, ... }
      #   I valori colore sono hex string; vengono convertiti in Sketchup::Color
      #   inferendo il tipo dalla RO corrente dello slot template (se la chiave
      #   è un colore nello slot, la stringa hex viene promossa a Color).
      # nickname: stringa friendly opzionale (validazione unicità a monte).
      #
      # Ritorna il Sketchup::Style allocato o nil (pool esaurito / errore).
      def allocate_new_slot_from_ro_hash(ro_hash, nickname: nil)
        m = model
        return nil unless m
        ro_hash ||= {}
        n = next_free_slot_index(m)
        unless n
          ::UI.messagebox(
            "Pool di stili esaurito (#{MAX_SLOT_INDEX} slot occupati).\n\n" \
            "Per estendere il pool: rilancia tools/generate-slot-styles.rb\n" \
            "su una postazione dev aumentando NUM_SLOTS, poi commit dei\n" \
            "nuovi assets/styles/slot_NN.style."
          )
          return nil
        end
        path = slot_path(n)
        unless File.exist?(path)
          ::UI.messagebox("File slot mancante: #{path}")
          return nil
        end
        name = slot_name(n)

        m.start_operation('SM+ New style from snapshot', true)
        begin
          m.styles.add_style(path, false)
          loaded = m.styles.find { |s| s.name == name }
          unless loaded
            m.abort_operation
            warn "[SM+] allocate_new_slot_from_ro_hash: add_style non ha aggiunto '#{name}'"
            return nil
          end

          # Attiva lo slot: model.rendering_options ora riflette il template.
          m.styles.selected_style = loaded
          ro = m.rendering_options

          apply_ro_snapshot(ro, ro_hash)

          m.styles.update_selected_style
          set_nickname(name, nickname) if nickname && !nickname.to_s.strip.empty?

          m.commit_operation
          loaded
        rescue => e
          m.abort_operation
          warn "[SM+] allocate_new_slot_from_ro_hash: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          nil
        end
      end

      # Applica uno snapshot RO (chiavi → valori, colori come hex string) su
      # un RenderingOptions live. Inferisce il tipo colore dal valore corrente.
      # Scrive sempre sia SilhouetteWidth che ProfileWidth se una delle due è
      # presente (alias non-ufficiale in SU 2019, cfr. CLAUDE.md).
      def apply_ro_snapshot(ro, ro_hash)
        ro_hash.each do |k, v|
          begin
            cur = ro[k]
            if cur.is_a?(Sketchup::Color) && v.is_a?(String)
              ro[k] = hex_to_color(v)
            else
              ro[k] = v
            end
          rescue
            # chiave read-only o non riassegnabile: best-effort, ignora.
          end
        end
        # Profile width: tieni allineate le due chiavi alias.
        pw = ro_hash['SilhouetteWidth'] || ro_hash['ProfileWidth']
        unless pw.nil?
          begin; ro['SilhouetteWidth'] = pw; rescue; end
          begin; ro['ProfileWidth']    = pw; rescue; end
        end
      end

      # "#rrggbb" → Sketchup::Color. Ritorna nil su input invalido.
      def hex_to_color(hex)
        s = hex.to_s.strip.sub(/^#/, '')
        return nil unless s =~ /^[0-9a-fA-F]{6}$/
        Sketchup::Color.new(s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16))
      end

      # Sketchup::Color → "#rrggbb" (drop alpha).
      def color_to_hex(color)
        return nil unless color.respond_to?(:red)
        format('#%02x%02x%02x', color.red, color.green, color.blue)
      end

      # ── Nickname API ──────────────────────────────────────────────────

      def get_nickname(style_name)
        m = model
        return nil unless m && style_name
        v = m.get_attribute(NICKNAMES_DICT, style_name.to_s, nil)
        return nil if v.nil?
        s = v.to_s
        s.empty? ? nil : s
      end

      # Set nickname. Ritorna true se applicato, false se conflict (un altro
      # stile ha già lo stesso display_name = stesso nickname, o nickname che
      # collide con il nome nativo di un altro stile). Stringa vuota = clear,
      # sempre OK.
      #
      # Validazione contro display_name (non solo nickname): se uno stile è
      # senza nickname e si chiama nativamente "Foo", non vogliamo permettere
      # ad un altro stile di nicknamarsi "Foo" — altrimenti il picker mostra
      # due voci con lo stesso label e l'utente non capisce quale sceglie.
      def set_nickname(style_name, nickname)
        m = model
        return false unless m && style_name
        key = style_name.to_s
        nick = nickname.to_s.strip
        if nick.empty?
          m.set_attribute(NICKNAMES_DICT, key, '')
          return true
        end
        return false if display_name_taken?(nick, except_native: key)
        m.set_attribute(NICKNAMES_DICT, key, nick)
        true
      end

      def clear_nickname(style_name)
        set_nickname(style_name, '')
      end

      # Rimuove proprio la key dal dizionario (vs set_nickname che lascia '').
      # Usato dopo purge_unused per non accumulare nickname orfani.
      def remove_nickname_attr(style_name)
        m = model
        return unless m && style_name
        d = m.attribute_dictionary(NICKNAMES_DICT, false)
        return unless d
        d.delete_key(style_name.to_s) if d.respond_to?(:delete_key)
      end

      # ── Badge color API ──────────────────────────────────────────────
      # Colore associato a uno stile, mostrato come background del letter
      # badge nella main window. Salvato come hex '#rrggbb' in un dict
      # dedicato (separato dai nickname). Stringa vuota / nil = nessun
      # colore (badge usa lo style default CSS).

      def get_color(style_name)
        m = model
        return nil unless m && style_name
        v = m.get_attribute(COLORS_DICT, style_name.to_s, nil)
        return nil if v.nil?
        s = v.to_s.strip
        return nil if s.empty?
        s =~ /^#?[0-9a-fA-F]{6}$/ ? (s.start_with?('#') ? s.downcase : "##{s.downcase}") : nil
      end

      def set_color(style_name, hex)
        m = model
        return false unless m && style_name
        key = style_name.to_s
        s   = hex.to_s.strip
        if s.empty?
          m.set_attribute(COLORS_DICT, key, '')
          return true
        end
        s = s.sub(/^#/, '')
        return false unless s =~ /^[0-9a-fA-F]{6}$/
        m.set_attribute(COLORS_DICT, key, "##{s.downcase}")
        true
      end

      def clear_color(style_name)
        set_color(style_name, '')
      end

      def remove_color_attr(style_name)
        m = model
        return unless m && style_name
        d = m.attribute_dictionary(COLORS_DICT, false)
        return unless d
        d.delete_key(style_name.to_s) if d.respond_to?(:delete_key)
      end

      # True se `name` è già usato come display_name (nickname o nativo) da
      # uno stile diverso da `except_native`. Case-sensitive, trim'ata.
      def display_name_taken?(name, except_native: nil)
        target = name.to_s.strip
        return false if target.empty?
        m = model
        return false unless m && m.respond_to?(:styles) && m.styles
        m.styles.any? do |s|
          sname = s.name.to_s
          next false if except_native && sname == except_native.to_s
          display_name(sname) == target
        end
      end

      # Nome da mostrare nella UI del plugin: nickname se presente, altrimenti
      # il nome nativo SU.
      def display_name(style_name)
        get_nickname(style_name) || style_name.to_s
      end

      # Enumera gli stili del modello NON usati da nessuna scena. Ritorna
      # array di hash { name, display_name } ordinati per display_name.
      def unused_styles
        m = model
        return [] unless m
        used_names = m.pages.map { |p| (p.style.name.to_s rescue nil) }.compact.uniq
        m.styles.reject { |s| used_names.include?(s.name.to_s) }
                .map { |s| { name: s.name.to_s, display_name: display_name(s.name.to_s) } }
                .sort_by { |h| h[:display_name].downcase }
      end

      # UI helper: prompt utente per nickname con retry su duplicato. Ritorna:
      #   - una stringa (anche vuota = "no nickname")
      #   - :aborted se l'utente cancella il dialog
      # Usato da "+ New style" (picker), "Save as new" (dirty dialog branches).
      def prompt_nickname_loop(title: 'Scene Manager+', label: 'Nickname:')
        default = ''
        loop do
          res = ::UI.inputbox([label], [default], title)
          return :aborted if res == false
          nick = res[0].to_s.strip
          return nick if nick.empty?
          if display_name_taken?(nick)
            ::UI.messagebox(
              "Nickname '#{nick}' è già usato da un altro stile.\n" \
              "Scegli un altro nome."
            )
            default = nick
            next
          end
          return nick
        end
      end

      # Purge degli unused via styles.purge_unused, + cleanup dei nickname
      # orfani (cancella le entry del dict per gli stili rimossi).
      # Ritorna l'array di nomi rimossi (per messagebox finale).
      def purge_unused_styles
        m = model
        return [] unless m && m.styles.respond_to?(:purge_unused)
        # Snapshot dei nomi unused PRIMA del purge, così sappiamo cosa pulire
        # dal nickname dict dopo.
        to_remove = unused_styles.map { |h| h[:name] }
        m.styles.purge_unused
        to_remove.each do |n|
          remove_nickname_attr(n)
          remove_color_attr(n)
        end
        to_remove
      end
    end
  end
end
