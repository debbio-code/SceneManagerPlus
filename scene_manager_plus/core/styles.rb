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

      # ── Nickname API ──────────────────────────────────────────────────

      def get_nickname(style_name)
        m = model
        return nil unless m && style_name
        v = m.get_attribute(NICKNAMES_DICT, style_name.to_s, nil)
        return nil if v.nil?
        s = v.to_s
        s.empty? ? nil : s
      end

      def set_nickname(style_name, nickname)
        m = model
        return unless m && style_name
        key = style_name.to_s
        nick = nickname.to_s.strip
        if nick.empty?
          # set_attribute con nil non sempre cancella la entry: tipo string vuota.
          m.set_attribute(NICKNAMES_DICT, key, '')
        else
          m.set_attribute(NICKNAMES_DICT, key, nick)
        end
      end

      def clear_nickname(style_name)
        set_nickname(style_name, '')
      end

      # Nome da mostrare nella UI del plugin: nickname se presente, altrimenti
      # il nome nativo SU.
      def display_name(style_name)
        get_nickname(style_name) || style_name.to_s
      end
    end
  end
end
