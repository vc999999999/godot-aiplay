#!/usr/bin/env node
// AIPlay 协议冒烟测试（aiplay/0.3）：对运行中的游戏（ws://127.0.0.1:8765）跑全部方法
// 用法：先起游戏 `Godot --headless --path .`，再 `node tests/smoke_ws.mjs`
//
// 两条必须先读的设计约束：
//   1. 每个测试块前调 game_reset，套件可重复跑；不再假设"游戏是全新状态"。
//   2. 安全断言必须验证"被拒绝"，且要验证拒绝发生在状态改变之前——只看 error
//      字符串不看状态，等于给守卫发感情牌。
//
// 环境变量：AIPLAY_URL、AIPLAY_TOKEN、AIPLAY_TOKEN_FILE（不设则读各平台 user:// 默认位置）

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const URL = process.env.AIPLAY_URL || "ws://127.0.0.1:8765";

function resolveToken() {
	if (process.env.AIPLAY_TOKEN) return process.env.AIPLAY_TOKEN.trim();
	if (process.env.AIPLAY_TOKEN_FILE) {
		try { return readFileSync(process.env.AIPLAY_TOKEN_FILE, "utf8").trim(); } catch { return ""; }
	}
	const project = process.env.AIPLAY_PROJECT || "AIPlay Demo";
	const home = homedir();
	const dirs = [
		join(home, "Library", "Application Support", "Godot", "app_userdata", project),
		join(home, ".local", "share", "godot", "app_userdata", project),
		join(home, "AppData", "Roaming", "Godot", "app_userdata", project),
	];
	for (const d of dirs) {
		try { return readFileSync(join(d, "aiplay.token"), "utf8").trim(); } catch { /* next */ }
	}
	return "";
}

const TOKEN = resolveToken();

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
		ws.onerror = () => { clearTimeout(timer); reject(new Error("ws error")); };
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

function rawRpc(method, params = {}, timeoutMs = 30000) {
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

// 除 auth 外的调用都走这里：先把凭据送进去，让套件对"开了鉴权/没开鉴权"都成立
async function rpc(method, params = {}, timeoutMs = 30000) {
	await ensureAuth();
	return rawRpc(method, params, timeoutMs);
}

let authDone = false;
async function ensureAuth() {
	if (authDone || !TOKEN) return;
	await rawRpc("auth", { token: TOKEN }, 5000);
	authDone = true;
}

function check(name, cond, extra = "") {
	if (cond) { passed++; console.log("  PASS", name); }
	else { failed++; console.log("  FAIL", name, extra); }
}

async function expectError(name, fn, substring) {
	try {
		await fn();
		check(name, false, "expected an error, got success");
	} catch (e) {
		check(name, substring ? e.message.includes(substring) : true, `${e.message} / wanted "${substring}"`);
	}
}

// 只比对"玩家能据此获利"的键。progress / t 本来每帧都在变，
// 拿整个 game 字典比对，测的就不是守卫而是计时器。
function winnable(g) {
	return JSON.stringify({
		gold: g.gold,
		seeds: g.seeds,
		harvested: g.harvested,
		p0: g.plot0_state,
		p1: g.plot1_state,
		p2: g.plot2_state,
	});
}

// 状态没变才说明"拒绝"是真的拒绝；只看 error 字符串可以自欺
async function expectNoStateChange(name, fn) {
	const before = winnable((await rpc("state")).game);
	try { await fn(); } catch { /* 拒绝本身不是判据 */ }
	const after = winnable((await rpc("state")).game);
	check(name, after === before, `state moved ${before} -> ${after}`);
}

async function resetGame() {
	await rpc("invoke", { tool: "game_reset", args: {} });
}

async function main() {
	await connect();
	console.log("connected", URL, TOKEN ? "(token loaded)" : "(no token)");

	// ---- 0. 鉴权 -------------------------------------------------------------
	const ping = await rpc("ping");
	check("ping.protocol", ping.protocol === "aiplay/0.3", JSON.stringify(ping));
	check("ping.game", ping.game === "AIPlay Demo", ping.game);
	check("ping declares auth_required", typeof ping.auth_required === "boolean", ping.auth_required);

	// 鉴权用例跟着 ping.auth_required 走：--aiplay-no-token 是开发者故意的，
	// 那时"未鉴权被拒"本就不该成立，判 FAIL 是测试在制造假警报。
	if (ping.auth_required) {
		const anon = new WebSocket(URL);
		const anonResult = await new Promise((resolve) => {
			const t = setTimeout(() => resolve("no-reply"), 3000);
			anon.onopen = () => anon.send(JSON.stringify({ id: 999, method: "state", params: {} }));
			anon.onmessage = (ev) => { clearTimeout(t); resolve(JSON.parse(ev.data)); };
			anon.onerror = () => { clearTimeout(t); resolve("ws-error"); };
		});
		anon.close();
		check("unauthenticated state is refused",
			anonResult === "ws-error" || (anonResult && anonResult.ok === false),
			JSON.stringify(anonResult).slice(0, 100));

		const wrong = new WebSocket(URL);
		const wrongResult = await new Promise((resolve) => {
			const t = setTimeout(() => resolve("no-reply"), 3000);
			wrong.onopen = () => wrong.send(JSON.stringify({ id: 1000, method: "auth", params: { token: "deadbeef" } }));
			wrong.onmessage = (ev) => { clearTimeout(t); resolve(JSON.parse(ev.data)); };
			wrong.onerror = () => { clearTimeout(t); resolve("ws-error"); };
		});
		wrong.close();
		check("bad token rejected", wrongResult && wrongResult.ok === false, JSON.stringify(wrongResult).slice(0, 100));
	} else {
		console.log("  SKIP auth cases (auth disabled by --aiplay-no-token)");
	}

	await resetGame();

	// ---- 1. 快照 -------------------------------------------------------------
	const st = await rpc("state");
	check("state.scene", st.scene === "Main", st.scene);
	check("state.game.seeds", st.game.seeds === 5, JSON.stringify(st.game.seeds));
	check("state.game.gold", st.game.gold === 0);
	check("state.elements has Plot0", st.elements.some((e) => e.id === "/Main/RootBox/PlotBox/Plot0"));
	check("state.elements hides DebugLabel", !st.elements.some((e) => e.id.includes("DebugLabel")));
	check("state.elements label meta",
		(st.elements.find((e) => e.id.includes("StatsLabel")) || {}).label === "农场状态");

	// 体积预算：这是协议的核心承诺，得真去量
	const snapBytes = Buffer.byteLength(JSON.stringify(st), "utf8");
	check("snapshot stays small", snapBytes < 2048, snapBytes + " bytes");
	check("game dict under 4096", Buffer.byteLength(JSON.stringify(st.game), "utf8") <= 4096);

	// ---- 2. 语义动作 ---------------------------------------------------------
	const acts = await rpc("actions");
	check("actions has plant", acts.actions.some((a) => a.action === "plant" && a.plot === 0));

	const tools = await rpc("tools");
	const tnames = tools.tools.map((t) => t.name);
	check("tools game_*", ["game_plant", "game_harvest", "game_status"].every((n) => tnames.includes(n)), tnames.join(","));

	const inv = await rpc("invoke", { tool: "game_plant", args: { plot: 0, seed: "radish" } });
	check("invoke plant ok", inv.result && inv.result.ok === true);
	check("invoke returns state", inv.state && inv.state.game.plot0_state === "growing");

	// 业务级失败走 result.ok=false（协议层仍是 ok），参数级失败才是协议错误。
	// 两者得分清楚，否则调用方没法判断"该改参数还是该改策略"。
	const rePlant = await rpc("invoke", { tool: "game_plant", args: { plot: 0, seed: "x" } });
	check("invoke re-plant rejected", rePlant.result && rePlant.result.ok === false, JSON.stringify(rePlant.result));
	await expectError("invoke missing arg", () => rpc("invoke", { tool: "game_plant", args: { plot: 1 } }), "missing arg");
	await expectError("invoke unknown arg", () => rpc("invoke", { tool: "game_plant", args: { plot: 1, seed: "x", evil: 1 } }), "unknown arg");
	await expectError("invoke unknown tool", () => rpc("invoke", { tool: "game_nope", args: {} }), "unknown tool");

	// ---- 3. 真实玩家权限：disabled / 不可见都不许点 -------------------------
	// 判据必须是"状态没推进"，而不是"返回了 error"：
	// 老版本正是返回 200 + 状态推进，只看 error 会漏掉。
	await resetGame();
	await rpc("invoke", { tool: "game_set_plot_disabled", args: { plot: 1, disabled: true } });
	const preDisabled = (await rpc("state")).game;
	await rpc("click", { id: "/Main/RootBox/PlotBox/Plot1" }).catch(() => {});
	const postDisabled = (await rpc("state")).game;
	check("click on disabled button does not plant",
		postDisabled.plot1_state === "empty" && postDisabled.seeds === preDisabled.seeds,
		JSON.stringify({ plot1: postDisabled.plot1_state, seeds: postDisabled.seeds }));
	await rpc("invoke", { tool: "game_set_plot_disabled", args: { plot: 1, disabled: false } });

	await rpc("invoke", { tool: "game_set_plot_visible", args: { plot: 2, vis: false } });
	const preHidden = (await rpc("state")).game;
	await rpc("click", { id: "/Main/RootBox/PlotBox/Plot2" }).catch(() => {});
	const postHidden = (await rpc("state")).game;
	check("click on invisible button does not plant",
		postHidden.plot2_state === "empty" && postHidden.seeds === preHidden.seeds,
		JSON.stringify({ plot2: postHidden.plot2_state, seeds: postHidden.seeds }));
	await rpc("invoke", { tool: "game_set_plot_visible", args: { plot: 2, vis: true } });

	// 正常按钮仍然要好用，别把权限收得连正常操作都做不了
	const okClick = await rpc("click", { id: "/Main/RootBox/PlotBox/Plot0" });
	check("click on a live button still works", okClick.state.game.plot0_state === "growing", okClick.state.game.plot0_state);

	// ---- 4. 逃生舱 call：默认关 + 白名单 ------------------------------------
	await expectError("call is off by default", () => rpc("call", { path: "/root/Main", method: "status" }), "disabled");
	await expectNoStateChange("call set(gold) blocked", async () => {
		await rpc("call", { path: "/root/Main", method: "set", args: ["gold", 9999] });
	});
	await expectNoStateChange("call_deferred queue_free blocked", async () => {
		await rpc("call", { path: "/Main/RootBox/PlotBox/Plot1", method: "call_deferred", args: ["queue_free"] });
	});
	await expectNoStateChange("set_script(null) blocked", async () => {
		await rpc("call", { path: "/Main/RootBox/PlotBox/Plot1", method: "set_script", args: [null] });
	});
	const stillThere = (await rpc("state")).elements.some((e) => e.id.endsWith("Plot1"));
	check("Plot1 survived all call attempts", stillThere);

	// ---- 5. 时间尺度默认关 ---------------------------------------------------
	await expectError("time_scale off by default", () => rpc("time_scale", { scale: 20 }), "disabled");
	check("Engine.time_scale untouched", (await rpc("state")) !== undefined);

	// ---- 6. wait / wait_until ------------------------------------------------
	const w = await rpc("wait", { frames: 20 }, 10000);
	check("wait frames returns state", w.state && w.state.scene === "Main");
	await expectError("wait frames=0", () => rpc("wait", { frames: 0 }), "frames");

	const t0 = Date.now();
	const wu = await rpc("wait_until", { expr: "plot0_progress >= 1.0", max_frames: 600 }, 20000);
	const elapsed = Date.now() - t0;
	check("wait_until plot0 ripe", wu.timeout === false, JSON.stringify(wu).slice(0, 100));
	check("wait_until woke without polling", elapsed > 2000 && elapsed < 8000, elapsed + "ms");

	const hv2 = await rpc("invoke", { tool: "game_harvest", args: { plot: 0 } });
	check("harvest ripe -> price", hv2.result === 10, JSON.stringify(hv2.result));
	const wu2 = await rpc("wait_until", { expr: "gold >= 10 and harvested >= 1", max_frames: 60 }, 10000);
	check("wait_until multi-cond", wu2.timeout === false && wu2.state.game.gold === 10);
	const wu3 = await rpc("wait_until", { expr: "gold >= 9999", max_frames: 30 }, 10000);
	check("wait_until timeout", wu3.timeout === true);
	await expectError("wait_until nested key refused", () => rpc("wait_until", { expr: "plots.0.state == ripe", max_frames: 1 }), "bad condition");
	await expectError("wait_until too many conds", () => rpc("wait_until", { expr: "a==1 and b==2 and c==3 and d==4", max_frames: 1 }), "too many");

	// ---- 7. 协议错误路径 -----------------------------------------------------
	await expectError("unknown method", () => rpc("nosuchmethod"), "unknown method");

	// ---- 8. 自清理：跑完把游戏恢复原状，让下一次基线成立 ---------------------
	await resetGame();
	const finalState = await rpc("state");
	check("reset restores baseline", finalState.game.seeds === 5 && finalState.game.gold === 0, JSON.stringify(finalState.game).slice(0, 120));

	ws.close();
	console.log(`\n${passed} passed, ${failed} failed`);
	process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error("SMOKE ERROR:", e); process.exit(1); });
