extends Control
## AIPlay demo：迷你菜地（放置游戏种子）。
## 演示三类接入：aiplay_label 元数据、aiplay_element/aiplay_hidden 组、
## AIPLAY_TOOLS 语义动作 + state/actions provider。

const GROW_TIME := 4.0
const BASE_PRICE := 10
const NUM_PLOTS := 3

const AIPLAY_TOOLS = {
	"plant": {"description": "在指定地块种下种子", "args": {"plot": "int", "seed": "string"}},
	"harvest": {"description": "收获指定地块", "args": {"plot": "int"}},
	"status": {"description": "查看农场状态", "args": {}},
	"reset": {"description": "把农场恢复到开局状态（仅供测试与演示）", "args": {}},
	"set_plot_disabled": {"description": "测试助手：把地块按钮置灰/恢复", "args": {"plot": "int", "disabled": "bool"}},
	"set_plot_visible": {"description": "测试助手：显示/隐藏地块按钮", "args": {"plot": "int", "vis": "bool"}},
}

var seeds := 5
var gold := 0
var harvested := 0
var plots: Array[Dictionary] = []

const INITIAL_SEEDS := 5

var _stats_label: Label
var _debug_label: Label
var _plot_box: HBoxContainer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_INHERIT
	_build_ui()
	add_to_group("aiplay_tools")
	for i in NUM_PLOTS:
		plots.append({"state": "empty", "t": 0.0, "seed": ""})
	var aiplay := get_node_or_null("/root/AIPlay")
	if aiplay != null:
		aiplay.register_state_provider(_aiplay_state)
		aiplay.register_actions_provider(_aiplay_actions)
		# 逃生舱默认关（aiplay/allow_call=false）。要用时再打开上面这行开关，
		# 并按下面这样逐条登记：方法名 → 允许被调的节点路径（"." 指场景根）
		# aiplay.register_callable("status", ".")


func _build_ui() -> void:
	var box := VBoxContainer.new()
	box.name = "RootBox"
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 16)
	add_child(box)

	var title := Label.new()
	title.text = "AIPlay Demo · 菜地"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_stats_label = Label.new()
	_stats_label.name = "StatsLabel"
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.add_to_group("aiplay_element")
	_stats_label.set_meta("aiplay_label", "农场状态")
	box.add_child(_stats_label)

	_plot_box = HBoxContainer.new()
	_plot_box.name = "PlotBox"
	_plot_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_plot_box.add_theme_constant_override("separation", 12)
	box.add_child(_plot_box)
	for i in NUM_PLOTS:
		var b := Button.new()
		b.name = "Plot%d" % i
		b.custom_minimum_size = Vector2(180, 90)
		b.pressed.connect(_on_plot_pressed.bind(i))
		_plot_box.add_child(b)

	_debug_label = Label.new()
	_debug_label.name = "DebugLabel"
	_debug_label.add_to_group("aiplay_hidden")
	_debug_label.text = "debug"
	box.add_child(_debug_label)


func _process(delta: float) -> void:
	for p in plots:
		if str(p["state"]) == "growing":
			p["t"] = float(p["t"]) + delta
			if float(p["t"]) >= GROW_TIME:
				p["state"] = "ripe"
	_refresh()


func _on_plot_pressed(idx: int) -> void:
	if idx < 0 or idx >= plots.size():
		return
	match str(plots[idx]["state"]):
		"empty":
			plant(idx, "radish")
		"ripe":
			harvest(idx)


func _refresh() -> void:
	if _stats_label == null:
		return
	_stats_label.text = "种子 %d · 金币 %d · 已收 %d" % [seeds, gold, harvested]
	if _plot_box != null:
		for i in _plot_box.get_child_count():
			var b := _plot_box.get_child(i) as Button
			if b == null:
				continue
			match str(plots[i]["state"]):
				"empty":
					b.text = "地块%d · 空（点我种）" % (i + 1)
				"growing":
					var pct := int(float(plots[i]["t"]) / GROW_TIME * 100.0)
					b.text = "地块%d · 生长 %d%%" % [i + 1, pct]
				"ripe":
					b.text = "地块%d · 已熟！收！" % (i + 1)
	if _debug_label != null:
		_debug_label.text = "debug frame=%d" % Engine.get_process_frames()


# ---------------------------------------------------------------------------
# 语义动作（AI 经 invoke / game_* 工具调用；人类玩家走按钮）
# ---------------------------------------------------------------------------

func plant(plot: int, seed: String) -> Dictionary:
	if plot < 0 or plot >= plots.size():
		return {"ok": false, "error": "bad plot"}
	if seeds <= 0:
		return {"ok": false, "error": "no seeds"}
	if str(plots[plot]["state"]) != "empty":
		return {"ok": false, "error": "plot not empty"}
	seeds -= 1
	plots[plot]["state"] = "growing"
	plots[plot]["t"] = 0.0
	plots[plot]["seed"] = seed
	return {"ok": true, "plot": plot, "seed": seed}


func harvest(plot: int) -> int:
	if plot < 0 or plot >= plots.size():
		return -1
	if str(plots[plot]["state"]) != "ripe":
		return -1
	var price := BASE_PRICE + plot * 2
	gold += price
	seeds += 1
	harvested += 1
	plots[plot]["state"] = "empty"
	plots[plot]["t"] = 0.0
	plots[plot]["seed"] = ""
	return price


func status() -> Dictionary:
	return _aiplay_state()


## 测试助手：让"点了会推进状态"的按钮进入不可点状态，
## 用来验证 click 与真人同权（disabled / 不可见都拒绝）。
func set_plot_disabled(plot: int, disabled: bool) -> Dictionary:
	if plot < 0 or _plot_box == null or plot >= _plot_box.get_child_count():
		return {"ok": false, "error": "bad plot"}
	var b := _plot_box.get_child(plot) as Button
	if b == null:
		return {"ok": false, "error": "not a button"}
	b.disabled = disabled
	return {"ok": true, "plot": plot, "disabled": disabled}


func set_plot_visible(plot: int, vis: bool) -> Dictionary:
	if plot < 0 or _plot_box == null or plot >= _plot_box.get_child_count():
		return {"ok": false, "error": "bad plot"}
	var b := _plot_box.get_child(plot) as Button
	if b == null:
		return {"ok": false, "error": "not a button"}
	b.visible = vis
	return {"ok": true, "plot": plot, "visible": vis}


## 把整块地恢复到开局状态。测试套件靠它自清理，
## 否则验收基线只在"第一次跑"时成立。
func reset() -> Dictionary:
	seeds = INITIAL_SEEDS
	gold = 0
	harvested = 0
	for i in plots.size():
		plots[i] = {"state": "empty", "t": 0.0, "seed": ""}
	_reset_ui_flags()
	_refresh()
	return {"ok": true, "reset": true}


func _reset_ui_flags() -> void:
	if _plot_box == null:
		return
	for i in _plot_box.get_child_count():
		var b := _plot_box.get_child(i) as Button
		if b == null:
			continue
		b.visible = true
		b.disabled = false


# ---------------------------------------------------------------------------
# providers：喂给快照 game 字段与 actions 方法
# ---------------------------------------------------------------------------

func _aiplay_state() -> Dictionary:
	var ps: Array = []
	for i in plots.size():
		var p: Dictionary = plots[i]
		var st := str(p["state"])
		var progress := 0.0
		if st == "growing":
			progress = minf(float(p["t"]) / GROW_TIME, 1.0)
		elif st == "ripe":
			progress = 1.0
		ps.append({
			"plot": i,
			"state": st,
			"progress": progress,
			"seed": str(p["seed"]),
		})
	# 平铺键：wait_until 只能断言 game 顶层键，给每块地一个可断言的进度
	var flat := {}
	for i in plots.size():
		var p: Dictionary = plots[i]
		var st := str(p["state"])
		var pr := 0.0
		if st == "growing":
			pr = minf(float(p["t"]) / GROW_TIME, 1.0)
		elif st == "ripe":
			pr = 1.0
		flat["plot%d_state" % i] = st
		flat["plot%d_progress" % i] = pr
	var out := {"gold": gold, "seeds": seeds, "harvested": harvested, "plots": ps}
	out.merge(flat)
	return out


func _aiplay_actions() -> Array:
	var acts: Array = []
	for i in plots.size():
		var st := str(plots[i]["state"])
		if st == "empty" and seeds > 0:
			acts.append({"action": "plant", "plot": i, "seed": "radish"})
		elif st == "ripe":
			acts.append({"action": "harvest", "plot": i})
	return acts
