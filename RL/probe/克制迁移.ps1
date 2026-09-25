# 【2026-09-24 一次性迁移脚本·用户要求】把「克制」/「被克制」两列从"自由文本（语义/数值词）"
# 换成**和「语义伙伴」同一套的加权人工名单**（`名字×N`，不写 = 2.0）。
#   做法：用引擎当前解析结果（`RL/probe/克制对自检.gd` 的输出）把 8 个有内容的格子改写成显示名名单。
#   改完必须逐对分值与改前完全相同（基线 `RL/probe/_kb_before.txt`）。
# 用法：powershell -File RL\probe\克制迁移.ps1 -Probe RL\probe\_kb_after0.txt          # 只算方案
#       powershell -File RL\probe\克制迁移.ps1 -Probe RL\probe\_kb_after0.txt -Apply  # 写 xlsx（Excel 须已关闭）
param(
  [string]$Probe = 'RL\probe\_kb_after0.txt',
  [string]$Json  = 'Data\Hero\Source\角色列表.json',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\probe -> 项目根
$xlsx = Join-Path $root 'Data\Hero\角色列表.xlsx'

# 1) 行号：名称 -> Excel 行
$rows = Get-Content (Join-Path $root $Json) -Raw -Encoding UTF8 | ConvertFrom-Json
$ci = @{}
for ($i = 0; $i -lt $rows[0].Count; $i++) { $ci[[string]$rows[0][$i]] = $i }
$rowOf = @{}
for ($r = 1; $r -lt $rows.Count; $r++) {
  $nm = [string]$rows[$r][$ci['名称']]
  if (-not [string]::IsNullOrWhiteSpace($nm)) { $rowOf[$nm] = $r + 1 }
}

# 2) 解析探针输出：每行形如
#    PROBE|毒蛇淑女(hero_03)|克制原文=「圣光」→圣光|被克制原文=「能麻痹的英雄」→战锤
$plan = @()
foreach ($line in (Get-Content (Join-Path $root $Probe) -Encoding UTF8)) {
  if ($line -notmatch '^PROBE\|[^|]+\(hero_') { continue }
  $parts = $line -split '\|'
  $nm = ($parts[1] -split '\(')[0]
  if (-not $rowOf.ContainsKey($nm)) { Write-Output ("⚠️ 探针里的英雄在表里找不到：" + $nm); continue }
  $eff = if ($parts[2] -match '→(.*)$') { $Matches[1] } else { '—' }
  $cnt = if ($parts[3] -match '→(.*)$') { $Matches[1] } else { '—' }
  $plan += [pscustomobject]@{
    行 = $rowOf[$nm]; 名称 = $nm
    克制格 = ('I' + $rowOf[$nm]); 新克制 = $(if ($eff -eq '—') { '' } else { $eff })
    被克制格 = ('J' + $rowOf[$nm]); 新被克制 = $(if ($cnt -eq '—') { '' } else { $cnt })
  }
}
$plan | Sort-Object 行 | Format-Table -AutoSize | Out-String -Width 300 | Write-Output
$nonEmpty = @($plan | Where-Object { $_.新克制 -ne '' -or $_.新被克制 -ne '' })
Write-Output ("要写的格子：克制 " + @($nonEmpty | Where-Object { $_.新克制 -ne '' }).Count + " 个 · 被克制 " + @($nonEmpty | Where-Object { $_.新被克制 -ne '' }).Count + " 个")

$locked = $false
try { $fs = [System.IO.File]::Open($xlsx, 'Open', 'ReadWrite', 'None'); $fs.Close() } catch { $locked = $true }
if (-not $Apply) { Write-Output '（只算方案、未落盘；加 -Apply 才写 xlsx）'; return }
if ($locked) { Write-Output '⚠️ xlsx 被 Excel 占用，未落盘：请先在 Excel 里关闭 角色列表.xlsx，再重跑加 -Apply。'; exit 1 }

# 3) 落盘：改 sheet1.xml 的 I/J 两列（写成 inlineStr；空 = 自闭合空单元格）
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Esc-Xml([string]$t) { return $t.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
$tmp = [System.IO.Path]::GetTempFileName() + '.xlsx'
$fsrc = [System.IO.File]::Open($xlsx, 'Open', 'Read', [System.IO.FileShare]::ReadWrite)
$fdst = [System.IO.File]::Create($tmp)
$fsrc.CopyTo($fdst); $fdst.Close(); $fsrc.Close()

$zip = [System.IO.Compression.ZipFile]::Open($tmp, 'Update')
$ent = $zip.GetEntry('xl/worksheets/sheet1.xml')
$sr = New-Object System.IO.StreamReader($ent.Open(), [System.Text.Encoding]::UTF8)
$xml = $sr.ReadToEnd(); $sr.Close(); $zip.Dispose()

$hit = 0
foreach ($p in $nonEmpty) {
  foreach ($pair in @(@($p.克制格, $p.新克制), @($p.被克制格, $p.新被克制))) {
    $ref = $pair[0]; $val = $pair[1]
    if ($null -eq $val -or $val -eq '') { continue }
    $pat = '(?s)<c r="' + $ref + '"[^>]*>.*?</c>'
    $rep = '<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' + (Esc-Xml $val) + '</t></is></c>'
    if ([regex]::IsMatch($xml, $pat)) { $xml = [regex]::Replace($xml, $pat, $rep); $hit++ }
    else { Write-Output ('⚠️ 没找到 ' + $ref + ' 单元格（' + $p.名称 + '）') }
  }
}
Write-Output ("改到 $hit 个格子")

$zip = [System.IO.Compression.ZipFile]::Open($tmp, 'Update')
$zip.GetEntry('xl/worksheets/sheet1.xml').Delete()
$ne = $zip.CreateEntry('xl/worksheets/sheet1.xml', [System.IO.Compression.CompressionLevel]::Optimal)
$sw = New-Object System.IO.StreamWriter($ne.Open(), (New-Object System.Text.UTF8Encoding($false)))
$sw.Write($xml); $sw.Close(); $zip.Dispose()

Copy-Item $tmp $xlsx -Force
Remove-Item $tmp -ErrorAction SilentlyContinue
Write-Output ('✅ 已写入 ' + $xlsx + '（克制/被克制 两列改成名单）')
