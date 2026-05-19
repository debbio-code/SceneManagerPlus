require 'json'

module SceneManagerPlus
  module Core
    # Settings persistiti via Sketchup.write_default (per-utente, globali al PC).
    module Settings
      module_function

      SECTION = 'SceneManagerPlus'.freeze

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
          'width'     => 1920,
          'height'    => 1080,
          'format'    => 'png',
          'antialias' => true,
          'transparent' => false,
          'output_dir' => '',
          'line_scale_multiplier' => 2.0
        },
        'logo' => {
          'enabled'      => false,
          'use_default'  => true,
          'path'         => '',
          'width_pct'    => 15,
          'offset_x'     => 20,
          'offset_y'     => 20,
          'opacity'      => 100
        },
        'ui' => {
          'show_order_banner' => true
        }
      }.freeze

      # Storage: una entry per leaf via Sketchup.write_default. Ogni leaf usa
      # come "key" il path piatto "group.field", e il valore è il primitivo
      # tipato (Boolean/Integer/Float/String). Più robusto del salvataggio
      # JSON-in-stringa in SU 2019: write_default è ottimizzato per primitivi
      # e ha comportamenti inaffidabili con stringhe complesse contenenti
      # virgolette/backslash su alcune versioni.
      def read_one(group, key, default)
        flat = "#{group}.#{key}"
        v = Sketchup.read_default(SECTION, flat, default)
        # write_default('foo', true) viene letto come 1/0 in alcune build.
        # Normalizziamo in base al tipo del default.
        case default
        when TrueClass, FalseClass
          return !!v if v.is_a?(TrueClass) || v.is_a?(FalseClass)
          return v.to_i != 0 if v.is_a?(Numeric)
          return default
        when Integer
          return v.to_i if v.respond_to?(:to_i)
        when Float
          return v.to_f if v.respond_to?(:to_f)
        when String
          return v.to_s
        end
        v
      end

      def write_one(group, key, value, default)
        flat = "#{group}.#{key}"
        coerced = case default
                  when TrueClass, FalseClass then value ? true : false
                  when Integer               then value.to_i
                  when Float                 then value.to_f
                  else                            value.to_s
                  end
        Sketchup.write_default(SECTION, flat, coerced)
      end

      def get(group)
        return {} unless DEFAULTS.key?(group)
        DEFAULTS[group].each_with_object({}) do |(k, default), h|
          h[k] = read_one(group, k, default)
        end
      end

      def set(group, hash)
        unless DEFAULTS.key?(group)
          warn "[SM+] Settings.set: unknown group #{group.inspect}"
          return nil
        end
        (hash || {}).each do |k, v|
          default = DEFAULTS[group][k]
          next if default.nil? # chiave sconosciuta: skip
          write_one(group, k, v, default)
        end
        result = get(group)
        puts "[SM+] Settings.set group=#{group.inspect} → #{result.inspect}"
        result
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
