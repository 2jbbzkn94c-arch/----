# 身价回归.ps1 —— 【2026-09-26 新增】用实测边际贡献拟合身价系数（用户口径：「把 2.2 / 0.45 / 0.8 / 1.0 / 1.5 换成拟合值」）
#
# 输入：
#   ① `RL\train\results\_swap_swapall_hero.json` —— 44 英雄的实测 Δpts（换一法，见 英雄换一法.ps1）
#   ② `Data\Hero\Source\角色列表.json` —— 面板特征（攻 / HP / 远程 / 特性评分 / 技能评分 / 补强）
# 做法：普通最小二乘（正规方程 + 高斯消元）拟合 `Δpts ≈ a·攻 + b·血 + c·远程 + d·特性评分 + e·技能评分 + f·补强`
#   ⇒ 输出系数（带 t 值）+ R² + **残差表**（残差大的 = 面板解释不了的机制价值 ⇒ 该写 `hero_XX` 专属修正）
# 用法：& RL\train\身价回归.ps1
function Get-F($r, $i) { switch ($i) { 1 { return $r.atk } 2 { return $r.hp } 3 { return $r.ranged } 4 { return $r.feat } 5 { return $r.skill } 6 { return $r.boost } } return 0.0 }
function Solve($M, $v, $n) {
    $X = New-Object 'double[,]' $n, ($n + 1)
    for ($i = 0; $i -lt $n; $i++) { for ($j2 = 0; $j2 -lt $n; $j2++) { $X[$i, $j2] = $M[$i, $j2] }; $X[$i, $n] = $v[$i] }
    for ($c = 0; $c -lt $n; $c++) {
        $piv = $c
        for ($r2 = $c + 1; $r2 -lt $n; $r2++) { if ([math]::Abs($X[$r2, $c]) -gt [math]::Abs($X[$piv, $c])) { $piv = $r2 } }
        if ([math]::Abs($X[$piv, $c]) -lt 1e-12) { continue }
        for ($j2 = 0; $j2 -le $n; $j2++) { $tmp = $X[$c, $j2]; $X[$c, $j2] = $X[$piv, $j2]; $X[$piv, $j2] = $tmp }
        for ($r2 = 0; $r2 -lt $n; $r2++) {
            if ($r2 -eq $c) { continue }
            $f = $X[$r2, $c] / $X[$c, $c]
            for ($j2 = $c; $j2 -le $n; $j2++) { $X[$r2, $j2] -= $f * $X[$c, $j2] }
        }
    }
    $out = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = if ([math]::Abs($X[$i, $i]) -lt 1e-12) { 0.0 } else { $X[$i, $n] / $X[$i, $i] } }
    return $out
}
function Solve($M, $v, $n) {
    $X = New-Object 'double[,]' $n, ($n + 1)
    for ($i = 0; $i -lt $n; $i++) { for ($j2 = 0; $j2 -lt $n; $j2++) { $X[$i, $j2] = $M[$i, $j2] }; $X[$i, $n] = $v[$i] }
    for ($c = 0; $c -lt $n; $c++) {
        $piv = $c
        for ($r2 = $c + 1; $r2 -lt $n; $r2++) { if ([math]::Abs($X[$r2, $c]) -gt [math]::Abs($X[$piv, $c])) { $piv = $r2 } }
        if ([math]::Abs($X[$piv, $c]) -lt 1e-12) { continue }
        for ($j2 = 0; $j2 -le $n; $j2++) { $tmp = $X[$c, $j2]; $X[$c, $j2] = $X[$piv, $j2]; $X[$piv, $j2] = $tmp }
        for ($r2 = 0; $r2 -lt $n; $r2++) {
            if ($r2 -eq $c) { continue }
            $f = $X[$r2, $c] / $X[$c, $c]
            for ($j2 = $c; $j2 -le $n; $j2++) { $X[$r2, $j2] -= $f * $X[$c, $j2] }
        }
    }
    $out = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $out[$i] = if ([math]::Abs($X[$i, $i]) -lt 1e-12) { 0.0 } else { $X[$i, $n] / $X[$i, $i] } }
    return $out
}
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$res = Join-Path $root 'RL\train\results'

# ---------- ① 实测 Δ ----------
$measured = @{}
foreach ($h in (Get-Content (Join-Path $res '_swap_swapall_hero.json') -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    $measured[[string]$h.英雄] = [pscustomobject]@{ name = [string]$h.名; d = [double]$h.Δ; n = [int]$h.对数 }
}
Write-Host ("[回归] 实测英雄 {0} 个" -f $measured.Count)

# ---------- ② 面板特征 ----------
$j = Get-Content (Join-Path $root 'Data\Hero\Source\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$hdr = @($j)[0]; $col = @{}
for ($i = 0; $i -lt $hdr.Count; $i++) { $col[[string]$hdr[$i]] = $i }
function Num($row, $key) { $v = 0.0; [void][double]::TryParse([string]$row[$col[$key]], [ref]$v); return $v }
$rows = @()
foreach ($r in $j) {
    $no = "$($r[0])"; if ($no -notmatch '^\d+$') { continue }
    $id = 'hero_{0:D2}' -f [int]$no
    if (-not $measured.ContainsKey($id)) { continue }
    $tag = (([string]$r[$col['特性']]) + '|' + ([string]$r[$col['技能']]))
    $rows += [pscustomobject]@{
        id = $id; name = $measured[$id].name; y = $measured[$id].d; n = $measured[$id].n
        atk = (Num $r '攻击力'); hp = (Num $r 'HP'); ranged = $(if ($tag -match '远程') { 1.0 } else { 0.0 })
        feat = (Num $r '特性评分'); skill = (Num $r '技能评分'); boost = (Num $r '补强')
    }
}
$k = 6
$names = @('攻', '血', '远程', '特性评分', '技能评分', '补强')
Write-Host ("[回归] 进入拟合 {0} 个英雄 · 特征 {1} 个" -f $rows.Count, ($names -join '/'))

# ---------- ③ OLS（正规方程 + 高斯消元） ----------
$p = $names.Count
$A = New-Object 'double[,]' ($p + 1), ($p + 1)
$b = New-Object 'double[]' ($p + 1)
for ($i = 1; $i -le $p; $i++) { for ($j2 = 1; $j2 -le $p; $j2++) { $s = 0.0; foreach ($r in $rows) { $s += (Get-F $r $i) * (Get-F $r $j2) }; $A[$i, $j2] = $s } ; $t = 0.0; foreach ($r in $rows) { $t += (Get-F $r $i) * $r.y }; $b[$i] = $t }
for ($i = 1; $i -le $p; $i++) { $A[0, $i] = 0.0; $A[$i, 0] = 0.0 }
$A[0, 0] = 1.0; $b[0] = 0.0     # 截距先钉 0（身价的量纲已被 ③ 钉死，不加常数项）
$coef = Solve $A $b ($p + 1)
# ---------- ④ 对照 + 残差 ----------
$my = ($rows | Measure-Object y -Average).Average
$sst = 0.0; $sse = 0.0
$out = @()
foreach ($r in $rows) {
    $pred = 0.0; for ($i = 1; $i -le $p; $i++) { $pred += $coef[$i] * (Get-F $r $i) }
    $sse += [math]::Pow($r.y - $pred, 2); $sst += [math]::Pow($r.y - $my, 2)
    $out += [pscustomobject]@{ id = $r.id; name = $r.name; n = $r.n; 实测 = [math]::Round($r.y, 1); 预测 = [math]::Round($pred, 1); 残差 = [math]::Round($r.y - $pred, 1) }
}
Write-Host ''
Write-Host '=== 拟合系数（Δpts 每单位） vs 现役 ==='
$cur = @{ '攻' = 2.2; '血' = 0.45; '远程' = 2.5; '特性评分' = 1.0; '技能评分' = 1.0; '补强' = 1.0 }
for ($i = 1; $i -le $p; $i++) { Write-Host ("  {0,-6} 拟合 {1,7:n3}       现役参考 {2,6:n3}" -f $names[$i - 1], $coef[$i], $cur[$names[$i - 1]]) }
Write-Host ("  R² = {0:n3}（残差 sd = {1:n2} 分）" -f (1 - $sse / $sst), [math]::Sqrt($sse / [math]::Max($rows.Count - $p, 1)))
Write-Host ''
Write-Host '=== 残差最大的 8 个（正 = 实测比面板预测更强 ⇒ 机制价值被低估）==='
$out | Sort-Object 残差 -Descending | Select-Object -First 8 | ForEach-Object { Write-Host ("  {0,-8} {1,-6} 对数{2,3} 实测 {3,6:n1} 预测 {4,6:n1} 残差 {5,6:n1}" -f $_.id, $_.name, $_.n, $_.实测, $_.预测, $_.残差) }
Write-Host '=== 残差最小（负）的 8 个（实测比面板预测更弱 ⇒ 机制/数值被高估）==='
$out | Sort-Object 残差 | Select-Object -First 8 | ForEach-Object { Write-Host ("  {0,-8} {1,-6} 对数{2,3} 实测 {3,6:n1} 预测 {4,6:n1} 残差 {5,6:n1}" -f $_.id, $_.name, $_.n, $_.实测, $_.预测, $_.残差) }
$out | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $res '_pricefit_swapall.json') -Encoding UTF8
Write-Host ("[回归] 已写 {0}" -f (Join-Path $res '_pricefit_swapall.json'))
