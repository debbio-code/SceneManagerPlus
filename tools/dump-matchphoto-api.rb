# Scene Manager+ — diagnostic: API Match Photo in SU 2019
#
# Uso: con una scena Match Photo attiva nel viewport,
#   load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/dump-matchphoto-api.rb'
# Stampa cosa Sketchup::Page e Sketchup::Pages espongono per Match Photo,
# così possiamo capire come copiare la photo dalla scena attiva alla nuova.

m = Sketchup.active_model
p = m && m.pages && m.pages.selected_page

puts "=" * 60
puts "Match Photo API dump — SU #{Sketchup.version}"
puts "=" * 60

unless p
  puts "ERROR: nessuna scena attiva."
  return
end

puts "Active page: #{p.name.inspect}"
puts ""

# 1. Metodi su Sketchup::Page con 'match', 'photo', 'image' nel nome
puts "Page methods con 'match'/'photo'/'image' nel nome:"
methods_filtered = (p.methods - Object.instance_methods).sort.select do |mname|
  mname.to_s =~ /(match|photo|image)/i
end
if methods_filtered.empty?
  puts "  (nessuno)"
else
  methods_filtered.each { |mn| puts "  #{mn}" }
end

puts ""
puts "Pages methods con 'match'/'photo'/'image' nel nome:"
pmethods = (m.pages.methods - Object.instance_methods).sort.select do |mname|
  mname.to_s =~ /(match|photo|image)/i
end
if pmethods.empty?
  puts "  (nessuno)"
else
  pmethods.each { |mn| puts "  #{mn}" }
end

puts ""
puts "Page#use_* flag getters (cerco use_matchphoto e simili):"
use_flags = (p.methods - Object.instance_methods).sort.select { |mn| mn.to_s.start_with?('use_') }
use_flags.each do |mn|
  begin
    val = p.send(mn)
    puts format("  %-30s = %s", mn, val.inspect)
  rescue => e
    puts format("  %-30s ERROR: %s", mn, e.message)
  end
end

puts ""
puts "PAGE_USE_* costanti definite top-level:"
const_use = Object.constants.select { |c| c.to_s.start_with?('PAGE_USE_') }
const_use.sort.each do |c|
  puts format("  %-40s = %s", c, Object.const_get(c).inspect)
end

puts ""
puts "Page#matchphoto? esiste? #{p.respond_to?(:matchphoto?)}"
if p.respond_to?(:matchphoto?)
  begin
    puts "Page#matchphoto? value = #{p.matchphoto?.inspect}"
  rescue => e
    puts "  ERROR: #{e.message}"
  end
end

puts ""
puts "Page#matchphoto esiste? #{p.respond_to?(:matchphoto)}"
if p.respond_to?(:matchphoto)
  begin
    mp = p.matchphoto
    puts "Page#matchphoto = #{mp.inspect}"
    if mp
      puts "  class: #{mp.class}"
      puts "  methods: #{(mp.methods - Object.instance_methods).sort.inspect}"
    end
  rescue => e
    puts "  ERROR: #{e.message}"
  end
end

puts ""
puts "Sketchup::Matchphoto class defined? #{Object.const_defined?('Sketchup::Matchphoto') rescue false}"

puts ""
puts "Camera info (Match Photo è parte della camera):"
c = p.camera
if c
  cm = (c.methods - Object.instance_methods).sort
  puts "  Camera methods: #{cm.inspect}"
end

puts "=" * 60
nil
