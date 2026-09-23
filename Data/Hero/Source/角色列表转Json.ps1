# 角色列表.xlsx -> 角色列表.json（供 Godot 运行时读取）
# Godot(此构建)无 ZipReader/Compression,无法直接解 xlsx,故在本机把数据转成 JSON 副产物。
# 路径（2026-09-22 晚 目录重构后）：xlsx 在 Data\Hero\，json 产物放到同级的 Source\（游戏读的就是它）。
param(
  [string]$Src = "",
  [string]$Out = ""
)
# 默认路径一律按「本脚本所在目录」推导（2026-09-22 深夜：不再写死 D:\Game creating\战旗\…）
#   本脚本在 Data\Hero\Source\ ⇒ xlsx 在上一级、json 产物放本目录（游戏读的就是它）
if ([string]::IsNullOrWhiteSpace($Src)) { $Src = Join-Path (Split-Path -Parent $PSScriptRoot) '角色列表.xlsx' }
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $PSScriptRoot '角色列表.json' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
# Excel 打开时会持有写锁,ZipFile.OpenRead(仅共享读)会失败;
# 改用"共享读写"打开源文件->复制到临时文件->再解包临时文件,即可在 Excel 打开时转换。
$tmp = [System.IO.Path]::GetTempFileName() + '.xlsx'
$fsrc = [System.IO.File]::Open($Src, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
$fdst = [System.IO.File]::Create($tmp)
$fsrc.CopyTo($fdst)
$fdst.Close(); $fsrc.Close()
$zip = [System.IO.Compression.ZipFile]::OpenRead($tmp)
function Read-Entry([string]$name) {
  $e = $zip.GetEntry($name)
  if (-not $e) { return $null }
  $sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
  $t = $sr.ReadToEnd(); $sr.Close(); return $t
}
$sharedXml = Read-Entry 'xl/sharedStrings.xml'
$sheetXml  = Read-Entry 'xl/worksheets/sheet1.xml'
$zip.Dispose()
Remove-Item $tmp -ErrorAction SilentlyContinue

$shared = @()
if ($sharedXml) {
  $xd = [xml]$sharedXml
  foreach ($si in $xd.SelectNodes("//*[local-name()='si']")) {
    $txt = ''
    foreach ($t in $si.SelectNodes(".//*[local-name()='t']")) { $txt += [string]$t.InnerText }
    $shared += $txt
  }
}

$rows = @()
if ($sheetXml) {
  $xd = [xml]$sheetXml
  foreach ($row in $xd.SelectNodes("//*[local-name()='row']")) {
    $cells = @()
    foreach ($c in $row.SelectNodes(".//*[local-name()='c']")) {
      $ref  = [string]$c.GetAttribute('r')
      $type = [string]$c.GetAttribute('t')
      $colIdx = 0
      if ($ref) {
        $letters = ''
        foreach ($ch in $ref.ToCharArray()) {
          if ($ch -ge 'A' -and $ch -le 'Z') { $letters += $ch } else { break }
        }
        $colIdx = 0
        foreach ($ch in $letters.ToCharArray()) { $colIdx = $colIdx * 26 + ([int][char]$ch - 64) }
        $colIdx -= 1
      } else {
        $colIdx = $cells.Count
      }
      if ($colIdx -lt 0) { $colIdx = $cells.Count }
      while ($cells.Count -lt $colIdx) { $cells += '' }
      $val = ''
      if ($type -eq 's') {
        $v = $c.SelectSingleNode(".//*[local-name()='v']")
        if ($v) { $val = [string]$shared[[int]$v.InnerText] }
      } elseif ($type -eq 'inlineStr') {
        foreach ($t in $c.SelectNodes(".//*[local-name()='t']")) { $val += [string]$t.InnerText }
      } else {
        $v = $c.SelectSingleNode(".//*[local-name()='v']")
        if ($v) { $val = [string]$v.InnerText }
      }
      if ($cells.Count -eq $colIdx) { $cells += $val } else { $cells[$colIdx] = $val }
    }
    $rows += ,([object[]]$cells)
  }
}
$json = ConvertTo-Json -InputObject $rows -Depth 8
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("rows=" + $rows.Count + "  out=" + $Out)
