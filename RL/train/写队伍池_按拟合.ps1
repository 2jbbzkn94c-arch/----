# 写队伍池_按拟合.ps1 —— 【2026-09-22 新增】按**强度拟合**（而不是原始胜率）切档、写"候选池"。
#
# 为什么单独一个脚本（不改 队伍车轮战.ps1 里那段写池）：
#   `队伍车轮战.ps1` 的排名是**原始胜率**（赢弱队和赢强队都算 1 分）—— 用户已经指出这不靠谱
#   （8 支对手的 Elo 从 1299 到 1819，差 5.8 倍）。本脚本改为：
#     · 主口径 = `队伍强度拟合.ps1` 的 **Bradley-Terry 实力**（对手强度自动校正）；
#     · 若给了瑞士轮名次（`-SwissJson`）⇒ 两套口径**取名次平均**（都不依赖同一批外部对手），
#       并打印一致性（Spearman + 逐档分歧数）。
#
# 输出：**`RL/weights/队伍池_候选.json`（游戏不读 ⇒ 不生效）**。
#   要真正启用：把它改名/复制成 `RL/weights/队伍池.json`（并删掉那份只读占位池）。
#   池子结构必须与 `src/Battle.gd::_load_pick_pool()` 对齐：顶层键 **ASCII** `weak/mid/strong`，
#   每档是 `[ [hero_id,...], ... ]`。写完立刻自检（键在不在、每队 ≥3 人、hero_id 是否都在角色列表里）。
#
# 用法：
#   & RL\train\写队伍池_按拟合.ps1 -FitJson RL\train\results\_fit_pool3.json `
#         -SwissJson RL\train\results\_swiss_swiss1_final.json -Out RL\weights\队伍池_候选.json
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FitJson,
    [string]$SwissJson = '',
    # ⚠️ 牌组**不在**拟合结果里（`_fit_pool3.json` 只存 idx/评分）⇒ 必须从**候选导出**按 idx 取。
    #    idx 口径 = 车轮战的 C### 编号 = 导出文件里 candidates 数组的 1-based 序号（同一份生成器）。
    [string]$CandFile = 'RL\train\results\_cands_pool3.json',
    [string]$Out = 'RL\weights\队伍池_候选.json',
    [string]$BaseWeights = 'RL\weights\噩梦.json',
    [switch]$RequireAgreement
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
function Resolve-UnderRoot([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { return $p } else { return (Join-Path $root $p) } }
$fitPath = Resolve-UnderRoot $FitJson
if (-not (Test-Path $fitPath)) { throw ('找不到拟合结果：' + $fitPath) }
$fit = Get-Content $fitPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cands = @($fit.candidates | Sort-Object -Property rank)
Write-Host ("[写池] 拟合来源 {0}（候选 {1} · 有效局 {2}）" -f (Split-Path -Leaf $fitPath), $cands.Count, $fit.有效局)

# ---------- 牌组表（idx -> "hero_a,hero_b,hero_c"）----------
$candPath = Resolve-UnderRoot $CandFile
if (-not (Test-Path $candPath)) { throw ('找不到候选导出文件：' + $candPath + '（先跑 队伍车轮战.ps1 -DumpCandidates …）') }
$dump = Get-Content $candPath -Raw -Encoding UTF8 | ConvertFrom-Json
$deckByIdx = @{}
$dlist = @($dump.candidates)
for ($i = 0; $i -lt $dlist.Count; $i++) { $deckByIdx[$i + 1] = (@($dlist[$i].deck) -join ',') }
Write-Host ("[写池] 候选导出 {0}：{1} 支（牌组按 idx 取）" -f (Split-Path -Leaf $candPath), $dlist.Count)

# ---------- 名次：拟合（主） ----------
$rankFit = @{}
for ($i = 0; $i -lt $cands.Count; $i++) { $rankFit[[int]$cands[$i].idx] = $i + 1 }
$rankSwiss = @{}
$swissNote = '（未提供瑞士轮名次 ⇒ 只用拟合口径）'
if ($SwissJson) {
    $sp = Resolve-UnderRoot $SwissJson
    if (Test-Path $sp) {
        $sw = Get-Content $sp -Raw -Encoding UTF8 | ConvertFrom-Json
        $rows = @($sw.rows | Sort-Object -Property @{ Expression = 'w'; Descending = $true }, @{ Expression = 'pts'; Descending = $true }, @{ Expression = 'idx'; Descending = $false })
        for ($i = 0; $i -lt $rows.Count; $i++) { $rankSwiss[[int]$rows[$i].idx] = $i + 1 }
        $swissNote = ('（瑞士轮 {0} 轮 · 取自 {1}）' -f $sw.轮次, (Split-Path -Leaf $sp))
        # 一致性：Spearman
        $ids = @($rankFit.Keys | Where-Object { $rankSwiss.ContainsKey($_) } | Sort-Object)
        if ($ids.Count -ge 3) {
            $d2 = 0.0
            foreach ($id in $ids) { $d = [double]$rankFit[$id] - [double]$rankSwiss[$id]; $d2 += $d * $d }
            $n = $ids.Count
            $sp2 = 1.0 - (6.0 * $d2) / ([double]$n * ($n * $n - 1))
            Write-Host ("[写池] 两套口径 Spearman = {0:N3}（n={1}）" -f $sp2, $n)
        }
    } else {
        Write-Host ('[写池] !! 瑞士轮名次不存在：' + $sp + ' ⇒ 退回只用拟合口径')
    }
}

# ---------- 合并名次（平均名次；两口径都参与时更稳） ----------
$combined = @()
foreach ($c in $cands) {
    $i0 = [int]$c.idx
    $r1 = [double]$rankFit[$i0]
    $r2 = $r1
    if ($rankSwiss.ContainsKey($i0)) { $r2 = [double]$rankSwiss[$i0] }
    $rc = ($r1 + $r2) / 2.0
    $combined += [pscustomobject]@{ idx = $i0; rankFit = $r1; rankSwiss = $r2; rank = $rc; elo = [double]$c.elo; deck = [string]$deckByIdx[$i0] }
}
$combined = @($combined | Sort-Object -Property rank)
# 只保留"两套口径都同意"的候选（可选）：按名次差排序，取前缀
if ($RequireAgreement -and $rankSwiss.Count -gt 0) {
    $maxDiff = [int][Math]::Ceiling($combined.Count / 3.0 / 2.0)
    $keep = @($combined | Where-Object { [Math]::Abs($_.rankFit - $_.rankSwiss) -le $maxDiff })
    Write-Host ("[写池] -RequireAgreement：名次差 ≤ {0} 的候选 {1}/{2} 支进入池子" -f $maxDiff, $keep.Count, $combined.Count)
    if ($keep.Count -ge 9) { $combined = $keep } else { Write-Host '[写池] !! 一致的太少（<9）⇒ 本次忽略该开关' }
}

# ---------- 切三档 ----------
$n = $combined.Count
$per = [int][Math]::Floor($n / 3)
if ($per -lt 3) { throw ('候选太少（{0} 支）⇒ 切不出三档' -f $n) }
$strong = @($combined | Select-Object -First $per)
$mid = @($combined | Select-Object -Skip $per | Select-Object -First $per)
$weak = @($combined | Select-Object -Skip (2 * $per))
Write-Host ("[写池] 切档：strong {0} · mid {1} · weak {2}" -f $strong.Count, $mid.Count, $weak.Count)

# ---------- 组装 + 写盘 ----------
function DeckArr($rows) { return @($rows | ForEach-Object { , @($_.deck -split ',') }) }
$wi = Resolve-UnderRoot $BaseWeights
$pool = [ordered]@{
    _说明 = '标准单机敌方"队伍池"（候选池：**尚未启用**）。src/Battle.gd 的 _load_pick_pool() 按 GameState.ai_difficulty 取档：0=weak(弱) 1=mid(中) 2/3=strong(强)。⚠️ 档位键必须是 ASCII。要启用：把本文件复制成 RL\weights\队伍池.json（并删掉那份只读占位池）。'
    _口径 = ('排名 = **Bradley-Terry 实力**（对手强度校正；每支候选打同一批固定对手、只取 a_side=1 生产侧）' + $swissNote + '；切档按合并名次三等份。**不是**原始胜率 —— 8 支对手的 Elo 差 5.8 倍，原始胜率不可横比。')
    _回退 = '删掉 RL\weights\队伍池.json 即可（立即回到"按评分加权随机组队"）。'
    meta = [ordered]@{
        生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        引擎sha12 = (Get-FileHash (Join-Path $root 'RL\ai\AI_Battle.gd') -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
        权重sha12 = (Get-FileHash $wi -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
        排名口径 = 'Bradley-Terry（队伍强度拟合.ps1）' + $(if ($rankSwiss.Count -gt 0) { ' + 瑞士轮平均名次' } else { '' })
        候选数 = $n; 每档 = $per
        来源 = @((Split-Path -Leaf $fitPath)) + $(if ($rankSwiss.Count -gt 0) { @((Split-Path -Leaf (Resolve-UnderRoot $SwissJson))) } else { @() })
    }
    weak = DeckArr $weak
    mid = DeckArr $mid
    strong = DeckArr $strong
}
$outPath = Resolve-UnderRoot $Out
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
[System.IO.File]::WriteAllText($outPath, ($pool | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[写池] 已写 ' + $outPath)

# ---------- 自检（写坏就 throw）----------
$chk = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($t in @('weak', 'mid', 'strong')) {
    if (-not ($chk.PSObject.Properties.Name -contains $t)) { throw ('池子写坏了：缺档位键 ' + $t) }
    $bad = @($chk.$t | Where-Object { @($_).Count -lt 3 })
    if ($bad.Count -gt 0) { throw ('池子写坏了：档 ' + $t + ' 里有 ' + $bad.Count + ' 支队伍不足 3 人') }
}
$known = @{}
# 角色列表列口径与 队伍车轮战.ps1 一致：第 0 列是**编号**（纯数字），hero_id = `hero_{编号:D2}`。
$rows = Get-Content (Join-Path $root '英雄相关\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($r in $rows) {
    $no = "$($r[0])"
    if ($no -notmatch '^\d+$') { continue }
    $known[('hero_{0:D2}' -f [int]$no)] = $true
}
$unknown = @()
foreach ($t in @('weak', 'mid', 'strong')) { foreach ($d in $chk.$t) { foreach ($h in $d) { if (-not $known.ContainsKey([string]$h)) { $unknown += [string]$h } } } }
if ($unknown.Count -gt 0) { throw ('池子写坏了：有 ' + $unknown.Count + ' 个 hero_id 不在角色列表里（例：' + ($unknown[0]) + '）') }
Write-Host '[写池] 自检通过：三个 ASCII 档位键都在 · 每队 ≥3 人 · hero_id 全部可解析'
Write-Host '[写池] 各档前 3 支（名次 / 拟合名次 / 瑞士名次 / Elo）：'
foreach ($pair in @(@('强', $strong), @('中', $mid), @('弱', $weak))) {
    $line = @()
    foreach ($r in @($pair[1] | Select-Object -First 3)) { $line += ('C{0:D3}({1:N1}/{2:N0}/{3:N0}/{4:N0})' -f $r.idx, $r.rank, $r.rankFit, $r.rankSwiss, $r.elo) }
    Write-Host ('  [{0}] {1}' -f $pair[0], ($line -join ' '))
}
