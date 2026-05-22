# Scene Manager+ — generator one-shot per i file .style del pool
#
# Genera 25 file slot_NN.style in scene_manager_plus/assets/styles/, ciascuno
# contenente uno stile chiamato "SM+ Slot NN" (NN = 01..25).
#
# Va girato UNA VOLTA SOLA. SU 2019 non espone Style#save_as via API, quindi
# serve un template esportato a mano via il native Styles browser. Lo script
# poi duplica il template 25 volte e rinomina lo style embedded nel
# document.xml interno via PowerShell + System.IO.Compression.
#
# ─── PREP (una volta, manuale) ────────────────────────────────────────────
#   1. Apri SU 2019 con un modello qualsiasi
#   2. Window → Styles
#   3. Seleziona uno stile semplice come template (es. "Default Style")
#   4. Click sull'icona "Save Style As..." nel Styles browser (la disco
#      con la freccia giù — diversa da "Create new Style")
#   5. Salva come: C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/_template.style
#
# ─── RUN ──────────────────────────────────────────────────────────────────
#   1. Window → Ruby Console
#   2. load 'C:/Claude/Sketchup Plugins/SceneManagerPlus/tools/generate-slot-styles.rb'
#   3. Lo script auto-detetta il nome dello stile dentro il template e lo
#      sostituisce con "SM+ Slot NN" per ogni slot.
#   4. Verifica caricando ciascuno via add_style. Output esito per slot.
#   5. Pulizia: gli stili "SM+ Slot NN" sono ora aggiunti al modello per
#      verifica. Ctrl+Z (o cancellali a mano dal native browser).
#   6. Commit di scene_manager_plus/assets/styles/*.style.

require 'fileutils'
require 'tmpdir'

module SceneManagerPlus
  module GenerateSlotStyles
    NUM_SLOTS = 25
    PLUGIN_ROOT = File.expand_path('..', __dir__)
    TOOLS_DIR = File.join(PLUGIN_ROOT, 'tools')
    OUT_DIR = File.join(PLUGIN_ROOT, 'scene_manager_plus', 'assets', 'styles')
    TEMPLATE = File.join(TOOLS_DIR, '_template.style')

    def self.run
      unless File.exist?(TEMPLATE)
        return abort_msg(
          "Template mancante. Step manuale richiesto:\n" \
          "  1. SU → Window → Styles\n" \
          "  2. Seleziona uno stile semplice (es. Default Style)\n" \
          "  3. Click 'Save Style As...' nel Styles browser\n" \
          "  4. Salva come:\n" \
          "       #{TEMPLATE}\n" \
          "  5. Rilancia questo script."
        )
      end

      m = Sketchup.active_model
      return abort_msg("Apri un modello in SU.") unless m
      styles = m.styles
      return abort_msg("styles.add_style non disponibile.") unless styles.respond_to?(:add_style)

      puts "[gen] SU version: #{Sketchup.version}"
      puts "[gen] Template:   #{TEMPLATE} (#{File.size(TEMPLATE)} bytes)"

      # Step 1: detect del nome originale dentro il template
      detect_out = run_ps('detect', TEMPLATE)
      old_name = parse_detected_name(detect_out)
      unless old_name
        return abort_msg("Detect del nome originale fallito.\nOutput PowerShell:\n#{detect_out}")
      end
      puts "[gen] Nome originale rilevato: #{old_name.inspect}"

      # Step 2: genera 25 slot
      FileUtils.mkdir_p(OUT_DIR)
      errors = []
      ok = 0

      (1..NUM_SLOTS).each do |n|
        new_name = format('SM+ Slot %02d', n)
        out_file = File.join(OUT_DIR, format('slot_%02d.style', n))
        ps_out = run_ps('rename', TEMPLATE, out_file, old_name, new_name)
        unless $?.success? && File.exist?(out_file)
          errors << "Slot #{n}: PS failure\n#{ps_out}"
          next
        end

        # Verifica caricando lo style
        begin
          pre = styles.size
          styles.add_style(out_file, false)
          post = styles.size
          if post > pre
            loaded = styles[post - 1].name
            if loaded == new_name
              puts "[gen] OK slot_#{format('%02d', n)} → #{loaded.inspect}"
              ok += 1
            else
              errors << "Slot #{n}: nome caricato #{loaded.inspect} != atteso #{new_name.inspect}"
            end
          else
            errors << "Slot #{n}: add_style no-op (pre=#{pre} post=#{post})"
          end
        rescue => e
          errors << "Slot #{n}: verifica fallita — #{e.class}: #{e.message}"
        end
      end

      puts ''
      puts '=' * 60
      puts "[gen] Successi: #{ok}/#{NUM_SLOTS}"
      unless errors.empty?
        puts "[gen] Errori (#{errors.size}):"
        errors.each { |e| puts "  - #{e}" }
      end
      puts "[gen] Output: #{OUT_DIR}"
      puts '[gen] Pulizia modello: Ctrl+Z (o cancella i 25 stili dal native browser).'
      puts '[gen] Poi commit di assets/styles/*.style nel repo.'
      nil
    end

    def self.abort_msg(msg)
      puts "[gen] ABORT: #{msg}"
      nil
    end

    # Esegue lo script PS in modalità 'detect' o 'rename'. Ritorna stdout+stderr.
    # Le backticks di SU Ruby su Windows non catturano stdout di processi PS in
    # modo affidabile (buffering issue), quindi redirigiamo su file temp e lo
    # rileggiamo. Stesso pattern usato per spawn nascoste in TextRender/TitleBlock.
    def self.run_ps(mode, *args)
      script = ps_script_path
      quoted = args.map { |a| %("#{a}") }.join(' ')
      out_file = File.join(Dir.tmpdir, "smp_ps_out_#{Process.pid}_#{Time.now.to_f}.txt")
      cmd = %(powershell -NoProfile -ExecutionPolicy Bypass -File "#{script}" -Mode #{mode} #{quoted} > "#{out_file}" 2>&1)
      system(cmd)
      output = File.exist?(out_file) ? File.read(out_file) : ''
      File.delete(out_file) rescue nil
      output
    end

    def self.parse_detected_name(out)
      # Linea attesa: "DETECTED_NAME: <nome>"
      out.each_line do |line|
        if line =~ /^DETECTED_NAME:\s*(.+?)\s*$/
          return Regexp.last_match(1)
        end
      end
      nil
    end

    def self.ps_script_path
      path = File.join(TOOLS_DIR, '_slot_styles_ps.ps1')
      File.write(path, PS_SOURCE) unless File.exist?(path) && File.size(path) == PS_SOURCE.bytesize
      path
    end

    PS_SOURCE = <<~'PS'
      param(
        [Parameter(Mandatory=$true)][ValidateSet('detect','rename')][string]$Mode,
        [Parameter(Position=0)][string]$Arg0,
        [Parameter(Position=1)][string]$Arg1,
        [Parameter(Position=2)][string]$Arg2,
        [Parameter(Position=3)][string]$Arg3
      )

      Add-Type -AssemblyName System.IO.Compression.FileSystem
      Add-Type -AssemblyName System.IO.Compression

      function Find-NameInXml([string]$text) {
        # Pattern 1: name="..."
        $m = [Regex]::Match($text, 'name="([^"]+)"')
        if ($m.Success) { return @{ kind = 'attr_double'; value = $m.Groups[1].Value } }
        # Pattern 2: name='...'
        $m = [Regex]::Match($text, "name='([^']+)'")
        if ($m.Success) { return @{ kind = 'attr_single'; value = $m.Groups[1].Value } }
        # Pattern 3: <name>...</name>
        $m = [Regex]::Match($text, '<name>([^<]+)</name>')
        if ($m.Success) { return @{ kind = 'element'; value = $m.Groups[1].Value } }
        return $null
      }

      function Read-FirstXmlEntry([System.IO.Compression.ZipArchive]$zip) {
        foreach ($e in $zip.Entries) {
          if ($e.Name -match '\.xml$') {
            $s = $e.Open()
            $r = New-Object System.IO.StreamReader $s
            $t = $r.ReadToEnd()
            $r.Dispose(); $s.Dispose()
            return @{ entry = $e; text = $t }
          }
        }
        return $null
      }

      if ($Mode -eq 'detect') {
        $tpl = $Arg0
        if (-not (Test-Path $tpl)) { Write-Host "ERROR: template not found: $tpl"; exit 1 }
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tpl)
        try {
          $payload = Read-FirstXmlEntry $zip
          if ($payload -eq $null) {
            Write-Host "ERROR: no xml entry in template. Zip entries:"
            foreach ($e in $zip.Entries) { Write-Host "  $($e.FullName)" }
            exit 2
          }
          Write-Host "XML_ENTRY: $($payload.entry.FullName)"
          $hit = Find-NameInXml $payload.text
          if ($hit -eq $null) {
            Write-Host "ERROR: name pattern not found in $($payload.entry.FullName)"
            Write-Host "DIAG: first 800 chars of xml:"
            Write-Host $payload.text.Substring(0, [Math]::Min(800, $payload.text.Length))
            exit 3
          }
          Write-Host "DETECTED_KIND: $($hit.kind)"
          Write-Host "DETECTED_NAME: $($hit.value)"
          exit 0
        }
        finally { $zip.Dispose() }
      }

      if ($Mode -eq 'rename') {
        $tpl = $Arg0
        $out = $Arg1
        $old = $Arg2
        $new = $Arg3
        if (-not (Test-Path $tpl)) { Write-Host "ERROR: template missing"; exit 1 }
        if (Test-Path $out) { Remove-Item $out -Force }
        Copy-Item $tpl $out -Force

        $zip = $null
        try {
          $zip = [System.IO.Compression.ZipFile]::Open($out, 'Update')
          $xmlEntries = @($zip.Entries | Where-Object { $_.Name -match '\.xml$' })
          $renamed = $false
          foreach ($e in $xmlEntries) {
            $s = $e.Open()
            $r = New-Object System.IO.StreamReader $s
            $text = $r.ReadToEnd()
            $r.Dispose(); $s.Dispose()

            $escOld = [Regex]::Escape($old)
            $patterns = @(
              @{ find = 'name="' + $escOld + '"';   replace = 'name="' + $new + '"' },
              @{ find = "name='" + $escOld + "'";   replace = "name='" + $new + "'" },
              @{ find = '<name>' + $escOld + '</name>'; replace = '<name>' + $new + '</name>' }
            )

            $newText = $text
            $hit = $false
            foreach ($p in $patterns) {
              $re = New-Object System.Text.RegularExpressions.Regex $p.find
              if ($re.IsMatch($newText)) {
                $newText = $re.Replace($newText, $p.replace, 1)
                $hit = $true
                break
              }
            }
            if (-not $hit) { continue }

            $fullName = $e.FullName
            $e.Delete()
            $newEntry = $zip.CreateEntry($fullName)
            $ws = $newEntry.Open()
            $writer = New-Object System.IO.StreamWriter $ws
            $writer.Write($newText)
            $writer.Dispose(); $ws.Dispose()
            $renamed = $true
            Write-Host "RENAMED entry $fullName"
            break
          }
          if (-not $renamed) { Write-Host "ERROR: no rename happened"; exit 4 }
          exit 0
        }
        finally {
          if ($zip -ne $null) { $zip.Dispose() }
        }
      }
    PS
  end
end

SceneManagerPlus::GenerateSlotStyles.run
