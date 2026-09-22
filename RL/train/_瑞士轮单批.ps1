# _瑞士轮单批.ps1 —— 【2026-09-22 新增】队伍瑞士轮的**单块 worker**：
#   读一份计划 json（由 队伍瑞士轮.ps1 写的 `_swissplan_<tag>_r<轮>_g<组>.json`），
#   按顺序把里面每一对"候选 vs 候选"交给 Train.ps1 跑一格（1 局、`-FixedDecks`、a_side=1）。
#
# 为什么单独一个文件而不是内联命令：内联要把一大串带引号的路径/参数拼进 `-ArgumentList`，
#   中文路径 + 嵌套引号在 PS 5.1 下极易拼错（本项目已经踩过一次）。
#
# 每一对都落三样东西：
#   · `results/<run>/measure.csv`（Train.ps1 自己的产物）
#   · `results/_swissmeta_<run>.json`（a/b = 哪两支候选、谁当敌方、种子 index）
#     —— 名次结算只认这份 meta，避免"从 spec 反推"时踩到方向/换边的歧义。
#
# 用法（只由 队伍瑞士轮.ps1 调）：
#   & RL\train\_瑞士轮单批.ps1 -Plan <plan.json> -Beam 100 -BaseWeights RL\weights\噩梦.json
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Plan,
    [int]$Beam = 100,
    [string]$BaseWeights = 'RL\weights\噩梦.json',
    # 单格超时（秒）。⚠️【2026-09-22 踩过】默认原来是 3600：有一格 Godot 在 `R|cfg` 之后**空转**
    #   （8 分钟烧了 480 秒 CPU、没有任何输出）⇒ 整条瑞士轮被那一格的**轮间栅栏**卡住近一小时。
    #   15 分钟对"2 局、beam 100"是 6 倍余量，够用；真超时会被判成"0 行"、该格记缺、其余继续。
    [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Continue'
$train = Join-Path $PSScriptRoot 'Train.ps1'
$results = Join-Path $PSScriptRoot 'results'
$rawItems = Get-Content $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
# ⚠️ PS 5.1 的 `ConvertFrom-Json` 把 **JSON 数组当"一个对象"** 返回（`@(…).Count` = 1，
#   于是 `$it.a` 变成 Object[] ⇒ `[int]$it.a` 直接抛 ConvertToFinalInvalidCastException）。
#   必须显式枚举一遍（`foreach` 会展开数组）—— 2026-09-22 踩过；瑞士轮与补种子都靠这里。
$items = @()
foreach ($x in $rawItems) { $items += $x }
# ⚠️ `seeds` 与 `lineups` 都必须在（`Read-TrainSpec` 会抛 `spec.lineups missing`，已踩一次）。
#   直接沿用 `spec_nmchk.json`（= 跑批通用的 120 个训练种子 + 阵容表），与 队伍车轮战.ps1 同一口径。
$seedBase = Get-Content (Join-Path $PSScriptRoot 'spec_nmchk.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Write-Host ('[瑞士批] {0}：{1} 对' -f (Split-Path -Leaf $Plan), $items.Count)
$done = 0
foreach ($it in $items) {
    $run = [string]$it.run
    $specPath = Join-Path $PSScriptRoot ('spec_{0}.json' -f $run)
    $o = [ordered]@{
        base_weights = $BaseWeights
        opponent     = 'base'
        beam         = @{ candidate = $Beam; opponent = $Beam }
        # decks.enemy = a_side=1 时**候选**扮演的那一方（Train.ps1 的既有语义，见 对局.gd:106）
        decks        = @{ enemy = [string]$it.deckEnemy; player = [string]$it.deckPlayer }
        seeds        = @{ train = @($seedBase.seeds.train); holdout = @($seedBase.seeds.holdout) }
        lineups      = $seedBase.lineups
        measurement  = @{ firsts = @('p'); asides = @('e') }
        params       = @{}
        configs      = @(@{ name = 'm'; note = 'swiss'; theta = @{}; beam = $Beam; beam_opp = $Beam })
    }
    [System.IO.File]::WriteAllText($specPath, ($o | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $results ('_swissmeta_' + $run + '.json')),
        ([ordered]@{ run = $run; a = [int]$it.a; b = [int]$it.b; enemy = [int]$it.enemy; player = [int]$it.player; seedIndex = [int]$it.seedIndex } | ConvertTo-Json),
        (New-Object System.Text.UTF8Encoding($false)))
    $csv = Join-Path (Join-Path $results $run) 'measure.csv'
    $had = Test-Path $csv
    # 直接在本进程里调 Train.ps1（与 队伍车轮战.ps1 同一写法）。
    # ⚠️ 不要再套一层 `powershell -Command '& "…"'`：中文路径 + 嵌套引号在 PS 5.1 下会被拼坏，
    #   症状是"子进程一行输出都没有、也不产出 measure.csv"（2026-09-22 踩过）。
    & $train -Task run -Spec $specPath -Run $run -SeedSet train -SeedStart ([int]$it.seedIndex) -SeedBlock 1 -FixedDecks -Workers 1 -TimeoutSec $TimeoutSec |
        Select-String -Pattern 'run=|TOTAL wall|FATAL|theta key' | ForEach-Object { Write-Host ('   ' + $_.Line) }
    $done += 1
    Write-Host ('[瑞士批] {0} 完成 {1}/{2}{3}' -f (Split-Path -Leaf $Plan), $done, $items.Count, $(if ($had) { '（已存在，resume）' } else { '' }))
}
Write-Host ('[瑞士批] {0} 全部结束' -f (Split-Path -Leaf $Plan))
