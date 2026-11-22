#!/usr/bin/env node
// MCP 桥冒烟测试：spawn bridge/server.mjs，走 initialize → tools/list → tools/call。
// 需游戏已在 ws://127.0.0.1:8765 运行（动态 game_* 工具才会出现）。
//
// 覆盖三件桥自己的事（协议本身由 smoke_ws.mjs 负责）：
//   1. 凭据能从 user:// 默认位置读到并自动完成 auth
//   2. listChanged 能力只在客户端声明时才回 true（说了就要做得到）
//   3. 调用完自清理，套件可重复跑

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bridge = join(here, "..", "bridge", "server.mjs");
const PROTOCOL = "aiplay/0.3";

const child = spawn("node", [bridge], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "";
const replies = [];
const notifications = [];
let passed = 0, failed = 0;

child.stdout.on("data", (d) => {
	buf += d.toString();
	let idx;
	while ((idx = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, idx).trim();
		buf = buf.slice(idx + 1);
		if (!line) continue;
		let msg;
		try { msg = JSON.parse(line); } catch { continue; }
		if (msg.method) notifications.push(msg);
		else replies.push(msg);
	}
});

function send(msg) {
	child.stdin.write(JSON.stringify(msg) + "\n");
}

function waitReply(id, timeoutMs = 20000) {
	return new Promise((resolve, reject) => {
		const t0 = Date.now();
		const iv = setInterval(() => {
			const r = replies.find((x) => x.id === id);
			if (r) { clearInterval(iv); resolve(r); }
			else if (Date.now() - t0 > timeoutMs) { clearInterval(iv); reject(new Error("reply timeout id=" + id)); }
		}, 20);
	});
}

function check(name, cond, extra = "") {
	if (cond) { passed++; console.log("  PASS", name); }
	else { failed++; console.log("  FAIL", name, extra); }
}

function textOf(r) {
	return (r && r.result && r.result.content && r.result.content[0] && r.result.content[0].text) || "";
}

async function main() {
	// 客户端声明支持 listChanged：桥应当回 true，并在游戏上线时主动推通知
	send({
		jsonrpc: "2.0", id: 1, method: "initialize",
		params: {
			protocolVersion: "2024-11-05",
			capabilities: { tools: { listChanged: true } },
			clientInfo: { name: "smoke", version: "0" },
		},
	});
	const init = await waitReply(1);
	check("initialize", init.result && init.result.serverInfo.name === "aiplay-bridge", JSON.stringify(init).slice(0, 120));
	check("capability matches client", init.result.capabilities.tools.listChanged === true,
		JSON.stringify(init.result.capabilities));

	send({ jsonrpc: "2.0", method: "notifications/initialized" });

	send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
	const tl = await waitReply(2, 25000);
	const names = (tl.result.tools || []).map((t) => t.name);
	check("tools/list static", ["aiplay_ping", "aiplay_state", "aiplay_wait_until", "aiplay_call"].every((n) => names.includes(n)));
	check("tools/list dynamic (auth worked)", ["game_plant", "game_harvest", "game_status"].every((n) => names.includes(n)),
		names.filter((n) => n.startsWith("game_")).join(","));
	const plantTool = (tl.result.tools || []).find((t) => t.name === "game_plant");
	check("game_plant schema",
		plantTool && plantTool.inputSchema.properties.plot && plantTool.inputSchema.required.includes("plot"),
		JSON.stringify(plantTool && plantTool.inputSchema));

	// 每个 case 自清理：否则第二次跑就是另一套断言
	send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "game_reset", arguments: {} } });
	await waitReply(3);

	const pingText = textOf(await (async () => {
		send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "aiplay_ping", arguments: {} } });
		return waitReply(4);
	})());
	check("call aiplay_ping", pingText.includes(PROTOCOL), pingText.slice(0, 120));

	const stText = textOf(await (async () => {
		send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "game_status", arguments: {} } });
		return waitReply(5);
	})());
	check("call game_status", stText.includes('"gold"'), stText.slice(0, 120));

	const plText = textOf(await (async () => {
		send({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "game_plant", arguments: { plot: 2, seed: "radish" } } });
		return waitReply(6);
	})());
	check("call game_plant", plText.includes('"ok":true'), plText.slice(0, 120));

	const wuText = textOf(await (async () => {
		send({ jsonrpc: "2.0", id: 7, method: "tools/call", params: { name: "aiplay_wait_until", arguments: { expr: "plot2_progress >= 1.0", max_frames: 600 } } });
		return waitReply(7, 40000);
	})());
	check("call aiplay_wait_until", wuText.includes('"timeout":false'), wuText.slice(0, 120));

	// call 默认关：桥必须把错误如实带回，而不是假装成功
	const callText = textOf(await (async () => {
		send({ jsonrpc: "2.0", id: 8, method: "tools/call", params: { name: "aiplay_call", arguments: { path: "/root/Main", method: "status" } } });
		return waitReply(8);
	})());
	check("aiplay_call disabled surfaces error", callText.includes("disabled"), callText.slice(0, 120));

	// 收尾
	send({ jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "game_reset", arguments: {} } });
	await waitReply(9);

	check("no list_changed spam while stable",
		notifications.filter((n) => n.method === "notifications/tools/list_changed").length <= 1,
		String(notifications.length));

	child.kill();
	console.log(`\n${passed} passed, ${failed} failed`);
	process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error("BRIDGE SMOKE ERROR:", e); child.kill(); process.exit(1); });
