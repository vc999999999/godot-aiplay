@tool
extends EditorPlugin
## AIPlay 编辑器层：启用插件时注册 Autoload 并把 aiplay/* 设置项挂进
## 项目设置面板；运行时层在 aiplay.gd（随游戏导出），本文件只在编辑器内执行。

const AUTOLOAD_NAME := "AIPlay"
const AUTOLOAD_PATH := "res://addons/aiplay/aiplay.gd"

const SETTING_ENABLED := "aiplay/enabled"
const SETTING_PORT := "aiplay/port"
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
	if not ProjectSettings.has_setting(SETTING_ENABLED):
		ProjectSettings.set_setting(SETTING_ENABLED, false)
	if not ProjectSettings.has_setting(SETTING_PORT):
		ProjectSettings.set_setting(SETTING_PORT, DEFAULT_PORT)
	ProjectSettings.save()
	_add_setting_info(SETTING_ENABLED, TYPE_BOOL, PROPERTY_HINT_NONE, "", "启用 AIPlay 本地协议服务（仅 127.0.0.1）")
	_add_setting_info(SETTING_PORT, TYPE_INT, PROPERTY_HINT_RANGE, "1,65535", "WebSocket 监听端口")


func _add_setting_info(sname: String, stype: int, hint: int, hint_string: String, description: String) -> void:
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
