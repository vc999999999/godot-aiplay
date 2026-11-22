# Build Log

记录每个版本的**实测证据**，不是设计意图。凡写"通过"，都能用本文件末尾的命令重跑。

## v0.3 — 2026-11-22

### 环境

| 项 | 值 |
|---|---|
| Godot | 4.7.2.stable.official.ed1daf0bf |
| Node | v25.2.1 |
| OS | macOS |

### 修复前：先复现四个问题

改代码之前，先用独立脚本打了一遍 v0.2，确认这些不是推测：

```
# 1. click 越过 disabled
set Plot0.disabled = true
click /Main/RootBox/PlotBox/Plot0
→ seeds 998 → 997        （被按住也种上了）

# 2. click 越过 visible
set Plot2.visible = false
（快照里 Plot2 已消失）
click /Main/RootBox/PlotBox/Plot2
→ plot2_state = "growing" （看不见的按钮点上了）

# 3. call 守卫三种绕过
call /root/Main set("gold", 9999)                      → gold = 9999
call /Main/RootBox/PlotBox/Plot1 call_deferred("queue_free")
  → 快照 before: StatsLabel,Plot0,Plot1
  → 快照 after : StatsLabel,Plot0                      （节点真被删了）
call /Main/RootBox/PlotBox/Plot2 set_script(null)       → 快照里消失

# 4. 浏览器来源不受限
GET / HTTP/1.1
Origin: https://evil.example.com
→ HTTP/1.1 101 Switching Protocols

# 5. time_scale 数值影响
正常速度 4 秒成熟：4017ms
time_scale=20    ：214ms     （18.3 倍）
```

引擎能力核查（决定了 Origin 白名单走不通）：

```
WebSocketPeer 服务端 get_handshake_headers() → []      # 拿不到 Origin
StreamPeerTCP 方法列表                          → 无 peek_buffer / 无 peek
```

### 修复后：同一批攻击重跑

```
call set → blocked: call is disabled (set aiplay/allow_call=true and register callables)
call_deferred → blocked: 同上
未鉴权 invoke → {"ok": false, "error": "unauthorized: send {\"method\":\"auth\"...} first"}
节点数 4→4，winnable 状态完全一致 → STATE UNCHANGED: true
```

再把 `allow_call=true` 打开、只登记 `status@"/"` 一个方法，验证白名单本身的深度：

```
call status（白名单内）      → 放行，返回 state
call set gold               → blocked: method not allowed: set
call_deferred queue_free    → blocked: method not allowed: call_deferred
call set_script null        → blocked: method not allowed: set_script
call free                   → blocked: method not allowed: free
call harvest（未登记）       → blocked: method not registered as callable: harvest
status 打 /root/AIPlay      → blocked: callable 'status' is bound to .
gold 0 → 0，unchanged: true
```

### 测试结果

```
Godot --headless --path . -- --aiplay &
node tests/smoke_ws.mjs

RUN 1: 42 passed, 0 failed
RUN 2: 42 passed, 0 failed      ← v0.2 在这里是 21/9
RUN 3: 42 passed, 0 failed

node tests/smoke_bridge.mjs
11 passed, 0 failed
```

编译检查：`--check-only --script` 对 `aiplay.gd`、`plugin.gd`、`farm.gd` 三个文件均无输出。

### 快照体积实测

```
state JSON: 735 bytes | elements: 4 | game: 321 bytes
```

## v0.2 — 2026-11-22

- 三套验收（抢 21 回归 / 种菜闭环 / 桥验收）首跑全绿。
- 30 项 WS 断言 + 8 项桥断言。
- **遗留问题**：断言依赖全新状态，第二次跑 21/9；上面列的五条安全项当时未测。

## v0.1 — 2026-11-21

- 协议骨架 + 插件 + 桥 + 「抢 21」演示，脚本 Agent 经协议 6 轮打到 21 获胜。

---

## 复现命令

```bash
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AIPlay Demo/aiplay.token"
$GODOT --headless --path . -- --aiplay > /tmp/aiplay.log 2>&1 &
sleep 8 && tail -3 /tmp/aiplay.log

node tests/smoke_ws.mjs          # 42 项，可重复跑
node tests/smoke_bridge.mjs      # 11 项

pkill -f "Godot --headless --path ."
```

token 自动生成在 `~/Library/Application Support/Godot/app_userdata/AIPlay Demo/aiplay.token`
（Linux：`~/.local/share/godot/app_userdata/...`，Windows：`%APPDATA%\Godot\app_userdata\...`）。
