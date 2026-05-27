require 'json'

module SceneManagerPlus
  module Core
    # Settings persistiti via Sketchup.write_default (per-utente, globali al PC).
    module Settings
      module_function

      SECTION = 'SceneManagerPlus'.freeze
      MODEL_CFG_DICT = 'SceneManagerPlus_cfg'.freeze

      DEFAULTS = {
        'naming' => {
          'enabled'        => false,
          'prefix_mode'    => 'skp_name', # 'skp_name' | 'custom' | 'none'
          'prefix_custom'  => '',
          'pad'            => 2,
          'separator'      => '_',
          'include_scene_name' => true
        },
        'export' => {
          'width'     => 3000,
          'height'    => 1500,
          'format'    => 'jpg',
          'antialias' => true,
          'transparent' => false,
          'output_dir' => '',
          'line_scale_multiplier' => 1.5
        },
        'preview' => {
          # Moltiplicatore independente di EdgeWidth/ProfileWidth applicato
          # durante la generazione delle thumbnail (300×150). A scale piccola,
          # 1px di edge sparisce: alzando questo si ottengono linee più
          # leggibili e testo che appare più proporzionato.
          'line_scale_multiplier' => 1.0
        },
        'logo' => {
          'enabled'      => false,
          'use_default'  => false,
          'path'         => '',
          'width_pct'    => 15,
          'offset_x'     => 20,
          'offset_y'     => 20,
          'opacity'      => 100
        },
        'filename_label' => {
          'enabled'     => false,
          'font_family' => 'Arial',
          'font_size'   => 28,
          'bold'        => false,
          'color'       => '#ffffff', # lowercase: HTML5 <input type=color> rifiuta hex uppercase
          'offset_x'    => 20, # px dal bordo SINISTRO
          'offset_y'    => 20, # px dal bordo INFERIORE
          'opacity'     => 100
        },
        'ui' => {
          'show_order_banner'       => false,
          # Workaround bug SU 2019: alla riapertura del file le Scene Tabs
          # possono restare visibili nel viewport anche se nel menu sono off.
          # Se true, all'apertura del dialog SM+ inviamo due send_action di
          # toggle (on→off) per ri-sincronizzare.
          'hide_scene_tabs_on_open' => true
        },
        'titleblock' => {
          # Cartiglio sotto l'immagine (canvas extension). Coesiste con
          # 'logo' (watermark overlay) e 'filename_label': indipendenti.
          # Cliente = naming.prefix_custom (riuso). Tavola = stesso {nnn}
          # del naming pattern. Dati aziendali + logo: bundlati in
          # assets/titleblock/{company.txt, logo.jpg}.
          'enabled'        => true,
          'height_px'      => 160,
          'font_family'    => 'Century Gothic',
          # Dropdown a tre voci, gestite UI-side. Default identici.
          'project_by'     => 'Arch. Nicola Debiasi',
          # '' = "Nessuno" nella dropdown UI (value="" della option).
          'designer'       => '',
          # Formato libero (es. "20/05/2026"). Vuoto = data del momento di export.
          'date_override'  => '',
          # Fase del progetto: 'Preliminare' | 'Definitivo' | 'Esecutivo'
          'project_phase'  => 'Preliminare'
        }
      }.freeze

      TITLEBLOCK_PEOPLE = [
        'Arch. Nicola Debiasi',
        'Guido',
        'Rahim'
      ].freeze

      # =========================================================
      # In-memory cache + lazy flush
      # =========================================================
      # Storage on-disk: 1 entry per leaf via model.set_attribute, key
      # piatta "group.field". Tipo robusto (Boolean/Integer/Float/String).
      # Più affidabile dello stringone JSON in SU 2019.
      #
      # Sui modelli con AttributeObserver di plugin terzi una singola
      # set_attribute può costare ~5 secondi. Per evitare lag durante
      # l'editing dei settings, manteniamo i cambiamenti in RAM
      # (`@runtime[model.object_id][group][key] = value`) e li
      # persistiamo TUTTI in una sola start_operation batch quando
      # l'utente chiude il Settings dialog o avvia un Export. Vedi
      # `flush!`.
      @runtime = {}  # { model_oid => { group => { key => coerced_value } } }
      @dirty   = {}  # { model_oid => true }

      def runtime_for(model_oid)
        @runtime[model_oid] ||= {}
      end

      # Coerce robusta: 1/0 → true/false (SU 2019 può restituire numeric
      # per Boolean salvati con set_attribute(..., true)).
      def coerce(value, default)
        case default
        when TrueClass, FalseClass
          case value
          when TrueClass, FalseClass then value
          when Numeric               then value.to_i != 0
          when String                then !%w[false 0 no off ''].include?(value.to_s.downcase)
          else                            !!value
          end
        when Integer               then value.to_i
        when Float                 then value.to_f
        else                            value.to_s
        end
      end

      # Lettura: runtime override > attribute_dictionary > DEFAULTS.
      # `attribute_dictionary(..., false)` ritorna nil se mai scritto,
      # quindi una sola chiamata API per group (anziché N get_attribute).
      def get(group)
        return {} unless DEFAULTS.key?(group)
        m = Sketchup.active_model
        m_dict = m ? m.attribute_dictionary(MODEL_CFG_DICT, false) : nil
        rt = m ? (runtime_for(m.object_id)[group] || {}) : {}
        DEFAULTS[group].each_with_object({}) do |(k, default), h|
          if rt.key?(k)
            h[k] = rt[k]
          else
            raw = m_dict ? m_dict["#{group}.#{k}"] : nil
            h[k] = raw.nil? ? default : coerce(raw, default)
          end
        end
      end

      # Scrittura: AGGIORNA RAM, NON tocca il disco. La persistenza
      # avviene solo via `flush!` (chiusura dialog / export start).
      # Risultato: l'editing dei settings ha lag 0 anche su modelli
      # con observer di terzi che costerebbe 5s/write.
      def set(group, hash)
        unless DEFAULTS.key?(group)
          warn "[SM+] Settings.set: unknown group #{group.inspect}"
          return nil
        end
        m = Sketchup.active_model
        return nil unless m
        rt_group = (runtime_for(m.object_id)[group] ||= {})
        changed = 0
        (hash || {}).each do |k, v|
          default = DEFAULTS[group][k]
          next if default.nil?
          coerced = coerce(v, default)
          next if rt_group[k] == coerced
          rt_group[k] = coerced
          changed += 1
        end
        @dirty[m.object_id] = true if changed > 0
        puts "[SM+] Settings.set group=#{group.inspect}: #{changed} key(s) updated in RAM (flush deferred)"
        nil
      end

      # Persisti tutti i cambi RAM-only del model in una singola
      # start_operation. Chiamato da SettingsDialog.set_on_closed e
      # all'inizio di Exporter.export. Idempotente: no-op se non dirty.
      def flush!(model = Sketchup.active_model)
        return unless model
        return unless @dirty[model.object_id]
        rt_for_model = @runtime[model.object_id]
        return unless rt_for_model
        began = false
        t0 = Time.now
        begin
          model.start_operation('SM+ Flush settings', true, false, true)
          began = true
          dict = model.attribute_dictionary(MODEL_CFG_DICT, true)
          written = 0
          rt_for_model.each do |group, overrides|
            next unless DEFAULTS.key?(group)
            overrides.each do |k, v|
              default = DEFAULTS[group][k]
              next if default.nil?
              flat = "#{group}.#{k}"
              existing = dict[flat]
              existing_coerced = existing.nil? ? default : coerce(existing, default)
              next if existing_coerced == v
              model.set_attribute(MODEL_CFG_DICT, flat, v)
              written += 1
            end
          end
          model.commit_operation
          @dirty.delete(model.object_id)
          puts "[SM+] Settings.flush!: wrote %d key(s) in %.1fms" %
               [written, (Time.now - t0) * 1000]
        rescue => e
          model.abort_operation if began
          warn "[SM+] Settings.flush!: failed (#{e.class}: #{e.message})"
        end
      end

      def all
        DEFAULTS.keys.each_with_object({}) { |k, h| h[k] = get(k) }
      end

      # Path al logo "default" embeddato come asset del plugin.
      # Deve stare dentro PLUGIN_DIR per essere accessibile anche quando il
      # plugin è deployato via Junction (il parent della cartella plugin è
      # %APPDATA%/.../Plugins, NON il repo).
      def default_logo_path
        primary = File.join(PLUGIN_DIR, 'assets', 'default_logo.png')
        return primary if File.file?(primary)
        # Fallback: primo .png in assets/
        dir = File.join(PLUGIN_DIR, 'assets')
        return nil unless File.directory?(dir)
        pick = Dir.entries(dir).find { |n| n =~ /\.png\z/i }
        pick ? File.join(dir, pick) : nil
      end

      # Path agli asset bundlati del cartiglio (testo dati aziendali, logo).
      # Stessa logica del default_logo_path: vivono dentro PLUGIN_DIR.
      def titleblock_company_txt_path
        File.join(PLUGIN_DIR, 'assets', 'titleblock', 'company.txt')
      end

      def titleblock_logo_path
        File.join(PLUGIN_DIR, 'assets', 'titleblock', 'logo.jpg')
      end

      # Path effettivo del logo da usare: rispetta use_default.
      def effective_logo_path
        cfg = get('logo')
        if cfg['use_default']
          default_logo_path || cfg['path']
        else
          cfg['path']
        end
      end
    end
  end
end
