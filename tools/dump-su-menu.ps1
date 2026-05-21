# Enumera il menu di SketchUp e stampa testo + command ID di ogni voce.
# Uso: aprire SU 2019, poi `powershell -ExecutionPolicy Bypass -File dump-su-menu.ps1`.
# Cerca nell'output la riga contenente "Scene Tabs" per leggere l'ID.

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
  [DllImport("user32.dll")] public static extern uint GetMenuItemID(IntPtr hMenu, int nPos);
  [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr hMenu, int nPos);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetMenuString(IntPtr hMenu, uint uIDItem, StringBuilder lpString, int cchMax, uint flags);
  public const uint MF_BYPOSITION = 0x400;
}
'@

$global:found = $null

function Walk-Menu([IntPtr]$hMenu, [string]$path) {
  if ($hMenu -eq [IntPtr]::Zero) { return }
  $count = [W]::GetMenuItemCount($hMenu)
  for ($i = 0; $i -lt $count; $i++) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][W]::GetMenuString($hMenu, $i, $sb, 512, [W]::MF_BYPOSITION)
    $label = $sb.ToString().Replace("`t"," / ")
    $sub   = [W]::GetSubMenu($hMenu, $i)
    if ($sub -ne [IntPtr]::Zero) {
      Walk-Menu $sub "$path > $label"
    } else {
      $id = [W]::GetMenuItemID($hMenu, $i)
      if ($id -ne 0 -and $id -ne [uint32]"0xFFFFFFFF") {
        Write-Host ("ID={0,-8} {1} > {2}" -f $id, $path, $label)
      }
    }
  }
}

[W]::EnumWindows({
  param($hWnd, $lParam)
  if (-not [W]::IsWindowVisible($hWnd)) { return $true }
  $len = [W]::GetWindowTextLength($hWnd)
  if ($len -eq 0) { return $true }
  $sb = New-Object System.Text.StringBuilder ($len + 1)
  [void][W]::GetWindowText($hWnd, $sb, $sb.Capacity)
  $t = $sb.ToString()
  if ($t -match 'SketchUp' -and $t -notmatch 'Ruby Console') {
    $menu = [W]::GetMenu($hWnd)
    if ($menu -ne [IntPtr]::Zero) {
      Write-Host "=== Window: $t ==="
      Walk-Menu $menu ""
      $global:found = $t
    }
  }
  return $true
}, [IntPtr]::Zero) | Out-Null

if (-not $global:found) { Write-Host "Nessuna finestra SketchUp con menu trovata. Assicurati che SU sia aperto e in primo piano." }
