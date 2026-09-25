# 派生低档权重.ps1 —— 从 RL\weights\噩梦.json **派生**「简单 / 普通 / 困难」三档权重文件。
#
# 口径（用户 2026-09-25 拍板）：
#   「把前三个难度按照噩梦的基础上修改」+「困难和噩梦的区别就是专属键和概率弱智」
#   +「简单p100%，普通p50%，困难2阶段关，beam200」
#   · **通用评分键照抄噩梦**（⑦位置暴露 / 队形 / 毒价 / 嘲讽吸火 / 破盾 / 判负线闸门 / 血量池 …）
#     ⇒ 三档的"判断力"与噩梦同一套，落差只由"概率弱智"承担。
#   · **算力：三档一律不写算力键**（= 引擎默认：现役组合搜索 `SEARCH_MODE=0`、beam 200、思考上限 10s）
#     —— 两阶段联合搜索 / `BEAM=400` / 长预算都是**噩梦专属**（用户：「困难2阶段关，beam200」）。
#   · **hero_XX 英雄专属段不抄** ⇒ 低档没有英雄特化价（毒蛇不额外看重毒、堡垒不额外看重坚固…），
#     它与"算力"一起构成「困难 vs 噩梦」的结构性差别。
#   · 三档之间只差 `WEAK_P`（= 这一回合改走弱化引擎的概率；弱化引擎 = 每单位各自贪心 + 关集火合力）：
#       简单 **1.00**（每回合都走弱化引擎）· 普通 **0.50** · 困难 **0.20** —— `WEAK_MODE=5` / `WEAK_SEED=0` 相同。
#
# 为什么要脚本而不是手抄：噩梦.json 一改（键值、新增键），三份派生文件就会漂移。
#   噩梦.json 是**唯一真源**；本脚本重跑一次即可对齐（并在屏幕上打印"抄了哪些 / 跳过哪些"）。
# 回退：删掉这三份 json（难度 0/1/2 就回到"不注入任何权重"= 引擎默认的旧口径）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File RL\train\派生低档权重.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # RL\train -> RL -> 项目根
$src = Join-Path $root 'RL\weights\噩梦.json'

# 算力键（"怎么搜"而不是"怎么评"）；**三档都不写**（只有噩梦要它们）
$COMPUTE = @('SEARCH_MODE', 'BEAM', 'TWO_PHASE_P1_BEAM', 'TWO_PHASE_DEDUP', 'TWO_PHASE_P2_DEDUP',
             'SUMMON_SLOT_ONLY', 'TWO_PHASE_INNER', 'TWO_PHASE_LAYOUTS', 'TIME_BUDGET_MS')
# 档位 -> @{ weak = WEAK_P; compute = 是否照抄算力; time = 覆盖 TIME_BUDGET_MS（0 = 用噩梦的值） }
$TIERS = [ordered]@{
    '简单' = @{ weak = 1.00; compute = $false; time = 0 }
    '普通' = @{ weak = 0.50; compute = $false; time = 0 }
    '困难' = @{ weak = 0.20; compute = $false; time = 0 }
}

Add-Type -AssemblyName System.Web.Extensions
$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = 20000000
$o = $ser.DeserializeObject([System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8))

# 把噩梦.json 的键分成 评分键 / 算力键 / hero 段（都保持原始顺序）
$score = New-Object System.Collections.ArrayList
$comp = New-Object System.Collections.ArrayList
$hero = New-Object System.Collections.ArrayList
foreach ($k in $o.Keys) {
    if ($k.StartsWith('_')) { continue }              # 注释键不抄（派生文件自带 _说明）
    if ($k -like 'hero_*') { [void]$hero.Add($k); continue }
    if ($COMPUTE -contains $k) { [void]$comp.Add($k) } else { [void]$score.Add($k) }
}
if ($score.Count -lt 10) { throw "噩梦.json 里评分键太少（$($score.Count)）⇒ 先确认文件是否正常" }

$inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt([object]$v) {
    if ($v -is [int] -or $v -is [long]) { return [string]$v }
    $d = [double]$v
    if ($d -eq [math]::Floor($d) -and [math]::Abs($d) -lt 1e15) { return $d.ToString('0.0', $inv) }
    return $d.ToString($inv)
}
$srcSha = (Get-FileHash $src -Algorithm SHA256).Hash.Substring(0, 12)

foreach ($tier in $TIERS.Keys) {
    $t = $TIERS[$tier]
    $computeTxt = if ($t.compute) {
        '**照抄噩梦那套**（`SEARCH_MODE=2` 两阶段 + `BEAM=400` + 两阶段各算力键），只有 `TIME_BUDGET_MS` = ' +
        $t.time + '（噩梦 40000）'
    } else {
        '**不写算力键** ⇒ 本档用引擎默认：现役组合搜索（`SEARCH_MODE=0`）、beam 200、思考上限 10s'
    }
    $note = ('派生文件：**请勿手改** —— 由 `RL\train\派生低档权重.ps1` 从 `RL\weights\噩梦.json`' +
             '（sha12 ' + $srcSha + '）生成。口径（用户 2026-09-25 拍板「把前三个难度按照噩梦的基础上修改」）：' +
             '① 通用评分键照抄噩梦（低档判断力与噩梦同一套，落差由"概率弱智"承担）；' +
             '② 算力：' + $computeTxt + '；' +
             '③ **不带 hero_XX 英雄专属段**（那是噩梦专属）；' +
             '④ 本档与其它低档只差 `WEAK_P` —— 本档 WEAK_P = ' + (Fmt $t.weak) +
             '（这一回合改走弱化引擎的概率：每单位各自贪心 + 关集火合力），`WEAK_MODE=5`、`WEAK_SEED=0`。' +
             '要改值：改 `噩梦.json` 再重跑派生脚本（三档一起对齐）；要回退：删掉这三份 json。')
    $esc = $note.Replace('\', '\\').Replace('"', '\"').Replace("`r", '').Replace("`n", '\n')

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('{')
    [void]$lines.Add('  "_说明": "' + $esc + '",')
    foreach ($k in $score) { [void]$lines.Add('  "' + $k + '": ' + (Fmt $o[$k]) + ',') }
    if ($t.compute) {
        foreach ($k in $comp) {
            $v = $o[$k]
            if ($k -eq 'TIME_BUDGET_MS' -and $t.time -gt 0) { $v = $t.time }
            [void]$lines.Add('  "' + $k + '": ' + (Fmt $v) + ',')
        }
    }
    [void]$lines.Add('  "WEAK_MODE": 5,')
    [void]$lines.Add('  "WEAK_P": ' + (Fmt $t.weak) + ',')
    [void]$lines.Add('  "WEAK_SEED": 0')
    [void]$lines.Add('}')
    $out = Join-Path $root ('RL\weights\' + $tier + '.json')
    [System.IO.File]::WriteAllText($out, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $n = $score.Count + 3 + $(if ($t.compute) { $comp.Count } else { 0 })
    $ctxt = if ($t.compute) { '两阶段/BEAM ' + (Fmt $o['BEAM']) + '/上限 ' + $t.time + 'ms' } else { '引擎默认' }
    Write-Host ('[写出] ' + $out + ' · 键 ' + $n + ' · WEAK_P=' + (Fmt $t.weak) + ' · 算力=' + $ctxt)
}
Write-Host ('[照抄·评分] ' + ($score -join ', '))
Write-Host ('[算力键] ' + ($comp -join ', ') + '（**三档都不写** = 引擎默认；只有噩梦要它们）')
Write-Host ('[跳过] hero 段：' + ($hero -join ', '))
Write-Host ('[真源] ' + $src + ' sha12=' + $srcSha)
