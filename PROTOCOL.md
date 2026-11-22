# AIPlay Protocol `aiplay/0.2`

让外部 AI Agent 以"玩家"身份观察并操作 Godot 游戏的本地协议。
本文档是参考实现（`addons/aiplay/aiplay.gd` + `bridge/server.mjs`）的协议正文。

## 传输

- `ws://127.0.0.1:8765`（端口可用 `aiplay/port` 项目设置或 `--aiplay-port=N` 覆盖；`--aiplay` 命令行参数强制启用）
- **仅绑定回环地址**，不接受外部连接。
- 帧为 UTF-8 JSON 文本。请求：`{"id": <任意 JSON 值>, "method": "<名>", "params": {...}}`。
- 响应：`{"id": <同上>, "ok": true, "result": ...}` 或 `{"id": <同上>, "ok": false, "error": "..."}`。
- 服务器不主动推送（v0.2 无事件流）；等待类方法在条件满足/超时/帧数到达时才回包。

## 默认开关

- 项目设置 `aiplay/enabled`（默认 `false`）控制运行时服务。
- 编辑器插件启用时注册 autoload `AIPlay` 与两个项目设置项；游戏侧用 `get_node_or_null("/root/AIPlay")` 判空调用，插件未启用时游戏照常运行。

## 方法

### 只读

| method | params | result |
|---|---|---|
| `ping` | — | `{protocol, game, engine}` |
| `state` | — | 快照（见下） |
| `actions` | — | `{actions: [...]}` 当前合法动作（provider 优先，否则从可见按钮派生） |
| `tools` | — | `{tools: [...]}` 游戏在 `aiplay_tools` 组声明的 `AIPLAY_TOOLS` |

### 动作

| method | params | result |
|---|---|---|
| `invoke` | `{tool: "game_x", args: {...}}` | `{result, state}` 调语义动作；参数按声明类型强转 |
| `click` | `{id}` 或 `{element}`/`{path}` | `{clicked, state}` 对 `BaseButton` 发 `pressed` 信号；隐藏/不存在报错 |
| `press` | `{action, pressed?}` | `{action, pressed, state}` `Input.action_press/release` |
| `key` | `{key}` 或 `{keycode}`，`pressed?` | `{key, pressed, state}` `Input.parse_input_event`；`key` 接受键名（`OS.find_keycode_from_string`）、数字串或单字符 |
| `call` | `{path, method, args?}` | `{result, state}` 逃生舱：对任意节点调任意方法；`path` 必填，接受元素 id、场景相对路径或 `/root/...` 绝对路径；拦截 `free`/`queue_free`/`exit_tree`/下划线开头方法与 `aiplay_hidden` 子树 |
| `wait` | `{frames}` 或 `{seconds}` | `{state}` 等 N 个物理帧后返回快照 |
| `wait_until` | `{expr, max_frames?}` | `{timeout: bool, state}` 条件等待（见下） |
| `time_scale` | `{scale}` | `{time_scale, state}` `Engine.time_scale`，钳制 0.1–20 |

所有动作方法成功后都附带最新快照，调用方无需再发 `state`。

## 状态快照 `state`

```json
{
  "scene": "Main",
  "game": { "...": "游戏自定义状态，≤4KB" },
  "elements": [
    {"id": "/Main/VBox/Plot0", "type": "Button", "label": "地块1 · 已熟！收！",
     "disabled": false, "tooltip": "..."}
  ],
  "truncated": false,
  "truncated_note": "elements 83>60"
}
```

- `elements`：当前场景内**可见**的 `BaseButton`（自动）或 `aiplay_element` 组成员（`Control`），上限 60；`aiplay_hidden` 组的祖先整棵排除。
- `id` 是稳定寻址：`/<场景名>/<相对路径>`，`click`/`call` 的 `path` 也接受该 id 或场景相对路径。
- `label`：`aiplay_label` 元数据 > 按钮文本 > 节点名。
- `game`：`register_state_provider` 返回的字典；JSON 超 4KB 时字符串逐级截断并标 `truncated`。
- 快照给**游戏级语义**而非节点树——这是协议的核心取舍。

## `wait_until` 断言语法

- `expr`：`key op literal`，多条件以 ` and ` 连接（不区分大小写），**最多 3 个**。
- `op`：`==` `!=` `>` `<` `>=` `<=`。
- `literal`：`true`/`false`、数字、`"字符串"`（单引号同）、裸词按字符串。
- 比较针对 `game` 字典顶层键：数值按 float、布尔按 bool、字符串按字典序；键缺失时仅 `!=` 成立。
- `max_frames` 默认 3600（物理帧）。超时返回 `{timeout: true, state}`。
- 限制：字符串值内不能含 ` and `；表达式在**物理帧**上求值（与游戏逻辑同步，不受 `time_scale` 影响节奏但帧数随缩放变快/慢）。

## 游戏侧接入（开发者视角）

```gdscript
# 1) 元素标注
$PlantButton.set_meta("aiplay_label", "种植萝卜")
$DebugPanel.add_to_group("aiplay_hidden")

# 2) 状态与动作 provider（可选；不写则 elements 按钮派生 actions、game={}）
AIPlay.register_state_provider(func() -> Dictionary: return {"gold": gold})
AIPlay.register_actions_provider(func() -> Array: return [{"action": "plant", "plot": 0}])

# 3) 语义动作：节点加入组 aiplay_tools + 声明常量
const AIPLAY_TOOLS = {
  "plant": {"description": "种植", "args": {"plot": "int", "seed": "string"}},
}
# 对应方法 func plant(plot: int, seed: String) -> Variant
```

`args` 类型：`int`/`float`/`string`/`bool`；JSON 数字到 int 要求整数值。未知类型原样透传。
桥会把每个声明展开成 `game_<name>` 动态工具，`invoke` 只认 `game_` 前缀。

## MCP 桥 `bridge/server.mjs`

零依赖 Node ≥22（全局 WebSocket）。stdio 上行下行换行分隔 JSON-RPC 2.0。

- 静态工具：12 个 `aiplay_*`（协议方法 1:1）。
- 动态工具：连接后拉 `tools`，每个声明生成 `game_*` 工具（参数 schema 自动推导，全部必填）。
- `wait`/`wait_until` 的 MCP 超时按 `max_frames` 推导（上限 600s）。
- 游戏未启动时桥正常工作，`tools/list` 只回静态工具；调用报连接错误。

## 安全边界（有意为之）

- `call` 拦截销毁类方法与下划线方法，且拒绝 `aiplay_hidden` 子树——逃生舱不是后门。
- 不提供任意代码执行（无 `eval`/`Expression`）。
- 只绑回环；默认关闭；快照有硬上限。
