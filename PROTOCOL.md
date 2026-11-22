# AIPlay Protocol `aiplay/0.3`

让外部 AI Agent 以"玩家"身份观察并操作 Godot 游戏的本地协议。
本文档是参考实现（`addons/aiplay/aiplay.gd` + `bridge/server.mjs`）的协议正文。

> v0.2 → v0.3 是不兼容变更（连接必须先 `auth`）。变更清单见 [CHANGELOG.md](CHANGELOG.md)，
> 每条都附了"为什么必须改"，其中三条是实测出的安全漏洞，不是设计口味。

## 传输

- `ws://127.0.0.1:8765`（端口可用 `aiplay/port` 项目设置或 `--aiplay-port=N` 覆盖；`--aiplay` 强制启用）
- **仅绑定回环地址**，不接受外部连接。
- **连接数上限 8**，超出直接关闭——端口被扫、被反复重连时不会拖垮游戏。
- 帧为 UTF-8 JSON 文本。请求：`{"id": <任意 JSON 值>, "method": "<名>", "params": {...}}`。
- 响应：`{"id": 同上, "ok": true, "result": ...}` 或 `{"id": 同上, "ok": false, "error": "..."}`。
- 服务器不主动推送（无事件流）；等待类方法在条件满足/超时/帧数到达时才回包。

## 鉴权（v0.3 新增，默认开启）

浏览器不受同源策略限制，任何网页的 JS 都能连 `127.0.0.1:8765`。
Godot 服务端**拿不到入站握手的 Origin 头**（`get_handshake_headers()` 在服务端返回空，
`StreamPeerTCP` 也无 peek），所以 Origin 白名单在当前引擎层做不了。
替代方案是凭据：

1. 首次启动时生成 48 位十六进制 token，写入 `user://aiplay.token`（本机文件，浏览器读不到）。
2. 连接后**第一个**必须发的请求是 `auth`：
   ```json
   {"id": 1, "method": "auth", "params": {"token": "<user://aiplay.token 的内容>"}}
   ```
3. 未鉴权的连接只能发 `auth`；其它方法一律返回 `unauthorized` 错误。
4. 连续 3 次 token 错误即断开；未鉴权连接最多存活 600 帧。
5. token 比较使用定长时间比较，不做长度短路。

关闭鉴权：`aiplay/require_token=false` 或 `--aiplay-no-token`（仅本机调试，不推荐）。
桥会自动从各平台 `user://` 默认位置读取 token；也可用 `--token` / `AIPLAY_TOKEN` /
`--token-file` / `AIPLAY_TOKEN_FILE` 指定。

## 默认开关（全部默认关闭/最严）

| 项目设置 | 默认 | 作用 |
|---|---|---|
| `aiplay/enabled` | `false` | 运行时服务总开关 |
| `aiplay/port` | `8765` | 监听端口 |
| `aiplay/require_token` | `true` | 要求连接先 `auth` |
| `aiplay/allow_call` | `false` | 打开 `call` 逃生舱（仍须逐条登记白名单） |
| `aiplay/allow_time_scale` | `false` | 允许改写 `Engine.time_scale` |

编辑器插件启用时注册 autoload `AIPlay` 与上述设置项，**但不写盘**——
不用 `ProjectSettings.save()` 悄悄改用户的 `project.godot`。

## 方法

### 鉴权

| method | params | result |
|---|---|---|
| `auth` | `{token}` | `{authed: true, required: bool}` 未鉴权连接唯一可调的方法 |

### 只读

| method | params | result |
|---|---|---|
| `ping` | — | `{protocol, game, engine, auth_required}` |
| `state` | — | 快照（见下） |
| `actions` | — | `{actions: [...]}` provider 优先，否则由可见按钮派生 |
| `tools` | — | `{tools: [...]}` 游戏在 `aiplay_tools` 组声明的 `AIPLAY_TOOLS` |

### 动作

| method | params | result |
|---|---|---|
| `invoke` | `{tool: "game_x", args: {...}}` | `{result, state}` 参数按声明类型强转；多余/缺失参数都报错 |
| `click` | `{id}` | `{clicked, state}` 对 `BaseButton` 发 `pressed`；**不可见或 disabled 一律拒绝** |
| `press` | `{action, pressed?}` | `{action, pressed, state}` `Input.action_press/release` |
| `key` | `{key}` 或 `{keycode}`，`pressed?` | `{key, pressed, state}` `Input.parse_input_event` |
| `call` | `{path, method, args?}` | `{result, state}` 逃生舱，默认关闭；开启后只认登记过的方法名+节点对 |
| `wait` | `{frames}` 或 `{seconds}` | `{state}` 等 N 个物理帧 |
| `wait_until` | `{expr, max_frames?}` | `{timeout: bool, state}` 条件等待（见下） |
| `time_scale` | `{scale}` | `{time_scale, state}` 默认关闭 |

**业务失败 vs 协议失败**：`invoke` 调用的游戏方法返回 `{"ok": false, "error": "..."}`
时，协议层仍是 `ok: true`（调用成功，业务说不行）；只有参数不合法、工具不存在这类
调用方式错误才走 `ok: false`。两种必须分清，否则调用方无法判断该改参数还是该改策略。

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

- `elements`：当前场景内**可见**的 `BaseButton`（自动）或 `aiplay_element` 组成员（`Control`），上限 60。
- `id` 是稳定寻址：`/<场景名>/<相对路径>`。
- `label`：`aiplay_label` 元数据 > 按钮文本 > 节点名。
- `game`：`register_state_provider` 返回的字典；JSON 超 4KB 时字符串逐级截断并标 `truncated`。

## `wait_until` 断言语法

- `expr`：`key op literal`，多条件以 ` and ` 连接（不区分大小写），**最多 3 个**。
- `op`：`==` `!=` `>` `<` `>=` `<=`；`literal`：`true`/`false`、数字、`"字符串"`、裸词。
- 比较针对 `game` **顶层键**（不支持 `a.b` 这种嵌套路径）。
- `max_frames` 默认 3600（物理帧）。超时返回 `{timeout: true, state}`。

**已知限制（协议天花板，不是实现 bug）**：只能断言顶层扁平键，所以开发者必须把
要等的状态摊平进 game 字典（demo 的 `plot0_progress` 就是这么来的）。这意味着
"统一约定"只统一了断言语法，没有统一状态形状——每款游戏仍得自己定一套摊平规则。
v0.4 若要让 `wait_until` 真正跨游戏通用，得给 `game` 加一层路径寻址或让 provider
声明可等待字段。

## 游戏侧接入（开发者视角）

```gdscript
# 1) 元素标注
$PlantButton.set_meta("aiplay_label", "种植萝卜")
$DebugPanel.add_to_group("aiplay_hidden")

# 2) 状态与动作 provider（可选）
AIPlay.register_state_provider(func() -> Dictionary: return {"gold": gold})
AIPlay.register_actions_provider(func() -> Array: return [{"action": "plant", "plot": 0}])

# 3) 语义动作：节点加入组 aiplay_tools + 声明常量
const AIPLAY_TOOLS = {
  "plant": {"description": "种植", "args": {"plot": "int", "seed": "string"}},
}
# 对应方法 func plant(plot: int, seed: String) -> Variant

# 4) 逃生舱（可选，且必须同时打开 aiplay/allow_call）
AIPlay.register_callable("status", ".")   # "." = 场景根
```

`args` 类型：`int`/`float`/`string`/`bool`；JSON 数字到 int 要求整数值。

## MCP 桥 `bridge/server.mjs`

零依赖 Node ≥22（全局 WebSocket）。stdio 换行分隔 JSON-RPC 2.0。

- 静态工具：12 个 `aiplay_*`（协议方法 1:1，含 `aiplay_call`，即便被禁用也列出——
  Agent 需要看到"有这个能力但被关了"的明确报错，而不是工具凭空消失）。
- 动态工具：连接后拉 `tools`，每个声明生成 `game_*`（参数 schema 自动推导，全部必填）。
- **自动鉴权**：从 `user://` 默认位置读 token 并在连接后立即 `auth`。
- **能力声明诚实**：只有当客户端在 `initialize` 里声明 `capabilities.tools.listChanged`
  时才回 `listChanged: true`，并且真的在游戏上线导致动态工具集变化时发
  `notifications/tools/list_changed`。
- `wait`/`wait_until` 的 MCP 超时按 `max_frames` 推导（上限 600s）。

## 安全边界

| 边界 | 做法 | 已验证 |
|---|---|---|
| 外部网络 | 只绑 `127.0.0.1` | ✅ |
| 本机浏览器 | token 鉴权（Origin 在引擎层取不到） | ✅ 未鉴权连接读不到任何状态 |
| 连接耗尽 | 连接数上限 8 + 未鉴权 600 帧超时 + 3 次错 token 断开 | ✅ |
| 任意代码执行 | 无 eval / Expression | ✅ |
| 状态篡改 | `call` 默认关；开启后只认登记的方法名+节点对，且拦截 `set`/`call_deferred`/`set_script` 等 | ✅ 实测绕过失败 |
| 越权点击 | `click` 校验 `is_visible_in_tree()` + `disabled` | ✅ 置灰/隐藏按钮点了无效 |
| 时间作弊 | `time_scale` 默认关（放置游戏压时间等于印钱） | ✅ |
| 快照体积 | elements ≤60、game ≤4KB，超限标 `truncated` | ✅ 实测 735B |

**仍然存在的风险（诚实声明）**：
- `invoke` 调用的是开发者自己写的方法。协议无法替你保证那句 `harvest()` 里没有后门。
- 白名单是"方法名 → 节点路径"的绑定，挡的是越权调用，挡不住游戏方法自身的业务 bug。
- token 存在 `user://`，同机其它进程若以同一用户身份运行可以读到它。
  这是本机工具的一般性问题；跨用户隔离靠操作系统的文件权限。
- 没有真实鼠标注入，所以遮挡、多点触控这类"物理世界"问题不在协议范围内。
