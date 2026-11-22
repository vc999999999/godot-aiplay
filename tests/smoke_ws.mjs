#!/usr/bin/env node
// AIPlay 协议冒烟测试：对运行中的游戏（ws://127.0.0.1:8765）跑全部 12 个方法。
// 用法：先起游戏 `Godot --headless --path .`，再 `node tests/smoke_ws.mjs`

const URL = process.env.AIPLAY_URL || "ws://127.0.0.1:8765";

let ws;
let nextId = 1;
const pending = new Map();
let passed = 0;
let failed = 0;

function connect() {
	return new Promise((resolve, reject) => {
		ws = new WebSocket(URL);
		const timer = setTimeout(() => reject(new Error("connect timeout")), 5000);
		ws.onopen = () => { clearTimeout(timer); resolve(); };
		ws.onerror = (e) => { clearTimeout(timer); reject(new Error("ws error")); };
		ws.onmessage = (ev) => {
			const msg = JSON.parse(ev.data);
			if (msg.id == null) return;
			const p = pending.get(msg.id);
			if (!p) return;
			pending.delete(msg.id);
			clearTimeout(p.timer);
			if (msg.ok) p.resolve(msg.result);
			else p.reject(new Error(msg.error || "aiplay error"));
		};
	});
}

function rpc(method, params = {}, timeoutMs = 30000) {
	return new Promise((resolve, reject) => {
		const id = nextId++;
		const timer = setTimeout(() => {
			pending.delete(id);
			reject(new Error("timeout: " + method));
		}, timeoutMs);
		pending.set(id, { resolve, reject, timer });
		ws.send(JSON.stringify({ id, method, params }));
	});
}

function check(name, cond, extra = "") {
	if (cond) { passed++; console.log("  PASS", name); }
	else { failed++; console.log("  FAIL", name, extra); }
}

async function main() {
	await connect();
	console.log("connected", URL);

	// 1. ping
	const ping = await rpc("ping");
	check("ping.protocol", ping.protocol === "aiplay/0.2", JSON.stringify(ping));
	check("ping.game", ping.game === "AIPlay Demo", ping.game);

	// 2. state
	const st = await rpc("state");
	check("state.scene", st.scene === "Main", st.scene);
	check("state.game.seeds", st.game.seeds === 5, JSON.stringify(st.game.seeds));
	check("state.game.gold", st.game.gold === 0);
	const ids = (st.elements || []).map((e) => e.id);
	check("state.elements has Plot0", ids.includes("/Main/RootBox/PlotBox/Plot0"), ids.join(","));
	check("state.elements has StatsLabel", ids.includes("/Main/RootBox/StatsLabel"));
	check("state.elements hides DebugLabel", !ids.some((i) => i.includes("DebugLabel")));
	check("state.elements has farm label meta", (st.elements.find((e) => e.id.includes("StatsLabel")) || {}).label === "农场状态");

	// 3. actions（provider 派生）
	const acts = await rpc("actions");
	check("actions has plant", acts.actions.some((a) => a.action === "plant" && a.plot === 0), JSON.stringify(acts.actions));

	// 4. tools
	const tools = await rpc("tools");
	const tnames = tools.tools.map((t) => t.name);
	check("tools game_*", ["game_plant", "game_harvest", "game_status"].every((n) => tnames.includes(n)), tnames.join(","));

	// 5. invoke plant plot0
	const inv = await rpc("invoke", { tool: "game_plant", args: { plot: 0, seed: "radish" } });
	check("invoke plant ok", inv.result && inv.result.ok === true, JSON.stringify(inv.result));
	check("invoke returns state", inv.state && inv.state.game.plot0_state === "growing", JSON.stringify(inv.state && inv.state.game.plot0_state));

	// 6. 重复种同一块 → 业务错误但协议 ok
	const inv2 = await rpc("invoke", { tool: "game_plant", args: { plot: 0, seed: "radish" } });
	check("invoke re-plant rejected", inv2.result && inv2.result.ok === false);

	// 7. 未熟就收 → -1
	const hv = await rpc("invoke", { tool: "game_harvest", args: { plot: 0 } });
	check("harvest unripe -> -1", hv.result === -1, JSON.stringify(hv.result));

	// 8. click 种 plot1（走按钮 pressed 路径）
	const ck = await rpc("click", { id: "/Main/RootBox/PlotBox/Plot1" });
	check("click plants plot1", ck.state && ck.state.game.plot1_state === "growing", JSON.stringify(ck.state && ck.state.game.plot1_state));
	check("click decrements seeds", ck.state.game.seeds === 3, ck.state.game.seeds);

	// 9. key / press / time_scale / wait
	const ky = await rpc("key", { key: "space" });
	check("key space", ky.ok !== false && ky.key > 0, JSON.stringify(ky));
	const pr = await rpc("press", { action: "ui_accept", pressed: true });
	check("press ui_accept", pr.action === "ui_accept" && pr.pressed === true);
	await rpc("press", { action: "ui_accept", pressed: false });
	const w = await rpc("wait", { frames: 30 }, 10000);
	check("wait frames returns state", w.state && w.state.scene === "Main");
	const ts = await rpc("time_scale", { scale: 2 });
	check("time_scale=2", ts.time_scale === 2.0, ts.time_scale);
	await rpc("time_scale", { scale: 1 });

	// 10. call 逃生舱
	const c1 = await rpc("call", { path: "/root/Main", method: "status" });
	check("call status()", c1.result && typeof c1.result.gold === "number", JSON.stringify(c1.result).slice(0, 80));
	const c2 = await rpc("call", { path: "/root/Main", method: "free" }).then(
		() => null,
		(e) => e.message,
	);
	check("call free blocked", typeof c2 === "string" && c2.includes("not allowed"), c2);
	const c3 = await rpc("call", { path: "/Main/RootBox/DebugLabel", method: "get" }).then(
		() => null,
		(e) => e.message,
	);
	check("call hidden blocked", typeof c3 === "string" && c3.includes("hidden"), c3);

	// 11. wait_until：等 plot0 熟（GROW_TIME=4s≈240 物理帧）
	const t0 = Date.now();
	const wu = await rpc("wait_until", { expr: "plot0_progress >= 1.0", max_frames: 600 }, 20000);
	check("wait_until plot0 ripe", wu.timeout === false, JSON.stringify(wu).slice(0, 120));
	console.log("    (wait_until took", Date.now() - t0, "ms)");

	// 12. 收获 + wait_until gold
	const hv2 = await rpc("invoke", { tool: "game_harvest", args: { plot: 0 } });
	check("harvest ripe -> price", hv2.result === 10, JSON.stringify(hv2.result));
	const wu2 = await rpc("wait_until", { expr: "gold >= 10 and harvested >= 1", max_frames: 60 }, 10000);
	check("wait_until multi-cond", wu2.timeout === false && wu2.state.game.gold === 10);

	// 13. 超时路径
	const wu3 = await rpc("wait_until", { expr: "gold >= 9999", max_frames: 30 }, 10000);
	check("wait_until timeout", wu3.timeout === true, JSON.stringify(wu3).slice(0, 80));

	// 14. 错误路径
	const bad = await rpc("invoke", { tool: "game_nope", args: {} }).then(() => null, (e) => e.message);
	check("invoke unknown tool", typeof bad === "string" && bad.includes("unknown tool"), bad);
	const badm = await rpc("nosuchmethod").then(() => null, (e) => e.message);
	check("unknown method", typeof badm === "string" && badm.includes("unknown method"), badm);

	ws.close();
	console.log(`\n${passed} passed, ${failed} failed`);
	process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error("SMOKE ERROR:", e); process.exit(1); });
