extends Node
## 卡组存储（全局自动加载）：保存/读取 3 个卡组，持久化到 user://，关闭游戏不丢。

const SAVE_PATH := "user://decks.cfg"
const SLOTS := [1, 2, 3]

var decks: Dictionary = {}   # slot -> Array[hero_id]
var deck_names: Dictionary = {}

func _ready() -> void:
	for s in SLOTS:
		decks[s] = []
		deck_names[s] = ""
	_load()

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	for s in SLOTS:
		var arr: Array = cfg.get_value("decks", "slot_%d" % s, [])
		var valid: Array = []
		for id in arr:
			if DataRegistry.get_hero(id) != null:
				valid.append(id)
		decks[s] = valid
		deck_names[s] = cfg.get_value("decks", "name_%d" % s, "")

func _save() -> void:
	var cfg := ConfigFile.new()
	for s in SLOTS:
		cfg.set_value("decks", "slot_%d" % s, decks[s])
		cfg.set_value("decks", "name_%d" % s, deck_names[s])
	var err := cfg.save(SAVE_PATH)
	if err != OK:
		print("卡组存档跳过（无法写入 user://）: ", err)

func save_deck(slot: int, ids: Array, deckname: String = "") -> void:
	if not decks.has(slot):
		return
	decks[slot] = ids.duplicate()
	deck_names[slot] = deckname
	_save()

func load_deck(slot: int) -> Array:
	return decks.get(slot, []).duplicate()

func has_deck(slot: int) -> bool:
	return decks.get(slot, []).size() > 0

func deck_name(slot: int) -> String:
	return deck_names.get(slot, "")
