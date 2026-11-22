extends Node
## AIPlay 运行时层（协议版本 aiplay/0.3）
##
## 随游戏导出：起本地 WebSocket 服务（仅 127.0.0.1）、导出状态快照、
## 执行语义动作。协议正文见仓库 PROTOCOL.md，本文件是其参考实现。
##
## 游戏侧接入（开发者）：
##   - 元素标注：关键控件 set_meta("aiplay_label", "名字")；
##     组 aiplay_element / aiplay_hidden 声明谁进快照、谁排除；
##   - AIPlay.register_state_provider(callable) → Dictionary 进快照 game 字段；
##   - AIPlay.register_actions_provider(callable) → Array 供 actions 方法；
##   - 节点加入组 aiplay_tools 并声明 const AIPLAY_TOOLS = {...}；
##   - 逃生舱 call 默认关闭；要开须同时设 aiplay/allow_call=true 并
##     AIPlay.register_callable("方法名", "节点路径") 逐条放行。
## 注意：插件可能未启用，游戏代码请用 get_node_or_null("/root/AIPlay") 判空后调用，
## 不要直接写 AIPlay. 标识符（autoload 缺失会导致脚本编译失败）。

const PROTOCOL_VERSION := "aiplay/0.3"
const DEFAULT_PORT := 8765
const MAX_ELEMENTS := 60
const MAX_GAME_DICT_BYTES := 4096
const MAX_WAIT_UNTIL_CONDITIONS := 3
const MIN_TIME_SCALE := 0.1
const MAX_TIME_SCALE := 20.0
const WAIT_UNTIL_DEFAULT_FRAMES := 3600

const SETTING_ENABLED := "aiplay/enabled"
const SETTING_PORT := "aiplay/port"
const SETTING_REQUIRE_TOKEN := "aiplay/require_token"
const SETTING_ALLOW_CALL := "aiplay/allow_call"
const SETTING_ALLOW_TIME_SCALE := "aiplay/allow_time_scale"

const TOKEN_FILE := "user://aiplay.token"
const TOKEN_BYTES := 24
const MAX_PEERS := 8
const MAX_AUTH_FAILS := 3
const AUTH_GRACE_FRAMES := 600

## 即使进了 callable 白名单也拒绝：销毁、间接调用、状态写入都算绕过
const CALL_BLOCKED_METHODS := [
	"free", "queue_free", "exit_tree", "notification",
	"set", "set_indexed", "set_deferred", "set_script",
	"call", "callv", "call_deferred", "call_group",
	"emit_signal", "rpc", "rpc_id", "rpcp",
	"reparent", "replace_by", "duplicate", "instantiate",
]

var _tcp := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _peer_info: Dictionary = {}
var _listening := false
var _port := -1

var _require_token := true
var _token := ""
var _allow_call := false
var _allow_time_scale := false
var _callables: Dictionary = {}

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
	_read_policy()
	var port_override := _cli_value("--aiplay-port")
	if port_override != "":
		_port = int(port_override)
	if _cli_flag("--aiplay") or bool(ProjectSettings.get_setting(SETTING_ENABLED, false)):
		start_server()


func _read_policy() -> void:
	_require_token = bool(ProjectSettings.get_setting(SETTING_REQUIRE_TOKEN, true))
	_allow_call = bool(ProjectSettings.get_setting(SETTING_ALLOW_CALL, false))
	_allow_time_scale = bool(ProjectSettings.get_setting(SETTING_ALLOW_TIME_SCALE, false))
	if _cli_flag("--aiplay-no-token"):
		_require_token = false


func _exit_tree() -> void:
	stop_server()


# ---------------------------------------------------------------------------
# 服务生命周期
# ---------------------------------------------------------------------------

func start_server() -> void:
	if _listening:
		return
	var port := _resolve_port()
	if _require_token and _token.is_empty():
		_token = _load_or_create_token()
	var err := _tcp.listen(port, "127.0.0.1")
	if err != OK:
		push_error("AIPlay: cannot listen on 127.0.0.1:%d (error %d)" % [port, err])
		return
	_listening = true
	print("AIPlay: listening on ws://127.0.0.1:%d (protocol %s)" % [port, PROTOCOL_VERSION])
	if _require_token:
		# 凭据只落本地文件，不进 stdout / 日志；浏览器读不到这个文件
		print("AIPlay: token required (user://aiplay.token), pass it as ?token=... on the URL")


func stop_server() -> void:
	for peer in _peers:
		peer.close()
	_peers.clear()
	_peer_info.clear()
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


# ---------------------------------------------------------------------------
# 鉴权凭据
# ---------------------------------------------------------------------------

func _load_or_create_token() -> String:
	if FileAccess.file_exists(TOKEN_FILE):
		var rf := FileAccess.open(TOKEN_FILE, FileAccess.READ)
		if rf != null:
			var existing := rf.get_as_text().strip_edges()
			rf.close()
			if existing.length() >= 32:
				return existing
	var raw := Crypto.new().generate_random_bytes(TOKEN_BYTES)
	var tok := raw.hex_encode()
	var wf := FileAccess.open(TOKEN_FILE, FileAccess.WRITE)
	if wf != null:
		wf.store_string(tok)
		wf.close()
	_restrict_token_permissions()
	return tok


## 凭据文件默认是 644，同机其它用户能读——把它收到 600。
## Windows 没有 chmod 语义，走用户目录 ACL，这里跳过。
func _restrict_token_permissions() -> void:
	if OS.get_name() == "Windows":
		return
	var abs := ProjectSettings.globalize_path(TOKEN_FILE)
	OS.execute("chmod", ["600", abs])


## 供本地工具/桥读取凭据（同机进程才有权限读 user://）
func get_token_path() -> String:
	return ProjectSettings.globalize_path(TOKEN_FILE)


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


## 逃生舱白名单：方法名 → 允许被调用的节点路径（场景相对路径或 /场景名/... 的绝对 id）。
## 不登记的方法即使 aiplay/allow_call=true 也调不通。
func register_callable(method: String, node_path: String) -> void:
	if method.is_empty():
		return
	_callables[method] = node_path


func clear_callables() -> void:
	_callables.clear()


## 当前生效的策略，给本地工具和排障用（不含 token 本身）
func get_policy() -> Dictionary:
	return {
		"protocol": PROTOCOL_VERSION,
		"require_token": _require_token,
		"allow_call": _allow_call,
		"allow_time_scale": _allow_time_scale,
		"callable_count": _callables.size(),
		"max_peers": MAX_PEERS,
	}


# ---------------------------------------------------------------------------
# 网络循环
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _listening:
		return
	while _tcp.is_connection_available():
		var conn := _tcp.take_connection()
		# 连接数硬上限：多余连接直接丢弃，避免被扫端口/恶意页面拖垮
		if _peers.size() >= MAX_PEERS:
			conn.disconnect_from_host()
			continue
		var peer := WebSocketPeer.new()
		peer.accept_stream(conn)
		_peers.append(peer)
		_peer_info[peer] = {"authed": not _require_token, "fails": 0, "frames": 0}
	var i := _peers.size() - 1
	while i >= 0:
		var peer := _peers[i]
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_CLOSED:
			_peer_info.erase(peer)
			_peers.remove_at(i)
		elif state == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				_handle_packet(peer, peer.get_packet().get_string_from_utf8())
		i -= 1
	_flush_auth_deadlines()


func _physics_process(_delta: float) -> void:
	_phys_frame += 1
	_tick_waits()
	_tick_untils()


# 未鉴权的连接不给无限期挂着的机会
func _flush_auth_deadlines() -> void:
	for peer in _peers:
		var info: Variant = _peer_info.get(peer)
		if not (info is Dictionary):
			continue
		var d: Dictionary = info
		if bool(d.get("authed", false)):
			continue
		d["frames"] = int(d.get("frames", 0)) + 1
		if int(d["frames"]) > AUTH_GRACE_FRAMES:
			peer.close()


func _is_authed(peer: WebSocketPeer) -> bool:
	var info: Variant = _peer_info.get(peer)
	if not (info is Dictionary):
		return false
	return bool((info as Dictionary).get("authed", false))


func _auth_error(peer: WebSocketPeer) -> void:
	var info: Variant = _peer_info.get(peer)
	if info is Dictionary:
		var d: Dictionary = info
		d["fails"] = int(d.get("fails", 0)) + 1
		if int(d["fails"]) >= MAX_AUTH_FAILS:
			# 连续猜错直接断开，不做无限次爆破
			_send(peer, {"id": null, "ok": false, "error": "too many auth failures, closing"})
			peer.close()
			return
	_send(peer, {
		"id": null,
		"ok": false,
		"error": "unauthorized: send {\"method\":\"auth\",\"params\":{\"token\":\"...\"}} first",
	})


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
	# auth 是唯一允许在未鉴权状态下调用的方法
	if method == "auth":
		_m_auth(peer, id, msg.get("params", {}))
		return
	if not _is_authed(peer):
		_auth_error(peer)
		return
	_dispatch(peer, id, method, msg.get("params", {}))


func _m_auth(peer: WebSocketPeer, id: Variant, params: Variant) -> void:
	var p := _params_dict(params)
	if not _require_token:
		_mark_authed(peer)
		_respond(peer, id, {"authed": true, "required": false})
		return
	var given := str(p.get("token", ""))
	if given.is_empty() or not _constant_time_eq(given, _token):
		var info: Variant = _peer_info.get(peer)
		if info is Dictionary:
			var d: Dictionary = info
			d["fails"] = int(d.get("fails", 0)) + 1
			if int(d["fails"]) >= MAX_AUTH_FAILS:
				_send(peer, {"id": id, "ok": false, "error": "too many auth failures, closing"})
				peer.close()
				return
		_respond_error(peer, id, "bad token")
		return
	_mark_authed(peer)
	_respond(peer, id, {"authed": true, "required": true})


func _mark_authed(peer: WebSocketPeer) -> void:
	var info: Variant = _peer_info.get(peer)
	if info is Dictionary:
		(info as Dictionary)["authed"] = true
	else:
		_peer_info[peer] = {"authed": true, "fails": 0, "frames": 0}


func _constant_time_eq(a: String, b: String) -> bool:
	var ab := a.to_utf8_buffer()
	var bb := b.to_utf8_buffer()
	if ab.size() != bb.size():
		return false
	var diff := 0
	for i in ab.size():
		diff |= ab[i] ^ bb[i]
	return diff == 0


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
		"auth_required": _require_token,
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
	# 多余参数直接报错：静默丢弃会让 AI 传错名字时"什么都没发生"，极难排查
	var unknown: Array[String] = []
	for k in args.keys():
		if not decl.has(str(k)):
			unknown.append(str(k))
	if not unknown.is_empty():
		out["ok"] = false
		out["error"] = "unknown arg(s): %s (accepted: %s)" % [
			", ".join(PackedStringArray(unknown)),
			", ".join(PackedStringArray(decl.keys().map(func(x): return str(x)))),
		]
		return out
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
	var btn := node as BaseButton
	# 与真人同权：看不见的、按不动的按钮不该被点到
	if not btn.is_visible_in_tree():
		_respond_error(peer, id, "element is not visible: " + ref)
		return
	if btn.disabled:
		_respond_error(peer, id, "element is disabled: " + ref)
		return
	btn.pressed.emit()
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
	# 逃生舱默认整机关闭；打开后仍只走开发者逐条登记的白名单。
	# 黑名单挡不住 call_deferred("queue_free")、set("gold", 9999) 这一类，
	# 所以判定标准只有一条：这个方法是不是开发者显式说过"可以给 AI 调"。
	if not _allow_call:
		_respond_error(peer, id, "call is disabled (set aiplay/allow_call=true and register callables)")
		return
	var p := _params_dict(params)
	var ref := str(p.get("path", p.get("node", "")))
	var method := str(p.get("method", ""))
	if method.is_empty():
		_respond_error(peer, id, "call requires 'method'")
		return
	if method in CALL_BLOCKED_METHODS or method.begins_with("_"):
		_respond_error(peer, id, "method not allowed: " + method)
		return
	if not _callables.has(method):
		_respond_error(peer, id, "method not registered as callable: " + method)
		return
	var node := _resolve_node(ref)
	if node == null:
		_respond_error(peer, id, "node not found: " + ref)
		return
	if _is_hidden(node):
		_respond_error(peer, id, "node is hidden: " + ref)
		return
	# 登记的路径必须对得上：防止拿白名单里的方法名去打别的节点
	var expect_path := str(_callables[method])
	if not expect_path.is_empty() and not _node_matches(node, expect_path):
		_respond_error(peer, id, "callable '%s' is bound to %s" % [method, expect_path])
		return
	if not node.has_method(method):
		_respond_error(peer, id, "no such method: " + method)
		return
	var raw_args: Variant = p.get("args", [])
	var cargs := _coerce_call_args(raw_args if raw_args is Array else [])
	var result: Variant = node.callv(method, cargs)
	_respond(peer, id, {"result": _jsonable(result), "state": _build_snapshot()})


func _node_matches(node: Node, expect_path: String) -> bool:
	var scene := get_tree().current_scene
	if scene != null:
		if str(scene.get_path_to(node)) == expect_path:
			return true
		if "/" + str(scene.name) + "/" + expect_path == expect_path:
			return true
		var full := "/" + str(scene.name) + "/" + str(scene.get_path_to(node))
		if full == expect_path:
			return true
	return str(node.get_path()) == expect_path


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
	# 放置游戏里唯一资源就是时间，压时间等于印钱；限时决策游戏里等于无限思考。
	# 所以默认关，只有开发者显式打开才算"自测用的开关"。
	if not _allow_time_scale:
		_respond_error(peer, id, "time_scale is disabled (set aiplay/allow_time_scale=true)")
		return
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
