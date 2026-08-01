module SceneManagerPlus
  module Core
    # Accesso ai controlli dei pannelli nativi di SketchUp via Win32.
    #
    # PERCHE' ESISTE
    # Alcune impostazioni dello stile NON sono esposte dall'API Ruby di SU 2019.
    # Il caso concreto: l'opacita' di "Foreground Photo" / "Background Photo"
    # della sezione Match Photo (Window -> Styles -> Edit -> Modeling).
    # Verificato il 2026-08-01 su 19.3.253, con la scena Match Photo ATTIVA nel
    # viewport (la condizione in cui una chiave dovrebbe comparire):
    #   - model.rendering_options: 61 chiavi prima, 61 dopo, zero chiavi nuove;
    #   - 14 nomi di chiave plausibili letti a mano: tutti nil;
    #   - Sketchup::Style e' un Entity e quindi HA attribute_dictionaries, ma
    #     sullo stile Match Photo ritorna nil; idem la pagina;
    #   - il formato .style su disco non contiene campi photo/opacity.
    # Il valore pero' esiste, ed e' nel pannello nativo: quello e' Win32, gli
    # slider sono `msctls_trackbar32` veri, leggibili e scrivibili.
    #
    # COME
    # `fiddle` (stdlib Ruby) e' disponibile dentro SU 2019, quindi si parla con
    # user32.dll direttamente: niente spawn di PowerShell, niente latenza.
    # Le SendMessage partono dal thread UI di SketchUp (lo stesso che ospita le
    # finestre), quindi sono chiamate sincrone dirette alla window proc.
    #
    # TRAPPOLA PRINCIPALE
    # TBM_SETPOS sposta il cursore ma NON notifica il parent: senza il
    # WM_HSCROLL che segue, SketchUp non sa che il valore e' cambiato e non
    # succede assolutamente niente. Stessa cosa per le checkbox: BM_SETCHECK
    # cambia solo l'aspetto, serve il WM_COMMAND/BN_CLICKED al parent.
    #
    # IDENTIFICAZIONE DEI CONTROLLI
    # Gli ID numerici non sono documentati da Trimble e possono cambiare tra
    # versioni. Per questo la strada primaria NON e' l'ID ma l'ETICHETTA: nel
    # pannello ogni slider segue immediatamente la propria checkbox, quindi si
    # cerca il Button con testo "Foreground Photo" e si prende la prima
    # trackbar dopo di lui. Gli ID restano solo come fallback (SU localizzato)
    # e sono sovrascrivibili con
    # `Sketchup.write_default('SceneManagerPlus', '<chiave>', N)` -- stessa
    # convenzione di add_scene_cmd_id / scene_tabs_cmd_id.
    # Per rimappare su una versione diversa: `NativePanel.dump('Styles')`.
    module NativePanel
      module_function

      # === Costanti Win32 ===
      GW_CHILD    = 5
      GW_HWNDNEXT = 2

      TBM_GETPOS      = 0x0400
      TBM_GETRANGEMIN = 0x0401
      TBM_GETRANGEMAX = 0x0402
      TBM_SETPOS      = 0x0405

      BM_GETCHECK = 0x00F0
      BM_SETCHECK = 0x00F1

      WM_HSCROLL = 0x0114
      WM_COMMAND = 0x0111

      SB_THUMBPOSITION = 4
      SB_ENDSCROLL     = 8
      BN_CLICKED       = 0

      BST_UNCHECKED = 0
      BST_CHECKED   = 1

      STYLES_PANEL = 'Styles'.freeze

      # Etichette (via primaria) + ID di fallback, mappati su SU 2019 19.3.253.
      MP_CONTROLS = {
        'foreground' => {
          label:       'Foreground Photo',
          check_key:   'mp_fg_check_ctrl_id',
          track_key:   'mp_fg_track_ctrl_id',
          check_id:    2881,
          track_id:    2884
        },
        'background' => {
          label:       'Background Photo',
          check_key:   'mp_bg_check_ctrl_id',
          track_key:   'mp_bg_track_ctrl_id',
          check_id:    2880,
          track_id:    2882
        }
      }.freeze

      def fallback_id(key, default)
        Sketchup.read_default(PLUGIN_ID, key, default).to_i
      rescue
        default
      end

      # === Binding fiddle (lazy, una volta sola) ===

      # True se user32 e' raggiungibile. Su piattaforme non-Windows, o se
      # fiddle manca, tutto il modulo degrada e i chiamanti disabilitano la UI.
      def available?
        return @available unless @available.nil?
        @available = begin
          require 'fiddle'
          u = Fiddle.dlopen('user32.dll')
          @fn = {
            desktop: Fiddle::Function.new(u['GetDesktopWindow'], [], Fiddle::TYPE_VOIDP),
            getwin:  Fiddle::Function.new(u['GetWindow'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_VOIDP),
            parent:  Fiddle::Function.new(u['GetParent'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
            ctrlid:  Fiddle::Function.new(u['GetDlgCtrlID'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
            iswin:   Fiddle::Function.new(u['IsWindow'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
            isenab:  Fiddle::Function.new(u['IsWindowEnabled'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
            wtext:   Fiddle::Function.new(u['GetWindowTextA'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT),
            wclass:  Fiddle::Function.new(u['GetClassNameA'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT),
            procid:  Fiddle::Function.new(u['GetWindowThreadProcessId'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_LONG),
            # wparam/lparam a 64 bit: su Win64 passare un `long` (4 byte)
            # lascerebbe sporcizia nella parte alta del registro.
            send:    Fiddle::Function.new(u['SendMessageA'],
                       [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP],
                       Fiddle::TYPE_LONG_LONG)
          }
          true
        rescue Exception => e
          warn "[SM+] NativePanel non disponibile: #{e.class}: #{e.message}"
          false
        end
      end

      def send_msg(hwnd, msg, wparam = 0, lparam = 0)
        return 0 unless available?
        @fn[:send].call(hwnd, msg, wparam, lparam)
      end

      # === Navigazione finestre ===

      def window_text(h)
        buf = "\0" * 256
        n = @fn[:wtext].call(h, buf, 256)
        n > 0 ? buf[0, n] : ''
      rescue
        ''
      end

      def window_class(h)
        buf = "\0" * 256
        n = @fn[:wclass].call(h, buf, 256)
        n > 0 ? buf[0, n] : ''
      rescue
        ''
      end

      def ctrl_id_of(h)
        @fn[:ctrlid].call(h)
      rescue
        0
      end

      def pid_of(h)
        out = [0].pack('L')
        @fn[:procid].call(h, out)
        out.unpack('L').first
      rescue
        0
      end

      def children(h)
        out = []
        c = @fn[:getwin].call(h, GW_CHILD)
        while c && !c.null?
          out << c
          c = @fn[:getwin].call(c, GW_HWNDNEXT)
        end
        out
      rescue
        []
      end

      def window?(h)
        !h.nil? && !h.null? && @fn[:iswin].call(h) != 0
      rescue
        false
      end

      def enabled?(h)
        @fn[:isenab].call(h) != 0
      rescue
        true
      end

      # Finestra top-level del NOSTRO processo con quel titolo. I pannelli
      # ancorati in un tray restano finestre top-level separate, e si trovano
      # anche quando il tray mostra un'altra scheda: in quel caso i controlli
      # sono invisibili ma rispondono ai messaggi lo stesso (verificato).
      def panel(title)
        return nil unless available?
        mypid = Process.pid
        children(@fn[:desktop].call).find do |h|
          window_text(h) == title && pid_of(h) == mypid
        end
      end

      # Come panel(), ma se non la trova chiede a SketchUp di aprire
      # l'inspector e riprova. UI.show_inspector e' l'API Trimble
      # cross-platform gia' usata altrove nel plugin.
      def panel!(title)
        p = panel(title)
        return p if p
        begin
          ::UI.show_inspector(title)
        rescue => e
          warn "[SM+] NativePanel.panel!: show_inspector(#{title}) fallito: #{e.message}"
        end
        panel(title)
      end

      # Lista piatta ORDINATA dei controlli del pannello (l'ordine e' quello di
      # enumerazione Win32, che nel pannello Styles mette ogni slider subito
      # dopo la propria checkbox: e' cio' su cui si regge labeled_pair).
      def controls(title)
        p = panel!(title)
        return [] unless p
        acc = []
        walk = lambda do |h, depth|
          next if depth > 8
          children(h).each do |c|
            acc << { hwnd: c, klass: window_class(c), text: window_text(c), id: ctrl_id_of(c) }
            walk.call(c, depth + 1)
          end
        end
        walk.call(p, 0)
        acc
      end

      # Cerca in profondita' un controllo per ID (fallback quando l'etichetta
      # non c'e', es. SketchUp localizzato).
      def find_by_id(title, ctrl_id)
        p = panel!(title)
        return nil unless p
        descend(p, ctrl_id, 0)
      end

      def descend(h, ctrl_id, depth)
        return nil if depth > 8
        children(h).each do |c|
          return c if ctrl_id_of(c) == ctrl_id
          r = descend(c, ctrl_id, depth + 1)
          return r if r
        end
        nil
      end

      # === Trackbar (slider) ===

      def trackbar_read(h)
        return nil unless h
        {
          pos:     send_msg(h, TBM_GETPOS),
          min:     send_msg(h, TBM_GETRANGEMIN),
          max:     send_msg(h, TBM_GETRANGEMAX),
          enabled: enabled?(h)
        }
      rescue => e
        warn "[SM+] trackbar_read: #{e.class}: #{e.message}"
        nil
      end

      # TBM_SETPOS da solo sposta il cursore e basta: il WM_HSCROLL che segue
      # e' cio' che fa reagire SketchUp. Senza, non cambia niente a video.
      def trackbar_write(h, value)
        return false unless h
        v   = value.to_i
        min = send_msg(h, TBM_GETRANGEMIN)
        max = send_msg(h, TBM_GETRANGEMAX)
        v = min if v < min
        v = max if v > max
        parent = @fn[:parent].call(h)
        send_msg(h, TBM_SETPOS, 1, v)
        send_msg(parent, WM_HSCROLL, (v << 16) | SB_THUMBPOSITION, h)
        send_msg(parent, WM_HSCROLL, SB_ENDSCROLL, h)
        true
      rescue => e
        warn "[SM+] trackbar_write(#{value}): #{e.class}: #{e.message}"
        false
      end

      # === Checkbox ===

      def checkbox_read(h)
        return nil unless h
        send_msg(h, BM_GETCHECK) == BST_CHECKED
      rescue => e
        warn "[SM+] checkbox_read: #{e.class}: #{e.message}"
        nil
      end

      # Come per la trackbar: BM_SETCHECK cambia solo il disegno, il
      # WM_COMMAND/BN_CLICKED e' quello che fa reagire l'applicazione.
      def checkbox_write(h, checked)
        return false unless h
        parent = @fn[:parent].call(h)
        send_msg(h, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0)
        send_msg(parent, WM_COMMAND, (BN_CLICKED << 16) | (ctrl_id_of(h) & 0xFFFF), h)
        true
      rescue => e
        warn "[SM+] checkbox_write(#{checked}): #{e.class}: #{e.message}"
        false
      end

      # === Match Photo ===

      # Risolve la coppia checkbox+slider di "Foreground Photo" /
      # "Background Photo". Primaria: per etichetta (la trackbar e' la prima
      # che segue il Button con quel testo). Fallback: ID numerici.
      # Cache invalidata da IsWindow, cosi' sopravvive alla chiusura del
      # pannello senza restituire handle morti.
      def mp_pair(which)
        cfg = MP_CONTROLS[which.to_s]
        return nil unless cfg && available?
        @mp_cache ||= {}
        cached = @mp_cache[which.to_s]
        return cached if cached && window?(cached[:check]) && window?(cached[:track])

        list  = controls(STYLES_PANEL)
        pair  = nil
        idx   = list.index { |c| c[:klass] =~ /button/i && c[:text].to_s.strip == cfg[:label] }
        if idx
          tb = list[(idx + 1)..-1].to_a.find { |c| c[:klass] =~ /trackbar/i }
          pair = { check: list[idx][:hwnd], track: tb[:hwnd] } if tb
        end
        if pair.nil?
          # Fallback su ID (SketchUp localizzato, o layout cambiato).
          ch = find_by_id(STYLES_PANEL, fallback_id(cfg[:check_key], cfg[:check_id]))
          tb = find_by_id(STYLES_PANEL, fallback_id(cfg[:track_key], cfg[:track_id]))
          pair = { check: ch, track: tb } if ch && tb
        end
        @mp_cache[which.to_s] = pair
        pair
      rescue => e
        warn "[SM+] mp_pair(#{which}): #{e.class}: #{e.message}"
        nil
      end

      # Stato corrente delle due voci Match Photo dello stile SELEZIONATO
      # (il pannello nativo mostra sempre selected_style, quindi il chiamante
      # deve aver gia' selezionato lo stile che vuole leggere/scrivere).
      # nil = controlli non raggiungibili -> la UI si disabilita.
      def match_photo_state
        return nil unless available?
        out = {}
        MP_CONTROLS.each_key do |which|
          pair = mp_pair(which)
          return nil unless pair
          tb = trackbar_read(pair[:track])
          return nil unless tb
          out[which] = {
            'on'      => checkbox_read(pair[:check]) ? true : false,
            'opacity' => tb[:pos],
            'min'     => tb[:min],
            'max'     => tb[:max],
            'enabled' => tb[:enabled]
          }
        end
        out
      end

      def match_photo_set_enabled(which, on)
        pair = mp_pair(which)
        return false unless pair
        return true if checkbox_read(pair[:check]) == !!on
        checkbox_write(pair[:check], !!on)
      end

      def match_photo_set_opacity(which, value)
        pair = mp_pair(which)
        return false unless pair
        trackbar_write(pair[:track], value)
      end

      def clear_cache
        @mp_cache = {}
      end

      # === Diagnostica ===
      #
      # Stampa i controlli interessanti di un pannello. E' il modo per
      # rimappare gli ID su una versione di SketchUp diversa (poi si fissano
      # con write_default). Analogo a tools/dump-su-menu.ps1 per i command ID.
      #
      #   SceneManagerPlus::Core::NativePanel.dump('Styles')
      def dump(title = STYLES_PANEL)
        unless available?
          puts '[SM+] NativePanel non disponibile su questa piattaforma'
          return nil
        end
        list = controls(title)
        if list.empty?
          puts "[SM+] pannello '#{title}' non trovato (aprilo da Window -> #{title})"
          return nil
        end
        rows = list.select { |c| c[:klass] =~ /trackbar|button|combobox/i }.map do |c|
          extra = if c[:klass] =~ /trackbar/i
                    "pos=#{send_msg(c[:hwnd], TBM_GETPOS)} range=#{send_msg(c[:hwnd], TBM_GETRANGEMIN)}..#{send_msg(c[:hwnd], TBM_GETRANGEMAX)}"
                  elsif c[:klass] =~ /button/i
                    "check=#{send_msg(c[:hwnd], BM_GETCHECK)}"
                  else
                    ''
                  end
          format('  %-16s id=%-6d %-26s %s', c[:klass][0, 16], c[:id], c[:text].to_s[0, 26], extra)
        end
        puts "[SM+] Controlli del pannello '#{title}' (#{rows.size}):"
        rows.uniq.each { |r| puts r }
        rows.size
      end
    end
  end
end
