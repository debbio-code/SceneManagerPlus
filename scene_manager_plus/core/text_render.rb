require 'json'
require 'tmpdir'
require 'fileutils'

module SceneManagerPlus
  module Core
    # Rende un batch di etichette testuali su PNG trasparenti tramite
    # PowerShell + System.Drawing (Windows). Una sola spawn di PS per export.
    #
    # Spawn nascosta via WScript.Shell.Run (windowStyle=0) per evitare il
    # flash della console di PowerShell ad ogni export. Fallback a system()
    # se Win32OLE non è disponibile.
    module TextRender
      module_function

      PS_SCRIPT = <<~PS
        Add-Type -AssemblyName System.Drawing
        $ErrorActionPreference = 'Stop'
        $cfgJson = Get-Content -Raw -LiteralPath $args[0] -Encoding UTF8
        $cfg = ConvertFrom-Json $cfgJson
        $fontFamily = [string]$cfg.font_family
        $fontSize   = [single]$cfg.font_size
        if ($cfg.bold) { $style = [System.Drawing.FontStyle]::Bold } else { $style = [System.Drawing.FontStyle]::Regular }
        try {
          $font = New-Object System.Drawing.Font($fontFamily, $fontSize, $style, [System.Drawing.GraphicsUnit]::Pixel)
        } catch {
          $font = New-Object System.Drawing.Font('Arial', $fontSize, $style, [System.Drawing.GraphicsUnit]::Pixel)
        }
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, [int]$cfg.r, [int]$cfg.g, [int]$cfg.b))
        $measureBmp = New-Object System.Drawing.Bitmap 1, 1
        $measureG = [System.Drawing.Graphics]::FromImage($measureBmp)
        $measureG.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
        foreach ($item in $cfg.items) {
          $text = [string]$item.text
          $out  = [string]$item.out
          if ([string]::IsNullOrEmpty($text)) { continue }
          $sz = $measureG.MeasureString($text, $font)
          $w = [int][Math]::Ceiling($sz.Width) + 6
          $h = [int][Math]::Ceiling($sz.Height) + 4
          if ($w -lt 1) { $w = 1 }
          if ($h -lt 1) { $h = 1 }
          $bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $g = [System.Drawing.Graphics]::FromImage($bmp)
          $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
          $g.DrawString($text, $font, $brush, 3, 2)
          $g.Dispose()
          $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
          $bmp.Dispose()
        }
        $measureG.Dispose()
        $measureBmp.Dispose()
        $font.Dispose()
        $brush.Dispose()
      PS

      # items: array di [uid, text]
      # cfg:   hash con font_family, font_size, bold, color (#RRGGBB)
      #
      # Ritorna { uid => png_path, '_tmpdir' => dir }. Chiamare cleanup(result)
      # quando finito.
      def render_batch(items, cfg)
        return { '_tmpdir' => nil } if items.empty?

        color_hex = (cfg['color'] || '#FFFFFF').to_s.sub(/^#/, '')
        color_hex = 'FFFFFF' unless color_hex =~ /\A[0-9a-fA-F]{6}\z/
        r = color_hex[0, 2].to_i(16)
        g = color_hex[2, 2].to_i(16)
        b = color_hex[4, 2].to_i(16)

        tmpdir = File.join(Dir.tmpdir, "sm_labels_#{Process.pid}_#{Time.now.to_i}_#{rand(10_000)}")
        FileUtils.mkdir_p(tmpdir)

        payload_items = items.each_with_index.map do |(_uid, text), i|
          { 'text' => text.to_s, 'out' => File.join(tmpdir, "#{i}.png") }
        end
        payload = {
          'font_family' => (cfg['font_family'] || 'Arial').to_s,
          'font_size'   => [(cfg['font_size'] || 28).to_i, 4].max,
          'bold'        => !!cfg['bold'],
          'r' => r, 'g' => g, 'b' => b,
          'items'       => payload_items
        }

        cfg_path    = File.join(tmpdir, 'cfg.json')
        script_path = File.join(tmpdir, 'render.ps1')
        File.binwrite(cfg_path,    payload.to_json)
        File.binwrite(script_path, PS_SCRIPT)

        cmd = %(powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "#{script_path}" "#{cfg_path}")
        ok = run_hidden(cmd)
        warn "[SM+] TextRender: PowerShell render returned non-zero" unless ok

        result = { '_tmpdir' => tmpdir }
        items.each_with_index do |(uid, _text), i|
          png = File.join(tmpdir, "#{i}.png")
          result[uid] = png if File.file?(png)
        end
        puts "[SM+] TextRender.render_batch: requested=#{items.size} produced=#{result.size - 1} tmpdir=#{tmpdir}"
        result
      end

      def cleanup(result)
        tmpdir = result && result['_tmpdir']
        return unless tmpdir && File.directory?(tmpdir)
        FileUtils.rm_rf(tmpdir)
      rescue => e
        warn "[SM+] TextRender.cleanup: #{e.class}: #{e.message}"
      end

      # Lancia il comando senza far apparire la console.
      def run_hidden(cmd)
        require 'win32ole'
        shell = WIN32OLE.new('WScript.Shell')
        # Run(command, windowStyle=0 hidden, waitOnReturn=true) → ritorna exit code
        rc = shell.Run(cmd, 0, true)
        rc.to_i == 0
      rescue LoadError, WIN32OLERuntimeError => e
        warn "[SM+] TextRender: Win32OLE non disponibile (#{e.message}), fallback system()"
        system(cmd)
      rescue => e
        warn "[SM+] TextRender.run_hidden: #{e.class}: #{e.message}"
        false
      end
    end
  end
end
