# 【2026-09-24 一次性迁移脚本·用户拍板①】把「协同英雄」点名档（+2.0）并入「语义伙伴」加权写法（`名字×N`），
# 然后把「协同英雄」列清空退役。
#   迁移口径：某对英雄当前 = 1.0(语义：任一方在语义伙伴里写了) + 2.0(点名：任一方在协同英雄里点了)
#             ⇒ 迁成语义伙伴里的 `名字×3`；只有点名、两边都没语义的迁成 `名字×2`。
#   改完必须逐对分值与迁移前**完全相同**（用 RL/probe/配合对自检 对拍 _before.txt）。
# 用法：pwsh -File RL\probe\语义迁移.ps1            # 只算方案、不落盘
#       pwsh -File RL\probe\语义迁移.ps1 -Apply     # 真正写 xlsx（需要 Excel 已关闭该文件）
param([switch]$Apply)
$ErrorActionPreference = 'Stop'

function Split-Tok([string]$t) {
  $out = @()
  $sepCh = [string][char]1
  foreach ($sep in @('、', '，', ',', '；', ';', '|', '／', '/', "`n", "`r", "`t", ' ', '　')) { $t = $t.Replace($sep, $sepCh) }
  foreach ($p in $t.Split($sepCh)) { $q = $p.Trim(); if ($q -ne '') { $out += $q } }
  return , $out
}
function Esc-Xml([string]$t) { return $t.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\probe -> 项目根
$xlsx = Join-Path $root 'Data\Hero\角色列表.xlsx'
$json = Join-Path $root 'Data\Hero\Source\角色列表.json'

$rows = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json
$hdr = $rows[0]
$ci = @{}
for ($i = 0; $i -lt $hdr.Count; $i++) { $ci[[string]$hdr[$i]] = $i }

$semTok = @{}; $kTok = @{}; $rowOf = @{}; $semRaw = @{}
for ($r = 1; $r -lt $rows.Count; $r++) {
  $nm = [string]$rows[$r][$ci['名称']]
  if ([string]::IsNullOrWhiteSpace($nm)) { continue }
  $rowOf[$nm] = $r + 1
  $semRaw[$nm] = [string]$rows[$r][$ci['语义伙伴']]
  $semTok[$nm] = Split-Tok ([string]$rows[$r][$ci['语义伙伴']])
  $kTok[$nm]   = Split-Tok ([string]$rows[$r][$ci['协同英雄']])
}

$plan = @(); $onlyK = @()
foreach ($nm in @($kTok.Keys)) {
  if ($kTok[$nm].Count -eq 0) { continue }
  $newS = @(); $done = @{}
  foreach ($tk in $semTok[$nm]) {
    if ($kTok[$nm] -contains $tk) { $newS += ($tk + '×3') } else { $newS += $tk }
    $done[$tk] = $true
  }
  foreach ($tk in $kTok[$nm]) {
    if ($done.ContainsKey($tk)) { continue }
    $back = $false
    if ($semTok.ContainsKey($tk)) { if ($semTok[$tk] -contains $nm) { $back = $true } }
    if ($back) { $newS += ($tk + '×3') } else { $newS += ($tk + '×2'); $onlyK += ($nm + '→' + $tk) }
  }
  $plan += [pscustomobject]@{ 行 = $rowOf[$nm]; 名称 = $nm; 原点名 = ($kTok[$nm] -join '、'); 新语义 = ($newS -join '、') }
}
$plan | Sort-Object 行 | Format-Table -AutoSize | Out-String -Width 220 | Write-Output
if ($onlyK.Count -gt 0) { Write-Output ('只有点名、两边都无语义的（迁 ×2）：' + ($onlyK -join ' / ')) } else { Write-Output '全部点名对都同时有语义 ⇒ 一律 ×3。' }

$locked = $false
try { $fs = [System.IO.File]::Open($xlsx, 'Open', 'ReadWrite', 'None'); $fs.Close() } catch { $locked = $true }
if (-not $Apply) { Write-Output '（只算方案、未落盘；加 -Apply 才写 xlsx）'; return }
if ($locked) { Write-Output '⚠️ xlsx 被 Excel 占用，未落盘：请先在 Excel 里关闭 角色列表.xlsx，再重跑加 -Apply。'; exit 1 }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$tmp = [System.IO.Path]::GetTempFileName() + '.xlsx'
$fsrc = [System.IO.File]::Open($xlsx, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
$fdst = [System.IO.File]::Create($tmp)
$fsrc.CopyTo($fdst); $fdst.Close(); $fsrc.Close()

$zip = [System.IO.Compression.ZipFile]::Open($tmp, 'Update')
$e = $zip.GetEntry('xl/worksheets/sheet1.xml')
$sr = New-Object System.IO.StreamReader($e.Open(), [System.Text.Encoding]::UTF8)
$xml = $sr.ReadToEnd(); $sr.Close(); $zip.Dispose()

$hitS = 0; $hitK = 0
foreach ($p in $plan) {
  $r = $p.行
  $patS = '(?s)<c r="S' + $r + '"[^>]*>.*?</c>'
  $repS = '<c r="S' + $r + '" t="inlineStr"><is><t xml:space="preserve">' + (Esc-Xml $p.新语义) + '</t></is></c>'
  if ([regex]::IsMatch($xml, $patS)) { $xml = [regex]::Replace($xml, $patS, $repS); $hitS++ }
  else { Write-Output ('⚠️ 没找到 S' + $r + ' 单元格（' + $p.名称 + '）') }
  $patK = '(?s)<c r="K' + $r + '"[^>]*>.*?</c>'
  if ([regex]::IsMatch($xml, $patK)) { $xml = [regex]::Replace($xml, $patK, ''); $hitK++ }
  else { Write-Output ('⚠️ 没找到 K' + $r + ' 单元格（' + $p.名称 + '）') }
}
Write-Output ("改到 S 格 $hitS 个 / 清掉 K 格 $hitK 个")

$zip = [System.IO.Compression.ZipFile]::Open($tmp, 'Update')
$zip.GetEntry('xl/worksheets/sheet1.xml').Delete()
$ne = $zip.CreateEntry('xl/worksheets/sheet1.xml', [System.IO.Compression.CompressionLevel]::Optimal)
$sw = New-Object System.IO.StreamWriter($ne.Open(), (New-Object System.Text.UTF8Encoding($false)))
$sw.Write($xml); $sw.Close(); $zip.Dispose()

Copy-Item $tmp $xlsx -Force
Remove-Item $tmp -ErrorAction SilentlyContinue
Write-Output ('✅ 已写入 ' + $xlsx + '（S 列加权、协同英雄列清空）')
