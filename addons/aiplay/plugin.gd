@tool
extends EditorPlugin
## AIPlay 编辑器层：启用插件时注册 Autoload 并把 aiplay/* 设置项挂进
## 项目设置面板；运行时层在 aiplay.gd（随游戏导出），本文件只在编辑器内执行。
##
## 这里刻意不做任何 ProjectSettings.save()：启用/禁用插件不应悄悄改写用户的
## project.godot。设置项的默认值只在运行时读取时兜底（见 aiplay.gd 的 get_setting 第二参）。

const AUTOLOAD_NAME := "AIPlay"
const AUTOLOAD_PATH := "res://addons/aiplay/aiplay.gd"

const SETTING_ENABLED := "aiplay/enabled"
const SETTING_PORT := "aiplay/port"
const SETTING_REQUIRE_TOKEN := "aiplay/require_token"
const SETTING_ALLOW_CALL := "aiplay/allow_call"
const SETTING_ALLOW_TIME_SCALE := "aiplay/allow_time_scale"
const DEFAULT_PORT := 8765

var _added_autoload := false


func _enter_tree() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
		_added_autoload = true
	_register_settings()


func _exit_tree() -> void:
	if _added_autoload:
		remove_autoload_singleton(AUTOLOAD_NAME)
		_added_autoload = false


func _register_settings() -> void:
	_declare(SETTING_ENABLED, TYPE_BOOL, PROPERTY_HINT_NONE, "",
		"启用 AIPlay 本地协议服务（仅 127.0.0.1）")
	_declare(SETTING_PORT, TYPE_INT, PROPERTY_HINT_RANGE, "1,65535",
		"WebSocket 监听端口")
	_declare(SETTING_REQUIRE_TOKEN, TYPE_BOOL, PROPERTY_HINT_NONE, "",
		"要求连接先提供 user://aiplay.token 里的凭据（防浏览器网页直连）")
	_declare(SETTING_ALLOW_CALL, TYPE_BOOL, PROPERTY_HINT_NONE, "",
		"打开 call 逃生舱（仍须 register_callable 逐条放行）")
	_declare(SETTING_ALLOW_TIME_SCALE, TYPE_BOOL, PROPERTY_HINT_NONE, "",
		"允许 time_scale 改写 Engine.time_scale（仅自测用）")


## 只登记默认值与说明，不落盘：has_setting 为假时才设默认值，
## 是否保存由开发者在项目设置面板里自己决定。
func _declare(sname: String, stype: int, hint: int, hint_string: String, description: String) -> void:
	if not ProjectSettings.has_setting(sname):
		match stype:
			TYPE_BOOL:
				ProjectSettings.set_setting(sname, false)
			TYPE_INT:
				ProjectSettings.set_setting(sname, DEFAULT_PORT)
			_:
				ProjectSettings.set_setting(sname, null)
	var info := {
		"name": sname,
		"type": stype,
		"hint": hint,
		"hint_string": hint_string,
		"usage": PROPERTY_USAGE_DEFAULT,
	}
	if not description.is_empty():
		info["description"] = description
	ProjectSettings.add_property_info(info)
