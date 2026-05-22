# Scene Manager+ — diagnostic: cerca il path della foto Match Photo
#
# `add_matchphoto_page(image_filename, camera, name)` esiste in SU 2019 ma
# richiede il path della foto, che non è esposto via API (Page#matchphoto
# non esiste). Ipotesi: SU lo memorizza in qualche attribute_dictionary del
# model o della scena. Se lo troviamo, possiamo clonare un Match Photo
# completamente automatico.
#
# Uso: con la scena Match Photo attiva,
#   load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/dump-matchphoto-attrs.rb'

m = Sketchup.active_model
p = m && m.pages && m.pages.selected_page

puts "=" * 60
puts "Match Photo attribute dump — SU #{Sketchup.version}"
puts "Active page: #{p ? p.name.inspect : '(nessuna)'}"
puts "=" * 60

def dump_dict(label, dict)
  return puts "  (#{label}: nessun attribute_dictionaries)" unless dict
  if dict.respond_to?(:count) ? dict.count == 0 : dict.to_a.empty?
    puts "  (#{label}: vuoto)"
    return
  end
  dict.each do |d|
    puts "  Dict '#{d.name}':"
    d.each_pair do |k, v|
      val = v.inspect
      val = val[0, 200] + '...(truncated)' if val.length > 200
      puts "    #{k.inspect} => #{val}"
    end
  end
end

puts ""
puts "Page attribute_dictionaries:"
dump_dict('page', p && p.attribute_dictionaries)

puts ""
puts "Model attribute_dictionaries:"
dump_dict('model', m && m.attribute_dictionaries)

# Cerca anche tra Sketchup::Image (residue) e nelle definizioni che hanno
# qualcosa di simile a 'matchphoto'
puts ""
puts "Sketchup::Image entities nel model:"
images = m.entities.grep(Sketchup::Image)
if images.empty?
  puts "  (nessuna)"
else
  images.each do |img|
    puts "  - #{img.inspect}"
    puts "    path: #{(img.image_rep.respond_to?(:path) ? img.image_rep.path : '?') rescue '?'}"
    puts "    methods: #{(img.methods - Object.instance_methods).sort.inspect}"
  end
end

puts ""
puts "Sketchup::ComponentDefinition con 'photo' o 'match' nel nome:"
m.definitions.each do |d|
  if d.name.to_s.downcase =~ /(photo|match)/
    puts "  - #{d.name.inspect} (#{d.entities.size} entities)"
  end
end

# Tutti i path dei file referenziati nel model
puts ""
puts "Cerco riferimenti a file immagine nel model:"
seen_paths = []
[m].each do |obj|
  next unless obj.respond_to?(:attribute_dictionaries)
  d = obj.attribute_dictionaries
  next unless d
  d.each do |dict|
    dict.each_pair do |k, v|
      vs = v.to_s
      if vs =~ /\.(jpg|jpeg|png|bmp|tif|tiff)/i
        seen_paths << "model dict='#{dict.name}' #{k}=#{vs[0,200]}"
      end
    end
  end
end
[p].compact.each do |obj|
  next unless obj.respond_to?(:attribute_dictionaries)
  d = obj.attribute_dictionaries
  next unless d
  d.each do |dict|
    dict.each_pair do |k, v|
      vs = v.to_s
      if vs =~ /\.(jpg|jpeg|png|bmp|tif|tiff)/i
        seen_paths << "page dict='#{dict.name}' #{k}=#{vs[0,200]}"
      end
    end
  end
end
if seen_paths.empty?
  puts "  (nessun path immagine trovato negli attributi)"
else
  seen_paths.each { |s| puts "  #{s}" }
end

puts "=" * 60
nil
