$ErrorActionPreference = "Stop"
Set-Location "D:\Game creating\战旗"
$T = [char]9
$LF = [char]10
$utf8 = New-Object System.Text.UTF8Encoding($false)
$fail = @()

function Apply($path, $old, $new, $tag) {
    $script:txt = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if (-not $script:txt.Contains($old)) { $script:fail += "$tag (锚点未找到)"; return }
    $script:txt = $script:txt.Replace($old, $new)
    [System.IO.File]::WriteAllText($path, $script:txt, (New-Object System.Text.UTF8Encoding($false)))
}

$fork = "RL\ai\AI_Battle.gd"

# 1) SimUnit 新增 echo_set
Apply $fork ($T + 'var atkdown := false') (@(
    ($T + '# 【RL 修正】共鸣者(hero_47)：快照带来的 echo_set（-1=未激活）。真实 effective_atk() 在'),
    ($T + '# echo_set >= 0 时**直接 return**（攻击力=队友攻击力之和，覆盖一切 buff/道具/被贴身），'),
    ($T + '# 所以 sim 侧要据此让「攻击道具 +1」不生效。'),
    ($T + 'var echo_set := -1'),
    ($T + 'var atkdown := false')
) -join $LF) "1-SimUnit.echo_set"

# 2) clone 复制
Apply $fork ($T+$T+$T + 'cu.atkdown = u.atkdown') (@(
    ($T+$T+$T + 'cu.echo_set = u.echo_set'),
    ($T+$T+$T + 'cu.atkdown = u.atkdown')
) -join $LF) "2-clone"

# 3) build_state 读取
Apply $fork ($T+$T + 'u.atkdown = bool(d.get("atkdown", false))') (@(
    ($T+$T + '# 【RL 修正】共鸣者的 echo 状态（src/BattleSnapshot.gd 新增该键；缺省 -1 = 未激活 = 改动前行为）'),
    ($T+$T + 'u.echo_set = int(d.get("echo_set", -1))'),
    ($T+$T + 'u.atkdown = bool(d.get("atkdown", false))')
) -join $LF) "3-build_state"

# 4) 捡攻击道具：echo 激活时不加进 eatk
Apply $fork (@(($T+$T+$T+$T+$T+$T + 'u.atk_use_buff += 1'), ($T+$T+$T+$T+$T+$T + 'u.eatk += 1')) -join $LF) (@(
    ($T+$T+$T+$T+$T+$T + 'u.atk_use_buff += 1'),
    ($T+$T+$T+$T+$T+$T + '# 【RL 修正】共鸣者 echo 激活时：真实 effective_atk() 直接 return echo 值，道具的 +1 不生效。'),
    ($T+$T+$T+$T+$T+$T + 'if u.echo_set < 0:'),
    ($T+$T+$T+$T+$T+$T+$T + 'u.eatk += 1')
) -join $LF) "4-pickup"

# 5) 消耗攻击道具：echo 激活时只清账
Apply $fork (@(
    ($T + 'if u == null or u.atk_use_buff <= 0:'),
    ($T+$T + 'return'),
    ($T + 'u.eatk = maxi(u.eatk - u.atk_use_buff, 0)')
) -join $LF) (@(
    ($T + 'if u == null or u.atk_use_buff <= 0:'),
    ($T+$T + 'return'),
    ($T + 'if u.echo_set >= 0:'),
    ($T+$T + '# 【RL 修正】echo 激活：这 +1 从未计入 eatk（真实 effective_atk 直接 return），只清账'),
    ($T+$T + 'u.atk_use_buff = 0'),
    ($T+$T + 'return'),
    ($T + 'u.eatk = maxi(u.eatk - u.atk_use_buff, 0)')
) -join $LF) "5-consume"

# 6) 风语者：另有风语者时本人也吃（真实 _another_windspeaker_exists）
Apply $fork (@(
    ($T + 'if moved_dist > 0:'),
    ($T+$T + 'for i in sim.units.size():'),
    ($T+$T+$T + 'var g: SimUnit = sim.units[i]'),
    ($T+$T+$T + 'if g == null or g == u or not g.alive or g.fn != u.fn:'),
    ($T+$T+$T+$T + 'continue'),
    ($T+$T+$T + 'if g.hero_id == "hero_43" and not g.silenced and not g.stunned:'),
    ($T+$T+$T+$T + 'u.hp = mini(u.hp + moved_dist, u.max_hp)'),
    ($T+$T+$T+$T + 'break')
) -join $LF) (@(
    ($T + '# 【RL 修正】场上是否另有风语者：真实 hero_43.on_ally_moved 只在「移动者是自己 且 没有别的风语者」'),
    ($T + '# 时才 return —— 有两个风语者时它们互为其他队友，**移动者本人也能回血**（实测矩阵抓到的那条）。'),
    ($T + 'var other_ws := false'),
    ($T + 'for i2 in sim.units.size():'),
    ($T+$T + 'var s2: SimUnit = sim.units[i2]'),
    ($T+$T + 'if s2 != null and s2 != u and s2.alive and s2.fn == u.fn and s2.hero_id == "hero_43":'),
    ($T+$T+$T + 'other_ws = true'),
    ($T+$T+$T + 'break'),
    ($T + 'if moved_dist > 0:'),
    ($T+$T + 'for i in sim.units.size():'),
    ($T+$T+$T + 'var g: SimUnit = sim.units[i]'),
    ($T+$T+$T + 'if g == null or g == u or not g.alive or g.fn != u.fn:'),
    ($T+$T+$T+$T + 'continue'),
    ($T+$T+$T + 'if g.hero_id == "hero_43" and not g.silenced and not g.stunned:'),
    ($T+$T+$T+$T + 'u.hp = mini(u.hp + moved_dist, u.max_hp)'),
    ($T+$T+$T+$T + 'break'),
    ($T+$T + '# 我自己就是风语者：另有风语者时本人也吃（与真实逐条对齐）'),
    ($T+$T + 'if other_ws and u.hero_id == "hero_43" and not u.silenced and not u.stunned:'),
    ($T+$T+$T + 'u.hp = mini(u.hp + moved_dist, u.max_hp)')
) -join $LF) "6-windspeaker"

$harness = "RL\harness\技能对拍.gd"
# 7) hero_43 那条场景复原（sim 已对齐真实规则）
Apply $harness ($T + 'if hid != "hero_43":') ($T + 'if true:   # sim 已对齐「另有风语者时本人也吃」，hero_43 自己那一遍也纳入') "7-scene43"
# 8) 新增共鸣者场景
Apply $harness ($T + 'if hid == "hero_35":') (@(
    ($T + 'if hid == "hero_47":'),
    ($T+$T + '# 【RL 修正】共鸣者：移动捡到攻击道具后出招 —— 真实 effective_atk() 在 echo 激活时直接 return，'),
    ($T+$T + '# 道具的 +1 **不生效**（修复前 sim 多算 1 点伤害：预测 14、实际 15）。'),
    ($T+$T + '# pre=begin 触发它自己的 on_side_turn_start，让 echo 生效后再做这一招。'),
    ($T+$T + 'out.append({ "scene": "带道具·共鸣者移动捡攻击", "fam": "ext", "hero": hid,'),
    ($T+$T+$T + '"units": [X2.duplicate(), A.duplicate(), D.duplicate()], "items": { C_NEAR: "atk" },'),
    ($T+$T+$T + '"act": { "by": 0, "move": C_NEAR, "atk": 2 }, "pre": "begin" })'),
    ($T + 'if hid == "hero_35":')
) -join $LF) "8-scene47"

if ($fail.Count -gt 0) { Write-Host ("替换失败: " + ($fail -join " / ")) } else { Write-Host "全部替换成功" }
Write-Host ("fork  sha12 = " + (Get-FileHash $fork -Algorithm SHA256).Hash.ToLower().Substring(0,12))
Write-Host ("技能对拍 sha12 = " + (Get-FileHash $harness -Algorithm SHA256).Hash.ToLower().Substring(0,12))
Write-Host ("echo_set 出现次数 = " + (Select-String -Path $fork -Pattern 'echo_set' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)
Write-Host ("other_ws 出现次数 = " + (Select-String -Path $fork -Pattern 'other_ws' -AllMatches | ForEach-Object { $_.Matches.Count } | Measure-Object -Sum).Sum)
