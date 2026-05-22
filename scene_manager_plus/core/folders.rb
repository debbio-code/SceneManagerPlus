require 'json'

module SceneManagerPlus
  module Core
    # Gestione cartelle (logiche). Persistenza JSON su attributo del modello.
    # Schema: { id:, name:, color:, expanded:, parent_id:, scene_ids: [] }
    module Folders
      module_function

      ATTR_KEY = 'folders'.freeze

      def model
        Sketchup.active_model
      end

      # Legge il raw da SU (bypassando Buffer). Usato da Buffer.ensure_folders!
      def read_raw
        raw = model.get_attribute(PLUGIN_ID, ATTR_KEY, '[]')
        list = JSON.parse(raw)
        list.is_a?(Array) ? list : []
      rescue
        []
      end

      # Scrive raw su SU bypassando Buffer. Usato da Buffer.flush!
      def write_raw(list)
        # Persistenza lazy degli uid scene referenziati: senza questo,
        # se gli uid sono ancora transient (apertura file senza interagire),
        # al riavvio le scene non si ritrovano nelle folder.
        scene_uids = list.flat_map { |f| Array(f['scene_ids']) }
        Core::SceneModel.persist_uids_for_ids(scene_uids) if scene_uids.any?
        model.set_attribute(PLUGIN_ID, ATTR_KEY, list.to_json)
        list
      end

      def all
        if Buffer.deferred?
          return Buffer.ensure_folders!
        end
        read_raw
      end

      def save(list)
        if Buffer.deferred?
          Buffer.set_folders(list)
          return list
        end
        write_raw(list)
      end

      def find(id)
        all.find { |f| f['id'] == id }
      end

      def new_id
        "f#{Time.now.to_i}-#{rand(1 << 24).to_s(16)}"
      end

      # Mappa scene_uid → folder_id per le scene attualmente in una cartella.
      def scene_parent_map
        map = {}
        all.each do |f|
          Array(f['scene_ids']).each { |sid| map[sid] = f['id'] }
        end
        map
      end

      def create(name: 'New folder', color: '#4ea1ff', parent_id: nil)
        list = all
        folder = {
          'id'        => new_id,
          'name'      => name.to_s,
          'color'     => color.to_s,
          'expanded'  => true,
          'parent_id' => parent_id,
          'scene_ids' => []
        }
        list << folder
        save(list)
        # appende il folder all'ordine logico (root) in coda
        order = Core::SceneModel.logical_order
        order << folder['id'] unless order.include?(folder['id'])
        Core::SceneModel.set_logical_order(order)
        folder
      end

      def update(id, attrs)
        list = all
        f = list.find { |x| x['id'] == id }
        return false unless f
        f['name']     = attrs['name'].to_s    if attrs.key?('name') && !attrs['name'].to_s.empty?
        f['color']    = attrs['color'].to_s   if attrs.key?('color')
        f['expanded'] = !!attrs['expanded']   if attrs.key?('expanded')
        save(list)
        true
      end

      def delete(id)
        list = all
        f = list.find { |x| x['id'] == id }
        return false unless f
        # le scene della cartella tornano al root in coda, preservando il loro ordine
        order = Core::SceneModel.logical_order
        order -= [id]
        Array(f['scene_ids']).each { |sid| order << sid unless order.include?(sid) }
        Core::SceneModel.set_logical_order(order)
        list.reject! { |x| x['id'] == id }
        save(list)
        true
      end
    end
  end
end
