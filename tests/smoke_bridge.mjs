#!/usr/bin/env node
// MCP 桥冒烟测试：spawn bridge/server.mjs，走 initialize → tools/list → tools/call。
// 需游戏已在 ws://127.0.0.1:8765 运行（动态 game_* 工具才会出现）。

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const bridge = join(here, "..", "bridge", "server.mjs");

const child = spawn("node", [bridge], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "";
const replies = [];
let passed = 0, failed = 0;

child.stdout.on("data", (d) => {
	buf += d.toString();
	let idx;
	while ((idx = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, idx).trim();
		buf = buf.slice(idx + 1);
		if (!line) continue;
		try { replies.push(JSON.parse(line)); } catch {}
	}
});

function send(msg) {
	child.stdin.write(JSON.stringify(msg) + "\n");
}

function waitReply(id, timeoutMs = 15000) {
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

async function main() {
	send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "smoke", version: "0" } } });
	const init = await waitReply(1);
	check("initialize", init.result && init.result.serverInfo && init.result.serverInfo.name === "aiplay-bridge", JSON.stringify(init).slice(0, 120));

	send({ jsonrpc: "2.0", method: "notifications/initialized" });

	send({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} });
	const tl = await waitReply(2, 20000);
	const names = (tl.result.tools || []).map((t) => t.name);
	check("tools/list static", ["aiplay_ping", "aiplay_state", "aiplay_wait_until", "aiplay_call"].every((n) => names.includes(n)), names.slice(0, 5).join(","));
	check("tools/list dynamic", ["game_plant", "game_harvest", "game_status"].every((n) => names.includes(n)), names.filter((n) => n.startsWith("game_")).join(","));
	const plantTool = (tl.result.tools || []).find((t) => t.name === "game_plant");
	check("game_plant schema", plantTool && plantTool.inputSchema && plantTool.inputSchema.properties.plot && plantTool.inputSchema.required.includes("plot"), JSON.stringify(plantTool && plantTool.inputSchema));

	send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "aiplay_ping", arguments: {} } });
	const ping = await waitReply(3);
	const pingText = ping.result && ping.result.content && ping.result.content[0] && ping.result.content[0].text;
	check("call aiplay_ping", pingText && pingText.includes("aiplay/0.2"), pingText);

	send({ jsonrpc: "2.0", id: 4, method: "tools/call", params: { name: "game_status", arguments: {} } });
	const st = await waitReply(4);
	const stText = st.result && st.result.content && st.result.content[0] && st.result.content[0].text;
	check("call game_status", stText && stText.includes('"gold"'), (stText || "").slice(0, 120));

	send({ jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "game_plant", arguments: { plot: 2, seed: "radish" } } });
	const pl = await waitReply(5);
	const plText = pl.result && pl.result.content && pl.result.content[0] && pl.result.content[0].text;
	check("call game_plant", plText && plText.includes('"ok":true'), (plText || "").slice(0, 120));

	send({ jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "aiplay_wait_until", arguments: { expr: "plot2_progress >= 1.0", max_frames: 600 } } });
	const wu = await waitReply(6, 30000);
	const wuText = wu.result && wu.result.content && wu.result.content[0] && wu.result.content[0].text;
	check("call aiplay_wait_until", wuText && wuText.includes('"timeout":false'), (wuText || "").slice(0, 120));

	child.kill();
	console.log(`\n${passed} passed, ${failed} failed`);
	process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error("BRIDGE SMOKE ERROR:", e); child.kill(); process.exit(1); });
