# 修复:格式化字符串 emit("...%d..." % [...]) 引号错位
# 策略:对每个 log_message/action_info.emit(...) 且参数含 '%' 的行,
#  规范化格式:字符串为一个引号包裹的格式串,真正的 '%' 运算符在引号外。
# 直接按 probe2 推导的正确原文替换(丢字处按可见残留还原/保留)。
$ErrorActionPreference='Stop'
$src='D:\Game creating\战旗\src'
$p="$src\Battle.gd"
$txt=[System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8)

# 精确替换表:(查找唯一旧文本 → 新文本)
$fix=@(
@('log_message.emit("竞技场选人完成：我%d 名，敌方" %d 名% [GameState.player_deck.size(), GameState.enemy_deck.size()])',
  'log_message.emit("竞技场选人完成：我方 %d 名，敌方 %d 名。" % [GameState.player_deck.size(), GameState.enemy_deck.size()])'),
@('action_info.emit("竞技场选人（第" %d/%d 轮，你的回合）：从两名英雄中1 名加入你的队伍% [_arena_player_rounds + 1, ARENA_PICKS_PER_SIDE])',
  'action_info.emit("竞技场选人（第 %d/%d 轮，你的回合）：从两名英雄中选择 1 名加入你的队伍。" % [_arena_player_rounds + 1, ARENA_PICKS_PER_SIDE])'),
@('log_message.emit("敌方选择%ss 归你% [DataRegistry.get_hero(en_hid").display_name, DataRegistry.get_hero(give_player).display_name])',
  'log_message.emit("敌方选择了 %s，%s 归你。" % [DataRegistry.get_hero(en_hid).display_name, DataRegistry.get_hero(give_player).display_name])'),
@('log_message.emit("你选择%s。敌方获%s% [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(_arena_enemy.back()).display_name if _arena_enemy.size() > 0 else "])',
  'log_message.emit("你选择了 %s。敌方获得了 %s。" % [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(_arena_enemy.back()).display_name if _arena_enemy.size() > 0 else ""])'),
@('action_info.emit("竞技场选卡（第" %d/%d 轮）：从两张中1 张留下，另一张将送给对方% [_oa_round + 1, ARENA_PICKS_PER_SIDE])',
  'action_info.emit("竞技场选卡（第 %d/%d 轮）：从两张中选择 1 张留下，另一张将送给对方。" % [_oa_round + 1, ARENA_PICKS_PER_SIDE])'),
@('log_message.emit("你留下了" %s，s」将送给对方% [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(gift).display_name])',
  'log_message.emit("你留下了 %s，%s」将送给对方。" % [DataRegistry.get_hero(hid).display_name, DataRegistry.get_hero(gift).display_name])'),
@('log_message.emit("竞技场选卡完成：我%d / 敌方" %d 名，开始部署% [GameState.player_deck.size(), GameState.enemy_deck.size()])',
  'log_message.emit("竞技场选卡完成：我方 %d 名 / 敌方 %d 名，开始部署。" % [GameState.player_deck.size(), GameState.enemy_deck.size()])'),
@('log_message.emit("双方各上3 名英雄，另有" %d / %d 名替补待命% [player_roster.size(), enemy_roster.size()])',
  'log_message.emit("双方各上 %d 名英雄，另有 %d / %d 名替补待命。" % [player_roster.size(), enemy_roster.size()])'),
@('log_message.emit("%s 在空地放置了" %d 个增益道具% [u.display_name, placed])',
  'log_message.emit("%s 在空地放置了 %d 个增益道具。" % [u.display_name, placed])'),
@('log_message.emit("%s" %s 丢下一块金矿% [u.display_name, str(c)])',
  'log_message.emit("%s 在 %s 丢下一块金矿。" % [u.display_name, str(c)])'),
@('action_info.emit("你的回合（第" %d 回合）：点击一名己方英雄% GameState.round_number)',
  'action_info.emit("你的回合（第 %d 回合）：点击一名己方英雄。" % GameState.round_number)'),
@('log_message.emit("%s 受到[猛毒"] 1 点伤害% u.display_name)',
  'log_message.emit("%s 受到[猛毒] 1 点伤害。" % u.display_name)'),
@('log_message.emit("双方都阵亡达" %d 名，同归于尽——但判本端获胜（对方负）% LOSS_DEATH_COUNT)',
  'log_message.emit("双方都阵亡达 %d 名，同归于尽——但判本端获胜（对方负）。" % LOSS_DEATH_COUNT)'),
@('log_message.emit("败北……我方英雄阵亡达" %d 名% LOSS_DEATH_COUNT)',
  'log_message.emit("败北……我方英雄阵亡达 %d 名。" % LOSS_DEATH_COUNT)'),
@('log_message.emit("胜利！敌方英雄阵亡达" %d 名% LOSS_DEATH_COUNT)',
  'log_message.emit("胜利！敌方英雄阵亡达 %d 名。" % LOSS_DEATH_COUNT)'),
@('action_info.emit("%s 本回合已完成（移动、攻击各一次）% clicked_unit.display_name")',
  'action_info.emit("%s 本回合已完成（移动、攻击各一次）。" % clicked_unit.display_name)'),
@('action_info.emit("%s（敌方）HP" %d 攻击 %d · 可移可攻% [u.display_name, u.hp, u.effective_atk()])',
  'action_info.emit("%s（敌方）HP %d 攻击 %d · 可移动可攻击。" % [u.display_name, u.hp, u.effective_atk()])'),
@('log_message.emit("%s 攻击障碍物% u.display_name")',
  'log_message.emit("%s 攻击障碍物。" % u.display_name)'),
@('log_message.emit("%s 踩中炸弹% u.display_name")',
  'log_message.emit("%s 踩中炸弹！" % u.display_name)'),
@('log_message.emit("%s 移动" %d 格，风语者令其回%d 点生命% [u.display_name, u.last_move_dist, u.last_move_dist])',
  'log_message.emit("%s 移动 %d 格，风语者令其回复 %d 点生命。" % [u.display_name, u.last_move_dist, u.last_move_dist])'),
@('log_message.emit("%s 拾取攻击道具：下一次攻+1% u.display_name")',
  'log_message.emit("%s 拾取攻击道具：下一次攻击 +1。" % u.display_name)'),
@('log_message.emit("%s 拾取移动道具：下一次移动力 +1% u.display_name")',
  'log_message.emit("%s 拾取移动道具：下一次移动力 +1。" % u.display_name)'),
@('log_message.emit("%s 拾取回血道具，恢%d 点生命！" % [u.display_name, g])',
  'log_message.emit("%s 拾取回血道具，恢复 %d 点生命！" % [u.display_name, g])'),
@('log_message.emit("%s 拾取护盾道具，获得[圣盾"]% u.display_name)',
  'log_message.emit("%s 拾取护盾道具，获得[圣盾]。" % u.display_name)'),
@('log_message.emit("%s 拾取金矿！攻1、血量上3% u.display_name")',
  'log_message.emit("%s 拾取金矿！攻击 +1、血量上限 +3。" % u.display_name)'),
@('log_message.emit("%s 攻击" %s% [attacker.display_name, target.display_name])',
  'log_message.emit("%s 攻击 %s。" % [attacker.display_name, target.display_name])'),
@('log_message.emit("%s 反击" %s，造成 %d 伤害% [counterer.display_name, attacker.display_name, cdmg])',
  'log_message.emit("%s 反击 %s，造成 %d 伤害。" % [counterer.display_name, attacker.display_name, cdmg])'),
@('log_message.emit("%s 的塔盾代替承1 点伤害% s.display_name")',
  'log_message.emit("%s 的塔盾代替承受 1 点伤害。" % s.display_name)'),
@('log_message.emit("%s 获得[%s"]% [u.display_name, label])',
  'log_message.emit("%s 获得[%s]。" % [u.display_name, label])'),
@('action_info.emit("%s：选择一处空地放置炸弹% u.display_name")',
  'action_info.emit("%s：选择一处空地放置炸弹。" % u.display_name)'),
@('log_message.emit("%s" %s 放置了炸弹% [u.display_name, str(cell)])',
  'log_message.emit("%s 在 %s 放置了炸弹。" % [u.display_name, str(cell)])'),
@('log_message.emit("血锁把" %s 拉到面前s）% [target.display_name, str(best)])',
  'log_message.emit("血锁把 %s 拉到面前（%s）。" % [target.display_name, str(best)])'),
@('log_message.emit("%s 变身%s% [u.display_name", def.display_name])',
  'log_message.emit("%s 变身 %s。" % [u.display_name, def.display_name])'),
@('log_message.emit("%s 阵亡% u.display_name")',
  'log_message.emit("%s 阵亡。" % u.display_name)'),
@('action_info.emit("选择" %s 的登场位置（绿格=出生地，土黄本方阵亡墓碑处）% DataRegistry.get_hero(hero_id).display_name)',
  'action_info.emit("选择 %s 的登场位置（绿格=出生地，土黄色=本方阵亡墓碑处）。" % DataRegistry.get_hero(hero_id).display_name)'),
@('log_message.emit("替补登场s% DataRegistry.get_hero(hero_id").display_name)',
  'log_message.emit("替补登场：%s。" % DataRegistry.get_hero(hero_id).display_name)'),
@('log_message.emit("%s 被主动撤下（视为阵亡）% u.display_name")',
  'log_message.emit("%s 被主动撤下（视为阵亡）。" % u.display_name)'),
@('log_message.emit("%s 替补登场s）% [def.display_name, "我方" if side == DataRegistry.Faction.PLAYER else "敌方""])',
  'log_message.emit("%s 替补登场（%s）。" % [def.display_name, "我方" if side == DataRegistry.Faction.PLAYER else "敌方"])')
)
$n=0
foreach($f in $fix){
  if($txt.Contains($f[0])){
    $txt=$txt.Replace($f[0],$f[1]); $n++
  } else {
    Write-Output ("NOT FOUND: "+$f[0].Substring(0,[Math]::Min(60,$f[0].Length)))
  }
}
[System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("fixed "+$n+" lines")