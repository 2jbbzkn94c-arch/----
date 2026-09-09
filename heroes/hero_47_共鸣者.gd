extends HeroBase
## 共鸣者（hero_47）：己方回合开始时，攻击力增加所有队友攻击力之和，直到我方回合结束。
## 结算在 Battle._sync_echo（己方回合开始技前统一取样再赋值）；被沉默/眩晕时本回合不共鸣。
## 己方回合结束由 _clear_statuses 清 echo_set 复位。
class_name HeroEcho
