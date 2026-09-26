# 单位账本.ps1 —— 【2026-09-25 新增】把 harness 打的 `R|u|` 行解析成一张表，并出"哪几列最能预测胜负"。
#
# 数据来源：`RL/harness/对局.gd` 的**每单位账本**（每局每单位一行 `R|u|...`，落在各格子的
#   `raw_lines.log` / `w1\*.out` 里）。见 `RL/reports/英雄平衡_初筛_pool3_20260925.md` 的"下一步 · 第 2 步"。
#
# 口径（重要）：
#   · `dealt/taken` 读引擎的 `Unit.damaged(受击者, 实际伤害)` 信号 ⇒ **圣盾/坚固/塔盾代扛之后**的值，
#     与 `measure.csv` 的 `dmgA/dmgB`（那是"血池净变化"，会被回血与溢出污染）不是一回事。
#   · 归因规则 = 一招之内只有发起者与目标两人：落在目标身上记给发起者，落在发起者身上记给目标（反击）；
#     毒/烧血/炸弹没有发起者 ⇒ 只记进 `taken`。
#   · `win` / `pts` 是该单位**所在阵营**的胜负与优势分（由 `measure.csv` 的 `a_side` 换算）。
#
# 用法：
#   & RL\train\单位账本.ps1 -Tags pool4,swap1
#   & RL\train\单位账本.ps1 -Tags pool4 -OutCsv RL\reports\stats\单位账本_pool4.csv
#
# 输出：
#   ① `RL\reports\stats\单位账本_<tag串>.csv` —— 每行 = 一局一个单位
#   ② `RL\reports\单位账本_口径初筛_<tag串>.md` —— 覆盖度 + 各列与胜负/优势分的相关 + 英雄级汇总
[CmdletBinding()]
param(
    [string[]]$Tags = @('pool4', 'swap1'),
    [string]$OutCsv = '',
    [string]$OutMd = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$results = Join-Path $PSScriptRoot 'results'
$tagLabel = ($Tags -join '+')
if (-not $OutCsv) { $OutCsv = Join-Path $root ("RL\reports\stats\单位账本_{0}.csv" -f $tagLabel) }
if (-not $OutMd) { $OutMd = Join-Path $root ("RL\reports\单位账本_口径初筛_{0}.md" -f $tagLabel) }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutCsv) | Out-Null

function To-FirstCode([string]$s) { if ($s -eq '0') { 'P' } elseif ($s -eq '1') { 'E' } else { $s } }

$rows = New-Object System.Collections.ArrayList
$cellsWith = 0
$cellsWithout = 0
foreach ($tg in $Tags) {
    foreach ($d in @(Get-ChildItem $results -Directory -Filter ($tg + '_*') -ErrorAction SilentlyContinue)) {
        # 先把这一格的局级账读进来（按 seed|a_side|first 建索引）
        $meta = @{}
        $csv = Join-Path $d.FullName 'measure.csv'
        if (Test-Path $csv) {
            foreach ($r in (Import-Csv $csv)) {
                $meta[('{0}|{1}|{2}' -f $r.seed, $r.a_side, $r.first)] = $r
            }
        }
        $lines = @()
        foreach ($f in @(Get-ChildItem $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.out' -or $_.Name -eq 'raw_lines.log' })) {
            $lines += @(Select-String -Path $f.FullName -Pattern '^R\|u\|' -Encoding UTF8 -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Line })
        }
        if ($lines.Count -eq 0) { $cellsWithout++; continue }
        $cellsWith++
        foreach ($ln in $lines) {
            $kv = @{}
            foreach ($seg in ($ln -split '\|')) {
                $i = $seg.IndexOf('=')
                if ($i -gt 0) { $kv[$seg.Substring(0, $i)] = $seg.Substring($i + 1) }
            }
            if (-not $kv.ContainsKey('hero')) { continue }
            $aSide = [int]$kv['a_side']
            $firstCode = To-FirstCode $kv['first']
            $m = $meta[('{0}|{1}|{2}' -f $kv['seed'], $aSide, $firstCode)]
            $isA = (($kv['fn'] -eq 'E' -and $aSide -eq 1) -or ($kv['fn'] -eq 'P' -and $aSide -eq 0))
            $win = ''
            $pts = ''
            $res = ''
            if ($m) {
                $res = [string]$m.res
                if ($isA) { $win = ($res -eq 'W'); $pts = [double]$m.ptsA }
                else { $win = ($res -eq 'L'); $pts = [double]$m.ptsB }
            }
            [void]$rows.Add([pscustomobject]@{
                run = $d.Name; tag = $tg; seed = $kv['seed']; a_side = $aSide; first = $firstCode
                res = $res; side_is_A = $isA; win = $win; pts = $pts
                fn = $kv['fn']; hero = $kv['hero']
                hp0 = [int]$kv['hp0']; max = [int]$kv['max']; hp_end = [int]$kv['hp_end']
                alive = [int]$kv['alive']; rounds = [int]$kv['rounds']; death_round = [int]$kv['death_round']
                dealt = [int]$kv['dealt']; taken = [int]$kv['taken']; kills = [int]$kv['kills']
                attacks = [int]$kv['attacks']; moves = [int]$kv['moves']; obs = [int]$kv['obs']
            })
        }
    }
}
Write-Host ("[账本] 有 R|u| 的格子 {0} 个 · 没有的 {1} 个 · 单位行 {2} 行" -f $cellsWith, $cellsWithout, $rows.Count)
if ($rows.Count -eq 0) { Write-Host '[账本] 没有可汇总的数据'; exit 0 }
$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
Write-Host ("[账本] 已写 {0}" -f $OutCsv)

# ---------- 与胜负/优势分的相关（点二列相关 = 皮尔逊） ----------
function Get-Corr($xs, $ys) {
    $n = $xs.Count
    if ($n -lt 3) { return [double]::NaN }
    $mx = ($xs | Measure-Object -Average).Average
    $my = ($ys | Measure-Object -Average).Average
    $sxy = 0.0; $sxx = 0.0; $syy = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $dx = $xs[$i] - $mx; $dy = $ys[$i] - $my
        $sxy += $dx * $dy; $sxx += $dx * $dx; $syy += $dy * $dy
    }
    if ($sxx -le 0 -or $syy -le 0) { return [double]::NaN }
    return $sxy / [math]::Sqrt($sxx * $syy)
}
$valid = @($rows | Where-Object { $_.res -ne '' })
$wins = @($valid | ForEach-Object { if ($_.win) { 1.0 } else { 0.0 } })
$ptsArr = @($valid | ForEach-Object { [double]$_.pts })
$metrics = @(
    @{ k = 'dealt';   cn = '打出伤害' }, @{ k = 'taken'; cn = '吃伤' },
    @{ k = 'rounds';  cn = '存活回合' }, @{ k = 'kills'; cn = '击杀' },
    @{ k = 'alive';   cn = '活到终局' }, @{ k = 'hp_end'; cn = '终局血量' },
    @{ k = 'attacks'; cn = '出手次数' }, @{ k = 'moves'; cn = '移动次数' },
    @{ k = 'obs';     cn = '敲障碍' }
)
$corr = foreach ($mt in $metrics) {
    $xs = @($valid | ForEach-Object { [double]$_.($mt.k) })
    [pscustomobject]@{
        列 = $mt.k; 说明 = $mt.cn
        与胜负 = [math]::Round((Get-Corr $xs $wins), 3)
        与优势分 = [math]::Round((Get-Corr $xs $ptsArr), 3)
        均值 = [math]::Round(($xs | Measure-Object -Average).Average, 2)
    }
}
$corr = @($corr | Sort-Object { -[math]::Abs($_.与胜负) })

# ---------- 英雄级汇总 ----------
$heroRows = $rows | Group-Object hero | ForEach-Object {
    $g = @($_.Group)
    $gv = @($g | Where-Object { $_.res -ne '' })
    [pscustomobject]@{
        英雄 = $_.Name; 局数 = $g.Count
        胜率 = if ($gv.Count -gt 0) { [math]::Round((@($gv | Where-Object { $_.win }).Count / $gv.Count), 3) } else { '' }
        均打出 = [math]::Round(($g | Measure-Object dealt -Average).Average, 1)
        均吃伤 = [math]::Round(($g | Measure-Object taken -Average).Average, 1)
        均存活回合 = [math]::Round(($g | Measure-Object rounds -Average).Average, 1)
        均击杀 = [math]::Round(($g | Measure-Object kills -Average).Average, 2)
        阵亡率 = [math]::Round((@($g | Where-Object { $_.alive -eq 0 }).Count / $g.Count), 3)
        均敲障碍 = [math]::Round(($g | Measure-Object obs -Average).Average, 2)
    }
} | Sort-Object 均打出 -Descending

$md = @()
$md += '# 单位账本 · 口径初筛'
$md += ''
$md += ('- 数据：`{0}` · 有账本的格子 **{1}** 个（没有的 {2} 个 —— 那些格子跑在账本生效**之前**）· 单位行 **{3}** 行' -f $tagLabel, $cellsWith, $cellsWithout, $rows.Count)
$md += '- 口径：`dealt/taken` 取自 `Unit.damaged` 信号（圣盾/坚固/塔盾代扛之后）；归因 = 一招之内的发起者与目标两人；毒/烧血/炸弹只进 `taken`'
$md += '- `win`/`pts` = 该单位**所在阵营**的胜负与优势分（由 `measure.csv` 的 `a_side` 换算）'
$md += ''
$md += '## 各列与胜负 / 优势分的相关（点二列相关 = 皮尔逊；单位行之间不独立，只做口径检查）'
$md += ''
$md += '| 列 | 说明 | 与胜负 r | 与优势分 r | 均值 |'
$md += '|---|---|---|---|---|'
foreach ($c in $corr) { $md += ('| `{0}` | {1} | {2} | {3} | {4} |' -f $c.列, $c.说明, $c.与胜负, $c.与优势分, $c.均值) }
$md += ''
$md += '## 英雄级汇总（按"均打出"降序）'
$md += ''
$md += '| 英雄 | 局数 | 所在阵营胜率 | 均打出 | 均吃伤 | 均存活回合 | 均击杀 | 阵亡率 | 均敲障碍 |'
$md += '|---|---|---|---|---|---|---|---|---|'
foreach ($h in $heroRows) { $md += ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $h.英雄, $h.局数, $h.胜率, $h.均打出, $h.均吃伤, $h.均存活回合, $h.均击杀, $h.阵亡率, $h.均敲障碍) }
$md += ''
$md += '---'
$md += ('复算：`& RL\train\单位账本.ps1 -Tags {0}`' -f ($Tags -join ','))
[System.IO.File]::WriteAllLines($OutMd, $md, [System.Text.UTF8Encoding]::new($false))
Write-Host ("[账本] 已写 {0}" -f $OutMd)
Write-Host ''
Write-Host '=== 各列与胜负的相关（|r| 降序）==='
$corr | ForEach-Object { "  {0,-8} {1,-6} 与胜负 {2,6}   与优势分 {3,6}   均值 {4}" -f $_.列, $_.说明, $_.与胜负, $_.与优势分, $_.均值 }
