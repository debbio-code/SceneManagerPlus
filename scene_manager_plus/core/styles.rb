module SceneManagerPlus
  module Core
    # Creazione e rinomina di stili nativi.
    #
    # Template unico (assets/styles/_template.style):
    #   `Sketchup::Styles#add_style` accetta solo file .style da disco, ma
    #   `Sketchup::Style#name=` FUNZIONA in SU 2019 (verificato 2026-08-01 su
    #   19.3.253, persistenza su .skp salvato+riletto inclusa). Quindi basta
    #   UN template importato N volte e rinominato subito dopo ogni import:
    #   stili illimitati con nomi arbitrari. Sostituisce il vecchio pool di 25
    #   slot pre-generati (`SM+ Slot NN`) + i nickname, che esistevano solo
    #   perché si credeva `name=` non disponibile.
    #
    # ⚠️ Unicità dei nomi: SU NON valida in sessione (due stili omonimi
    #   convivono), ma AL SALVATAGGIO ne rinomina uno in silenzio aggiungendo
    #   un suffisso numerico ("Foo" + "Foo" → "Foo" + "Foo1"), e non è
    #   deterministico quale. Siccome i metadata del plugin (COLORS_DICT) sono
    #   chiavati per nome, un duplicato lascerebbe appunti orfani dopo la
    #   riapertura del file. Quindi l'unicità la impone il plugin, a monte:
    #   vedi style_name_taken? / unique_style_name / rename_style.
    #
    # Nickname per-modello (LEGACY, in sola lettura + migrazione):
    #   Mappa native_name → friendly_name nel dict 'SMP_style_nicks'. Era il
    #   modo di dare un nome leggibile agli slot quando non si poteva
    #   rinominare. I file già lavorati la contengono ancora: display_name la
    #   rispetta, e migrate_legacy_nicknames! la converte in nomi veri
    #   (bottone in Settings). Sui file nuovi non viene mai scritta.
    module Styles
      module_function

      NICKNAMES_DICT  = 'SMP_style_nicks'.freeze
      COLORS_DICT     = 'SMP_style_colors'.freeze
      TEMPLATE_FILE   = '_template.style'.freeze
      DEFAULT_NEW_NAME = 'New style'.freeze

      def model
        Sketchup.active_model
      end

      def styles_dir
        File.join(PLUGIN_DIR, 'assets', 'styles')
      end

      def template_path
        File.join(styles_dir, TEMPLATE_FILE)
      end

      # Importa il template e ritorna il Sketchup::Style appena nato.
      #
      # L'identificazione è per IDENTITÀ del wrapper (`==` / object_id, stabili
      # per tutta la sessione — verificato), NON per nome: il nome embedded nel
      # template può già esistere nel modello (file legacy col vecchio pool) e
      # un diff per nome fallirebbe silenziosamente. `Style#persistent_id` non
      # è un'alternativa: in SU 2019 è uno stub che ritorna 0, come Material.
      #
      # Da chiamare dentro una start_operation del caller. Ritorna nil se il
      # template manca o se add_style non ha aggiunto esattamente uno stile.
      def import_template(m)
        path = template_path
        unless File.exist?(path)
          ::UI.messagebox(
            "Style template mancante:\n#{path}\n\n" \
            "Asset .style bundled non trovato. Re-deploy del plugin."
          )
          return nil
        end
        before = m.styles.to_a
        # activate=false: l'attivazione la decide il caller (evita side-effect
        # sulla scena attiva e sullo stile dirty pending).
        m.styles.add_style(path, false)
        fresh = m.styles.to_a.reject { |s| before.any? { |o| o == s } }
        if fresh.size != 1
          warn "[SM+] import_template: attesi 1 nuovo stile, trovati #{fresh.size}"
          return nil
        end
        fresh[0]
      rescue => e
        warn "[SM+] import_template: #{e.class}: #{e.message}"
        nil
      end

      # Crea uno stile nuovo con le rendering options del template.
      # name: nome desiderato (verrà reso unico); nil = DEFAULT_NEW_NAME.
      # Ritorna il Sketchup::Style creato o nil.
      def create_style(name: nil)
        m = model
        return nil unless m
        m.start_operation('SM+ New style', true)
        begin
          st = import_template(m)
          unless st
            m.abort_operation
            return nil
          end
          st.name = unique_style_name(name.to_s.strip.empty? ? DEFAULT_NEW_NAME : name)
          m.commit_operation
          st
        rescue => e
          m.abort_operation
          warn "[SM+] create_style: #{e.class}: #{e.message}"
          nil
        end
      end

      # Variante "save as new style": crea uno stile nuovo e ci committa
      # dentro le rendering options correnti del viewport. Il risultato è uno
      # stile che, quando applicato a una scena, riproduce esattamente la vista
      # corrente — comprese eventuali modifiche pending non ancora salvate
      # sullo stile attivo (è esattamente lo use case del branch "NO = save as
      # new" del dialog dirty-style).
      #
      # Flusso:
      #   1. Snapshot di tutte le model.rendering_options (= ciò che il
      #      viewport mostra ora, dirty edit inclusi)
      #   2. import_template — aggiunge lo stile nuovo al modello
      #   3. rinomina subito col nome scelto (reso unico)
      #   4. styles.selected_style = nuovo stile — viewport ora mostra le RO
      #      del template; eventuali pending edit sullo stile precedente
      #      vengono droppate silenziosamente (è OK: le abbiamo nello snapshot
      #      e lo stile precedente torna pulito allo state salvato,
      #      comportamento equivalente al "Don't save" nativo)
      #   5. Riapplica snapshot su model.rendering_options
      #   6. styles.update_selected_style — committa le RO restored allo
      #      stile nuovo
      #
      # Tutto in 1 start_operation = 1 Ctrl+Z.
      def create_style_from_viewport(name: nil)
        m = model
        return nil unless m

        # Snapshot rendering options prima di toccare nulla.
        ro = m.rendering_options
        snapshot = {}
        ro.each_pair { |k, v| snapshot[k] = v }

        m.start_operation('SM+ New style from viewport', true)
        begin
          loaded = import_template(m)
          unless loaded
            m.abort_operation
            return nil
          end
          loaded.name = unique_style_name(
            name.to_s.strip.empty? ? DEFAULT_NEW_NAME : name
          )

          # Switching active style: scrive le RO del template su
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

          # Fix orizzonte nero del template (vedi normalize_horizon!).
          normalize_horizon!(ro)

          # Committa: il nuovo stile ora contiene esattamente la vista
          # catturata. È persistente sullo stile, non più "dirty".
          m.styles.update_selected_style

          m.commit_operation
          loaded
        rescue => e
          m.abort_operation
          warn "[SM+] create_style_from_viewport: #{e.class}: #{e.message}"
          warn e.backtrace.first(3).join("\n")
          nil
        end
      end

      # Come create_style_from_viewport ma applica uno snapshot di
      # rendering options ARBITRARIO invece di catturare il viewport corrente.
      # Usato dal paste cross-file (Core::Clipboard): lo snapshot RO arriva
      # dal clipboard.json del file sorgente, con i colori serializzati come
      # stringhe hex "#rrggbb".
      #
      # ro_hash: { 'BackgroundColor' => '#ffffff', 'EdgeColorMode' => 1, ... }
      #   I valori colore sono hex string; vengono convertiti in Sketchup::Color
      #   inferendo il tipo dalla RO corrente del template (se la chiave è un
      #   colore nel template, la stringa hex viene promossa a Color).
      # name: nome desiderato per lo stile (reso unico automaticamente).
      #
      # Ritorna il Sketchup::Style creato o nil (errore).
      def create_style_from_ro_hash(ro_hash, name: nil)
        m = model
        return nil unless m
        ro_hash ||= {}

        m.start_operation('SM+ New style from snapshot', true)
        begin
          loaded = import_template(m)
          unless loaded
            m.abort_operation
            return nil
          end
          loaded.name = unique_style_name(
            name.to_s.strip.empty? ? DEFAULT_NEW_NAME : name
          )

          # Attiva lo stile: model.rendering_options ora riflette il template.
          m.styles.selected_style = loaded
          ro = m.rendering_options

          # NB: niente normalize_horizon! qui. Il paste deve riprodurre
          # FEDELMENTE l'orizzonte sorgente (alpha preservato dal clipboard);
          # normalizzarlo a bianco falserebbe il transfer. normalize_horizon!
          # resta solo in create_style_from_viewport ("+ New style").
          apply_ro_snapshot(ro, ro_hash)

          m.styles.update_selected_style

          m.commit_operation
          loaded
        rescue => e
          m.abort_operation
          warn "[SM+] create_style_from_ro_hash: #{e.class}: #{e.message}"
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

      # Fix dell'orizzonte nero degli slot del pool.
      #
      # Il cielo SU è un gradiente SkyColor (zenit) → HorizonColor (orizzonte).
      # Il template degli slot bundled ha HorizonColor = #000000 a=0 → banda
      # nera all'orizzonte. HorizonColor non è esposto da NESSUNA UI (né nativa
      # SU né Mini Style Manager), quindi l'utente non può correggerlo a mano.
      # Vedi docs/SU2019-LESSONS.md, sezione "HorizonColor".
      #
      # Strategia: se HorizonColor è il default "cattivo" (nero puro e/o alpha 0)
      # lo rimpiazziamo con **bianco opaco** → il cielo sfuma da SkyColor (zenit)
      # a bianco (orizzonte), come il default nativo di SketchUp. Condizionale:
      # un HorizonColor già sensato (es. da un file sorgente in paste) viene
      # preservato. (Mettere SkyColor invece di bianco dava un cielo piatto senza
      # gradiente — vedi screenshot OpzB; bianco è quello giusto.)
      def normalize_horizon!(ro)
        hc = (ro['HorizonColor'] rescue nil)
        return unless hc.is_a?(Sketchup::Color)
        bad = (hc.red == 0 && hc.green == 0 && hc.blue == 0) || hc.alpha == 0
        return unless bad
        begin; ro['HorizonColor'] = Sketchup::Color.new(255, 255, 255, 255); rescue; end
      end

      # "#rrggbb" o "#rrggbbaa" → Sketchup::Color. Ritorna nil su input invalido.
      # L'8-digit preserva l'alpha (necessario per il transfer fedele di RO con
      # alpha != 255, es. HorizonColor "non impostato" = nero con alpha 0; senza
      # alpha quel sentinel diventerebbe nero opaco e non si trasferirebbe).
      def hex_to_color(hex)
        s = hex.to_s.strip.sub(/^#/, '')
        if s =~ /^[0-9a-fA-F]{8}$/
          return Sketchup::Color.new(
            s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16), s[6, 2].to_i(16)
          )
        end
        return nil unless s =~ /^[0-9a-fA-F]{6}$/
        Sketchup::Color.new(s[0, 2].to_i(16), s[2, 2].to_i(16), s[4, 2].to_i(16))
      end

      # Sketchup::Color → "#rrggbbaa" (alpha preservato). Usato SOLO dal clipboard
      # (copy/paste RO snapshot): il round-trip deve essere fedele al colore
      # nativo, alpha incluso. Gli altri consumer di colori (badge, scene color,
      # mini style manager) usano percorsi 6-hex separati, non toccati da qui.
      def color_to_hex(color)
        return nil unless color.respond_to?(:red)
        a = (color.respond_to?(:alpha) ? color.alpha : 255)
        format('#%02x%02x%02x%02x', color.red, color.green, color.blue, a)
      end

      # ── Nomi degli stili (nativi) ─────────────────────────────────────
      # `Sketchup::Style#name=` funziona e persiste nel .skp. Il legame
      # scena→stile è per riferimento, quindi rinominare NON stacca le scene
      # (verificato anche dopo save + rilettura da disco). Rinominare non
      # sporca lo stile (`active_style_changed` resta false).

      def find_style(name)
        m = model
        return nil unless m && m.respond_to?(:styles) && m.styles && name
        m.styles.find { |s| s.name.to_s == name.to_s }
      rescue
        nil
      end

      # True se `name` è già il nome nativo di uno stile diverso da `except`.
      # Case-sensitive come SU. Serve a impedire i duplicati che SU accetta in
      # sessione ma poi rinomina di nascosto al salvataggio.
      def style_name_taken?(name, except: nil)
        target = name.to_s.strip
        return false if target.empty?
        m = model
        return false unless m && m.respond_to?(:styles) && m.styles
        m.styles.any? do |s|
          sname = s.name.to_s
          next false if except && sname == except.to_s
          sname == target
        end
      end

      # Rende univoco un nome aggiungendo " 2", " 3", ... Non tocca il nome se
      # è già libero.
      def unique_style_name(base, except: nil)
        b = base.to_s.strip
        b = DEFAULT_NEW_NAME if b.empty?
        return b unless style_name_taken?(b, except: except)
        i = 2
        i += 1 while style_name_taken?("#{b} #{i}", except: except)
        "#{b} #{i}"
      end

      # Rinomina uno stile e sposta con lui i metadata del plugin chiavati per
      # nome (badge color). Cancella anche l'eventuale nickname legacy: da qui
      # in poi la verità è il nome nativo, non l'etichetta.
      #
      # Ritorna true se rinominato, false se il nome è già usato da un altro
      # stile (il caller mostra il messaggio).
      def rename_style(style_name, new_name)
        st = find_style(style_name)
        return false unless st
        old = st.name.to_s
        want = new_name.to_s.strip
        return false if want.empty?
        return true if want == old
        return false if style_name_taken?(want, except: old)
        m = model
        m.start_operation('SM+ Rename style', true)
        begin
          st.name = want
          rekey_metadata(old, want)
          m.commit_operation
          true
        rescue => e
          m.abort_operation
          warn "[SM+] rename_style: #{e.class}: #{e.message}"
          false
        end
      end

      # Sposta badge color + nickname legacy dalla vecchia chiave alla nuova.
      # Il nickname NON viene ricopiato: dopo un rename esplicito il nome
      # nativo è il nome, e tenere l'etichetta sopra lo maschererebbe.
      def rekey_metadata(old_name, new_name)
        col = get_color(old_name)
        remove_color_attr(old_name)
        set_color(new_name, col) if col
        remove_nickname_attr(old_name)
        remove_nickname_attr(new_name)
      end

      # `Sketchup::Style#description=` esiste e persiste (verificato).
      def set_description(style_name, text)
        st = find_style(style_name)
        return false unless st
        m = model
        m.start_operation('SM+ Style description', true)
        begin
          st.description = text.to_s
          m.commit_operation
          true
        rescue => e
          m.abort_operation
          warn "[SM+] set_description: #{e.class}: #{e.message}"
          false
        end
      end

      def get_description(style_name)
        st = find_style(style_name)
        st ? st.description.to_s : nil
      rescue
        nil
      end

      # UI helper: prompt per un nome stile con retry su duplicato. Ritorna
      # una stringa non vuota, oppure :aborted se l'utente annulla.
      def prompt_style_name_loop(title: 'Scene Manager+', label: 'Style name:', default: nil)
        val = (default.to_s.strip.empty? ? DEFAULT_NEW_NAME : default.to_s)
        loop do
          res = ::UI.inputbox([label], [val], title)
          return :aborted if res == false
          name = res[0].to_s.strip
          if name.empty?
            ::UI.messagebox('Please enter a name for the style.')
            val = DEFAULT_NEW_NAME
            next
          end
          if style_name_taken?(name)
            ::UI.messagebox(
              "A style named '#{name}' already exists.\n" \
              "Please choose a different name."
            )
            val = name
            next
          end
          return name
        end
      end

      # ── Migrazione dei file legacy ────────────────────────────────────
      # I file lavorati prima del 2026-08 hanno stili "SM+ Slot NN" con il
      # nome leggibile parcheggiato nel dict dei nickname. Qui il nickname
      # diventa il nome nativo vero, così anche Window → Styles di SketchUp
      # mostra finalmente quello che l'utente vede nel plugin.
      # Innescata da un bottone in Settings (mai in automatico: rinominare
      # stili dentro file già consegnati è una decisione dell'utente).

      # [{ native:, nick:, target: }, ...] per gli stili rinominabili.
      def legacy_nickname_candidates
        m = model
        return [] unless m && m.respond_to?(:styles) && m.styles
        d = m.attribute_dictionary(NICKNAMES_DICT, false)
        return [] unless d
        out = []
        m.styles.each do |s|
          native = s.name.to_s
          nick   = d[native].to_s.strip
          next if nick.empty? || nick == native
          out << { native: native, nick: nick }
        end
        out
      rescue => e
        warn "[SM+] legacy_nickname_candidates: #{e.class}: #{e.message}"
        []
      end

      # Applica la migrazione. Ritorna { renamed: [[old, new], ...],
      # skipped: [[old, nick, reason], ...] }.
      def migrate_legacy_nicknames!
        renamed = []
        skipped = []
        m = model
        return { renamed: renamed, skipped: skipped } unless m
        cands = legacy_nickname_candidates
        return { renamed: renamed, skipped: skipped } if cands.empty?
        # Un'unica operazione: rekey_metadata scrive attributi di modello, e
        # sui file con AttributeObserver di plugin terzi ogni write costa ~5s
        # (vedi CLAUDE.md, sezione Performance). disable_ui evita i refresh
        # sincroni degli inspector tra una scrittura e l'altra.
        m.start_operation('SM+ Migrate style names', true)
        begin
          cands.each do |h|
            st = find_style(h[:native])
            unless st
              skipped << [h[:native], h[:nick], 'style not found']
              next
            end
            # Il nickname era garantito unico tra i display_name, ma può
            # collidere con il nome nativo di un altro stile mai nicknameato.
            target = unique_style_name(h[:nick], except: h[:native])
            begin
              st.name = target
              rekey_metadata(h[:native], target)
              renamed << [h[:native], target]
            rescue => e
              skipped << [h[:native], h[:nick], "#{e.class}: #{e.message}"]
            end
          end
          m.commit_operation
        rescue => e
          m.abort_operation
          warn "[SM+] migrate_legacy_nicknames!: #{e.class}: #{e.message}"
        end
        { renamed: renamed, skipped: skipped }
      end

      # ── Nickname API (legacy) ─────────────────────────────────────────

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
