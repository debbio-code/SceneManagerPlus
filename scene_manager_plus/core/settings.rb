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
          'output_dir' => ''
        },
        'logo' => {
          'enabled'   => false,
          'path'      => '',
          'width_pct' => 15,
          'offset_x'  => 20,
          'offset_y'  => 20,
          'opacity'   => 100
        }
      }.freeze

      def get(group)
        raw = Sketchup.read_default(SECTION, group, nil)
        return DEFAULTS[group].dup unless raw
        parsed = JSON.parse(raw) rescue {}
        DEFAULTS[group].merge(parsed)
      end

      def set(group, hash)
        merged = DEFAULTS[group].merge(hash || {})
        Sketchup.write_default(SECTION, group, merged.to_json)
        merged
      end

      def all
        DEFAULTS.keys.each_with_object({}) { |k, h| h[k] = get(k) }
      end
    end
  end
end
