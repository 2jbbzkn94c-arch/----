# 一键更新AI选择池.ps1 —— 把 `Data\Team\队伍池.md` 里的队伍落成"游戏真正读的那份池子"。
#
# 你平时只需要：编辑 `Data\Team\队伍池.md`（加队 / 改队 / 改配方）=> 双击 `Data\Team\一键更新AI选择池.bat`
#
# 位置（2026-09-23 用户把本脚本挪进 Source\）：本文件在 `Data\Team\Source\`，启动器 bat 在上一级 `Data\Team\`；
#   bat 会先找 `%~dp0Source\一键更新AI选择池.ps1`，再退回 `%~dp0` 与 `%~dp0..\Source\` => 三个位置都能点。
#
# 本脚本干三件事：
#   1) 调 `RL\train\写队伍池_按人工标注.ps1` 解析 MD（强 = 配方 + 固定队 / 中 / 弱 = C### 名单）
#      => 写 `RL\weights\队伍池_人工.json`（同时自带自检：三档键在不在 / 每队 ≥3 人 / hero_id 可解析）
#   2) 把当前生效的 `RL\weights\队伍池.json` 备份到 `RL\backups\队伍池_<时间>.json`
#   3) 把新产物复制成 `RL\weights\队伍池.json` —— **游戏读的就是这一份**
#
# [注意] 游戏已经在运行的话，改动要【重启游戏】才生效（池子在进关时读一次）。
# [注意] 池子一换，跑批的"格指纹 / 对手池"就变了 => 之前批次的读数别和新池子混着比较。
# 参数：-NoCopy 只生成不生效（只写 `队伍池_人工.json`）· -Md / -Out 换源/换产物（测试用）
[CmdletBinding()]
param(
    [string]$Md = '',
    [string]$Out = '',
    [switch]$NoCopy
)
$ErrorActionPreference = 'Stop'

function Show([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# ---------- 定位项目根：从本脚本所在目录往上找 project.godot（脚本放哪儿都能用）----------
$root = $null
$probe = $PSScriptRoot
for ($i = 0; $i -lt 8 -and $probe; $i++) {
    if (Test-Path (Join-Path $probe 'project.godot')) { $root = $probe; break }
    $probe = Split-Path -Parent $probe
}
if (-not $root) {
    Show "[错误] 从 $PSScriptRoot 往上找不到 project.godot，无法定位项目根目录。" 'Red'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Md)) { $Md = Join-Path $root 'Data\Team\队伍池.md' }
if ([string]::IsNullOrWhiteSpace($Out)) { $Out = Join-Path $root 'RL\weights\队伍池_人工.json' }
$tool     = Join-Path $root 'RL\train\写队伍池_按人工标注.ps1'
$prod     = Join-Path $root 'RL\weights\队伍池.json'
$heroJson = Join-Path $root 'Data\Hero\Source\角色列表.json'
$cands    = Join-Path $root 'RL\train\results\_cands_pool3.json'
$bakDir   = Join-Path $root 'RL\backups'

Show '============================================================' 'Cyan'
Show '  一键更新 AI 选择池（队伍池.md  →  游戏读的池子）' 'Cyan'
Show '============================================================' 'Cyan'
Show ('  源      ：' + $Md)
Show ('  产物    ：' + $Out)
Show ('  生效路径：' + $prod)
if ($NoCopy) { Show '  模式    ：-NoCopy（只生成，不动生效池子）' 'Yellow' }
Write-Host ''

# ---------- 前置检查 ----------
$miss = @()
foreach ($p in @($Md, $tool, $heroJson)) { if (-not (Test-Path -LiteralPath $p)) { $miss += $p } }
if ($miss.Count -gt 0) {
    foreach ($m in $miss) { Show ('[错误] 找不到：' + $m) 'Red' }
    exit 1
}
if (-not (Test-Path -LiteralPath $cands)) {
    Show ('[警告] 没找到候选表 ' + $cands + ' => MD 里新加的 C### 编号可能取不到牌组') 'Yellow'
}

# ---------- 1) 解析 MD → 池子 ----------
Show '[1/3] 解析 队伍池.md → 池子 ...' 'Yellow'
try {
    & $tool -Md $Md -Out $Out -CompareOld $prod
} catch {
    Write-Host ''
    Show ('[错误] 写池工具失败：' + $_.Exception.Message) 'Red'
    Show '   常见原因：MD 某行认不出（英雄名/特性名写错）· 某个槽被"排除"排空了 · 新 C### 不在候选表里' 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $Out)) { Show ('[错误] 没写出产物：' + $Out) 'Red'; exit 1 }

# ---------- 2) 与当前生效池子对照 ----------
Show ''
Show '[2/3] 与当前生效池子对照 ...' 'Yellow'

$rows = Get-Content -LiteralPath $heroJson -Raw -Encoding UTF8 | ConvertFrom-Json
$id2name = @{}
for ($i = 1; $i -lt $rows.Count; $i++) {
    $n = 0
    if ([int]::TryParse([string]$rows[$i][0], [ref]$n)) { $id2name['hero_{0:D2}' -f $n] = [string]$rows[$i][2] }
}
function Team-Label([string]$key) {
    $ids = @($key -split ',')
    return (($ids | ForEach-Object { $nm = $id2name[$_]; if ($nm) { $nm } else { $_ } }) -join '/')
}
function Pool-Stats([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cn = @{ strong = '强'; mid = '中'; weak = '弱' }
    $st = [pscustomobject]@{ 固定队伍 = 0; 配方 = 0; 强 = 0; 中 = 0; 弱 = 0; 队伍键 = @{} }
    foreach ($t in @('strong', 'mid', 'weak')) {
        if (-not ($j.PSObject.Properties.Name -contains $t)) { continue }
        foreach ($e in @($j.$t)) {
            $k = $cn[$t]
            $st.$k = $st.$k + 1
            if ($e -is [System.Array]) {
                $st.固定队伍 = $st.固定队伍 + 1
                $st.队伍键[(@($e) -join ',')] = $t
            } else {
                $st.配方 = $st.配方 + 1
            }
        }
    }
    return $st
}
# 配方（strong 档里的字典元素）按 id → 每槽的候选 hero_id 列表；没有 id 的池子返回空表（老格式）
function Recipe-Slots([string]$path) {
    $m = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $m }
    $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($e in @($j.strong)) {
        if ($e -is [System.Array]) { continue }
        if (-not ($e.PSObject.Properties.Name -contains 'id')) { continue }
        $sl = @()
        foreach ($s in @($e.slots)) {
            $ids = @()
            if ($s.PSObject.Properties.Name -contains 'pool') { $ids += @($s.pool) }
            if ($s.PSObject.Properties.Name -contains 'fixed') { $ids += @([string]$s.fixed) }
            $sl += , @($ids)
        }
        $m[[string]$e.id] = $sl
    }
    return $m
}

$oldSt = Pool-Stats $prod
$newSt = Pool-Stats $Out
if (-not $newSt) { Show '[错误] 读不出新池子' 'Red'; exit 1 }
foreach ($k in @('强', '中', '弱')) {
    $was = if ($oldSt) { [string]$oldSt.$k } else { '—' }
    Show ('    {0}：{1} 支（原 {2} 支）' -f $k, $newSt.$k, $was)
}
Show ('    合计：固定队伍 {0} 支 + 配方 {1} 条' -f $newSt.固定队伍, $newSt.配方)

if ($oldSt) {
    $added = @(); $removed = @()
    foreach ($k in @($oldSt.队伍键.Keys)) { if (-not $newSt.队伍键.ContainsKey($k)) { $removed += $k } }
    foreach ($k in @($newSt.队伍键.Keys)) { if (-not $oldSt.队伍键.ContainsKey($k)) { $added += $k } }
    Show ('    固定队伍变化：新增 {0} 支 · 移除 {1} 支' -f $added.Count, $removed.Count)
    foreach ($k in $removed) { Show ('      - ' + (Team-Label $k)) 'DarkYellow' }
    foreach ($k in $added) { Show ('      + ' + (Team-Label $k)) 'Green' }

    # 配方内部：逐槽候选池的增删（改「排除X」之后最该看的就是这里）
    $oldR = Recipe-Slots $prod
    $newR = Recipe-Slots $Out
    $rN = 0
    foreach ($id in @($newR.Keys)) {
        if (-not $oldR.ContainsKey($id)) { Show ('      配方 {0}：新增' -f $id) 'Green'; $rN++; continue }
        $a = @($oldR[$id]); $b = @($newR[$id])
        for ($s = 0; $s -lt [Math]::Max($a.Count, $b.Count); $s++) {
            $x = if ($s -lt $a.Count) { @($a[$s]) } else { @() }
            $y = if ($s -lt $b.Count) { @($b[$s]) } else { @() }
            $minus = @($x | Where-Object { $y -notcontains $_ })
            $plus = @($y | Where-Object { $x -notcontains $_ })
            if ($minus.Count -gt 0 -or $plus.Count -gt 0) {
                $rN++
                $txt = @()
                if ($minus.Count -gt 0) { $txt += ('- ' + (Team-Label ($minus -join ','))) }
                if ($plus.Count -gt 0) { $txt += ('+ ' + (Team-Label ($plus -join ','))) }
                Show ('      配方 {0} 槽{1}（{2} → {3} 人）：{4}' -f $id, ($s + 1), $x.Count, $y.Count, ($txt -join '   ')) 'Cyan'
            }
        }
    }
    foreach ($id in @($oldR.Keys)) { if (-not $newR.ContainsKey($id)) { Show ('      配方 {0}：移除' -f $id) 'DarkYellow'; $rN++ } }
    if ($rN -eq 0) { Show '    配方槽位候选：无变化' }
}

# ---------- 安全网 ----------
$newTotal = $newSt.固定队伍 + $newSt.配方
$oldTotal = if ($oldSt) { $oldSt.固定队伍 + $oldSt.配方 } else { 0 }
if ($newTotal -eq 0) { Show '[错误] 新池子一支队伍都没有 => 拒绝覆盖生效池子' 'Red'; exit 1 }
if ($oldTotal -gt 0 -and $newTotal -lt [int]($oldTotal * 0.6)) {
    Show ('[警告] 新池子只有 {0} 支（原来 {1} 支）—— MD 是不是被改坏了？' -f $newTotal, $oldTotal) 'Red'
    $ans = Read-Host '仍要覆盖生效池子吗？(y/N)'
    if ($ans -notmatch '^[yY]') { Show '已取消：生效池子没动。' 'Yellow'; exit 1 }
}

# ---------- 3) 备份 + 覆盖生效池子 ----------
Show ''
if ($NoCopy) {
    Show '[3/3] 已跳过（-NoCopy）：生效池子没动。' 'Yellow'
    Show ('   想生效：双击 一键更新AI选择池.bat（不带参数），或把产物复制成 ' + $prod) 'Yellow'
} else {
    Show '[3/3] 备份旧池子 → 覆盖生效池子 ...' 'Yellow'
    New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
    if (Test-Path -LiteralPath $prod) {
        $bak = Join-Path $bakDir ('队伍池_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.json')
        Copy-Item -LiteralPath $prod -Destination $bak -Force
        Show ('    旧池子已备份 → ' + $bak) 'DarkGray'
    }
    Copy-Item -LiteralPath $Out -Destination $prod -Force
    $h = (Get-FileHash -LiteralPath $prod -Algorithm SHA256).Hash.Substring(0, 12)
    Show ('    [OK] 生效池子已更新 → ' + $prod) 'Green'
    Show ('       sha12 = ' + $h) 'DarkGray'
}
Write-Host ''
Show '完成。' 'Cyan'
Show '  [注意] 游戏已经在运行的话，要【重启游戏】才生效（池子在进关时读一次）。' 'Yellow'
Show '  [注意] 池子换了 => 跑批的格指纹/对手池跟着变，旧读数别和新池子混着比。' 'Yellow'
Show '  回退：删掉 RL\weights\队伍池.json（立刻回到"按评分加权随机组队"），或从上面的备份复制回来。' 'DarkGray'
