module SceneManagerPlus
  module Core
    # Scene Tabs di SketchUp nascoste SEMPRE (richiesta dell'utente,
    # 2026-11-04: "non vorrei mai vedere le scene tabs sopra la view").
    #
    # IL BUG DI SU 2019
    # Alla riapertura di un file le linguette possono comparire anche se
    # View -> Scene Tabs risulta spento. Il rimedio manuale e' cliccare due
    # volte la voce (la prima la "accende", senza effetto visibile; la seconda
    # la spegne davvero).
    #
    # PERCHE' IL VECCHIO RIMEDIO NON BASTAVA
    # Fino al 2026-11-04 il plugin mandava due toggle alla cieca UNA volta,
    # all'apertura della sua finestra (Dialog.show). Tre buchi:
    #   - all'avvio di SketchUp la finestra si riapre 0,5 s dopo il caricamento
    #     del plugin: con un file pesante il modello finisce di caricarsi DOPO,
    #     e le linguette ricompaiono a toggle gia' fatti;
    #   - aprendo un altro file con la finestra gia' aperta non scattava niente;
    #   - alla cieca: se le linguette erano accese davvero (menu spuntato), due
    #     toggle le lasciavano accese.
    #
    # COME FUNZIONA ADESSO
    # Un timer leggero guarda se la barra delle linguette e' DAVVERO visibile
    # (Win32: e' un SysTabControl32 dentro un msctls_statusbar32 figlio della
    # finestra principale, vedi CLAUDE.md, sezione "Limite SU 2019"). Se lo e',
    # manda UN toggle e aspetta che SketchUp lo esegua (send_action e'
    # asincrono); se e' ancora visibile ne manda un secondo (caso del bug).
    # Cosi' copre tutti e due gli stati senza sapere quale sia quello vero:
    # il feedback e' la barra stessa, non il segno di spunta del menu (che MFC
    # aggiorna solo quando il menu viene aperto, quindi e' inaffidabile).
    # Dopo MAX_TOGGLES tentativi a vuoto si ferma finche' non vede la barra
    # nascosta almeno una volta: niente lampeggio infinito se un giorno la
    # barra e' fatta diversamente (due toggle = stato di partenza).
    #
    # Lettura e basta, a ogni giro: IsWindowVisible + GetWindowRect su un
    # handle in cache. Nessuna scrittura sul modello.
    #
    # SOLO PER POCHI SECONDI (scelta dell'utente, 2026-11-04): il timer gira
    # per STARTUP_FOR secondi dopo il caricamento del plugin e AFTER_OPEN_FOR
    # dopo ogni file aperto o nuovo (AppObserver), poi si ferma da solo. Il bug
    # scatta a ogni apertura di file (riprodotto), non solo all'avvio. A riposo
    # non gira niente: l'utente non accende mai le linguette a mano (se lo
    # facesse, restano accese fino al prossimo file aperto).
    # ⚠️ 10 s e' un valore DI PROVA, voluto corto dall'utente ("al massimo
    # aumentiamo"). Se le linguette ricompaiono dopo l'apertura di un file
    # pesante, alzare queste due costanti. SceneTabs.log mostra quando la
    # guardia e' stata armata e quando ha cliccato.
    #
    # Preferenza PER MACCHINA (write_default 'hide_scene_tabs', default ON),
    # non per file: e' un gusto dell'utente, non una proprieta' del progetto.
    # Prima era il setting per-file 'ui.hide_scene_tabs_on_open'.
    module SceneTabs
      module_function

      PREF_KEY = 'hide_scene_tabs'.freeze

      # View -> Scene Tabs su SU 2019 Windows (tools/dump-su-menu.ps1).
      # Override: Sketchup.write_default('SceneManagerPlus', 'scene_tabs_cmd_id', N)
      WIN_SHOW_SCENE_TABS_CMD_ID = 10534

      TICK         = 0.3 # s fra due controlli
      # Dopo un toggle si salta un giro (si riguarda dopo ~0,6 s). Misurato
      # 2026-11-04 su 19.0.685: la barra cambia stato ~35 ms dopo send_action,
      # cioe' prima del giro di timer successivo (stesso message loop).
      SETTLE_TICKS = 1
      MAX_TOGGLES  = 2   # nel caso del bug ne servono 2
      SEARCH_EVERY = 10  # barra non trovata: si ricerca ogni ~3 s
      STARTUP_FOR    = 10.0 # s di guardia dopo il caricamento del plugin (DI PROVA)
      AFTER_OPEN_FOR = 10.0 # s di guardia dopo ogni file aperto o nuovo (DI PROVA)

      @timer   = nil unless defined?(@timer)
      @enabled = nil unless defined?(@enabled)
      @app_obs = nil unless defined?(@app_obs)
      @until   = nil unless defined?(@until)
      # Ultimi eventi (armo / toggle), per la diagnosi: SceneTabs.log
      @log     = [] unless defined?(@log)

      def log
        @log
      end

      def note(what)
        @log << "#{Time.now.strftime('%H:%M:%S.%L')} #{what}"
        @log.shift while @log.size > 20
      end

      # Riarma la guardia a ogni file aperto o nuovo.
      class AppObs < Sketchup::AppObserver
        # Senza questo SketchUp NON chiama onOpenModel per il file aperto
        # all'avvio (doppio clic sul .skp): misurato 2026-11-04, il registro
        # aveva solo "startup" e le linguette sono comparse 9,6 s dopo, a un
        # soffio dalla fine della finestra. Con file pesanti sarebbero sfuggite.
        def expectsStartupModelNotifications
          true
        end

        def onOpenModel(_model)
          SceneTabs.arm!('file opened')
        rescue => e
          warn "[SM+] SceneTabs onOpenModel: #{e.class}: #{e.message}"
        end

        def onNewModel(_model)
          SceneTabs.arm!('new model')
        rescue => e
          warn "[SM+] SceneTabs onNewModel: #{e.class}: #{e.message}"
        end
      end

      def enabled?
        if @enabled.nil?
          @enabled = Sketchup.read_default('SceneManagerPlus', PREF_KEY, true) ? true : false
        end
        @enabled
      end

      def set_enabled(on)
        @enabled = on ? true : false
        Sketchup.write_default('SceneManagerPlus', PREF_KEY, @enabled)
        @enabled ? arm!('setting turned on', AFTER_OPEN_FOR) : stop!
      end

      def scene_tabs_cmd_id
        Sketchup.read_default('SceneManagerPlus', 'scene_tabs_cmd_id', WIN_SHOW_SCENE_TABS_CMD_ID).to_i
      end

      # = clic su View -> Scene Tabs.
      def toggle!
        if RUBY_PLATFORM =~ /darwin/
          Sketchup.send_action('showSceneTabs:')
        else
          Sketchup.send_action(scene_tabs_cmd_id)
        end
      end

      # Diagnostica dalla Ruby Console, per un ID di comando diverso:
      #   SceneManagerPlus::Core::SceneTabs.try_cmd(21031)
      # Se le linguette si accendono/spengono e' quello giusto; per fissarlo:
      #   Sketchup.write_default('SceneManagerPlus', 'scene_tabs_cmd_id', 21031)
      def try_cmd(id)
        puts "[SM+] try send_action(#{id})"
        Sketchup.send_action(id.to_i)
      end

      # Chiamato da main.rb al caricamento del plugin: aggancia l'observer
      # (una volta sola, anche dopo un `load` a caldo) e apre la prima finestra.
      def start!
        unless @app_obs
          @app_obs = AppObs.new
          Sketchup.add_observer(@app_obs)
        end
        arm!('startup', STARTUP_FOR)
      end

      # Apre (o allunga) una finestra di controllo di `secs` secondi.
      def arm!(why = nil, secs = AFTER_OPEN_FOR)
        return unless enabled?
        return unless NativePanel.available?
        t_end = Time.now + secs
        @until = t_end if @until.nil? || !@timer || t_end > @until
        reset!
        @wait = 0
        @search_cd = 0
        note("armed #{secs.to_i} s (#{why})")
        puts "[SM+] Scene Tabs guard on for #{secs.to_i} s (#{why})"
        @timer ||= ::UI.start_timer(TICK, true) { tick }
      end

      def stop!
        ::UI.stop_timer(@timer) if @timer
        @timer = nil
      end

      def active?
        !@timer.nil?
      end

      def reset!
        @toggles = 0
        @gave_up = false
      end

      # Barra delle linguette visibile adesso? nil se non trovata.
      def visible_now?
        bar = tab_control
        return nil unless bar
        shown?(bar)
      end

      def tick
        # Fine della finestra: ci si ferma, ma non a meta' di una coppia di
        # toggle (il secondo e' quello che le spegne davvero).
        if !enabled? || @until.nil? ||
           (Time.now > @until && (@toggles.to_i == 0 || @gave_up))
          stop!
          note('stopped')
          return
        end
        if @wait.to_i > 0
          @wait -= 1
          return
        end
        bar = tab_control
        return unless bar
        unless shown?(bar)
          reset!
          return
        end
        return if @gave_up
        # Finestra modale aperta (messagebox, Preferences, Apri file...): la
        # finestra principale e' disabilitata. Non e' il momento.
        return unless @frame && NativePanel.enabled?(@frame)
        if @toggles >= MAX_TOGGLES
          @gave_up = true
          note('gave up')
          warn "[SM+] Scene Tabs: still visible after #{MAX_TOGGLES} toggles, " \
               'leaving them alone until they are hidden again'
          return
        end
        toggle!
        @toggles += 1
        @wait = SETTLE_TICKS
        note("toggle #{@toggles}")
        puts "[SM+] Scene Tabs visible -> hiding (toggle #{@toggles})"
      rescue => e
        warn "[SM+] SceneTabs.tick: #{e.class}: #{e.message}"
      end

      # Visibile davvero: WS_VISIBLE su di lei e sugli antenati, e un'altezza.
      def shown?(bar)
        return false unless NativePanel.visible?(bar)
        r = NativePanel.window_rect(bar)
        r.nil? || (r[3] - r[1]) > 2
      end

      def tab_control
        return @bar if @bar && NativePanel.window?(@bar)
        @bar = nil
        @frame = nil
        @search_cd = @search_cd.to_i - 1
        return nil if @search_cd > 0
        @search_cd = SEARCH_EVERY
        @frame, @bar = find_bar
        puts '[SM+] Scene Tabs bar found' if @bar
        @bar
      end

      # [finestra principale, SysTabControl32 delle linguette] o [nil, nil].
      # Si guardano solo le finestre top-level di QUESTO processo, e mai i
      # dialog #32770: il pannello Styles flottante e' un #32770 top-level con
      # un SysTabControl32 figlio (Select/Edit/Mix), e non va confuso.
      def find_bar
        mypid = Process.pid
        NativePanel.children(NativePanel.desktop).each do |top|
          next unless NativePanel.pid_of(top) == mypid
          next if NativePanel.window_class(top) == '#32770'
          NativePanel.children(top).each do |c|
            k = NativePanel.window_class(c)
            return [top, c] if k == 'SysTabControl32'
            next unless k == 'msctls_statusbar32'
            t = NativePanel.children(c).find { |g| NativePanel.window_class(g) == 'SysTabControl32' }
            return [top, t] if t
          end
        end
        [nil, nil]
      end
    end
  end
end
