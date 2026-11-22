# godot-aiplay · 项目须知

Godot 4.7.2 插件：AIPlay **v0.3** 协议参考实现（`addons/aiplay/`）+ 零依赖 MCP 桥（`bridge/`）+ demo 菜地（`demo/`）。
协议正文 `PROTOCOL.md`，变更 `CHANGELOG.md`，实测证据 `BUILDLOG.md`，三家研读 `REFERENCE-REVIEW.md`。

## 命令

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
$GODOT --headless --path . --import                        # 新克隆先导入（.godot/ 不入库）
$GODOT --headless --path . --check-only --script <gd>      # 单脚本编译检查
$GODOT --headless --path . -- --aiplay                      # 无头跑 demo（强制开 WS）
$GODOT --path .                                             # 开窗口玩 demo
node tests/smoke_ws.mjs                                     # WS 协议（需游戏在跑，42 项）
node tests/smoke_bridge.mjs                                 # MCP 桥（需游戏在跑，11 项）
node bridge/server.mjs                                      # 起 MCP 桥（自动读 token 鉴权）
```

## 验证基线

- `tests/smoke_ws.mjs` 42 项、`tests/smoke_bridge.mjs` 11 项，**且必须能连跑三次都全过**。
  只跑一次就宣布通过，等于没测——v0.2 就栽在这里：断言假设全新状态，第二跑 21/9。
- 每个用例前调 `game_reset`；新增断言不许依赖"游戏刚好是开局状态"。
- 安全类断言必须验证**状态没变**，不能只看返回了 error。
- Godot 退出码不反映脚本错误：无头冒烟后 grep 日志 `SCRIPT ERROR|^ERROR:`。
- 改协议行为要同步 `PROTOCOL.md` + `CHANGELOG.md`；协议版本在 `aiplay.gd` 的
  `PROTOCOL_VERSION` 与桥的 `serverInfo.version`。

## 约定

- GDScript 严格类型：Dictionary/Variant 取值必须显式标类型，不用 `:=` 推断动态值。
- 桥零依赖（Node ≥22 全局 WebSocket + readline）；stdout 只走 JSON-RPC，日志走 stderr。
- 插件只绑 127.0.0.1，并要求 token 鉴权。Origin 白名单在引擎层取不到，
  不要试图用 `get_handshake_headers()`——服务端返回空数组，已验证。
- 安全默认不可放宽：`call` 默认关且只走 `register_callable` 白名单；
  `click` 必须校验 `is_visible_in_tree()` 与 `disabled`；`time_scale` 默认关。
  这几条任何一条放宽，都要在 `CHANGELOG.md` 写清理由和影响面。
- 编辑器插件不得调用 `ProjectSettings.save()`。
- `.devin/skills/` 是 gamedev-skills 子集，仅方法参考，不覆盖协议规则。

## 已知天花板（不是待办，写清楚免得反复讨论）

- `wait_until` 只能断言 `game` 顶层扁平键 → 每游戏自定摊平规则。
  要通用得给 `game` 加路径寻址或让 provider 声明可等待字段，属 v0.4 议题。
- 只有自家 demo 验证过通用性；第二个采用者之前不对外宣称"装上就能玩"。
