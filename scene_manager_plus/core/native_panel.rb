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
    # TBM_SETPOS sposta il cursore ma NON notifica il parent. E non basta
    # nemmeno il WM_HSCROLL: il viewport reagisce, ma SketchUp non segna lo
    # stile come modificato e il valore evapora al cambio di scena. Serve un
    # click emulato sul cursore (vedi trackbar_write) e poi
    # `styles.update_selected_style`. Per le checkbox invece BM_SETCHECK +
    # WM_COMMAND/BN_CLICKED bastano: segnano lo stile dirty (verificato).
    #
    # SECONDA TRAPPOLA: le LETTURE sono aggiornate solo se la scheda Edit del
    # pannello e' stata mostrata dopo l'ultimo cambio. Vedi
    # refresh_styles_panel!, che lo simula (funziona anche a tray nascosto).
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
      TBM_GETTHUMBRECT = 0x0419

      WM_LBUTTONDOWN = 0x0201
      WM_LBUTTONUP   = 0x0202
      MK_LBUTTON     = 1
      WM_KEYDOWN     = 0x0100
      WM_KEYUP       = 0x0101
      VK_LEFT        = 0x25
      VK_RIGHT       = 0x27

      BM_GETCHECK = 0x00F0
      BM_SETCHECK = 0x00F1

      WM_HSCROLL = 0x0114
      WM_COMMAND = 0x0111

      SB_THUMBPOSITION = 4
      SB_ENDSCROLL     = 8
      BN_CLICKED       = 0

      BST_UNCHECKED = 0
      BST_CHECKED   = 1

      TCM_GETCURSEL = 0x130B
      TCM_SETCURSEL = 0x130C
      WM_NOTIFY     = 0x004E
      # TCN_SELCHANGE = -551, come UINT a 32 bit nel campo `code` dell'NMHDR.
      TCN_SELCHANGE = 0xFFFFFDD9

      STYLES_PANEL = 'Styles'.freeze
      # Schede del pannello Styles: 0 Select, 1 Edit, 2 Mix. I controlli Match
      # Photo stanno nella pagina "Modeling" della scheda Edit.
      STYLES_EDIT_TAB = 1

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
            isvis:   Fiddle::Function.new(u['IsWindowVisible'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
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

      # Finestra del pannello con quel titolo, nel NOSTRO processo. Dove sta
      # dipende da come l'utente ha sistemato i tray (misurato 2026-09-20):
      #   - pannello flottante           -> finestra top-level col titolo;
      #   - tray flottante ("Tray N")    -> MiniFrame top-level, e il pannello
      #     e' un dialog #32770 figlio, col titolo come testo;
      #   - tray agganciato alla finestra principale ("Default Tray") -> il
      #     dialog #32770 e' un discendente della finestra principale di SU.
      # La prima versione cercava solo il primo caso: su una postazione con il
      # tray agganciato il pannello Styles "non esisteva" e la sezione Match
      # Photo restava disabilitata. Ora si cercano tutti e tre.
      #
      # I controlli rispondono ai messaggi anche quando il pannello e' su una
      # scheda non visibile, MA in quello stato i loro valori possono essere
      # VECCHI: il pannello li aggiorna solo quando viene mostrato (letto
      # 0/0 su un pannello nascosto che, reso visibile, diceva 80/100). Vedi
      # visible? e la nota in match_photo_state.
      def panel(title)
        return nil unless available?
        mypid = Process.pid
        tops = children(@fn[:desktop].call).select { |h| pid_of(h) == mypid }
        hit = tops.find { |h| window_text(h) == title }
        return hit if hit
        tops.each do |t|
          r = find_dialog_titled(t, title, 0)
          return r if r
        end
        nil
      end

      # Dialog (#32770) con quel testo tra i discendenti di h. Il pannello
      # agganciato sta a profondita' 3 (frame -> ControlBar -> #32770 ->
      # #32770 "Styles"); il limite 6 lascia margine senza camminare tutto
      # l'albero della finestra principale.
      def find_dialog_titled(h, title, depth)
        return nil if depth > 6
        children(h).each do |c|
          return c if window_class(c) == '#32770' && window_text(c) == title
          r = find_dialog_titled(c, title, depth + 1)
          return r if r
        end
        nil
      end

      def visible?(h)
        !h.nil? && !h.null? && @fn[:isvis].call(h) != 0
      rescue
        false
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

      # TBM_SETPOS da solo sposta il cursore e basta. La prima versione lo
      # faceva seguire da WM_HSCROLL (THUMBPOSITION + ENDSCROLL): il viewport
      # reagiva, ma SketchUp NON segnava lo stile come modificato, quindi
      # `update_selected_style` non aveva niente da salvare e il valore
      # spariva al primo cambio di scena (misurato 2026-09-20, con confronto
      # di render: 100 -> 30 -> cambio scena -> 100). Stessa sorte con la
      # tastiera (VK_RIGHT) e con la notifica TRBN_THUMBPOSCHANGING.
      # L'unica via che SketchUp tratta come "l'utente ha mosso lo slider" e'
      # il MOUSE: dopo il TBM_SETPOS silenzioso al valore esatto, un click a
      # spostamento zero sul cursore (WM_LBUTTONDOWN/UP al centro del
      # TBM_GETTHUMBRECT) fa generare al trackbar le sue notifiche e lo stile
      # diventa dirty. Il chiamante poi committa con update_selected_style.
      def trackbar_write(h, value)
        return false unless h
        v   = value.to_i
        min = send_msg(h, TBM_GETRANGEMIN)
        max = send_msg(h, TBM_GETRANGEMAX)
        v = min if v < min
        v = max if v > max
        send_msg(h, TBM_SETPOS, 1, v)
        rect = "\0" * 16
        send_msg(h, TBM_GETTHUMBRECT, 0, Fiddle::Pointer[rect])
        l, t, r, b = rect.unpack('llll')
        x = (l + r) / 2
        y = (t + b) / 2
        lp = (y << 16) | (x & 0xFFFF)
        send_msg(h, WM_LBUTTONDOWN, MK_LBUTTON, lp)
        send_msg(h, WM_LBUTTONUP, 0, lp)
        # Il click ricalcola la posizione dal pixel del mouse e puo' sbagliare
        # di 1 (chiesto 35, letto 34). Si corregge con le frecce: la tastiera
        # non segna lo stile dirty (lo ha gia' fatto il click) ma il valore lo
        # applica, come verificato col confronto di render.
        4.times do
          cur = send_msg(h, TBM_GETPOS)
          break if cur == v
          vk = cur < v ? VK_RIGHT : VK_LEFT
          send_msg(h, WM_KEYDOWN, vk, 0)
          send_msg(h, WM_KEYUP, vk, 0)
        end
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
      #
      # I controlli rispondono anche a pannello nascosto, ma SketchUp li
      # rinfresca solo quando la scheda Edit viene MOSTRATA: a tray nascosto o
      # con la scheda Select davanti i valori letti sono vecchi (misurato
      # 2026-09-20: 0/0 da nascosto contro 80/100 reali). Per questo prima di
      # leggere si passa da refresh_styles_panel!, che simula il cambio di
      # scheda via messaggi: funziona anche a tray nascosto (letto 60 vecchio,
      # poi 100 vero subito dopo la simulazione). 'refreshed' = false se non e'
      # stato possibile (tab control non trovato): la UI allora avvisa.
      # 'panel_visible' resta per diagnostica. Le SCRITTURE fanno presa sempre.
      def match_photo_state
        return nil unless available?
        refreshed = refresh_styles_panel!
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
        out['panel_visible'] = visible?(panel(STYLES_PANEL))
        out['refreshed'] = refreshed
        out
      end

      # Fa rinfrescare a SketchUp i controlli della scheda Edit del pannello
      # Styles simulando la selezione della scheda: TCM_SETCURSEL sposta la
      # linguetta, ma e' il WM_NOTIFY/TCN_SELCHANGE al parent che fa reagire
      # il dialog (stessa famiglia di trappole di TBM_SETPOS/WM_HSCROLL).
      # Poi la scheda viene rimessa com'era. A pannello visibile e gia' sulla
      # scheda Edit non si fa niente: SketchUp la tiene aggiornata da solo, e
      # il balletto Select->Edit sarebbe solo uno sfarfallio.
      #
      # NON gestito: la sotto-pagina della scheda Edit (Edge/Face/.../Modeling).
      # I suoi bottoni non rispondono ne' a BM_CLICK ne' a WM_COMMAND, quindi
      # si legge la pagina che l'utente ha lasciato attiva; se non e' Modeling
      # i controlli Match Photo potrebbero non essere rinfrescati. Nei test la
      # pagina attiva era sempre Modeling.
      def refresh_styles_panel!
        return false unless available?
        pnl = panel(STYLES_PANEL)
        return false unless pnl
        tab = controls(STYLES_PANEL).find { |c| c[:klass] == 'SysTabControl32' }
        return false unless tab
        parent = @fn[:parent].call(tab[:hwnd])
        cur = send_msg(tab[:hwnd], TCM_GETCURSEL)
        return true if visible?(pnl) && cur == STYLES_EDIT_TAB
        select_tab(tab, parent, cur == STYLES_EDIT_TAB ? 0 : STYLES_EDIT_TAB)
        select_tab(tab, parent, STYLES_EDIT_TAB) if cur == STYLES_EDIT_TAB
        select_tab(tab, parent, cur) if cur != STYLES_EDIT_TAB && cur >= 0
        true
      rescue => e
        warn "[SM+] refresh_styles_panel!: #{e.class}: #{e.message}"
        false
      end

      def select_tab(tab, parent, index)
        send_msg(tab[:hwnd], TCM_SETCURSEL, index, 0)
        # NMHDR x64: HWND hwndFrom (8), UINT_PTR idFrom (8), UINT code (4) + pad.
        hdr = [tab[:hwnd].to_i, tab[:id], TCN_SELCHANGE, 0].pack('QQLL')
        send_msg(parent, WM_NOTIFY, tab[:id], Fiddle::Pointer[hdr])
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
