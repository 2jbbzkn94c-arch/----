extends HeroBase
## 坠炮手（hero_45）：可攻击全场的任意目标，弹道无视障碍/单位/墓碑阻挡。
## 纯被动机制：全场射程(99)与"无视阻挡"由 Unit/Battle/BattleAI 按 hero_id 处理，
## 本脚本无需额外触发器（贴脸时仍吃远程限制：射程压 1、基础攻击压 1）。
class_name HeroMortar
