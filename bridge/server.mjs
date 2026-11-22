#!/usr/bin/env node
// AIPlay MCP 桥（stdio JSON-RPC ↔ ws://127.0.0.1:8765，协议 aiplay/0.2）
// 零依赖：Node >= 22（全局 WebSocket）。
//   node bridge/server.mjs [--url ws://127.0.0.1:8765]
//   AIPLAY_URL=ws://127.0.0.1:8765 node bridge/server.mjs
// 游戏未启动时桥照常工作，动态 game_* 工具为空。

import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
const urlIdx = argv.indexOf("--url");
const WS_URL = urlIdx >= 0 ? argv[urlIdx + 1] : (process.env.AIPLAY_URL || "ws://127.0.0.1:8765");

// ---------------------------------------------------------------------------
// WebSocket 客户端（懒连接，用完不断开；断了下次调用自动重连）
// ---------------------------------------------------------------------------

let ws = null;
let wsReady = null;
let nextId = 1;
const pending = new Map();

function connect() {
	if (ws && ws.readyState === WebSocket.OPEN) return Promise.resolve(ws);
	if (wsReady) return wsReady;
	wsReady = new Promise((resolve, reject) => {
		const sock = new WebSocket(WS_URL);
		const timer = setTimeout(() => {
			try { sock.close(); } catch {}
			wsReady = null;
			reject(new Error("connect timeout: " + WS_URL));
		}, 4000);
		sock.onopen = () => {
			clearTimeout(timer);
			ws = sock;
			wsReady = null;
			resolve(sock);
		};
		sock.onerror = () => {
			clearTimeout(timer);
			wsReady = null;
			reject(new Error("connect failed: " + WS_URL));
		};
		sock.onclose = () => { ws = null; };
		sock.onmessage = (ev) => onWsMessage(ev);
	});
	return wsReady;
}

function onWsMessage(ev) {
	let msg;
	try { msg = JSON.parse(ev.data); } catch { return; }
	if (msg.id === undefined || msg.id === null) return;
	const p = pending.get(msg.id);
	if (!p) return;
	pending.delete(msg.id);
	clearTimeout(p.timer);
	if (msg.ok) p.resolve(msg.result);
	else p.reject(new Error(msg.error || "aiplay error"));
}

function call(method, params, timeoutMs = 30000) {
	return connect().then((sock) => new Promise((resolve, reject) => {
		const id = nextId++;
		const timer = setTimeout(() => {
			pending.delete(id);
			reject(new Error("aiplay call timeout: " + method));
		}, timeoutMs);
		pending.set(id, { resolve, reject, timer });
		sock.send(JSON.stringify({ id, method, params: params ?? {} }));
	}));
}

function timeoutFor(method, args) {
	const a = args || {};
	let frames = 0;
	if (method === "wait") {
		frames = a.frames || Math.round((a.seconds || 0) * 60);
	} else if (method === "wait_until") {
		frames = a.max_frames || 3600;
	}
	if (frames > 0) {
		return Math.min(Math.max(30000, (frames / 60) * 1000 + 15000), 600000);
	}
	return 30000;
}

// ---------------------------------------------------------------------------
// MCP 工具面：8+ 静态 aiplay_*（协议方法 1:1）+ 动态 game_*（游戏声明）
// ---------------------------------------------------------------------------

const STATIC_TOOLS = [
	["aiplay_ping", "ping", "连通性、游戏名、协议版本", {}],
	["aiplay_state", "state", "状态快照（scene/game/elements）", {}],
	["aiplay_actions", "actions", "当前合法动作", {}],
	["aiplay_tools", "tools", "游戏声明的语义动作清单", {}],
	["aiplay_invoke", "invoke", "调用 game_* 语义动作", {
		type: "object",
		properties: { tool: { type: "string" }, args: { type: "object" } },
		required: ["tool"],
	}],
	["aiplay_click", "click", "对界面元素触发语义点击", {
		type: "object",
		properties: { id: { type: "string" } },
		required: ["id"],
	}],
	["aiplay_press", "press", "按下/释放 InputMap 动作", {
		type: "object",
		properties: { action: { type: "string" }, pressed: { type: "boolean" } },
		required: ["action"],
	}],
	["aiplay_key", "key", "注入键盘事件", {
		type: "object",
		properties: {
			key: { type: "string" }, keycode: { type: "integer" }, pressed: { type: "boolean" },
		},
	}],
	["aiplay_call", "call", "对节点调任意方法（逃生舱，带守卫）", {
		type: "object",
		properties: { path: { type: "string" }, method: { type: "string" }, args: { type: "array" } },
		required: ["method"],
	}],
	["aiplay_wait", "wait", "等 N 个物理帧后返回快照", {
		type: "object",
		properties: { frames: { type: "integer" }, seconds: { type: "number" } },
	}],
	["aiplay_wait_until", "wait_until", "条件等待（受限断言语法）", {
		type: "object",
		properties: { expr: { type: "string" }, max_frames: { type: "integer" } },
		required: ["expr"],
	}],
	["aiplay_time_scale", "time_scale", "设 Engine.time_scale（0.1–20）", {
		type: "object",
		properties: { scale: { type: "number" } },
		required: ["scale"],
	}],
];

const ARG_TYPES = { int: "integer", float: "number", string: "string", bool: "boolean" };

function argsToSchema(args) {
	const properties = {};
	const required = [];
	if (args && typeof args === "object") {
		for (const [k, t] of Object.entries(args)) {
			properties[k] = { type: ARG_TYPES[t] || "string" };
			required.push(k);
		}
	}
	return { type: "object", properties, required };
}

async function listTools() {
	const tools = STATIC_TOOLS.map(([name, , description, schema]) => ({
		name, description, inputSchema: schema,
	}));
	try {
		const res = await call("tools", {}, 5000);
		const list = res && Array.isArray(res.tools) ? res.tools : [];
		for (const t of list) {
			tools.push({
				name: t.name,
				description: t.description || "",
				inputSchema: argsToSchema(t.args),
			});
		}
	} catch {
		// 游戏未启动：动态工具为空
	}
	return { tools };
}

async function callTool(name, args) {
	if (typeof name === "string" && name.startsWith("game_")) {
		return call("invoke", { tool: name, args: args || {} }, timeoutFor("invoke", args));
	}
	const t = STATIC_TOOLS.find((x) => x[0] === name);
	if (!t) throw new Error("unknown tool: " + name);
	return call(t[1], args || {}, timeoutFor(t[1], args));
}

// ---------------------------------------------------------------------------
// MCP stdio：换行分隔的 JSON-RPC 2.0；stdout 只走协议，日志走 stderr
// ---------------------------------------------------------------------------

function respond(id, result) {
	process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function respondError(id, code, message) {
	process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

async function handle(msg) {
	const { id, method, params } = msg;
	const isNotif = id === undefined || id === null;
	try {
		let result;
		switch (method) {
			case "initialize":
				result = {
					protocolVersion: (params && params.protocolVersion) || "2024-11-05",
					capabilities: { tools: { listChanged: true } },
					serverInfo: { name: "aiplay-bridge", version: "0.2.0" },
				};
				break;
			case "ping":
				result = {};
				break;
			case "tools/list":
				result = await listTools();
				break;
			case "tools/call": {
				const { name, arguments: targs } = params || {};
				try {
					const r = await callTool(name, targs || {});
					result = { content: [{ type: "text", text: JSON.stringify(r) }] };
				} catch (e) {
					result = {
						content: [{ type: "text", text: String((e && e.message) || e) }],
						isError: true,
					};
				}
				break;
			}
			default:
				// notifications/* 与未知方法：通知不回，未知方法回 -32601
				if (!isNotif && typeof method === "string" && !method.startsWith("notifications/")) {
					return respondError(id, -32601, "method not found: " + method);
				}
				return;
		}
		if (!isNotif) respond(id, result);
	} catch (e) {
		if (!isNotif) respondError(id, -32603, String((e && e.message) || e));
	}
}

const rl = createInterface({ input: process.stdin, terminal: false });
rl.on("line", (line) => {
	line = line.trim();
	if (!line) return;
	let msg;
	try {
		msg = JSON.parse(line);
	} catch {
		return;
	}
	handle(msg).catch((e) => {
		if (msg.id !== undefined && msg.id !== null) {
			respondError(msg.id, -32603, String((e && e.message) || e));
		}
	});
});

console.error("aiplay-bridge ready -> " + WS_URL);
