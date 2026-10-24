module SceneManagerPlus
  module Core
    # Le due pipette del selettore colore condiviso (ui/html/js/color_popup.js),
    # come le due icone del pannello Colori di SketchUp. Portate dal plugin
    # Componenti parametrici (colore.rb, 2026-10-15), stesso funzionamento:
    #
    #   :model   clic su un oggetto del modello: il colore che ha li'
    #            (materiale della faccia dal lato che si guarda, se no quello
    #            del gruppo o componente che la contiene, se no il colore di
    #            default dello stile)
    #   :screen  il pixel sotto il cursore, ovunque sullo schermo, anche fuori
    #            da SketchUp (Win32 via fiddle, come NativePanel)
    #
    # Rispondono alla pagina con SMColorPopup.picked(hex, done, notice): mentre
    # il mouse si muove (anteprima dal vivo, done=false) e alla fine (done=true,
    # hex vuoto = annullata). Ogni finestra che usa il selettore chiama
    # ColorPick.register(dlg) nel suo register_callbacks.
    #
    # ATTENZIONE: dentro SceneManagerPlus esiste il modulo UI dei dialog, quindi
    # le API di SketchUp vanno scritte ::UI.
    module ColorPick
      module_function

      # Vedi busy?: il clic che conferma la pipetta dallo schermo arriva anche
      # a SketchUp, che cambia la selezione al rilascio del tasto, quando la
      # pipetta ha gia' finito.
      GRACE = 0.8   # s

      # Stato che regge il `load` a caldo con una pipetta in corso.
      @dialog = nil unless defined?(@dialog)
      @kind   = nil unless defined?(@kind)    # :model | :screen mentre una pipetta lavora
      @last   = nil unless defined?(@last)    # l'ultimo colore mandato alla pagina
      @ended  = nil unless defined?(@ended)

      def register(dlg)
        dlg.add_action_callback('sm_cp_model')  { |_ctx, *_| start(dlg, :model) }
        dlg.add_action_callback('sm_cp_screen') { |_ctx, *_| start(dlg, :screen) }
        dlg.add_action_callback('sm_cp_cancel') { |_ctx, *_| cancel }
      end

      def last
        @last
      end

      # Vero mentre una pipetta lavora e per un attimo dopo.
      def busy?
        !@kind.nil? || (!@ended.nil? && Time.now - @ended < GRACE)
      end

      def start(dialog, kind)
        # Una pipetta ancora in corso: se e' di un'altra finestra la si avvisa
        # che e' finita; se e' di questa, la pagina l'ha gia' chiusa da se'.
        @dialog.equal?(dialog) ? halt : finish(nil)
        @dialog = dialog
        @last   = nil
        @kind   = kind
        ok = kind == :model ? Model.start : Screen.start
        return if ok
        @kind = nil
        deliver('', true, kind == :screen ? 'The screen eyedropper only works on Windows.' :
                                            'Eyedropper not available.')
        @dialog = nil
      end

      def preview(hex)
        return if hex.nil? || hex == @last
        @last = hex
        deliver(hex, false)
      end

      # Fine della pipetta: hex = il colore preso, nil = annullata.
      def finish(hex)
        kind = @kind
        return unless kind
        @kind  = nil
        @ended = Time.now
        kind == :model ? Model.stop : Screen.stop
        Sketchup.status_text = ''
        deliver(hex || '', true)
        @dialog = nil
      end

      def cancel
        finish(nil)
      end

      # La pagina non c'e' piu' (finestra chiusa o ricaricata): si smette
      # senza dirle niente, o il timer resterebbe a parlare col vuoto.
      def halt
        return unless @kind
        @dialog = nil
        finish(nil)
      end

      def deliver(hex, done, notice = nil)
        d = @dialog
        unless d && d.visible?
          halt
          return
        end
        d.execute_script("if(window.SMColorPopup&&SMColorPopup.picked){SMColorPopup.picked(" \
                         "#{hex.to_s.inspect},#{done ? 'true' : 'false'},#{notice.to_s.inspect});}")
      rescue StandardError
        nil
      end

      def hex_of(c)
        format('#%02x%02x%02x', c.red, c.green, c.blue)
      end

      # -----------------------------------------------------------------------
      # Pipetta nel modello: uno strumento di SketchUp messo SOPRA quello in
      # uso (push_tool), che alla fine torna quello di prima. Il clic lo prende
      # lo strumento: la selezione non cambia.
      # -----------------------------------------------------------------------
      module Model
        module_function

        CURSOR = File.expand_path('../assets/eyedropper.png', __dir__)

        @tool   = nil unless defined?(@tool)
        @cursor = nil unless defined?(@cursor)

        def tool
          @tool
        end

        def start
          @tool = Tool.new
          Sketchup.active_model.tools.push_tool(@tool)
          true
        rescue StandardError
          @tool = nil
          false
        end

        # Torna lo strumento di prima, se nel frattempo non ne e' stato scelto
        # un altro (allora il nostro e' gia' stato tolto).
        def stop
          t = @tool
          @tool = nil
          Sketchup.active_model.tools.pop_tool if t && t.active
        rescue StandardError
          nil
        end

        def cursor
          @cursor ||= File.exist?(CURSOR) ? ::UI.create_cursor(CURSOR, 2, 29) : 0
        end

        # Il colore che si vede sotto il punto (x, y) della vista, o nil.
        def color_at(view, x, y)
          model = view.model
          pt, dir = view.pickray(x, y)
          8.times do
            hit = model.raytest([pt, dir], true)   # true: niente di nascosto
            return nil unless hit
            path = hit[1]
            return face_color(model, path, dir) if path.last.is_a?(Sketchup::Face)
            pt = hit[0].offset(dir, 0.05)           # uno spigolo: si guarda oltre
          end
          nil
        end

        # path = [gruppo, componente, ..., faccia], dal modello in giu'.
        def face_color(model, path, dir)
          face = path.last
          tr = Geom::Transformation.new
          path[0...-1].each { |e| tr *= e.transformation if e.respond_to?(:transformation) }
          front = face.normal.transform(tr).dot(dir) < 0
          mat = front ? face.material : face.back_material
          path[0...-1].reverse_each do |e|
            break if mat
            mat = e.material if e.respond_to?(:material)
          end
          c = mat ? mat.color : model.rendering_options[front ? 'FaceFrontColor' : 'FaceBackColor']
          ColorPick.hex_of(c)
        end
      end

      class Tool
        attr_reader :active

        STATUS = 'Eyedropper: click an object in the model to take its color, Esc to cancel.'.freeze

        def activate
          @active = true
          Sketchup.status_text = STATUS
        end

        def resume(_view)
          Sketchup.status_text = STATUS
        end

        # scelto un altro strumento mentre la pipetta lavorava: annullata
        def deactivate(_view)
          @active = false
          ColorPick.finish(nil) if Model.tool.equal?(self)
        end

        def onCancel(_reason, _view)
          ColorPick.finish(nil)
        end

        def onMouseMove(_flags, x, y, view)
          ColorPick.preview(Model.color_at(view, x, y))
        end

        # un clic nel vuoto non prende niente: si resta in attesa
        def onLButtonDown(_flags, x, y, view)
          hex = Model.color_at(view, x, y)
          ColorPick.finish(hex) if hex
        end

        def onSetCursor
          c = Model.cursor
          ::UI.set_cursor(c) if c && c != 0
        end
      end

      # -----------------------------------------------------------------------
      # Pipetta dallo schermo: SketchUp non ha nessuna API per farlo, si passa
      # da Win32 con fiddle.
      #
      #   GetCursorPos  -> dove sta il mouse (coordinate dello schermo virtuale)
      #   GetDC(NULL)   -> il device context dell'INTERO schermo
      #   GetPixel      -> il colore di quel pixel, chiunque lo stia disegnando
      #
      # Il campionamento gira in un ::UI.start_timer ripetuto: a ogni giro manda
      # alla pagina il colore per l'anteprima dal vivo, e guarda i tasti con
      # GetAsyncKeyState. Conferma con clic sinistro / Invio / Spazio, annulla
      # con Esc.
      #
      # ATTENZIONE (limite vero, non aggirabile senza hook di sistema): il clic
      # di conferma arriva ANCHE alla finestra sotto il cursore - non lo si puo'
      # intercettare senza un hook globale WH_MOUSE_LL, che se va storto blocca
      # l'input di tutto Windows. Per questo Invio e Spazio confermano allo
      # stesso modo: sopra una finestra dove un clic farebbe danni (la lista
      # scene, per esempio), si usa la tastiera.
      # -----------------------------------------------------------------------
      module Screen
        module_function

        VK_LBUTTON  = 0x01
        VK_ESCAPE   = 0x1B
        VK_RETURN   = 0x0D
        VK_SPACE    = 0x20
        INTERVAL    = 0.04     # s fra un campione e l'altro
        CLR_INVALID = 0xFFFFFFFF

        @fn     = nil   unless defined?(@fn)
        @loaded = false unless defined?(@loaded)
        @timer  = nil   unless defined?(@timer)
        @armed  = false unless defined?(@armed)

        # Puntatori alle funzioni Win32, caricati una volta sola. Su Mac (o se
        # fiddle non c'e') resta nil e la pipetta dice di no.
        def fn
          return @fn if @loaded
          @loaded = true
          @fn = nil
          return nil unless Sketchup.platform == :platform_win
          begin
            require 'fiddle'
            u = Fiddle.dlopen('user32.dll')
            g = Fiddle.dlopen('gdi32.dll')
            @fn = {
              :pos => Fiddle::Function.new(u['GetCursorPos'],
                                           [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT),
              :dc  => Fiddle::Function.new(u['GetDC'],
                                           [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOIDP),
              :rel => Fiddle::Function.new(u['ReleaseDC'],
                                           [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                                           Fiddle::TYPE_INT),
              :pix => Fiddle::Function.new(g['GetPixel'],
                                           [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT,
                                            Fiddle::TYPE_INT], Fiddle::TYPE_LONG),
              :key => Fiddle::Function.new(u['GetAsyncKeyState'],
                                           [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
            }
          rescue Exception
            @fn = nil
          end
          @fn
        end

        # Colore sotto il cursore, come '#rrggbb'. GetPixel torna un COLORREF
        # 0x00bbggrr: il rosso e' il byte BASSO, non l'alto.
        def color_under_cursor
          f = fn
          return nil unless f
          buf = "\0" * 8                      # POINT = due LONG
          return nil if f[:pos].call(buf) == 0
          x, y = buf.unpack('l<l<')
          hdc = f[:dc].call(nil)
          return nil if hdc.nil? || hdc.null?
          c = f[:pix].call(hdc, x, y) & 0xFFFFFFFF
          f[:rel].call(nil, hdc)
          return nil if c == CLR_INVALID
          format('#%02x%02x%02x', c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff)
        end

        def down?(vk)
          f = fn
          return false unless f
          (f[:key].call(vk) & 0x8000) != 0
        end

        def start
          return false if fn.nil?
          stop
          # Il clic che ha premuto l'icona e' probabilmente ancora giu': si
          # arma solo quando il tasto e' stato rilasciato, altrimenti la
          # pipetta si chiuderebbe subito da sola.
          @armed = !down?(VK_LBUTTON)
          Sketchup.status_text = 'Eyedropper: move the mouse anywhere on the screen. ' \
                                 'Click (or Enter / Space) to take the color, Esc to cancel.'
          @timer = ::UI.start_timer(INTERVAL, true) { tick }
          true
        end

        def stop
          ::UI.stop_timer(@timer) if @timer
          @timer = nil
        end

        def tick
          hex = color_under_cursor
          ColorPick.preview(hex)
          if down?(VK_ESCAPE)
            ColorPick.finish(nil)
          elsif !@armed
            @armed = true unless down?(VK_LBUTTON)
          elsif down?(VK_LBUTTON) || down?(VK_RETURN) || down?(VK_SPACE)
            ColorPick.finish(hex || ColorPick.last)
          end
        rescue Exception
          # in un timer ripetuto un'eccezione non gestita si ripresenta a ogni
          # giro: meglio chiudere la pipetta e stare zitti.
          ColorPick.finish(nil)
        end
      end
    end
  end
end
