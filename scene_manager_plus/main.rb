require 'sketchup.rb'

module SceneManagerPlus
  require File.join(PLUGIN_DIR, 'core', 'buffer')
  require File.join(PLUGIN_DIR, 'core', 'scene_model')
  require File.join(PLUGIN_DIR, 'core', 'folders')
  require File.join(PLUGIN_DIR, 'core', 'settings')
  require File.join(PLUGIN_DIR, 'core', 'naming')
  require File.join(PLUGIN_DIR, 'core', 'previews')
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

    file_loaded(__FILE__)
  end
end
