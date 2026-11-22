# godot-aiplay · 项目须知

Godot 4.7.2 插件：AIPlay v0.2 协议参考实现（`addons/aiplay/`）+ 零依赖 MCP 桥（`bridge/`）+ demo 菜地（`demo/`）。协议正文 `PROTOCOL.md`，用法 `README.md`。

## 命令

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --headless --path . --import                        # 新克隆先导入（.godot/ 不入库）
$GODOT --headless --path . --check-only --script <gd>      # 单脚本编译检查
$GODOT --headless --path .                                  # 无头跑 demo（aiplay/enabled=true 已开 WS）
$GODOT --path .                                             # 开窗口玩 demo
node tests/smoke_ws.mjs                                     # WS 协议冒烟（需游戏在跑，30 项）
node tests/smoke_bridge.mjs                                 # MCP 桥冒烟（需游戏在跑，8 项）
node bridge/server.mjs                                      # 起 MCP 桥（游戏不在也能起，只少动态工具）
```

## 验证基线

- `tests/smoke_ws.mjs`：30 项全过；`tests/smoke_bridge.mjs`：8 项全过。
- Godot 退出码不反映脚本错误：无头冒烟后 grep 日志 `SCRIPT ERROR|^ERROR:`。
- 改协议行为要同步 `PROTOCOL.md`；协议版本在 `aiplay.gd` 的 `PROTOCOL_VERSION` 与桥的 `serverInfo.version`。

## 约定

- GDScript 严格类型：Dictionary/Variant 取值必须显式标类型，不用 `:=` 推断动态值。
- 桥零依赖（Node ≥22 全局 WebSocket + readline）；stdout 只走 JSON-RPC，日志走 stderr。
- 插件只绑 127.0.0.1；`call` 逃生舱守卫（禁 free/queue_free/exit_tree/_* 与 aiplay_hidden 子树）不可放宽。
- `.devin/skills/` 是 gamedev-skills/awesome-gamedev-agent-skills 子集（router + godot-* + disciplines），仅方法参考。
