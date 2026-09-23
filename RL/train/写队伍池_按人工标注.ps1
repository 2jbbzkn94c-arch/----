# 写队伍池_按人工标注.ps1 —— 【2026-09-22 新增·用户口径】把 `队伍池.md` 里的人工标注落成池子文件。
#
# 用户的规则（原话）：「队伍池MD 是我自己优化了一下，1放进强池，2中池，3弱池，没有数字的保持原位」
#   ⇒ 每行开头：
#       · `1` / `2` / `3`  = 强制放进 强 / 中 / 弱 档（覆盖它原来所在的分区）
#       · 没有数字         = 保持它在该 MD 里所属的分区（强 / 中 / 弱 三个小节）
#       · `★`（紧跟数字或行首）= 该队也在"严格池"里（本脚本只读不改，纯提示）
#   ⇒ **配方行**（`1.近战（…）+ 远程（…）+ 嘲讽（…）`）的行尾还能写 `★数字` = 该配方的**抽签权重**：
#       · 例：`… + 嘲讽（排除替补和大骑士）★2` ⇒ 这条类型 `w = 2`（比其它类型多一倍出场率）；不写 = 1。
#       · 游戏端 `Battle._pick_entry_weighted()` 按 `w` 加权抽类型（2026-09-23 新增，见 `5_选人策略.md` §现状⑤-8）。
#       · ⚠️ 槽位文字里的三个关键词：含「随机」⇒ 整池均匀；含「根据」⇒ 按克制取最高分；**其余 ⇒ band 上位圈随机**。
#   ⇒ **全局参数行**（独立一行，可写在 MD 任意位置；本池子写在文件末尾、收尾围栏之前）：
#       · 写法：`@参数 圈宽=6 抖动=2`（也认英文 `@band 6` / `@jitter 2`；顺序随意、可只写一个）
#       · 圈宽 = `meta.pick_band`：泛化槽取"最高分 − 圈宽"以内的人**均匀随机**（越大越摊平；3 = 紧、6 = 近战池全均匀）
#       · 抖动 = `meta.pick_jitter`：每候选 `底分 + randf()×抖动`（一次克制 = 2.0 分 ⇒ 2.0 ≈ "七成按分数"）
#       · ⚠️ **别写在配方行之前**：配方 id 是按**行号**生成的（`R{行号}`）⇒ 上面插一行会把 R04/R05 顶成 R05/R06。
#       · 不写参数行 ⇒ 用默认 圈宽 3 / 抖动 2（脚本会打印实际取值，别靠猜）。
#   ⚠️ `-RewriteMd` 目前**只重写队伍行**（配方行与参数行会被丢掉、且行号一变配方 id 也跟着变）⇒ 池子里有配方时
#      脚本会直接**拒绝执行**这个开关（见文件末的守卫）；真要重排格式请手工改，或让我把重写补全。
#   MD 里每行都带 `C###` 编号 ⇒ 牌组按编号从 `-CandFile`（车轮战导出的候选表）取，
#   **不从那行文字里反解牌组名**（防止改名/空格导致错位）。
#
# 用法：
#   & RL\train\写队伍池_按人工标注.ps1 -Md 队伍池.md -Out RL\weights\队伍池_人工.json
#   & RL\train\写队伍池_按人工标注.ps1 -Md 队伍池.md -Out RL\weights\队伍池_人工.json -RewriteMd
#      ⇒ 额外把 MD **本身**重写成"已按最终档位归位、行首数字去掉"的版本（★ 与后面的读数保留），
#        并把带标注的原版备份到 `RL\backups\队伍池_标注版_<时间>.md`。重写后的 MD 再跑本脚本是幂等的。
#
# 输出：`weak/mid/strong` 三个 ASCII 档位键（与 `src/Battle.gd::_load_pick_pool()` 对齐）
#   + 自检（键在不在 / 每队 3 人 / hero_id 可解析 / 120 支不重不漏）+ 与旧候选池的档位差异清单。
# ⚠️ 游戏读的是 `RL/weights/队伍池.json`；本脚本只写"候选/人工"文件 ⇒ **不生效**。
[CmdletBinding()]
param(
    [string]$Md = '队伍池.md',
    [string]$CandFile = 'RL\train\results\_cands_pool3.json',
    [string]$Out = 'RL\weights\队伍池_人工.json',
    # 可选：给一份旧池子做"档位变动"对照（只打印，不参与写盘）
    [string]$CompareOld = 'RL\weights\队伍池_候选.json',
    # 可选：把 MD 重写成去数字版（见文件头）
    [switch]$RewriteMd,
    # 可选：允许写"某档为空"的池子（默认拒绝，见写盘前的安全网）
    [switch]$AllowEmptyTier
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Resolve-UnderRoot([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p } else { return (Join-Path $root $p) }
}

# ---------- 英雄名/特性表（模板行要用）----------
$heroRows = Get-Content (Join-Path $root 'Data\Hero\Source\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$name2id = @{}; $id2name = @{}; $traits = @{}; $allIds = @()
for ($i = 1; $i -lt $heroRows.Count; $i++) {
    $num = 0
    if (-not [int]::TryParse([string]$heroRows[$i][0], [ref]$num)) { continue }
    $hid = 'hero_{0:D2}' -f $num
    $nmx = [string]$heroRows[$i][2]
    $name2id[$nmx] = $hid; $id2name[$hid] = $nmx; $traits[$hid] = [string]$heroRows[$i][5]
    $allIds += $hid
}
# ⚠️ 常见手误别名（用户手写模板时出现；命中就提示一声，不当成特性名去匹配）
$alias = @{ '烈焰祭祀' = '烈焰祭司' }

# ---------- 展开一行模板 ----------
# 支持写法（用户口径）：
#   `（A/B/C）+ 圣诞老人 + 宿魂`        括号内多选（`/` 或 `、` 分隔）= 各生成一支
#   `嘲讽（排除替补和大骑士）+ 长剑 + 烛火`  前缀是**特性名**（嘲讽/替补/远程/…）⇒ 取该特性的英雄，
#                                         `排除X` 里 X 可以是英雄名或特性名
#   `死灵法师+烈焰祭司+共鸣者`            直接三个英雄名
#   尾部 `其中一人` / `其中随机N人` 只是人话补充，**一律按"全部组合"展开**（保证文件可复现、无随机）
function Expand-Spec([string]$text) {
    $t = $text -replace [char]0xFF08, '(' -replace [char]0xFF09, ')' -replace '\s', ''
    $slots = @($t -split '\+')
    $slotSets = @()
    foreach ($s in $slots) {
        $base = $s
        $excl = @()
        $alts = @()
        # 括号组可能多个：内容以「排除」开头 ⇒ 排除项；否则 ⇒ 备选项
        foreach ($mm in [regex]::Matches($s, '\(([^)]*)\)')) {
            $inner = $mm.Groups[1].Value -replace '其中随机\d+人', '' -replace '其中一人', ''
            foreach ($part in @($inner -split '[/、,，]' | Where-Object { $_ })) {
                if ($part -match '^排除') { $excl += ($part -replace '^排除', '') } else { $alts += $part }
            }
        }
        # 裸写的「排除X」（不在括号里）也支持
        foreach ($mm in [regex]::Matches($s, '排除([^\s+()]*)')) {
            foreach ($part in @($mm.Groups[1].Value -split '[/、,，和与]' | Where-Object { $_ })) { $excl += $part }
        }
        # base = 去掉所有括号组与「其中…」补充语后剩下的部分（英雄名或特性名）
        $base = ($s -replace '\([^)]*\)', '') -replace '其中随机\d+人', '' -replace '其中一人', ''
        $names = @()
        foreach ($b in @($base -split '[/、,，]' | Where-Object { $_ })) {
            if ($alias.ContainsKey($b)) { Write-Host ('[人工池]   (别名) {0} → {1}' -f $b, $alias[$b]); $b = $alias[$b] }
            if ($name2id.ContainsKey($b)) { $names += $b; continue }
            # 不是英雄名 ⇒ 当特性名，取该特性全部英雄
            $hit = @()
            foreach ($hid in $traits.Keys) { if ([string]$traits[$hid] -match [regex]::Escape($b)) { $hit += $id2name[$hid] } }
            if ($hit.Count -eq 0) { throw ('模板里的「' + $b + '」既不是英雄名也不是特性名 ⇒ 我没法解析这一行：' + $text) }
            $names += $hit
        }
        $names = @($names + $alts) | Sort-Object -Unique
        foreach ($e in $excl) {
            $ex = $e
            if ($alias.ContainsKey($ex)) { $ex = $alias[$ex] }
            if ($name2id.ContainsKey($ex)) {
                $names = @($names | Where-Object { $_ -ne $ex })
            } else {
                $names = @($names | Where-Object { [string]$traits[$name2id[$_]] -notmatch [regex]::Escape($ex) })
            }
        }
        if ($names.Count -eq 0) { throw ('模板某一槽被排空了 ⇒ 检查排除条件：' + $s) }
        $slotSets += , @($names)
    }
    # 笛卡尔积
    $acc = @(, @())
    foreach ($set in $slotSets) {
        $next = @()
        foreach ($a in $acc) { foreach ($x in $set) { $next += , (@($a) + @($x)) } }
        $acc = $next
    }
    $out = @()
    # ⚠️ 每支队伍包成 **对象**（真正的数组放在 `heroes` 属性里）：PowerShell 会把"数组的数组"拆平，
    #   直接返回裸数组时"只生成 1 支"与"生成 6 支"在调用方看起来一样（2026-09-22 踩过两次）。
    foreach ($a in $acc) { $out += [pscustomobject]@{ heroes = @($a | ForEach-Object { $name2id[$_] }) } }
    return $out
}

# ---------- 配方（"类型"）解析 ----------
# 把**一个槽位**的文字解析成英雄名列表（全池，不截断）。支持写法：
#   `古灵精怪`                     单名 ⇒ 调用方会当"锁定槽"
#   `（复仇者/负墟）根据对方要求…`   括号内多选（后面的人话说明会被丢掉）
#   `(共鸣者/巨剑）随机1人`         同上（"随机N人"由调用方解释成"替补补几个"）
#   `嘲讽（排除替补和大骑士，根据对方首发决定）`  特性名 + 排除（排除项可以是英雄名或特性名）
#   `近战` / `远程`                特殊词：近战 = 没有 <远程> 标签；远程 = 有 <远程> 标签
function Resolve-SlotPool([string]$slotText) {
    $s = $slotText
    # ⚠️ 顺序很重要（踩过）：**先**从括号里取"排除项 / 备选项"，**再**剥掉人话说明。
    #   反过来的话 `嘲讽（排除替补和大骑士，根据对方首发决定）` 会先被"根据…"截断成
    #   `嘲讽（排除替补和大骑士` ⇒ 括号配不成对 ⇒ 槽位名变成 `嘲讽（` ⇒ 整条配方解析失败。
    $excl = @()
    foreach ($mm in [regex]::Matches($s, '排除([^)）]*)')) {
        $inner = [regex]::Replace($mm.Groups[1].Value, '[，,]?\s*根据.*$', '')
        foreach ($p in @($inner -split '[/、,，和与]' | Where-Object { $_ })) { $excl += $p }
    }
    $alts = @()
    foreach ($mm in [regex]::Matches($s, '[（(]([^)）]*)[)）]')) {
        $inner = $mm.Groups[1].Value
        if ($inner -match '^\s*排除') { continue }
        $inner = [regex]::Replace($inner, '[，,]?\s*根据.*$', '')
        $inner = [regex]::Replace($inner, '其中随机\s*\d+\s*人', '')
        $inner = [regex]::Replace($inner, '其中一人', '')
        foreach ($p in @($inner -split '[/、,，]' | Where-Object { $_ })) { $alts += $p }
    }
    $base = ($s -replace '[（(][^)）]*[)）]', '')
    $base = ($base -replace '排除[^)）]*', '')
    $base = [regex]::Replace($base, '[，,]?\s*根据.*$', '')
    $base = [regex]::Replace($base, '其中随机\s*\d+\s*人', '')
    $base = [regex]::Replace($base, '其中一人', '')
    $base = [regex]::Replace($base, '其中', '')
    $base = [regex]::Replace($base, '随机\s*\d+\s*人', '')
    $base = $base.Trim().Trim('，', ',', '、')
    $names = @()
    foreach ($b in @($base -split '[/、,，]' | Where-Object { $_ })) {
        if ($b -eq '近战') { $names += @($allIds | Where-Object { $traits[$_] -notmatch '远程' } | ForEach-Object { $id2name[$_] }); continue }
        if ($b -eq '远程') { $names += @($allIds | Where-Object { $traits[$_] -match '远程' } | ForEach-Object { $id2name[$_] }); continue }
        if ($alias.ContainsKey($b)) { $names += $alias[$b]; continue }
        if ($name2id.ContainsKey($b)) { $names += $b; continue }
        $hit = @($allIds | Where-Object { [string]$traits[$_] -match [regex]::Escape($b) } | ForEach-Object { $id2name[$_] })
        if ($hit.Count -eq 0) { throw ('槽位「' + $b + '」认不出（既不是英雄名也不是特性名）') }
        $names += $hit
    }
    $names += $alts
    $names = @($names | Sort-Object -Unique)
    foreach ($e in $excl) {
        $ex = $e
        if ($alias.ContainsKey($ex)) { $ex = $alias[$ex] }
        if ($name2id.ContainsKey($ex)) {
            $names = @($names | Where-Object { $_ -ne $ex })
        } else {
            $names = @($names | Where-Object { [string]$traits[$name2id[$_]] -notmatch [regex]::Escape($ex) })
        }
    }
    # ⚠️ **不要**写成 `return , $names`：那样调用方的 `@(...)` 会收到"1 个元素（= 整个名单数组）"，
    #   于是"多候选槽"被误判成 `Count -eq 1` ⇒ 写成 fixed（2026-09-22 踩过）。直接返回即可。
    return $names
}

# 把一整行配方（如 `3.首发：古灵精怪 + 暗域 + 嬉皮死神，替补：（…）其中随机3人`）解析成配方对象。
# 产物与游戏端读取端（`src/Battle.gd::_normalize_recipe`）对齐：
#   { id, note, slots: [ {fixed:"hero_xx"} | {pool:[...]} ], bench:[...], bench_multi:[{pool:[...],n:N}], w }
function Convert-SpecToRecipe([string]$text, [int]$lineNo) {
    # 【2026-09-23 新增】行尾 `★数字` = 该配方的**抽签权重**（游戏端 `Battle._pick_entry_weighted()` 按 w 加权；
    #   不写 = 1）。例：`… + 嘲讽（排除替补和大骑士）★2` ⇒ w = 2。
    #   ⚠️ 必须在解析槽位**之前**抠掉：否则它会留在最后一个槽的文字里（`★` 认不出 ⇒ 直接抛"槽位认不出"）；
    #   顺便让写进池子/日志的 `note` 保持干净（note = 原始行文字，控制台会打）。
    $wVal = 1.0
    $mw = [regex]::Match($text, '\u2605\s*(\d+(?:\.\d+)?)\s*$')
    if ($mw.Success) {
        $wVal = [double]$mw.Groups[1].Value
        $text = $text.Substring(0, $mw.Index).TrimEnd()
    }
    $t = [regex]::Replace($text, '^\s*\d+\s*[.、]\s*', '')
    $main = $t
    $benchTxt = ''
    $m = [regex]::Match($t, '^(.*?)[，,]\s*替补\s*[:：]\s*(.*)$')
    if ($m.Success) {
        $main = $m.Groups[1].Value; $benchTxt = $m.Groups[2].Value
    } else {
        $m2 = [regex]::Match($t, '^(.*?)\s*替补\s*[:：]\s*(.*)$')
        if ($m2.Success) { $main = $m2.Groups[1].Value; $benchTxt = $m2.Groups[2].Value }
    }
    $main = [regex]::Replace($main, '^\s*首发\s*[:：]?\s*', '')
    $main = $main.Trim().TrimEnd('，', ',')
    $slots = @()
    foreach ($st in @($main -split '\+' | Where-Object { $_.Trim() -ne '' })) {
        # ⚠️ 用 foreach 累加，别用 `@(函数)`（函数的输出是"名字数组"，`@()` 包起来会变成
        #   "1 个元素 = 整个数组" ⇒ 多候选槽被误判成 fixed）
        $poolNames = @()
        foreach ($x in (Resolve-SlotPool $st)) { $poolNames += $x }
        if ($poolNames.Count -eq 0) { throw ('槽位解析为空：' + $st) }
        # `pick` 三种（游戏端 `Battle._recipe_deploy_pick()` 读它）：
        #   · 槽位文字里有「随机N人」   ⇒ `random`  = **整池均匀随机**（用户明确写了"随机1人"，
        #     就不能被分数垄断 —— 实测 `(暗域/血锁/傀儡师)` 里暗域高 4.5，band=3 圈里只剩它）
        #   · 有「根据…决定 / 根据…要求」⇒ `counter` = **按克制取最高分**（"对面有毒蛇就上战锤"那类）
        #   · 其它（近战/远程 这种泛化） ⇒ 空 = 游戏端走"上位圈随机"（`meta.pick_band`）
        $pickMode = ''
        if ($st -match '随机') { $pickMode = 'random' }
        elseif ($st -match '根据') { $pickMode = 'counter' }
        if ($poolNames.Count -eq 1) { $slots += [ordered]@{ fixed = $name2id[$poolNames[0]] } }
        else { $slots += [ordered]@{ pool = @($poolNames | ForEach-Object { $name2id[$_] }); pick = $pickMode } }
    }
    $bench = @()
    $benchMulti = @()
    $dynamic = $true
    if ($benchTxt.Trim() -ne '') {
        $dynamic = $false
        foreach ($grp in @($benchTxt -split '\+' | Where-Object { $_.Trim() -ne '' })) {
            $mn = [regex]::Match($grp, '随机\s*(\d+)\s*人')
            $hasRandom = $mn.Success
            $n = 1
            if ($hasRandom) { $n = [int]$mn.Groups[1].Value }
            $pool2 = @()
            foreach ($x in (Resolve-SlotPool $grp)) { $pool2 += $x }
            if ($pool2.Count -eq 0) { continue }
            if ($hasRandom) {
                $benchMulti += [ordered]@{ pool = @($pool2 | ForEach-Object { $name2id[$_] }); n = $n }
            } else {
                foreach ($x in $pool2) { $bench += $name2id[$x] }
            }
        }
    }
    return [ordered]@{
        id = ('R{0:D2}' -f $lineNo)
        note = $text
        slots = @($slots)
        bench = @($bench)
        bench_multi = @($benchMulti)
        dynamic_bench = $dynamic
        w = $wVal
    }
}

# ---------- 读 MD ----------
$mdPath = Resolve-UnderRoot $Md
if (-not (Test-Path $mdPath)) { throw ('找不到标注文件：' + $mdPath) }
$lines = Get-Content $mdPath -Encoding UTF8
$secMap = @{ '强' = 'strong'; '中' = 'mid'; '弱' = 'weak' }
$section = ''
$items = @()
$specs = @()
$recipes = @()
# 【2026-09-23 新增】全局参数行 `@参数 圈宽=6 抖动=2` 的读取口（默认 = 脚本原先写死的 3.0 / 2.0 ⇒ 不写行为不变）
$pickBand = 3.0
$pickJitter = 2.0
$paramSeen = $false
$lineNo = 0
foreach ($ln in $lines) {
    $lineNo++
    $t = $ln.Trim()
    if ($t -eq '' -or $t -eq '```') { continue }
    if ($secMap.ContainsKey($t)) { $section = $secMap[$t]; continue }
    # 内容行：可选数字标记 + 可选 ★ + C### + 其余
    $m = [regex]::Match($ln, '^\s*([123])?\s*(\u2605)?\s*C(\d+)\b')
    if (-not $m.Success) {
        # 围栏（``` / ~~~）忽略；"编号配方行"（`1.近战（排除…）+ …`）只提示、不展开 ——
        #   配方 = 槽位 + 候选集合 + 排除 + 条件 + 随机，当前池子格式（一档一串固定队伍）表达不了，
        #   落地方式待用户拍板（见文件头与 `5_选人策略.md` §现状⑤-3）。
        if ($t -match '^[`~]+$') { continue }
        # 【2026-09-23 新增】全局参数行：`@参数 圈宽=6 抖动=2`（也认 `@band 6` / `@jitter 2`，顺序随意、可只写一个）。
        #   认得出数值才生效；**一个都认不出就报警**（不静默忽略 —— 见 `5_选人策略.md` §现状⑤-6 的教训）。
        if ($t -match '^@') {
            $mb = [regex]::Match($t, '(圈宽|band)\s*[:：=]?\s*(\d+(?:\.\d+)?)')
            $mj = [regex]::Match($t, '(抖动|jitter)\s*[:：=]?\s*(\d+(?:\.\d+)?)')
            if ($mb.Success) { $pickBand = [double]$mb.Groups[2].Value }
            if ($mj.Success) { $pickJitter = [double]$mj.Groups[2].Value }
            if (-not $mb.Success -and -not $mj.Success) {
                Write-Host ('[人工池] !! 第 {0} 行参数认不出（应写成 `@参数 圈宽=6 抖动=2`）：{1}' -f $lineNo, $t)
            } else {
                $paramSeen = $true
                Write-Host ('[人工池] 参数（第 {0} 行）：圈宽 band={1} · 抖动 jitter={2}' -f $lineNo, $pickBand, $pickJitter)
            }
            continue
        }
        if ($t -match '^\d+\s*[.、]') {
            # 编号配方行 ⇒ 解析成"类型（配方）"，与固定队伍一起写进同一档（游戏端两种元素都认）
            try {
                $rec = Convert-SpecToRecipe $t $lineNo
                $recipes += [pscustomobject]@{ tier = $section; rec = $rec; line = $lineNo }
                Write-Host ('[人工池] 配方（第 {0} 行 → {1} 档）：{2} 槽 · 预设替补 {3} 名 / 多组 {4} 组 / 动态={5} · 权重 w={6}' -f `
                    $lineNo, $section, @($rec.slots).Count, @($rec.bench).Count, @($rec.bench_multi).Count, $rec.dynamic_bench, $rec.w)
            } catch {
                Write-Host ('[人工池] !! 第 {0} 行配方解析失败，已跳过：{1}' -f $lineNo, $_.Exception.Message)
            }
            continue
        }
        if ($section -eq '') { throw ('第 ' + $lineNo + ' 行出现在任何分区之前 ⇒ MD 结构不对') }
        $specs += [pscustomobject]@{ line = $lineNo; tier = $section; text = $t }
        continue
    }
    if ($section -eq '') { throw ('第 ' + $lineNo + ' 行出现在任何分区之前 ⇒ MD 结构不对') }
    $mark = $m.Groups[1].Value
    $star = $m.Groups[2].Success
    $idx = [int]$m.Groups[3].Value
    $tier = $section
    if ($mark -eq '1') { $tier = 'strong' }
    elseif ($mark -eq '2') { $tier = 'mid' }
    elseif ($mark -eq '3') { $tier = 'weak' }
    # 重写 MD 时要用的"去数字"原文：从 ★/C 开始整段保留（读数、箭头注释都不动），只统一行首缩进
    $tail = [regex]::Match($ln, '(\u2605)?\s*C\d+\b.*$').Value
    $raw = $(if ($star) { $tail } else { ' ' + $tail.TrimStart() })
    $items += [pscustomobject]@{ idx = $idx; tier = $tier; mark = $mark; star = $star; sec = $section; line = $lineNo; raw = $raw }
}

# ---------- 牌组按 idx 取 ----------
$candPath = Resolve-UnderRoot $CandFile
if (-not (Test-Path $candPath)) { throw ('找不到候选导出文件：' + $candPath) }
$cand = Get-Content $candPath -Raw -Encoding UTF8 | ConvertFrom-Json
# ⚠️ `_cands_pool3.json` 的候选**没有 idx 字段**：idx 口径 = candidates 数组的 1-based 序号
#   （与 `写队伍池_按拟合.ps1` 同一口径：车轮战的 C### = 导出顺序）。若日后加了 idx 字段则优先用它。
$deckByIdx = @{}
$pos = 0
foreach ($c in $cand.candidates) {
    $pos++
    $i0 = $pos
    if ($c.PSObject.Properties.Name -contains 'idx') { $i0 = [int]$c.idx }
    $deckByIdx[$i0] = @($c.deck)
}

# ---------- 组装三档（保持 MD 行序；模板行展开后插在该段末尾）----------
$tiers = [ordered]@{ weak = @(); mid = @(); strong = @() }
$seenDeck = @{}          # 去重键：牌组字符串（sorted）⇒ 同一支队只进一次
foreach ($it in $items) {
    if (-not $deckByIdx.ContainsKey($it.idx)) { throw ('候选表里没有 C{0:D3}（MD 第 {1} 行）' -f $it.idx, $it.line) }
    $dk = @($deckByIdx[$it.idx])
    $key = (@($dk | Sort-Object) -join ',')
    if ($seenDeck.ContainsKey($key)) { Write-Host ('[人工池] !! C{0:D3} 与前面某支重复（同三英雄）⇒ 跳过' -f $it.idx); continue }
    $seenDeck[$key] = $true
    $tiers[$it.tier] += , $dk
}
# 手写模板行 ⇒ 展开成具体队伍（全部组合）
$specMade = 0
foreach ($sp in $specs) {
    # ⚠️ 含「其中随机N人」的行**不落库**：那是"抽样"口径，池子文件必须是确定的
    #   （同一份 MD 重跑必须得到同一份池子）。要么改成列全部，要么定死抽样个数后再手工列。
    if ($sp.text -match '随机\s*\d+\s*人') {
        Write-Host ('[人工池] !! 第 {0} 行含「随机N人」⇒ 跳过不落库（抽样口径不确定，池子文件必须可复现）：' -f $sp.line)
        Write-Host ('         ' + $sp.text)
        continue
    }
    Write-Host ('[人工池] 展开模板（第 {0} 行 → {1} 档）：{2}' -f $sp.line, $sp.tier, $sp.text)
    $teams = @(Expand-Spec $sp.text)
    $added = 0
    foreach ($tm in $teams) {
        $team = @($tm.heroes)
        $key = (@($team | Sort-Object) -join ',')
        if ($seenDeck.ContainsKey($key)) { continue }
        $seenDeck[$key] = $true
        $tiers[$sp.tier] += , @($team)
        $added++
    }
    $specMade += $added
    $nmList = @($teams | Select-Object -First 3 | ForEach-Object { (@($_.heroes | ForEach-Object { $id2name[$_] }) -join '/') })
    Write-Host ('    生成 {0} 支（去重后新增 {1}）；例：{2}' -f @($teams).Count, $added, ($nmList -join ' · '))
}
if ($specs.Count -gt 0) { Write-Host ('[人工池] 模板行共 {0} 行 ⇒ 新增 {1} 支' -f $specs.Count, $specMade) }
# 配方（类型）⇒ 与固定队伍一起进同一档（元素是字典，游戏端 `_normalize_recipe()` 认）
foreach ($r in $recipes) {
    $tiers[$r.tier] += , $r.rec
}
if ($recipes.Count -gt 0) { Write-Host ('[人工池] 配方 {0} 条已并入对应档（强 {1} / 中 {2} / 弱 {3} 条）' -f $recipes.Count, @($recipes | Where-Object { $_.tier -eq 'strong' }).Count, @($recipes | Where-Object { $_.tier -eq 'mid' }).Count, @($recipes | Where-Object { $_.tier -eq 'weak' }).Count) }
# ⚠️ 安全网：**空档拒绝写盘**。池子空档在游戏里会走 `_load_pick_pool()` 的回退（= 与"没有池子"一样），
#   静默写出一份"强档为空"的池子，等于白跑一趟还可能被当成"已启用"。要故意写空档得显式 `-AllowEmptyTier`。
foreach ($t in @('weak', 'mid', 'strong')) {
    if (@($tiers[$t]).Count -eq 0 -and -not $AllowEmptyTier) {
        throw ('档 ' + $t + ' 一支队伍都没有（MD 里这一节现在没有可落库的内容？）⇒ 拒绝写盘。确实想写空档就加 -AllowEmptyTier')
    }
}
$uniq = @($items | ForEach-Object { $_.idx } | Sort-Object -Unique)
$nMark = @($items | Where-Object { $_.mark -ne '' }).Count
$nStar = @($items | Where-Object { $_.star }).Count
# ⚠️ `-f` 必须与字符串同一行（PS 5.1 换行后会当成新语句，踩过）
Write-Host ('[人工池] 读到 {0} 支固定队伍（唯一 {1}）+ {2} 条配方 · 强 {3} / 中 {4} / 弱 {5} · 带标记 {6} 支 · 带★ {7} 支' -f $items.Count, $uniq.Count, $recipes.Count, @($tiers.strong).Count, @($tiers.mid).Count, @($tiers.weak).Count, $nMark, $nStar)
if ($uniq.Count -ne $items.Count) { throw ('有重复编号：' + (($items | Group-Object idx | Where-Object { $_.Count -gt 1 } | ForEach-Object { 'C{0:D3}' -f [int]$_.Name }) -join ',')) }

# ---------- 写盘 ----------
$wi = Resolve-UnderRoot 'RL\weights\噩梦.json'
# 元素两种：固定队伍（hero_id 数组）与**配方（类型）**（字典）—— 游戏端 `_load_pick_pool()` 两种都认
# ⚠️ 必须用 `+= , (...)` 逐条追加：`$arr | ForEach-Object { @($_) }` 会被 PowerShell **拆平**
#   （固定队伍会散成一串 hero_id ⇒ 写出来的池子"每支队伍不足 3 人"，2026-09-22 踩过）。
function Pack-Tier($entries) {
    $out = @()
    foreach ($e in $entries) {
        if ($e -is [System.Collections.IDictionary]) { $out += , $e }
        else { $out += , @($e) }
    }
    return , $out
}
$pool = [ordered]@{
    _说明 = '标准单机敌方"队伍池"（**人工标注版 + 配方/类型 · 尚未启用**）。src/Battle.gd 的 _load_pick_pool() 按 GameState.ai_difficulty 取档：0=weak(弱) 1=mid(中) 2/3=strong(强)。⚠️ 档位键必须是 ASCII。要启用：把本文件复制成 RL\weights\队伍池.json（并删掉那份只读占位池）。'
    _口径 = '档位 = 人工标注（来源 `队伍池.md`）。档内可混两种元素：① **固定队伍** = hero_id 数组；② **配方（类型）** = 字典（`slots` 首发槽候选池 + 可选 `bench` 预设替补；没写 bench ⇒ 替补在需要时从全英雄池按局面挑）。含配方的档按"每场按 w 加权随机抽 1 条"处理（w 默认 1；MD 配方行尾写 ★数字 可调，见 5_选人策略.md §现状⑤-8）。槽位文字：含「随机」⇒ 整池均匀 / 含「根据」⇒ 按克制取最高分 / 其余 ⇒ band 上位圈随机。'
    _回退 = '删掉 RL\weights\队伍池.json 即可（立即回到"按评分加权随机组队"）。'
    meta = [ordered]@{
        生成时间 = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        引擎sha12 = (Get-FileHash (Join-Path $root 'RL\ai\AI_Battle.gd') -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
        权重sha12 = (Get-FileHash $wi -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
        排名口径 = ('人工标注（队伍池.md：C### 名单 + {0} 条配方）' -f $recipes.Count)
        # ★ 配方/候选挑人的"抖动"：一次克制 = 2.0 ⇒ 默认 2.0 ≈ 七成按分数、三成随缘（用户口径）
        # 【2026-09-23】改成读 MD 的 `@参数 …抖动=N`（没写 = 2.0 = 原值，行为不变）
        pick_jitter = $pickJitter
        # ★ 泛化槽（近战/远程/"随机1人"）的"上位圈宽度"：取"最高分 − pick_band"以内的候选随机。
        #   实测抖动撬不动（远程池最高分领先 1.9）⇒ 靠这个控制"敌人有多不固定"：0 = 永远最强，越大越随意。
        # 【2026-09-23】改成读 MD 的 `@参数 圈宽=N`（没写 = 3.0 = 原值；用户拍板恢复成 6）
        pick_band = $pickBand
        候选数 = @($items).Count; 配方数 = @($recipes).Count
        来源 = @((Split-Path -Leaf $mdPath))
    }
    weak = Pack-Tier $tiers.weak
    mid = Pack-Tier $tiers.mid
    strong = Pack-Tier $tiers.strong
}
$outPath = Resolve-UnderRoot $Out
[System.IO.File]::WriteAllText($outPath, ($pool | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('[人工池] 已写 ' + $outPath)

# ---------- 自检 ----------
$chk = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
$known = @{}
$rows = Get-Content (Join-Path $root 'Data\Hero\Source\角色列表.json') -Raw -Encoding UTF8 | ConvertFrom-Json
for ($i = 1; $i -lt $rows.Count; $i++) {
    $num = 0
    if ([int]::TryParse([string]$rows[$i][0], [ref]$num)) { $known['hero_{0:D2}' -f $num] = $true }
}
$nDeck = 0; $nRecipe = 0; $unknown = @()
foreach ($t in @('weak', 'mid', 'strong')) {
    if (-not ($chk.PSObject.Properties.Name -contains $t)) { throw ('池子写坏了：缺档位键 ' + $t) }
    foreach ($e in @($chk.$t)) {
        # ⚠️ 读回来的 JSON：固定队伍 = 数组；配方 = PSCustomObject（**不是** IDictionary）⇒ 用 `-is [System.Array]` 区分
        if (-not ($e -is [System.Array])) {
            $nRecipe++
            $slots = @($e.slots)
            if ($slots.Count -lt 1) { throw ('配方写坏了（档 ' + $t + '）：slots 为空') }
            foreach ($s in $slots) {
                # 槽位两种写法（读取端 `_normalize_recipe` 两种都认）：`{pool:[...]}` 或 `{fixed:"hero_xx"}`
                $names = @($s.PSObject.Properties.Name)
                $sid = @()
                if ($names -contains 'pool') { $sid = @($s.pool) }
                if ($names -contains 'fixed') { $sid += @([string]$s.fixed) }
                if ($sid.Count -lt 1) { throw ('配方写坏了（档 ' + $t + '）：某个槽位既没 pool 也没 fixed') }
                foreach ($h in $sid) {
                    if ([string]$h -eq '') { throw ('配方写坏了（档 ' + $t + '）：槽位里有空 hero_id') }
                    if (-not $known.ContainsKey([string]$h)) { $unknown += [string]$h }
                }
            }
            if ($e.PSObject.Properties.Name -contains 'bench') {
                foreach ($h in @($e.bench)) { if (-not $known.ContainsKey([string]$h)) { $unknown += [string]$h } }
            }
        } else {
            $nDeck++
            if (@($e).Count -lt 3) { throw ('池子写坏了：档 ' + $t + ' 里有固定队伍不足 3 人') }
            foreach ($h in @($e)) { if (-not $known.ContainsKey([string]$h)) { $unknown += [string]$h } }
        }
    }
}
if ($unknown.Count -gt 0) { throw ('池子写坏了：有 ' + $unknown.Count + ' 个 hero_id 不在角色列表里（例：' + $unknown[0] + '）') }
Write-Host ('[人工池] 自检通过：三个 ASCII 档位键都在 · 固定队伍 {0} 支（≥3 人）· 配方 {1} 条（槽位候选非空、hero_id 全部可解析）· pick_jitter={2} · pick_band={3}' -f $nDeck, $nRecipe, $pool.meta.pick_jitter, $pool.meta.pick_band)
# 【2026-09-23 新增】参数行没写就明说用了默认值（免得"以为改了 band"却一直跑在 3 上）
if (-not $paramSeen) {
    Write-Host ('[人工池] 参数：MD 里没写 `@参数` 行 ⇒ 用默认 圈宽 band={0} · 抖动 jitter={1}（想改就在 MD 任意一行写 `@参数 圈宽=6 抖动=2`）' -f $pool.meta.pick_band, $pool.meta.pick_jitter)
}

# ---------- 与旧候选池对照（只打印）----------
$cmpPath = Resolve-UnderRoot $CompareOld
if ($CompareOld -and (Test-Path $cmpPath)) {
    $old = Get-Content $cmpPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $oldTier = @{}
    foreach ($t in @('weak', 'mid', 'strong')) { foreach ($d in $old.$t) { $oldTier[(@($d) -join ',')] = $t } }
    $cn = @{ weak = '弱'; mid = '中'; strong = '强' }
    $moved = @()
    foreach ($t in @('weak', 'mid', 'strong')) {
        foreach ($d in $chk.$t) {
            $k = (@($d) -join ',')
            if ($oldTier.ContainsKey($k) -and $oldTier[$k] -ne $t) { $moved += ('{0}: {1} → {2}' -f $k, $cn[$oldTier[$k]], $cn[$t]) }
        }
    }
    Write-Host ('[人工池] 与旧候选池相比：档位变动 {0} 支' -f $moved.Count)
    $moved | ForEach-Object { Write-Host ('    ' + $_) }
}

# ---------- 可选：把 MD 重写成"去数字 + 按最终档位归位"的版本 ----------
if ($RewriteMd) {
    # 【2026-09-23 新增守卫】重写只按 `$items`（队伍行）拼，**配方行与 `@参数` 行都不在 $items 里** ⇒
    #   加了 -RewriteMd 会把 8 条配方连同 `★2` / 参数行一起从 MD 里删掉，而且行号一变配方 id（`R{行号}`）
    #   也跟着变（R04/R05 → 别的）。这是"会吃掉用户手写数据"的操作 ⇒ 直接拒绝，让他手工改或让我补全重写。
    if (@($recipes).Count -gt 0 -or $paramSeen) {
        throw ('本池子含配方行/参数行（{0} 条配方）⇒ 拒绝执行 -RewriteMd：重写会把它们从 MD 里删掉、并让配方 id 重新编号。要重排格式请手工改 MD，或让我把重写逻辑补全。' -f @($recipes).Count)
    }
    # 先备份带标注的原版（用户的标注是"决策记录"，不要只留在内存里）
    $bakDir = Join-Path $root 'RL\backups'
    New-Item -ItemType Directory -Force -Path $bakDir | Out-Null
    $bak = Join-Path $bakDir ('队伍池_标注版_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.md')
    Copy-Item -LiteralPath $mdPath -Destination $bak -Force
    Write-Host ('[人工池] 带标注的原版已备份 → ' + $bak)

    $tierName = [ordered]@{ strong = '强'; mid = '中'; weak = '弱' }
    $outLines = @()
    $outLines += '```'
    $first = $true
    foreach ($t in @('strong', 'mid', 'weak')) {
        if (-not $first) { $outLines += '' }      # 段间空行（与人工排版的观感一致）
        $first = $false
        $outLines += $tierName[$t]
        foreach ($it in @($items | Where-Object { $_.tier -eq $t })) { $outLines += $it.raw }
    }
    $outLines += '```'
    [System.IO.File]::WriteAllText($mdPath, (($outLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ('[人工池] MD 已重写（去数字、按最终档位归位）→ ' + $mdPath)
    foreach ($t in @('strong', 'mid', 'weak')) {
        Write-Host ('    {0}: {1} 支' -f $tierName[$t], @($items | Where-Object { $_.tier -eq $t }).Count)
    }
    # 幂等自检：重写后的文件再解析一次，档位应与本次完全一致、且行首再无数字
    $re = Get-Content $mdPath -Encoding UTF8
    $badDigits = @($re | Where-Object { $_ -match '^\s*[123]\s*(\u2605)?\s*C\d+' })
    if ($badDigits.Count -gt 0) { throw ('重写后仍残留带数字的行：' + $badDigits[0]) }
    $nTeams = @($re | Where-Object { $_ -match 'C\d+\b' }).Count
    if ($nTeams -ne $items.Count) { throw ('重写后队伍行数 {0} ≠ 解析到的 {1}' -f $nTeams, $items.Count) }
    Write-Host ('[人工池] MD 自检通过：无残留数字 · 队伍行 {0} 条' -f $nTeams)
}
