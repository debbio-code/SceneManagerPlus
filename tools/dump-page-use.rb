# Scene Manager+ — diagnostic: dump PAGE_USE_* constants
#
# Uso: aprire SketchUp 2019, aprire la Ruby Console (Window → Ruby Console),
# poi caricare questo file:
#
#   load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/dump-page-use.rb'
#
# Stampa quali costanti PAGE_USE_* esistono nell'ambiente SU corrente e i
# loro valori. Serve a verificare la mappatura predicate → bitmask in
# Core::SceneModel.update_from_view (in particolare se PAGE_USE_STYLE,
# PAGE_USE_SKETCHCS, PAGE_USE_AXES esistono in SU 2019).
#
# Anche elenca la lista completa di costanti top-level che iniziano con
# "PAGE_" così non perdiamo eventuali nomi non previsti.

puts "=" * 60
puts "PAGE_USE_* dump (SU #{Sketchup.version})"
puts "=" * 60

# Lista canonica delle costanti che il plugin tenta o potrebbe tentare
CANDIDATES = %w[
  PAGE_NO_CAMERA
  PAGE_USE_CAMERA
  PAGE_USE_RENDERING_OPTIONS
  PAGE_USE_SHADOWINFO
  PAGE_USE_STYLE
  PAGE_USE_SKETCHCS
  PAGE_USE_AXES
  PAGE_USE_HIDDEN
  PAGE_USE_HIDDEN_GEOMETRY
  PAGE_USE_HIDDEN_LAYERS
  PAGE_USE_LAYER_VISIBILITY
  PAGE_USE_SECTION_PLANES
  PAGE_USE_ACTIVE_SECTION_PLANES
  PAGE_USE_ALL
].freeze

CANDIDATES.each do |name|
  if Object.const_defined?(name)
    val = Object.const_get(name)
    puts format("  %-35s = %d  (0x%x)", name, val, val)
  else
    puts format("  %-35s = (undefined)", name)
  end
end

puts ""
puts "Tutte le costanti top-level che iniziano con PAGE_:"
all_page_consts = Object.constants.grep(/\APAGE_/).sort
all_page_consts.each do |name|
  val = Object.const_get(name)
  puts format("  %-35s = %d  (0x%x)", name.to_s, val, val) if val.is_a?(Integer)
end

# Eventuali "extra" non in CANDIDATES (potrebbero esistere costanti che non
# avevamo previsto)
extras = all_page_consts.map(&:to_s) - CANDIDATES
puts ""
if extras.empty?
  puts "Nessuna costante PAGE_* extra (oltre a quelle previste)."
else
  puts "Costanti PAGE_* EXTRA non previste dal plugin:"
  extras.each { |n| puts "  - #{n}" }
end

puts "=" * 60
nil
