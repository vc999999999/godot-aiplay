# godot-aiplay

让外部 AI Agent 以"玩家"身份试玩你的 Godot 游戏：本地 WebSocket 协议 + MCP 桥。

AIPlay 是一个 Godot 插件（`addons/aiplay/`）：编辑器层注册 autoload 与设置项，运行时层随游戏导出。协议版本 **`aiplay/0.2`**。协议正文见 [PROTOCOL.md](PROTOCOL.md)。

```
AI Agent ──MCP stdio──> bridge/server.mjs ──ws://127.0.0.1:8765──> Godot 游戏 (AIPlay autoload)
```

## 30 秒上手

```bash
# 1) 克隆本仓库，把 addons/aiplay/ 拷进你的 Godot 4.7+ 项目，启用插件
#    （插件会注册 autoload "AIPlay" 和项目设置 aiplay/enabled、aiplay/port）
# 2) 游戏里设 aiplay/enabled = true（或运行加 --aiplay）
# 3) 按 PROTOCOL.md「游戏侧接入」做三类标注（可选，零标注也能用）
```

```bash
# 4) 起 MCP 桥（Node >= 22，零依赖）
node bridge/server.mjs
# 游戏没起也行：tools/list 只回静态工具
```

MCP 客户端配置示例（Claude Desktop / 兼容 MCP 的 Agent）：

```json
{
  "mcpServers": {
    "aiplay": { "command": "node", "args": ["/path/to/godot-aiplay/bridge/server.mjs"] }
  }
}
```

## 本仓库自带 demo

`demo/` 是一个迷你菜地（放置游戏）：种子 → 生长 → 收获，演示了全部三类接入。直接用 Godot 打开本仓库即玩：

```bash
Godot --path .            # 开窗口（aiplay/enabled=true 已在 project.godot）
# 另一个终端：
node bridge/server.mjs    # 然后让 Agent 调 aiplay_state / game_plant / game_harvest / aiplay_wait_until
```

无头冒烟（验证用）：

```bash
Godot --headless --path . -- --aiplay     # 强制开 WS，供协议测试
```

## 设计要点

- **语义优先**：快照给 `game` 字典 + 元素标签，不给节点树；Agent 看到的是"金币 120、地块2 已熟"而不是 400 个节点。
- **等待内建**：`wait`/`wait_until` 在游戏物理帧上判定，不靠 Agent 轮询——放置游戏的核心就是"等"。
- **安全默认**：默认关闭、只绑回环、不提供任意代码执行、`call` 逃生舱带守卫。
- **渐进接入**：零标注时 `state` 仍给按钮快照、`actions` 从按钮派生；标注越多 Agent 越聪明。

## 协议方法一览

`ping` `state` `actions` `tools` `invoke` `click` `press` `key` `call` `wait` `wait_until` `time_scale` —— 详见 [PROTOCOL.md](PROTOCOL.md)。

## License

MIT
