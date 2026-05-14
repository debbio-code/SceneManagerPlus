require 'json'

module SceneManagerPlus
  module Core
    # Gestione cartelle. Stub per Fase 1: solo schema dati e API base.
    # Implementazione completa in Fase 2.
    module Folders
      module_function

      ATTR_KEY = 'folders'.freeze

      def model
        Sketchup.active_model
      end

      # Schema folder: { id:, name:, color:, expanded:, parent_id:, scene_ids: [] }
      def all
        raw = model.get_attribute(PLUGIN_ID, ATTR_KEY, '[]')
        JSON.parse(raw)
      rescue
        []
      end

      def save(list)
        model.set_attribute(PLUGIN_ID, ATTR_KEY, list.to_json)
        list
      end
    end
  end
end
