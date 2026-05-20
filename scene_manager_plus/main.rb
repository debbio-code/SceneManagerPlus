require 'sketchup.rb'

module SceneManagerPlus
  require File.join(PLUGIN_DIR, 'core', 'buffer')
  require File.join(PLUGIN_DIR, 'core', 'scene_model')
  require File.join(PLUGIN_DIR, 'core', 'folders')
  require File.join(PLUGIN_DIR, 'core', 'settings')
  require File.join(PLUGIN_DIR, 'core', 'naming')
  require File.join(PLUGIN_DIR, 'core', 'previews')
  require File.join(PLUGIN_DIR, 'core', 'text_render')
  require File.join(PLUGIN_DIR, 'core', 'exporter')
  require File.join(PLUGIN_DIR, 'ui', 'dialog')
  require File.join(PLUGIN_DIR, 'ui', 'settings_dialog')
  require File.join(PLUGIN_DIR, 'ui', 'properties_dialog')
  require File.join(PLUGIN_DIR, 'ui', 'export_dialog')

  unless file_loaded?(__FILE__)
    cmd = ::UI::Command.new(PLUGIN_NAME) { SceneManagerPlus::UI::Dialog.show }
    cmd.tooltip   = PLUGIN_NAME
    cmd.status_bar_text = 'Open Scene Manager+ window'
    cmd.menu_text = PLUGIN_NAME

    ::UI.menu('Plugins').add_item(cmd)

    toolbar = ::UI::Toolbar.new(PLUGIN_NAME)
    icon_dir = File.join(PLUGIN_DIR, 'ui', 'icons')
    if File.exist?(File.join(icon_dir, 'scene_manager_24.png'))
      cmd.small_icon = File.join(icon_dir, 'scene_manager_16.png')
      cmd.large_icon = File.join(icon_dir, 'scene_manager_24.png')
    end
    toolbar.add_item(cmd)
    toolbar.show

    # Auto-riapertura come i pannelli nativi: se la finestra era aperta
    # all'ultima chiusura di SU, la ri-mostriamo. Salvato in Dialog#show e
    # Dialog#set_on_closed via write_default('SceneManagerPlus', 'main_dialog_open').
    # Defer di 0.5s: a `file_loaded` la UI di SU non è ancora pronta a ospitare
    # un HtmlDialog (su SU 2019 mostrare la finestra troppo presto causa
    # posizione errata o crash silenzioso).
    if Sketchup.read_default('SceneManagerPlus', 'main_dialog_open', false)
      ::UI.start_timer(0.5, false) do
        begin
          SceneManagerPlus::UI::Dialog.show
        rescue => e
          warn "[SM+] auto-open failed: #{e.class}: #{e.message}"
        end
      end
    end

    file_loaded(__FILE__)
  end
end
