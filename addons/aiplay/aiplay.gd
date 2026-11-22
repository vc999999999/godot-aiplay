extends Node
## AIPlay 运行时层（协议版本 aiplay/0.2）
##
## 随游戏导出：起本地 WebSocket 服务（仅 127.0.0.1）、导出状态快照、
## 执行语义动作。协议正文见仓库 PROTOCOL.md，本文件是其参考实现。
##
## 游戏侧接入（开发者）：
##   - 元素标注：关键控件 set_meta("aiplay_label", "名字")；
##     组 aiplay_element / aiplay_hidden 声明谁进快照、谁排除；
##   - AIPlay.register_state_provider(callable) → Dictionary 进快照 game 字段；
##   - AIPlay.register_actions_provider(callable) → Array 供 actions 方法；
##   - 节点加入组 aiplay_tools 并声明 const AIPLAY_TOOLS = {...}。
## 注意：插件可能未启用，游戏代码请用 get_node_or_null("/root/AIPlay") 判空后调用，
## 不要直接写 AIPlay. 标识符（autoload 缺失会导致脚本编译失败）。

const PROTOCOL_VERSION := "aiplay/0.2"
const DEFAULT_PORT := 8765
const MAX_ELEMENTS := 60
const MAX_GAME_DICT_BYTES := 4096
const MAX_WAIT_UNTIL_CONDITIONS := 3
const MIN_TIME_SCALE := 0.1
const MAX_TIME_SCALE := 20.0
const WAIT_UNTIL_DEFAULT_FRAMES := 3600

const SETTING_ENABLED := "aiplay/enabled"
const SETTING_PORT := "aiplay/port"

const CALL_BLOCKED_METHODS := ["free", "queue_free", "exit_tree"]

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _listening := false
var _port := -1

var _state_provider := Callable()
var _actions_provider := Callable()

var _pending_waits: Array[Dictionary] = []
var _pending_untils: Array[Dictionary] = []
var _phys_frame := 0

var _and_re: RegEx
var _cond_re: RegEx


func _init() -> void:
	_and_re = RegEx.new()
	_and_re.compile("(?i)\\s+and\\s+")
	_cond_re = RegEx.new()
	_cond_re.compile("^\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*(==|!=|>=|<=|>|<)\\s*(.+?)\\s*$")


func _ready() -> void:
	# 常开：暂停中的游戏也要能被 AI 观察与操作（它是开发工具，不是玩法逻辑）
	process_mode = Node.PROCESS_MODE_ALWAYS
	var port_override := _cli_value("--aiplay-port")
	if port_override != "":
		_port = int(port_override)
	if _cli_flag("--aiplay") or bool(ProjectSettings.get_setting(SETTING_ENABLED, false)):
		start_server()


func _exit_tree() -> void:
	stop_server()


# ---------------------------------------------------------------------------
# 服务生命周期
# ---------------------------------------------------------------------------

func start_server() -> void:
	if _listening:
		return
	var port := _resolve_port()
	var err := _tcp.listen(port, "127.0.0.1")
	if err != OK:
		push_error("AIPlay: cannot listen on 127.0.0.1:%d (error %d)" % [port, err])
		return
	_listening = true
	print("AIPlay: listening on ws://127.0.0.1:%d (protocol %s)" % [port, PROTOCOL_VERSION])


func stop_server() -> void:
	for peer in _peers:
		peer.close()
	_peers.clear()
	_pending_waits.clear()
	_pending_untils.clear()
	if _listening:
		_tcp.stop()
		_listening = false


func is_running() -> bool:
	return _listening


func _resolve_port() -> int:
	if _port > 0:
		return _port
	return int(ProjectSettings.get_setting(SETTING_PORT, DEFAULT_PORT))


func _cli_flag(name: String) -> bool:
	return OS.get_cmdline_user_args().has(name)


func _cli_value(name: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(name + "="):
			return arg.substr(name.length() + 1)
	return ""


# ---------------------------------------------------------------------------
# 游戏侧注册 API
# ---------------------------------------------------------------------------

func register_state_provider(provider: Callable) -> void:
	_state_provider = provider


func register_actions_provider(provider: Callable) -> void:
	_actions_provider = provider


func clear_state_provider() -> void:
	_state_provider = Callable()


func clear_actions_provider() -> void:
	_actions_provider = Callable()


# ---------------------------------------------------------------------------
# 网络循环
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _listening:
		return
	while _tcp.is_connection_available():
		var peer := WebSocketPeer.new()
		peer.accept_stream(_tcp.take_connection())
		_peers.append(peer)
	var i := _peers.size() - 1
	while i >= 0:
		var peer := _peers[i]
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_peers.remove_at(i)
		elif state == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				_handle_packet(peer, peer.get_packet().get_string_from_utf8())
		i -= 1


func _physics_process(_delta: float) -> void:
	_phys_frame += 1
	_tick_waits()
	_tick_untils()


func _handle_packet(peer: WebSocketPeer, text: String) -> void:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_send(peer, {"id": null, "ok": false, "error": "invalid JSON message"})
		return
	var msg: Dictionary = parsed
	var id: Variant = msg.get("id")
	var method := str(msg.get("method", ""))
	if method.is_empty():
		_respond_error(peer, id, "missing 'method'")
		return
	_dispatch(peer, id, method, msg.get("params", {}))


func _dispatch(peer: WebSocketPeer, id: Variant, method: String, params: Variant) -> void:
	match method:
		"ping":
			_respond(peer, id, _m_ping())
		"state":
			_respond(peer, id, _build_snapshot())
		"actions":
			_respond(peer, id, {"actions": _m_actions()})
		"tools":
			_respond(peer, id, {"tools": _m_tools()})
		"invoke":
			_m_invoke(peer, id, params)
		"click":
			_m_click(peer, id, params)
		"press":
			_m_press(peer, id, params)
		"key":
			_m_key(peer, id, params)
		"call":
			_m_call(peer, id, params)
		"wait":
			_m_wait(peer, id, params)
		"wait_until":
			_m_wait_until(peer, id, params)
		"time_scale":
			_m_time_scale(peer, id, params)
		_:
			_respond_error(peer, id, "unknown method: " + method)


func _respond(peer: WebSocketPeer, id: Variant, result: Variant) -> void:
	_send(peer, {"id": id, "ok": true, "result": result})


func _respond_error(peer: WebSocketPeer, id: Variant, err: String) -> void:
	_send(peer, {"id": id, "ok": false, "error": err})


func _send(peer: WebSocketPeer, msg: Dictionary) -> void:
	if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(msg))


func _params_dict(params: Variant) -> Dictionary:
	if params is Dictionary:
		return params
	return {}


# ---------------------------------------------------------------------------
# 只读方法
# ---------------------------------------------------------------------------

func _m_ping() -> Dictionary:
	return {
		"protocol": PROTOCOL_VERSION,
		"game": str(ProjectSettings.get_setting("application/config/name", "")),
		"engine": str(Engine.get_version_info().get("string", "")),
	}


func _build_snapshot() -> Dictionary:
	var scene := get_tree().current_scene
	var truncated_parts: Array[String] = []

	var elements: Array = []
	var element_total := 0
	if scene != null:
		var nodes := _find_elements()
		element_total = nodes.size()
		for i in mini(element_total, MAX_ELEMENTS):
			elements.append(_element_entry(nodes[i], scene))
		if element_total > MAX_ELEMENTS:
			truncated_parts.append("elements %d>%d" % [element_total, MAX_ELEMENTS])

	var game := _game_state()
	var fitted := _fit_game_dict(game)
	if bool(fitted["truncated"]):
		truncated_parts.append("game dict truncated to <=%d bytes" % MAX_GAME_DICT_BYTES)

	var snap := {
		"scene": "" if scene == null else str(scene.name),
		"game": fitted["data"],
		"elements": elements,
		"truncated": not truncated_parts.is_empty(),
	}
	if not truncated_parts.is_empty():
		snap["truncated_note"] = "; ".join(PackedStringArray(truncated_parts))
	return snap


func _game_state() -> Dictionary:
	if not _state_provider.is_valid():
		return {}
	var r: Variant = _state_provider.call()
	if r is Dictionary:
		return r
	return {}


func _find_elements() -> Array[Node]:
	var out: Array[Node] = []
	var scene := get_tree().current_scene
	if scene == null:
		return out
	var candidates := scene.find_children("*", "Control", true, false)
	for c in candidates:
		var node := c as Control
		if node == null or not node.is_visible_in_tree():
			continue
		if _is_hidden(node, scene):
			continue
		if node is BaseButton or node.is_in_group("aiplay_element"):
			out.append(node)
	return out


func _is_hidden(node: Node, stop_at: Node = null) -> bool:
	var n: Node = node
	while n != null:
		if n.is_in_group("aiplay_hidden"):
			return true
		if stop_at != null and n == stop_at:
			break
		n = n.get_parent()
	return false


func _element_id(node: Node, scene: Node) -> String:
	var rel := str(scene.get_path_to(node))
	if rel == ".":
		return "/" + str(scene.name)
	return "/" + str(scene.name) + "/" + rel


func _element_label(node: Node) -> String:
	if node.has_meta("aiplay_label"):
		var meta: Variant = node.get_meta("aiplay_label")
		if meta is String and not (meta as String).is_empty():
			return meta
	if node is BaseButton:
		var text: String = (node as BaseButton).text
		if not text.is_empty():
			return text
	return node.name


func _element_entry(node: Node, scene: Node) -> Dictionary:
	var disabled := false
	var tooltip := ""
	if node is BaseButton:
		disabled = (node as BaseButton).disabled
		tooltip = (node as BaseButton).tooltip_text
	var entry := {
		"id": _element_id(node, scene),
		"type": node.get_class(),
		"label": _element_label(node),
		"disabled": disabled,
	}
	if not tooltip.is_empty():
		entry["tooltip"] = tooltip
	return entry


func _fit_game_dict(game: Dictionary) -> Dictionary:
	var g: Dictionary = game.duplicate(true)
	if JSON.stringify(g).to_utf8_buffer().size() <= MAX_GAME_DICT_BYTES:
		return {"data": g, "truncated": false}
	for limit in [512, 128, 32, 8]:
		_truncate_strings(g, limit)
		if JSON.stringify(g).to_utf8_buffer().size() <= MAX_GAME_DICT_BYTES:
			return {"data": g, "truncated": true}
	return {"data": {}, "truncated": true}


func _truncate_strings(v: Variant, limit: int) -> void:
	if v is Dictionary:
		for k in v.keys():
			var val: Variant = v[k]
			if val is String:
				if val.length() > limit:
					v[k] = val.substr(0, limit) + "..."
			else:
				_truncate_strings(val, limit)
	elif v is Array:
		for i in v.size():
			var val: Variant = v[i]
			if val is String:
				if val.length() > limit:
					v[i] = val.substr(0, limit) + "..."
			else:
				_truncate_strings(val, limit)


func _m_actions() -> Array:
	if _actions_provider.is_valid():
		var r: Variant = _actions_provider.call()
		if r is Array:
			return r
	var scene := get_tree().current_scene
	var acts: Array = []
	if scene != null:
		for node in _find_elements():
			if node is BaseButton and not (node as BaseButton).disabled:
				acts.append({
					"id": _element_id(node, scene),
					"label": _element_label(node),
					"action": "click",
				})
	return acts


func _m_tools() -> Array:
	var tools: Array = []
	for node in get_tree().get_nodes_in_group("aiplay_tools"):
		var decl := _read_aiplay_tools(node)
		for k in decl.keys():
			var spec: Variant = decl[k]
			if not (spec is Dictionary):
				continue
			var s: Dictionary = spec
			tools.append({
				"name": "game_" + str(k),
				"method": str(k),
				"description": str(s.get("description", "")),
				"args": s.get("args", {}),
			})
	return tools


func _read_aiplay_tools(node: Node) -> Dictionary:
	var script := node.get_script() as Script
	if script == null:
		return {}
	var consts := script.get_script_constant_map()
	var decl: Variant = consts.get(&"AIPLAY_TOOLS", consts.get("AIPLAY_TOOLS", {}))
	if decl is Dictionary:
		return decl
	return {}


# ---------------------------------------------------------------------------
# 动作方法
# ---------------------------------------------------------------------------

func _m_invoke(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var tool := str(p.get("tool", p.get("name", "")))
	if not tool.begins_with("game_"):
		_respond_error(peer, id, "invoke requires a game_* tool name")
		return
	var method := tool.substr(5)
	var raw_args: Variant = p.get("args", {})
	var args: Dictionary = raw_args if raw_args is Dictionary else {}
	var found := _find_tool(method)
	if found.is_empty():
		_respond_error(peer, id, "unknown tool: " + tool)
		return
	var node: Node = found["node"]
	var spec: Dictionary = found["spec"]
	if not node.has_method(method):
		_respond_error(peer, id, "tool method missing on node: " + method)
		return
	var built := _build_call_args(spec, args)
	if not bool(built["ok"]):
		_respond_error(peer, id, str(built["error"]))
		return
	var result: Variant = node.callv(method, built["args"])
	_respond(peer, id, {"result": _jsonable(result), "state": _build_snapshot()})


func _find_tool(method: String) -> Dictionary:
	for node in get_tree().get_nodes_in_group("aiplay_tools"):
		var decl := _read_aiplay_tools(node)
		for k in decl.keys():
			if str(k) != method:
				continue
			var spec: Variant = decl[k]
			if spec is Dictionary:
				return {"node": node, "spec": spec}
	return {}


func _build_call_args(spec: Dictionary, args: Dictionary) -> Dictionary:
	var out := {"ok": true, "args": [], "error": ""}
	var arg_spec := spec.get("args", {})
	if not (arg_spec is Dictionary):
		return out
	var decl: Dictionary = arg_spec
	if decl.is_empty():
		return out
	var call_args: Array = []
	for pname in decl.keys():
		var ptype := str(decl[pname])
		if not args.has(pname):
			out["ok"] = false
			out["error"] = "missing arg: " + str(pname)
			return out
		var coerced := _coerce_arg(args[pname], ptype)
		if not bool(coerced["ok"]):
			out["ok"] = false
			out["error"] = "bad arg '%s': expected %s" % [pname, ptype]
			return out
		call_args.append(coerced["value"])
	out["args"] = call_args
	return out


func _coerce_arg(v: Variant, ptype: String) -> Dictionary:
	if v == null:
		return {"ok": false, "value": null}
	match ptype:
		"int":
			if v is int:
				return {"ok": true, "value": v}
			if v is float:
				if v == floorf(v):
					return {"ok": true, "value": int(v)}
				return {"ok": false, "value": null}
			if v is bool:
				return {"ok": true, "value": int(v)}
			if v is String and v.is_valid_int():
				return {"ok": true, "value": v.to_int()}
			return {"ok": false, "value": null}
		"float":
			if v is int or v is float:
				return {"ok": true, "value": float(v)}
			if v is bool:
				return {"ok": true, "value": 1.0 if v else 0.0}
			if v is String and v.is_valid_float():
				return {"ok": true, "value": v.to_float()}
			return {"ok": false, "value": null}
		"string":
			return {"ok": true, "value": str(v)}
		"bool":
			var b := _bool_or_null(v)
			if b == null:
				return {"ok": false, "value": null}
			return {"ok": true, "value": b}
		_:
			return {"ok": true, "value": v}
	return {"ok": false, "value": null}


func _m_click(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var ref := str(p.get("id", p.get("element", p.get("path", ""))))
	var node := _resolve_node(ref)
	if node == null:
		_respond_error(peer, id, "element not found: " + ref)
		return
	if _is_hidden(node):
		_respond_error(peer, id, "element is hidden: " + ref)
		return
	if not (node is BaseButton):
		_respond_error(peer, id, "element is not clickable: " + ref)
		return
	(node as BaseButton).pressed.emit()
	_respond(peer, id, {"clicked": ref, "state": _build_snapshot()})


func _m_press(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var action := str(p.get("action", ""))
	if action.is_empty():
		_respond_error(peer, id, "press requires 'action'")
		return
	var pressed := bool(p.get("pressed", true))
	if pressed:
		Input.action_press(action)
	else:
		Input.action_release(action)
	_respond(peer, id, {"action": action, "pressed": pressed, "state": _build_snapshot()})


func _m_key(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var keycode := _parse_key(p)
	if keycode == 0:
		_respond_error(peer, id, "key requires 'key' name or 'keycode' int")
		return
	var ev := InputEventKey.new()
	ev.keycode = keycode as Key
	ev.physical_keycode = keycode as Key
	ev.pressed = bool(p.get("pressed", true))
	Input.parse_input_event(ev)
	_respond(peer, id, {"key": keycode, "pressed": ev.pressed, "state": _build_snapshot()})


func _parse_key(p: Dictionary) -> int:
	if p.has("keycode"):
		return int(p["keycode"])
	var k := str(p.get("key", ""))
	if k.is_empty():
		return 0
	if k.is_valid_int():
		return k.to_int()
	var code := OS.find_keycode_from_string(k)
	if code != KEY_NONE:
		return code
	if k.length() == 1:
		return k.to_upper().unicode_at(0)
	return 0


func _m_call(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var ref := str(p.get("path", p.get("node", "")))
	var method := str(p.get("method", ""))
	if method.is_empty():
		_respond_error(peer, id, "call requires 'method'")
		return
	if method in CALL_BLOCKED_METHODS or method.begins_with("_"):
		_respond_error(peer, id, "method not allowed: " + method)
		return
	var node := _resolve_node(ref)
	if node == null:
		_respond_error(peer, id, "node not found: " + ref)
		return
	if _is_hidden(node):
		_respond_error(peer, id, "node is hidden: " + ref)
		return
	if not node.has_method(method):
		_respond_error(peer, id, "no such method: " + method)
		return
	var raw_args: Variant = p.get("args", [])
	var cargs := _coerce_call_args(raw_args if raw_args is Array else [])
	var result: Variant = node.callv(method, cargs)
	_respond(peer, id, {"result": _jsonable(result), "state": _build_snapshot()})


func _coerce_call_args(raw: Array) -> Array:
	var out: Array = []
	for v in raw:
		if v is float and v == floorf(v):
			out.append(int(v))
		else:
			out.append(v)
	return out


func _resolve_node(ref: String) -> Node:
	if ref.is_empty():
		return null
	var scene := get_tree().current_scene
	if ref.begins_with("/"):
		if scene != null:
			var parts := ref.split("/", false)
			if parts.size() >= 2 and parts[0] == str(scene.name):
				var rel := "/".join(parts.slice(1))
				var n := scene.get_node_or_null(rel)
				if n != null:
					return n
		var abs := get_node_or_null(ref)
		if abs != null:
			return abs
		return null
	if scene != null:
		return scene.get_node_or_null(ref)
	return get_node_or_null(ref)


func _m_time_scale(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	if not p.has("scale"):
		_respond_error(peer, id, "time_scale requires 'scale'")
		return
	var s := clampf(float(p["scale"]), MIN_TIME_SCALE, MAX_TIME_SCALE)
	Engine.time_scale = s
	_respond(peer, id, {"time_scale": Engine.time_scale, "state": _build_snapshot()})


func _jsonable(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in v.keys():
			d[k] = _jsonable(v[k])
		return d
	if v is Array:
		var a: Array = []
		for item in v:
			a.append(_jsonable(item))
		return a
	if v is String or v is int or v is float or v is bool or v == null:
		return v
	return str(v)


# ---------------------------------------------------------------------------
# 等待：wait / wait_until（物理帧驱动，游戏内判定一次唤醒，不轮询网络）
# ---------------------------------------------------------------------------

func _m_wait(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var frames := 0
	if p.has("frames"):
		frames = int(p["frames"])
	elif p.has("seconds"):
		frames = int(round(float(p["seconds"]) * Engine.physics_ticks_per_second))
	if frames < 1:
		_respond_error(peer, id, "wait requires 'frames' >= 1 or 'seconds' > 0")
		return
	_pending_waits.append({"peer": peer, "id": id, "remaining": frames})


func _m_wait_until(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	var expr := str(p.get("expr", ""))
	if expr.is_empty():
		_respond_error(peer, id, "wait_until requires 'expr'")
		return
	var parsed: Variant = _parse_conditions(expr)
	if not (parsed is Dictionary):
		_respond_error(peer, id, "expr parse failed")
		return
	var pd: Dictionary = parsed
	if not bool(pd.get("ok", false)):
		_respond_error(peer, id, str(pd.get("error", "bad expr")))
		return
	var max_frames := int(p.get("max_frames", WAIT_UNTIL_DEFAULT_FRAMES))
	if max_frames < 1:
		_respond_error(peer, id, "max_frames must be >= 1")
		return
	_pending_untils.append({
		"peer": peer,
		"id": id,
		"conditions": pd["conditions"],
		"deadline": _phys_frame + max_frames,
	})


func _tick_waits() -> void:
	var i := _pending_waits.size() - 1
	while i >= 0:
		var w: Dictionary = _pending_waits[i]
		var peer: WebSocketPeer = w["peer"]
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_pending_waits.remove_at(i)
			i -= 1
			continue
		w["remaining"] = int(w["remaining"]) - 1
		if int(w["remaining"]) <= 0:
			_respond(peer, w["id"], {"state": _build_snapshot()})
			_pending_waits.remove_at(i)
		i -= 1


func _tick_untils() -> void:
	var i := _pending_untils.size() - 1
	while i >= 0:
		var w: Dictionary = _pending_untils[i]
		var peer: WebSocketPeer = w["peer"]
		if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
			_pending_untils.remove_at(i)
			i -= 1
			continue
		if _phys_frame >= int(w["deadline"]):
			_respond(peer, w["id"], {"timeout": true, "state": _build_snapshot()})
			_pending_untils.remove_at(i)
			i -= 1
			continue
		var game := _game_state()
		var all := true
		for cond in w["conditions"]:
			if not _eval_condition(game, cond):
				all = false
				break
		if all:
			_respond(peer, w["id"], {"timeout": false, "state": _build_snapshot()})
			_pending_untils.remove_at(i)
		i -= 1


func _parse_conditions(expr: String) -> Dictionary:
	# RegEx 无 split：用 search_all 手工切分（" and " 不区分大小写、任意空白）
	var e := expr.strip_edges()
	var raw_parts: Array[String] = []
	var last := 0
	for m in _and_re.search_all(e):
		var mb := m.get_start()
		var me := m.get_end()
		if mb > last:
			raw_parts.append(e.substr(last, mb - last))
		last = me
	if last < e.length():
		raw_parts.append(e.substr(last))
	var parts: Array[String] = []
	for rp in raw_parts:
		var s := rp.strip_edges()
		if not s.is_empty():
			parts.append(s)
	if parts.size() > MAX_WAIT_UNTIL_CONDITIONS:
		return {"ok": false, "conditions": [], "error": "too many conditions (max %d)" % MAX_WAIT_UNTIL_CONDITIONS}
	var conditions: Array = []
	for part in parts:
		var m := _cond_re.search(part)
		if m == null:
			return {"ok": false, "conditions": [], "error": "bad condition: " + str(part)}
		conditions.append({
			"key": m.get_string(1),
			"op": m.get_string(2),
			"value": _parse_literal(m.get_string(3)),
		})
	if conditions.is_empty():
		return {"ok": false, "conditions": [], "error": "empty expr"}
	return {"ok": true, "conditions": conditions, "error": ""}


func _parse_literal(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s == "true":
		return true
	if s == "false":
		return false
	var n := s.length()
	if n >= 2:
		var q0 := s.unicode_at(0)
		var q1 := s.unicode_at(n - 1)
		if (q0 == 34 and q1 == 34) or (q0 == 39 and q1 == 39):
			return s.substr(1, n - 2)
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return s.to_float()
	return s


func _eval_condition(game: Dictionary, cond: Dictionary) -> bool:
	var key := str(cond["key"])
	var op := str(cond["op"])
	var expected: Variant = cond["value"]
	var actual: Variant = game.get(key)
	return _compare(actual, op, expected)


func _compare(actual: Variant, op: String, expected: Variant) -> bool:
	if actual == null:
		return op == "!="
	var an := _num_or_null(actual)
	var en := _num_or_null(expected)
	if an != null and en != null:
		return _cmp_num(an, op, en)
	var ab := _bool_or_null(actual)
	var eb := _bool_or_null(expected)
	if ab != null and eb != null:
		return _cmp_num(1.0 if ab else 0.0, op, 1.0 if eb else 0.0)
	if actual is String and expected is String:
		var a := actual as String
		var e := expected as String
		match op:
			"==":
				return a == e
			"!=":
				return a != e
			">":
				return a > e
			"<":
				return a < e
			">=":
				return a >= e
			"<=":
				return a <= e
	return op == "!="


func _num_or_null(v: Variant) -> Variant:
	if v is int or v is float:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	if v is String:
		var s := v as String
		if s.is_valid_float():
			return s.to_float()
	return null


func _bool_or_null(v: Variant) -> Variant:
	if v is bool:
		return v
	if v is int or v is float:
		return v != 0
	if v is String:
		var s := (v as String).to_lower()
		if s == "true":
			return true
		if s == "false":
			return false
	return null


func _cmp_num(a: float, op: String, b: float) -> bool:
	match op:
		"==":
			return a == b
		"!=":
			return a != b
		">":
			return a > b
		"<":
			return a < b
		">=":
			return a >= b
		"<=":
			return a <= b
	return false
