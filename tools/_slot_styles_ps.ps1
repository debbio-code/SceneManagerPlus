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
