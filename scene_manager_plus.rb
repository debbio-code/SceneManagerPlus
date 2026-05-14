require 'sketchup.rb'
require 'extensions.rb'

module SceneManagerPlus
  PLUGIN_ID      = 'SceneManagerPlus'.freeze
  PLUGIN_NAME    = 'Scene Manager+'.freeze
  PLUGIN_VERSION = '0.1.0'.freeze
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
