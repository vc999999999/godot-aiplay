# godot-aiplay

让外部 AI Agent 以"玩家"身份试玩你的 Godot 游戏：本地 WebSocket 协议 + MCP 桥。

AIPlay 是一个 Godot 插件（`addons/aiplay/`）：编辑器层注册 autoload 与设置项，运行时层随游戏导出。
协议版本 **`aiplay/0.3`**。协议正文见 [PROTOCOL.md](PROTOCOL.md)，版本变更见 [CHANGELOG.md](CHANGELOG.md)。

```
AI Agent ──MCP stdio──> bridge/server.mjs ──ws://127.0.0.1:8765 (auth)──> Godot 游戏 (AIPlay autoload)
```

## 30 秒上手

```bash
# 1) 克隆本仓库，把 addons/aiplay/ 拷进你的 Godot 4.7+ 项目，启用插件
#    （插件会注册 autoload "AIPlay" 和 aiplay/* 设置项，不写你的 project.godot）
# 2) 设 aiplay/enabled = true（或运行加 --aiplay）
# 3) 按 PROTOCOL.md「游戏侧接入」做三类标注（可选，零标注也能用）
```

```bash
# 4) 起 MCP 桥（Node >= 22，零依赖）。它会自动读取 user:// 下的 token 完成鉴权
node bridge/server.mjs
# 游戏没起也行：tools/list 只回静态工具，游戏上线后桥会发 list_changed 通知
```

MCP 客户端配置（Claude Desktop / 兼容 MCP 的 Agent）：

```json
{
  "mcpServers": {
    "aiplay": { "command": "node", "args": ["/path/to/godot-aiplay/bridge/server.mjs"] }
  }
}
```

如果你的游戏 `application/config/name` 不是 `AIPlay Demo`，给桥加 `--project "<游戏名>"`
或直接 `--token-file <绝对路径>`。

## 本仓库自带 demo

`demo/` 是一个迷你菜地（放置游戏）：种子 → 生长 → 收获，演示了全部三类接入。
直接用 Godot 打开本仓库即玩：

```bash
Godot --path .            # 开窗口（aiplay/enabled=true 已在 project.godot）
# 另一个终端：
node bridge/server.mjs    # 然后让 Agent 调 aiplay_state / game_plant / game_harvest / aiplay_wait_until
```

无头跑测试：

```bash
Godot --headless --path . -- --aiplay &
node tests/smoke_ws.mjs        # 42 项，可重复跑（每个用例前自清理）
node tests/smoke_bridge.mjs    # 11 项
```

## 设计要点

- **语义优先**：快照给 `game` 字典 + 元素标签，不给节点树；Agent 看到的是
  "金币 120、地块2 已熟"而不是 400 个节点。
- **等待内建**：`wait`/`wait_until` 在游戏物理帧上判定，不靠 Agent 轮询——
  放置游戏的核心就是"等"。
- **默认最严**：服务默认关、只绑回环、**token 鉴权**（挡浏览器直连本地端口）、
  无任意代码执行、`call` 逃生舱默认关且要逐条白名单、`click` 与真人同权
  （置灰/隐藏的按钮点不动）、`time_scale` 默认关。
- **渐进接入**：零标注时 `state` 仍给按钮快照、`actions` 从按钮派生；标注越多 Agent 越聪明。

安全边界的完整清单（含"仍然存在的风险"）见 [PROTOCOL.md](PROTOCOL.md) 末尾。
实测证据见 [BUILDLOG.md](BUILDLOG.md)——每条修复都附了"改之前怎么复现、改之后怎么验证"。

## 协议方法一览

`auth` `ping` `state` `actions` `tools` `invoke` `click` `press` `key` `call`
`wait` `wait_until` `time_scale` —— 详见 [PROTOCOL.md](PROTOCOL.md)。

## 已知限制

- `wait_until` 只能断言 `game` 的**顶层扁平键**，每款游戏须自己设计摊平规则。
  这是协议层的天花板（详见 PROTOCOL.md），不是实现 bug。
- 只在自家 demo 上验证过。没有第二个采用者的 Godot 游戏之前，不宣称通用性。
- 没有真实鼠标注入，遮挡/多点触控类问题不在范围内。

## License

MIT
