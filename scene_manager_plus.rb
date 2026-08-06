require 'sketchup.rb'
require 'extensions.rb'

module SceneManagerPlus
  PLUGIN_ID      = 'SceneManagerPlus'.freeze
  PLUGIN_NAME    = 'Scene Manager+'.freeze
  # Mostrata nel titolo della finestra principale ("Scene Manager+ v1.0.0"):
  # serve a verificare a colpo d'occhio che tutte le postazioni usino la
  # stessa build. VA ALZATA A MANO a ogni distribuzione, altrimenti mente.
  PLUGIN_VERSION = '1.0.0'.freeze
  PLUGIN_DIR     = File.join(File.dirname(__FILE__), 'scene_manager_plus').freeze

  unless file_loaded?(__FILE__)
    ext = SketchupExtension.new(PLUGIN_NAME, File.join(PLUGIN_DIR, 'main'))
    ext.version     = PLUGIN_VERSION
    ext.creator     = 'Scene Manager+'
    ext.description = 'Advanced scene manager with folders, drag&drop, batch export and watermark.'
    Sketchup.register_extension(ext, true)
    file_loaded(__FILE__)
  end
end
