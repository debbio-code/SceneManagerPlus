# Scene Manager+ — diagnostic: dump Sketchup::Styles / Sketchup::Style API
#
# Uso: nella Ruby Console di SU 2019:
#   load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/dump-styles-api.rb'
#
# Serve a capire quali metodi sono disponibili in SU 2019 per:
# - rilevare se lo stile attivo ha modifiche pending
# - aggiornare lo stile selezionato con le modifiche correnti
# - creare un nuovo stile dalle modifiche correnti (Save as new)

m = Sketchup.active_model
styles = m && m.styles

puts "=" * 60
puts "Sketchup::Styles API dump (SU #{Sketchup.version})"
puts "=" * 60

unless styles
  puts "ERROR: nessun model attivo, apri un file e riprova."
  return
end

# Metodi istanza chiave che ci interessano
KEY_INSTANCE = %w[
  active_style
  selected_style
  active_style_changed
  active_style_changed?
  update_selected_style
  add_style
  count
  size
  purge_unused
  each
].freeze

puts ""
puts "Metodi rilevanti su Sketchup::Styles (instance):"
KEY_INSTANCE.each do |name|
  available = styles.respond_to?(name)
  puts format("  %-30s %s", name, available ? "OK" : "(missing)")
end

puts ""
puts "Tutti i metodi istanza di Sketchup::Styles (non ereditati da Object):"
inst_methods = (styles.methods - Object.instance_methods).sort
inst_methods.each { |m_| puts "  #{m_}" }

puts ""
puts "Stile attivo corrente:"
begin
  a = styles.active_style
  if a
    puts "  active_style.name         = #{a.name.inspect}"
    puts "  active_style.description  = #{(a.description rescue '?').inspect[0,80]}"
    puts "  active_style.class        = #{a.class}"
    puts "  active_style.methods (extra): #{(a.methods - Object.instance_methods).sort.inspect}"
  else
    puts "  (nessuno)"
  end
rescue => e
  puts "  ERROR: #{e.class}: #{e.message}"
end

puts ""
puts "Stile selezionato corrente:"
begin
  s = styles.selected_style
  if s
    puts "  selected_style.name = #{s.name.inspect}"
  else
    puts "  (nessuno)"
  end
rescue => e
  puts "  ERROR: #{e.class}: #{e.message}"
end

# Detect modifiche pending — proviamo entrambi i nomi
puts ""
puts "Detect modifiche pending allo stile attivo:"
%w[active_style_changed active_style_changed?].each do |n|
  if styles.respond_to?(n)
    begin
      val = styles.send(n)
      puts "  styles.#{n} = #{val.inspect}"
    rescue => e
      puts "  styles.#{n} -> ERROR: #{e.message}"
    end
  end
end

puts "=" * 60
nil
