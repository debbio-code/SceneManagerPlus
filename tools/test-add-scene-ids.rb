# Scene Manager+ — diagnostic: cerca il command ID di "+" della Scenes inspector
#
# Sappiamo che send_action(21067) (View → Animation → Add Scene) NON preserva il
# Match Photo. Il bottone "+" della Scenes inspector invece sì. Hanno code path
# diversi in SU 2019 C++ interno. Questo tester:
#   1. Salva il count iniziale di pagine
#   2. Per ciascun ID nel range, chiama send_action e annota se è stata aggiunta
#      una nuova pagina
#   3. Stampa la lista degli ID che hanno creato pagine — l'utente poi clicca a
#      mano su ciascuna delle nuove scene per verificare se il Match Photo è
#      preservato. L'ID buono è quello da usare.
#
# Uso:
#   1. Apri il file SKP con almeno una scena Match Photo
#   2. ATTIVA la scena Match Photo (così è quella di partenza)
#   3. Ruby Console:
#      load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/test-add-scene-ids.rb'
#   4. Lo script aggiunge varie scene nuove. Clicca su ciascuna nella lista del
#      plugin (o nei tab nativi) e verifica se la foto compare.
#   5. Mandami i risultati: quali ID hanno preservato il Match Photo.
#
# Pulizia dopo: Ctrl+Z multipli, o nel plugin seleziona+cancella in blocco.

m = Sketchup.active_model
unless m
  puts "ABORT: nessun model attivo."
  return
end

active = m.pages.selected_page
unless active
  puts "ABORT: nessuna scena attiva. Attiva una scena Match Photo prima."
  return
end

# Range strategici: vicino al 21067 noto, + range tipici per inspector commands.
# Tieni la lista piccola per non aggiungere troppe scene al model.
IDS_TO_TEST = [
  # Cluster Animation noto: 21067=Add, 21068=Update, 21078=Delete
  21065, 21066, 21069, 21070, 21071, 21072, 21073, 21074, 21075, 21076, 21077,
  # Cluster vicino a 10535 (Next/Prev scene) — magari c'è inspector add lì
  10530, 10531, 10532, 10533, 10537, 10538, 10539, 10540,
  # Range tipico inspector commands (esperimentale)
  10620, 10621, 10622, 10623, 10625, 10626, 10627, 10628, 10629, 10630
].freeze

puts "=" * 60
puts "Test add-scene IDs — SU #{Sketchup.version}"
puts "Active scene (Match Photo): #{active.name.inspect}"
puts "Initial page count: #{m.pages.size}"
puts "=" * 60

results = []
IDS_TO_TEST.each do |id|
  pre = m.pages.size
  pre_active = m.pages.selected_page
  begin
    Sketchup.send_action(id)
  rescue => e
    next
  end
  # Riportiamo la scena attiva alla Match Photo per il prossimo test
  m.pages.selected_page = pre_active if pre_active
  post = m.pages.size
  if post > pre
    new_pages = m.pages.to_a.last(post - pre)
    new_pages.each do |np|
      results << { id: id, page_name: np.name }
      puts "  ID #{id}: aggiunta scena '#{np.name}'"
    end
  end
end

puts ""
puts "=" * 60
if results.empty?
  puts "Nessun ID ha aggiunto scene. Allarghiamo il range."
else
  puts "#{results.size} scene aggiunte da #{results.map { |r| r[:id] }.uniq.size} ID distinti."
  puts ""
  puts "Click su ciascuna scena nuova e verifica Match Photo:"
  results.each_with_index do |r, i|
    puts "  [#{i + 1}/#{results.size}] ID=#{r[:id]} scena='#{r[:page_name]}'"
  end
  puts ""
  puts "Riporta quali ID hanno preservato il Match Photo."
  puts "Pulizia: Ctrl+Z multipli, o seleziona+cancella nel plugin."
end
puts "=" * 60
nil
