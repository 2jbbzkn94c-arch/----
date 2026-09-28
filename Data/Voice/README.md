# 配音管线（骨架 · 2026-09-28）

还没接进游戏（按约定先只搭管线）。三步走：

1. **写台词** → `Data/Voice/台词表.csv`（Excel 直接开；UTF-8 带 BOM，别另存成 ANSI）
2. **丢音频** → TTS 产出的原始文件放 `Data/Voice/源音频/`，**文件名 = 表里 `文件名` 列**（该列留空就用 `id`）
3. **整理** → 跑 `tools\配音整理.ps1` ⇒ 转出 `assets/audio/voice/*.ogg`（单声道 opus）+ 刷新 `Data/Voice/voice_index.json`

```
powershell -NoProfile -ExecutionPolicy Bypass -File tools\配音整理.ps1            # 正式跑
powershell -NoProfile -ExecutionPolicy Bypass -File tools\配音整理.ps1 -DryRun    # 只看缺哪几句，不转码不写索引
```
退出码：**0 = 全部就绪 · 2 = 有缺句**（可以串进批处理）。其它参数：`-Src`（源目录）· `-Out`（ogg 落地处，默认 `assets/audio/voice`）· `-BitrateK 48`（opus 码率）。

## 台词表各列

| 列 | 说明 |
|---|---|
| `id` | **唯一键**，代码里点播就用它（约定：`hero_XX_事件` / `common_事件`） |
| `英雄` | 英雄 id 或名字，只给人看 + 索引里带一份 |
| `事件` | 触发点（部署/普攻/技能/受击/残血/阵亡/击杀/胜利/失败…）—— 将来接战斗事件时按它对表 |
| `文本` | 台词原文（TTS 就读这一列） |
| `情绪` | 给 TTS 的提示词（嚣张/低沉/喘…），不参与游戏逻辑 |
| `音色` | 哪个声线（同一声线要一致，方便同一个 TTS 模型批量生成） |
| `文件名` | 对应音频的**文件名（不带扩展名）**；留空 = 用 `id` |

## 约定

- 成品音频统一 **ogg（opus 单声道 48k）** ⇒ 1 秒 ≈ 7 KB，几十句也就几百 KB。
- `Data/Voice/源音频/` 里有 `.gdignore`：**Godot 不扫描这个目录**，原始 wav 不会被打进游戏；`.gitignore` 里也已排除（大文件不进库）。
- 表里登记了但没音频 ⇒ 脚本会列出来并返回 2；目录里有音频但表里没登记 ⇒ 只提示，**不删**。
- Godot 侧还没接：下一步加 `autoload/VoiceBank.gd`（读 `voice_index.json` 点播）+ 战斗事件挂点 + 设置里"配音音量"滑条。
