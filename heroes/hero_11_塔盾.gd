extends HeroBase
## 塔盾：每当相邻队友受到多于1点伤害时，代替承受其中1点。
## 由 Battle._bulwark_absorb 在伤害结算前主动减免（队友少受1、塔盾扣1），
## 此处不再于伤害后补救，避免"队友仍扣满 + 塔盾白扣"。
class_name HeroBulwark
