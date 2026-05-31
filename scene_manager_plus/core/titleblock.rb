require 'json'
require 'tmpdir'
require 'fileutils'

module SceneManagerPlus
  module Core
    # Renderer del cartiglio (title block) come PNG da appendere sotto
    # l'immagine esportata. Una singola spawn PowerShell genera in batch
    # N PNG (uno per scena: cambia solo Cliente e Tavola nr.).
    #
    # Layout 5 box (left → right) con proporzioni:
    #   1) Cliente            ~20%
    #   2) Tavola nr. / Data  ~18%
    #   3) Progetto / Disegn. ~30%
    #   4) Dati aziendali     ~20%
    #   5) Logo               ~12%
    #
    # Spawn nascosta via WScript.Shell.Run (stesso meccanismo di TextRender).
    module TitleBlock
      module_function

      PS_SCRIPT = <<~PS
        Add-Type -AssemblyName System.Drawing
        $ErrorActionPreference = 'Stop'
        $cfgJson = Get-Content -Raw -LiteralPath $args[0] -Encoding UTF8
        $cfg = ConvertFrom-Json $cfgJson

        $W = [int]$cfg.width
        $H = [int]$cfg.height
        $fontFamily = [string]$cfg.font_family
        $logoPath = [string]$cfg.logo_path
        $companyLines = @($cfg.company_lines)
        $date = [string]$cfg.date
        $projectBy  = [string]$cfg.project_by
        $designer   = [string]$cfg.designer
        $phaseValue = [string]$cfg.project_phase
        if ([string]::IsNullOrEmpty($phaseValue)) { $phaseValue = "Definitivo" }

        # Carica logo una sola volta (se path valido)
        $logoImg = $null
        if ($logoPath -and (Test-Path -LiteralPath $logoPath)) {
          try { $logoImg = [System.Drawing.Image]::FromFile($logoPath) } catch { $logoImg = $null }
        }

        # Font: prova famiglia richiesta, fallback Arial.
        function New-Fnt([string]$fam, [single]$sz, $style) {
          try { return New-Object System.Drawing.Font($fam, $sz, $style, [System.Drawing.GraphicsUnit]::Pixel) }
          catch { return New-Object System.Drawing.Font('Arial', $sz, $style, [System.Drawing.GraphicsUnit]::Pixel) }
        }

        # Auto-fit: prova $startSz, scala -1 finché il testo non entra in $maxW.
        # Mai sotto $minSz. Caller deve disposare il font ritornato.
        function Fit-Fnt($g, [string]$text, [string]$fam, [single]$startSz, $style, [single]$maxW, [single]$minSz) {
          $sz = $startSz
          while ($sz -gt $minSz) {
            $f = New-Fnt $fam $sz $style
            $w = $g.MeasureString($text, $f).Width
            if ($w -le $maxW) { return $f }
            $f.Dispose()
            $sz = $sz - 1
          }
          return (New-Fnt $fam $minSz $style)
        }

        # Divide $words in 2 righe bilanciate (larghezze il più simili
        # possibile), almeno 1 parola per riga. Ritorna SEMPRE @($line1, $line2)
        # con entrambe non vuote (presuppone $words.Count >= 2).
        function Split-Balanced($g, $words, $font) {
          $total = $words.Count
          $best = 1
          $bestDiff = [double]::PositiveInfinity
          for ($s = 1; $s -lt $total; $s++) {
            $l1 = ($words[0..($s - 1)] -join ' ')
            $l2 = ($words[$s..($total - 1)] -join ' ')
            $w1 = $g.MeasureString($l1, $font).Width
            $w2 = $g.MeasureString($l2, $font).Width
            $diff = [Math]::Abs($w1 - $w2)
            if ($diff -lt $bestDiff) { $bestDiff = $diff; $best = $s }
          }
          return ,@(($words[0..($best - 1)] -join ' '), ($words[$best..($total - 1)] -join ' '))
        }

        # Fit per l'OGGETTO:
        #  - se entra su UNA riga a $startSz → una riga, NESSUN rimpicciolimento.
        #  - altrimenti va a capo: SEMPRE 2 righe bilanciate (mai collasso a una
        #    riga rimpicciolita), partendo da -30% del font pieno e scalando
        #    ancora solo se serve fino a $minSz.
        # Ritorna @{ Font=..; Lines=@(..) } (1 o 2 righe). Caller disposa il Font.
        function Fit-Object($g, [string]$text, [string]$fam, [single]$startSz, $style, [single]$maxW, [single]$minSz) {
          $f = New-Fnt $fam $startSz $style
          if ($g.MeasureString($text, $f).Width -le $maxW) { return @{ Font = $f; Lines = @($text) } }
          $f.Dispose()
          $words = @($text -split '\s+' | Where-Object { $_ -ne '' })
          if ($words.Count -lt 2) {
            # Una sola parola: non si può andare a capo, riduci e basta.
            return @{ Font = (Fit-Fnt $g $text $fam $startSz $style $maxW $minSz); Lines = @($text) }
          }
          # Costretti ad andare a capo: parti da -30% del font pieno (richiesta
          # esplicita), split bilanciato in 2 righe; se non entrano scala fino
          # a $minSz (a $minSz si accetta l'eventuale overflow).
          $sz = [single]([Math]::Max($minSz, $startSz * 0.7))
          while ($true) {
            $f = New-Fnt $fam $sz $style
            $split = Split-Balanced $g $words $f
            $line1 = $split[0]; $line2 = $split[1]
            $w1 = $g.MeasureString($line1, $f).Width
            $w2 = $g.MeasureString($line2, $f).Width
            if (([Math]::Max($w1, $w2) -le $maxW) -or ($sz -le $minSz)) {
              return @{ Font = $f; Lines = @($line1, $line2) }
            }
            $f.Dispose()
            $sz = $sz - 1
          }
        }

        $tavolaPlaceholder = [string]$cfg.tavola_placeholder
        if ([string]::IsNullOrEmpty($tavolaPlaceholder)) { $tavolaPlaceholder = "00" }
        # Cliente: il valore è costante per tutto il batch (= prefix_custom).
        $clientStr = [string]$cfg.client
        # Nome scena più lungo nel batch (Ruby lo precalcola).
        $sceneLongest = [string]$cfg.scene_longest

        # Font sizes (max): spinti su per riempire bene. Verranno scalati
        # tutti insieme se la somma delle larghezze auto-sized supera W.
        $maxLabelSz = [Math]::Max(11.0, [single]($H * 0.18))
        $maxValueSz = [Math]::Max(13.0, [single]($H * 0.22))
        $maxSmallSz = [Math]::Max(10.0, [single]($H * 0.17))
        $maxBoldSz  = [Math]::Max(11.0, [single]($H * 0.18))
        $labelSz = $maxLabelSz; $valueSz = $maxValueSz
        $smallSz = $maxSmallSz; $boldSz  = $maxBoldSz

        # Box 2 (Tavola/Data) e 3 (Progetto/Disegnato) usano font intermedi
        # — più piccoli di Cliente/Oggetto, più grandi dei dati aziendali.
        $midRatio = 0.82
        $midLabelSz = [single]($labelSz * $midRatio)
        $midValueSz = [single]($valueSz * $midRatio)

        $labelFont    = New-Fnt $fontFamily $labelSz    ([System.Drawing.FontStyle]::Bold)
        $valueFont    = New-Fnt $fontFamily $valueSz    ([System.Drawing.FontStyle]::Regular)
        $smallFont    = New-Fnt $fontFamily $smallSz    ([System.Drawing.FontStyle]::Regular)
        $boldFont     = New-Fnt $fontFamily $boldSz     ([System.Drawing.FontStyle]::Bold)
        $midLabelFont = New-Fnt $fontFamily $midLabelSz ([System.Drawing.FontStyle]::Bold)
        $midValueFont = New-Fnt $fontFamily $midValueSz ([System.Drawing.FontStyle]::Regular)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
        $whiteBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $borderPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 2
        $linePen   = New-Object System.Drawing.Pen ([System.Drawing.Color]::Black), 1

        $pad = [int]([Math]::Max(6, $H * 0.06))

        # Bitmap di servizio per misurare i testi (Graphics standalone).
        $measureBmp = New-Object System.Drawing.Bitmap 1, 1
        $measureG = [System.Drawing.Graphics]::FromImage($measureBmp)
        $measureG.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

        function Measure-Lbl($g, $text, $font) {
          return $g.MeasureString($text, $font).Width
        }
        # Misura larghezza di "label{gap}value" con due font (label bold + value regular).
        function Measure-LV($g, [string]$label, [string]$value, $labelFont, $valueFont) {
          $wL = $g.MeasureString($label, $labelFont).Width
          $wV = $g.MeasureString($value, $valueFont).Width
          return [single]($wL + 8 + $wV)
        }

        # ---------- Calcolo larghezze auto-size dei box ----------
        # Logo: % fissa della larghezza totale.
        $logoW = [int]([Math]::Max(80, $W * 0.10))
        $target = $W - $logoW
        # Fattore "respiro" sui box 2/3/4 (Tavola/Data, Progetto/Disegnato,
        # Dati aziendali): +15% di larghezza rispetto al testo nudo, così
        # i contenuti centrati hanno aria attorno. Sottratto dal box Cliente.
        $boxBreath = 1.15

        # Itera: misura i box ai font correnti, se somma > target scala
        # i font globalmente (-1px). Ferma quando entrano (o font minimo).
        $clienteW = 0; $tavolaW = 0; $progW = 0; $datiW = 0
        $iter = 0
        while ($true) {
          # OGGETTO (nome scena) NON guida lo shrink globale dei font: se è
          # troppo lungo viene compresso e mandato a capo su 2 righe nel suo
          # box (vedi Fit-Object). Lo shrink globale è guidato solo da CLIENTE
          # (valore costante) + il label "OGGETTO:" come floor, così gli altri
          # box restano a font pieno a parità di altezza del cartiglio.
          $w1a = Measure-LV $measureG "CLIENTE:" $clientStr $labelFont $valueFont
          $w1oggLbl = $measureG.MeasureString("OGGETTO:", $labelFont).Width
          $clienteW = [int]([Math]::Ceiling([Math]::Max($w1a, $w1oggLbl))) + 2 * $pad
          # Box 2/3 misurati col MID font (più piccolo).
          $w2a = Measure-LV $measureG "TAVOLA nr.:" $tavolaPlaceholder $midLabelFont $midValueFont
          $w2b = Measure-LV $measureG "DATA:"       $date              $midLabelFont $midValueFont
          $tavolaW = [int]([Math]::Ceiling([Math]::Max($w2a, $w2b) * $boxBreath)) + 2 * $pad
          $w3a = Measure-LV $measureG "PROGETTO:"      $projectBy $midLabelFont $midValueFont
          $w3b = Measure-LV $measureG "CONTROLLATO DA:" $designer $midLabelFont $midValueFont
          $progW = [int]([Math]::Ceiling([Math]::Max($w3a, $w3b) * $boxBreath)) + 2 * $pad
          $dW = 0.0
          for ($k=0; $k -lt $companyLines.Count; $k++) {
            if ($k -eq 0) { $font = $boldFont } else { $font = $smallFont }
            $ww = $measureG.MeasureString([string]$companyLines[$k], $font).Width
            if ($ww -gt $dW) { $dW = $ww }
          }
          $datiW = [int]([Math]::Ceiling($dW * $boxBreath)) + 2 * $pad
          # Box FASE (right sub-box of Cliente): auto-sized on "PROGETTO:" + phase value.
          $wFase = Measure-LV $measureG "PROGETTO:" $phaseValue $midLabelFont $midValueFont
          $faseW = [int]([Math]::Ceiling($wFase * $boxBreath)) + 2 * $pad

          $autoSum = $clienteW + $faseW + $tavolaW + $progW + $datiW
          if ($autoSum -le $target) { break }
          # Scala globalmente i font -1px e riprova.
          if ($valueSz -le 10.0) { break }
          $labelSz -= 1; $valueSz -= 1; $smallSz -= 1; $boldSz -= 1
          $midLabelSz = [single]($labelSz * $midRatio)
          $midValueSz = [single]($valueSz * $midRatio)
          $labelFont.Dispose(); $valueFont.Dispose(); $smallFont.Dispose(); $boldFont.Dispose()
          $midLabelFont.Dispose(); $midValueFont.Dispose()
          $labelFont    = New-Fnt $fontFamily $labelSz    ([System.Drawing.FontStyle]::Bold)
          $valueFont    = New-Fnt $fontFamily $valueSz    ([System.Drawing.FontStyle]::Regular)
          $smallFont    = New-Fnt $fontFamily $smallSz    ([System.Drawing.FontStyle]::Regular)
          $boldFont     = New-Fnt $fontFamily $boldSz     ([System.Drawing.FontStyle]::Bold)
          $midLabelFont = New-Fnt $fontFamily $midLabelSz ([System.Drawing.FontStyle]::Bold)
          $midValueFont = New-Fnt $fontFamily $midValueSz ([System.Drawing.FontStyle]::Regular)
          $iter++
          if ($iter -gt 60) { break }
        }
        # Spazio rimanente al Cliente (box più "elastico"), dedotto il box FASE.
        $clienteW = $W - $logoW - $faseW - $tavolaW - $progW - $datiW
        $widths = @($clienteW, $faseW, $tavolaW, $progW, $datiW, $logoW)
        Write-Host "[SM+ TB] fonts: label=$labelSz value=$valueSz small=$smallSz bold=$boldSz iters=$iter widths=$($widths -join ',')"

        foreach ($item in $cfg.items) {
          $out = [string]$item.out
          $client = [string]$item.client
          $tavola = [string]$item.tavola
          $sceneName = [string]$item.scene_name

          $bmp = [System.Drawing.Bitmap]::new([int]$W, [int]$H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
          $g = [System.Drawing.Graphics]::FromImage($bmp)
          $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
          $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
          $g.FillRectangle($whiteBrush, 0, 0, $W, $H)
          $halfH = [int]($H / 2)

          # Bordi esterni + divisori verticali
          $g.DrawRectangle($borderPen, 0, 0, $W - 1, $H - 1)
          $xAccum = 0
          for ($i=0; $i -lt $widths.Length - 1; $i++) {
            $xAccum += $widths[$i]
            # Il divisore tra box 0 (CLIENTE) e box 1b (FASE) è parziale:
            # solo riga superiore — la riga OGGETTO non è divisa.
            if ($i -eq 0) {
              $g.DrawLine($borderPen, $xAccum, 0, $xAccum, $halfH)
            } else {
              $g.DrawLine($borderPen, $xAccum, 0, $xAccum, $H)
            }
          }

          # Helper: ascent in pixel di un Font (offset dal top alla baseline).
          # Per allineare i baseline di font con size diverse: y_top_text =
          # baseline_y - ascent.
          function Get-Asc($font) {
            $fam = $font.FontFamily
            $style = $font.Style
            return [single]($fam.GetCellAscent($style) / $fam.GetEmHeight($style) * $font.Size)
          }
          function Get-Dsc($font) {
            $fam = $font.FontFamily
            $style = $font.Style
            return [single]($fam.GetCellDescent($style) / $fam.GetEmHeight($style) * $font.Size)
          }

          # Disegna "label{gap}value" con baseline allineato e start X esplicito.
          function Draw-LV-At($g, [string]$label, [string]$value, $labelFont, $valueFont, $brush, [int]$startX, [int]$y0, [int]$y1) {
            $lblW = $g.MeasureString($label, $labelFont).Width
            $lblAsc = Get-Asc $labelFont; $lblDsc = Get-Dsc $labelFont
            $valAsc = Get-Asc $valueFont; $valDsc = Get-Dsc $valueFont
            $maxAsc = [Math]::Max($lblAsc, $valAsc)
            $maxDsc = [Math]::Max($lblDsc, $valDsc)
            $rowH   = $maxAsc + $maxDsc
            $baselineY = [single]($y0 + (($y1 - $y0) - $rowH) / 2.0 + $maxAsc)
            $lblTop = [single]($baselineY - $lblAsc)
            $valTop = [single]($baselineY - $valAsc)
            $g.DrawString($label, $labelFont, $brush, [single]$startX, $lblTop)
            $g.DrawString($value, $valueFont, $brush, [single]($startX + $lblW + 8), $valTop)
          }

          # Disegna un singolo testo a partire da una start X esplicita,
          # baseline centrato verticalmente in [y0, y1].
          function Draw-At($g, [string]$text, $font, $brush, [int]$startX, [int]$y0, [int]$y1) {
            $asc = Get-Asc $font; $dsc = Get-Dsc $font
            $rowH = $asc + $dsc
            $baselineY = [single]($y0 + (($y1 - $y0) - $rowH) / 2.0 + $asc)
            $top = [single]($baselineY - $asc)
            $g.DrawString($text, $font, $brush, [single]$startX, $top)
          }

          # Pre-calcolo metriche font (uguali per tutti i box con label+value).
          $lblAsc = Get-Asc $labelFont; $lblDsc = Get-Dsc $labelFont
          $valAsc = Get-Asc $valueFont; $valDsc = Get-Dsc $valueFont
          $mAscR = [Math]::Max($lblAsc, $valAsc)
          $mDscR = [Math]::Max($lblDsc, $valDsc)
          $rowH  = $mAscR + $mDscR
          $bY_top = [single](0 + (($halfH - 0) - $rowH) / 2.0 + $mAscR)
          $bY_bot = [single]($halfH + (($H - $halfH) - $rowH) / 2.0 + $mAscR)

          # ---------- Box 0+1b: Cliente (top) / Oggetto merged (bottom) ----------
          $x = 0
          # Divisore orizzontale esteso a coprire anche il box FASE.
          $g.DrawLine($linePen, $x, $halfH, $x + $widths[0] + $widths[1], $halfH)
          # CLIENTE: solo nella metà sinistra (box 0).
          $rowMaxW = [single]($widths[0] - 2 * $pad)

          $lblCli = "CLIENTE:"
          $lblCliW = $g.MeasureString($lblCli, $labelFont).Width
          $valMaxW1 = [single]($rowMaxW - $lblCliW - 8)
          $fClient = Fit-Fnt $g $client $fontFamily $valueSz ([System.Drawing.FontStyle]::Regular) $valMaxW1 9.0

          $lblOgg = "OGGETTO:"
          $lblOggW = $g.MeasureString($lblOgg, $labelFont).Width
          # OGGETTO: occupa la larghezza unificata box 0 + box 1b.
          $rowMaxW_ogg = [single]($widths[0] + $widths[1] - 2 * $pad)
          $valMaxW2 = [single]($rowMaxW_ogg - $lblOggW - 8)
          # Se il nome scena non entra su una riga: comprime e va a capo (max 2 righe).
          $oggFit = Fit-Object $g $sceneName $fontFamily $valueSz ([System.Drawing.FontStyle]::Regular) $valMaxW2 9.0
          $fScene = $oggFit.Font
          $oggLines = @($oggFit.Lines)

          # Label CLIENTE: e valore (riga superiore del box 0).
          $vAsc1 = Get-Asc $fClient
          $g.DrawString($lblCli, $labelFont, $brush, [single]($x + $pad),               [single]($bY_top - $lblAsc))
          $g.DrawString($client, $fClient,   $brush, [single]($x + $pad + $lblCliW + 8), [single]($bY_top - $vAsc1))

          # Label OGGETTO: + valore (riga inferiore). Una o due righe.
          $vAsc2 = Get-Asc $fScene
          $vDsc2 = Get-Dsc $fScene
          $oggValX = [single]($x + $pad + $lblOggW + 8)
          if ($oggLines.Count -le 1) {
            # Una riga: baseline centrata $bY_bot (come prima).
            $g.DrawString($lblOgg, $labelFont, $brush, [single]($x + $pad), [single]($bY_bot - $lblAsc))
            $g.DrawString([string]$oggLines[0], $fScene, $brush, $oggValX, [single]($bY_bot - $vAsc2))
          } else {
            # Due righe: blocco centrato verticalmente nella riga inferiore [halfH, H].
            $oggLineH  = [single]($vAsc2 + $vDsc2)
            $oggBlockH = [single]($oggLineH * 2)
            $oggTopY   = [single]($halfH + (($H - $halfH) - $oggBlockH) / 2.0)
            $base1 = [single]($oggTopY + $vAsc2)
            $base2 = [single]($base1 + $oggLineH)
            # Label OGGETTO: allineata alla prima riga del valore.
            $g.DrawString($lblOgg, $labelFont, $brush, [single]($x + $pad), [single]($base1 - $lblAsc))
            $g.DrawString([string]$oggLines[0], $fScene, $brush, $oggValX, [single]($base1 - $vAsc2))
            $g.DrawString([string]$oggLines[1], $fScene, $brush, $oggValX, [single]($base2 - $vAsc2))
          }

          $fClient.Dispose(); $fScene.Dispose()
          $x += $widths[0]

          # Metriche per i MID font (box 1b, 2 e 3). Le baseline $bY_top/$bY_bot
          # restano quelle calcolate sul font grande (box 1) per allineamento
          # cross-box; ogni testo si posiziona a $bY - propria_ascent.
          $mLblAsc = Get-Asc $midLabelFont
          $mValAsc = Get-Asc $midValueFont

          # ---------- Box 1b: Fase di progetto (MID font, solo riga superiore) ----------
          # Centrata nel range [0, halfH] — la riga inferiore è unificata con OGGETTO.
          $wFr = (Measure-LV $g "PROGETTO:" $phaseValue $midLabelFont $midValueFont)
          $startXf = $x + [int](($widths[1] - $wFr) / 2)
          Draw-LV-At $g "PROGETTO:" $phaseValue $midLabelFont $midValueFont $brush $startXf 0 $halfH
          $x += $widths[1]

          # ---------- Box 2: Tavola / Data (MID font) ----------
          $g.DrawLine($linePen, $x, $halfH, $x + $widths[2], $halfH)
          $r2aW = (Measure-LV $g "TAVOLA nr.:" $tavola $midLabelFont $midValueFont)
          $r2bW = (Measure-LV $g "DATA:"       $date   $midLabelFont $midValueFont)
          $block2W = [Math]::Max($r2aW, $r2bW)
          $startX2 = $x + [int](($widths[2] - $block2W) / 2)
          $lblTavW = $g.MeasureString("TAVOLA nr.:", $midLabelFont).Width
          $lblDtW  = $g.MeasureString("DATA:",       $midLabelFont).Width
          $g.DrawString("TAVOLA nr.:", $midLabelFont, $brush, [single]$startX2, [single]($bY_top - $mLblAsc))
          $g.DrawString($tavola,       $midValueFont, $brush, [single]($startX2 + $lblTavW + 8), [single]($bY_top - $mValAsc))
          $g.DrawString("DATA:",       $midLabelFont, $brush, [single]$startX2, [single]($bY_bot - $mLblAsc))
          $g.DrawString($date,         $midValueFont, $brush, [single]($startX2 + $lblDtW  + 8), [single]($bY_bot - $mValAsc))
          $x += $widths[2]

          # ---------- Box 3: Progetto / Disegnato (MID font) ----------
          $g.DrawLine($linePen, $x, $halfH, $x + $widths[3], $halfH)
          $r3aW = (Measure-LV $g "PROGETTO:"      $projectBy $midLabelFont $midValueFont)
          $r3bW = (Measure-LV $g "CONTROLLATO DA:" $designer $midLabelFont $midValueFont)
          $block3W = [Math]::Max($r3aW, $r3bW)
          $startX3 = $x + [int](($widths[3] - $block3W) / 2)
          $lblPjW = $g.MeasureString("PROGETTO:",      $midLabelFont).Width
          $lblDsW = $g.MeasureString("CONTROLLATO DA:", $midLabelFont).Width
          $g.DrawString("PROGETTO:",      $midLabelFont, $brush, [single]$startX3, [single]($bY_top - $mLblAsc))
          $g.DrawString($projectBy,       $midValueFont, $brush, [single]($startX3 + $lblPjW + 8), [single]($bY_top - $mValAsc))
          $g.DrawString("CONTROLLATO DA:", $midLabelFont, $brush, [single]$startX3, [single]($bY_bot - $mLblAsc))
          if (-not [string]::IsNullOrEmpty($designer)) {
            $g.DrawString($designer, $midValueFont, $brush, [single]($startX3 + $lblDsW + 8), [single]($bY_bot - $mValAsc))
          }
          $x += $widths[3]

          # ---------- Box 4: Dati aziendali ----------
          # Blocco di N righe centrate verticalmente come unità, tutte
          # left-aligned alla stessa X. Interlinea molto stretta: usa
          # ascent + small_gap (no descent intero) così le righe sono vicine.
          $boldAsc = Get-Asc $boldFont
          $smallAsc = Get-Asc $smallFont
          # Interlinea compatta: ~95% del font size del small.
          $lineHeight = [single]($smallSz * 1.0)
          # Altezza totale: somma ascent prima riga + (N-1)*lineHeight + descent ultima
          $smallDsc = Get-Dsc $smallFont
          $blockH = [single]($boldAsc + ($companyLines.Count - 1) * $lineHeight + $smallDsc)
          $yTop4  = [single](($H - $blockH) / 2.0)

          $maxRowW4 = 0.0
          for ($k=0; $k -lt $companyLines.Count; $k++) {
            if ($k -eq 0) { $f = $boldFont } else { $f = $smallFont }
            $rw = $g.MeasureString([string]$companyLines[$k], $f).Width
            if ($rw -gt $maxRowW4) { $maxRowW4 = $rw }
          }
          $startX4 = $x + [int](($widths[4] - $maxRowW4) / 2)
          # Baseline prima riga: yTop4 + boldAsc.
          # Righe successive: precedente baseline + lineHeight.
          $baseY4 = [single]($yTop4 + $boldAsc)
          for ($k=0; $k -lt $companyLines.Count; $k++) {
            if ($k -eq 0) { $f = $boldFont; $asc = $boldAsc } else { $f = $smallFont; $asc = $smallAsc }
            $top = [single]($baseY4 - $asc)
            $g.DrawString([string]$companyLines[$k], $f, $brush, [single]$startX4, $top)
            $baseY4 = [single]($baseY4 + $lineHeight)
          }
          $x += $widths[4]

          # ---------- Box 5: Logo ----------
          if ($logoImg) {
            $boxW = $widths[5]
            $margin = [int]([Math]::Max(4, $H * 0.10))
            $availW = $boxW - 2 * $margin
            $availH = $H - 2 * $margin
            if ($availW -gt 0 -and $availH -gt 0) {
              $rw = $availW / $logoImg.Width
              $rh = $availH / $logoImg.Height
              $r = [Math]::Min($rw, $rh)
              $lw = [int]($logoImg.Width * $r)
              $lh = [int]($logoImg.Height * $r)
              $lx = $x + [int](($boxW - $lw) / 2)
              $ly = [int](($H - $lh) / 2)
              $g.DrawImage($logoImg, $lx, $ly, $lw, $lh)
            }
          }

          $g.Dispose()
          $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
          $bmp.Dispose()
        }

        $measureG.Dispose()
        $measureBmp.Dispose()
        $labelFont.Dispose()
        $valueFont.Dispose()
        $smallFont.Dispose()
        $boldFont.Dispose()
        $midLabelFont.Dispose()
        $midValueFont.Dispose()
        $brush.Dispose()
        $whiteBrush.Dispose()
        $borderPen.Dispose()
        $linePen.Dispose()
        if ($logoImg) { $logoImg.Dispose() }
      PS

      # items: array di hash { uid:, client:, tavola: }
      # cfg:   { width:, height:, font_family:, date:, project_by:,
      #          designer:, company_lines:[..], logo_path: }
      #
      # Ritorna { uid => png_path, '_tmpdir' => dir }. Chiamare cleanup quando finito.
      def render_batch(items, cfg)
        return { '_tmpdir' => nil } if items.empty?

        tmpdir = File.join(Dir.tmpdir, "sm_titleblock_#{Process.pid}_#{Time.now.to_i}_#{rand(10_000)}")
        FileUtils.mkdir_p(tmpdir)

        payload_items = items.each_with_index.map do |it, i|
          {
            'client'     => it[:client].to_s,
            'tavola'     => it[:tavola].to_s,
            'scene_name' => it[:scene_name].to_s,
            'out'        => File.join(tmpdir, "#{i}.png")
          }
        end
        # Placeholder per misurare la larghezza del box Tavola/Data: il
        # numero tavola cambia per scena ma è padded, quindi prendiamo il
        # massimo possibile = pad cifre, tutte '0'. Se non passato, default "00".
        placeholder = (cfg[:tavola_placeholder] || '00').to_s
        # Nome scena più lungo nel batch → dimensiona il box Cliente.
        scene_longest = items.map { |it| it[:scene_name].to_s }.max_by(&:length) || ''
        # Client = costante per tutto il batch (= prefix_custom).
        client_const = items.first ? items.first[:client].to_s : ''

        payload = {
          'width'              => cfg[:width].to_i,
          'height'             => cfg[:height].to_i,
          'font_family'        => cfg[:font_family].to_s,
          'date'               => cfg[:date].to_s,
          'project_by'         => cfg[:project_by].to_s,
          'designer'           => cfg[:designer].to_s,
          'project_phase'      => cfg[:project_phase].to_s,
          'company_lines'      => Array(cfg[:company_lines]).map(&:to_s),
          'logo_path'          => cfg[:logo_path].to_s,
          'tavola_placeholder' => placeholder,
          'client'             => client_const,
          'scene_longest'      => scene_longest,
          'items'              => payload_items
        }

        cfg_path    = File.join(tmpdir, 'cfg.json')
        script_path = File.join(tmpdir, 'render.ps1')
        File.binwrite(cfg_path,    payload.to_json)
        File.binwrite(script_path, PS_SCRIPT)

        cmd = %(powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "#{script_path}" "#{cfg_path}")
        ok = run_hidden(cmd)
        warn '[SM+] TitleBlock: PowerShell render returned non-zero' unless ok

        result = { '_tmpdir' => tmpdir }
        items.each_with_index do |it, i|
          png = File.join(tmpdir, "#{i}.png")
          result[it[:uid]] = png if File.file?(png)
        end
        produced = result.size - 1
        puts "[SM+] TitleBlock.render_batch: requested=#{items.size} produced=#{produced} tmpdir=#{tmpdir}"
        result
      end

      def cleanup(result)
        tmpdir = result && result['_tmpdir']
        return unless tmpdir && File.directory?(tmpdir)
        FileUtils.rm_rf(tmpdir)
      rescue => e
        warn "[SM+] TitleBlock.cleanup: #{e.class}: #{e.message}"
      end

      # Lancia il comando senza far apparire la console (stesso pattern di TextRender).
      def run_hidden(cmd)
        require 'win32ole'
        shell = WIN32OLE.new('WScript.Shell')
        rc = shell.Run(cmd, 0, true)
        rc.to_i == 0
      rescue LoadError, WIN32OLERuntimeError => e
        warn "[SM+] TitleBlock: Win32OLE non disponibile (#{e.message}), fallback system()"
        system(cmd)
      rescue => e
        warn "[SM+] TitleBlock.run_hidden: #{e.class}: #{e.message}"
        false
      end

      # Helper: legge le righe del file Dati Aziendali bundlato.
      def load_company_lines
        path = Settings.titleblock_company_txt_path
        return [] unless File.file?(path)
        File.read(path, encoding: 'UTF-8').split(/\r?\n/).map(&:strip).reject(&:empty?)
      rescue => e
        warn "[SM+] TitleBlock.load_company_lines: #{e.class}: #{e.message}"
        []
      end
    end
  end
end
