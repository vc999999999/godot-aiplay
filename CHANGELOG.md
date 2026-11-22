# Changelog

## v0.3.0 — 2026-11-22

**不兼容变更**：连接后第一个请求必须是 `auth`（`aiplay/0.2` 客户端需补一步握手）。

这一版只做一件事：把 v0.2 文档里写着"不可妥协"、代码里却没做到的地方补齐。
下面四条安全修复都在改之前先复现、改之后再跑一遍原攻击脚本验证（见 `tests/`）。

### 安全修复

- **`call` 逃生舱改为默认关闭 + 显式白名单。**
  v0.2 的黑名单只挡方法名字符串，实测三种绕过全部成功：
  `call_deferred("queue_free")` 能删节点、`set_script(null)` 能废节点、
  `set("gold", 9999)` 能直接改游戏状态——最后一条正好违反了"永不引入任意代码执行、
  AI 应像玩家一样操作"的立场。现在判定标准反过来：只有开发者用
  `register_callable(method, node_path)` 登记过的方法名 + 节点对才放行，
  且 `set`/`call_deferred`/`set_script`/`free`/`__` 开头一类方法即使登记也拒绝。
- **`click` 与真人同权。** v0.2 直接 `pressed.emit()`，能把 `disabled=true` 的按钮
  按下去（实测种子从 998 变 997），也能点 `visible=false` 的按钮。
  现在先校验 `is_visible_in_tree()` 与 `disabled`。
- **token 鉴权。** v0.2 只绑回环，但任何网页的 JS 都能连 `127.0.0.1`。
  实测带 `Origin: https://evil.example.com` 的握手直接拿到 `101 Switching Protocols`。
  Godot 服务端读不到入站 Origin（`get_handshake_headers()` 为空、`StreamPeerTCP`
  无 peek），所以改用凭据：首次启动生成 token 写入 `user://aiplay.token`，
  未鉴权连接只能调 `auth`。桥会自动读取并完成握手。
- **连接资源上限。** 连接数上限 8；未鉴权连接 600 帧后关闭；连续 3 次错 token 断开。
  v0.2 的 `_peers` 无上限，恶意页面开几千个连接即可拖垮游戏。
- **`time_scale` 默认关闭。** 实测 `time_scale=20` 把 4 秒成熟压到 214ms（快 18.3 倍）。
  放置游戏里时间就是唯一资源，这个口子等于印钞；限时决策游戏里等于无限思考时间。

### 修复

- **`invoke` 不再静默丢弃多余参数。** 传错参数名时 v0.2 表现为"什么都没发生"，
  极难排查；现在返回 `unknown arg(s): ... (accepted: ...)`。
- **MCP 桥不再谎报能力。** v0.2 固定回 `capabilities.tools.listChanged: true`，
  却从不发 `notifications/tools/list_changed`。现在只在客户端声明支持时才回 true，
  并在游戏上线、动态工具集变化时真的发通知。
- **编辑器插件不再写盘。** v0.2 在 `_enter_tree` 里调 `ProjectSettings.save()`，
  等于启用插件就悄悄改用户的 `project.godot`——而这正是 v0.2 用来批评
  Erodenn 式注入的理由。现在只登记设置项与默认值，保存与否由开发者决定。

### 测试

- **测试套件可重复跑。** v0.2 的 30 项断言假设游戏是全新状态（`seeds===5`、`gold===0`），
  实测第二次跑 21 通过 9 失败——那不是回归测试，是 demo 回放。
  现在每个用例前调 `game_reset`，套件连跑三次均 42/42。
  桥测试 11/11。
- **安全断言改成验证状态不变。** 只看返回 `error` 会漏掉"返回 200 + 状态被改"
  这类真漏洞；现在比对玩家能据此获利的键（gold/seeds/harvested/地块状态），
  不比对每帧都在变的 `progress`。
- 新增拒绝路径用例：未鉴权读状态、错 token、置灰按钮点击、隐藏按钮点击、
  `call` 在默认关闭下被拒、`call` 开启后越权方法/未登记方法/跨节点调用被拒。

### 变更

- 协议版本 `aiplay/0.2` → `aiplay/0.3`。
- 新增项目设置：`aiplay/require_token`（默认 true）、`aiplay/allow_call`（默认 false）、
  `aiplay/allow_time_scale`（默认 false）。
- `ping` 新增 `auth_required` 字段。
- demo 新增 `reset` / `set_plot_disabled` / `set_plot_visible` 三个测试辅助动作。
- 补上 v0.2 文档引用但仓库里不存在的 `REFERENCE-REVIEW.md`、`BUILDLOG.md`。

## v0.2.0 — 2026-11-22

- 语义动作注册（`AIPLAY_TOOLS`）、桥动态工具、`wait_until`、快照预算、`call` 守卫、`time_scale`。
- demo 加"菜地"。

## v0.1.0 — 2026-11-21

- 协议骨架 + 插件 + 桥 + 演示「抢 21」。
