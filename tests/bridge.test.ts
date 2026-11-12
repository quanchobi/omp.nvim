import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

import ompNvimBridge, { PROTOCOL_VERSION } from "../extension/omp-nvim-bridge.ts";

type Handler = (event: unknown, ctx: unknown) => void;

interface Sent {
  text: string;
  options?: { deliverAs?: string };
}

let dir: string;
let shutdowns: Array<() => void> = [];

beforeEach(() => {
  dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "omp-nvim-bridge-")));
  process.env.OMP_NVIM_RUN_DIR = path.join(dir, "run");
});

afterEach(() => {
  for (const shutdown of shutdowns) shutdown();
  shutdowns = [];
  fs.rmSync(dir, { recursive: true, force: true });
});

function ctxFor(overrides: Record<string, unknown> = {}) {
  const state = { idle: true, editor: "" };
  const ctx = {
    mode: "tui",
    hasUI: true,
    cwd: dir,
    agent: { kind: "main" },
    isIdle: () => state.idle,
    ui: {
      getEditorText: () => state.editor,
      setEditorText: (text: string) => {
        state.editor = text;
      },
    },
    ...overrides,
  };
  return { ctx, state };
}

/** Loads the bridge against a fake omp runner. */
function fakeOmp(sessionName = "test session") {
  const handlers = new Map<string, Handler>();
  const sent: Sent[] = [];
  const pi = {
    sendUserMessage: (text: string, options?: { deliverAs?: string }) => {
      sent.push({ text, options });
    },
    on: (event: string, handler: Handler) => {
      handlers.set(event, handler);
    },
    getSessionName: () => sessionName,
  };
  ompNvimBridge(pi);
  const emit = (event: string, ctx: unknown) => handlers.get(event)?.(undefined, ctx);
  return { sent, emit };
}

function startMain(overrides: Record<string, unknown> = {}) {
  const omp = fakeOmp();
  const { ctx, state } = ctxFor(overrides);
  omp.emit("session_start", ctx);
  shutdowns.push(() => omp.emit("session_shutdown", ctx));
  return { ...omp, ctx, state };
}

const metaPath = () => path.join(process.env.OMP_NVIM_RUN_DIR ?? "", `${process.pid}.json`);
const readMeta = () => JSON.parse(fs.readFileSync(metaPath(), "utf8"));

/** Minimal JSONL client; `next()` resolves with the next frame from the bridge. */
async function connect(socket: string) {
  const frames: unknown[] = [];
  const waiters: Array<(frame: unknown) => void> = [];
  let buf = "";
  const client = net.createConnection(socket);
  client.on("data", (chunk) => {
    const lines = (buf + chunk.toString()).split("\n");
    buf = lines.pop() ?? "";
    for (const line of lines) {
      const frame = JSON.parse(line);
      const waiter = waiters.shift();
      if (waiter) waiter(frame);
      else frames.push(frame);
    }
  });
  await new Promise<void>((resolve, reject) => {
    client.once("connect", resolve);
    client.once("error", reject);
  });
  shutdowns.unshift(() => client.destroy());
  const next = () =>
    new Promise<unknown>((resolve) => {
      const frame = frames.shift();
      if (frame !== undefined) resolve(frame);
      else waiters.push(resolve);
    });
  const send = (frame: object) => client.write(`${JSON.stringify(frame)}\n`);
  expect(await next()).toEqual({ type: "status", event: "ready" });
  return { next, send };
}

test("advertises only the main interactive session", () => {
  const omp = fakeOmp();
  omp.emit("session_start", ctxFor({ agent: { kind: "sub" } }).ctx);
  omp.emit("session_start", ctxFor({ mode: "rpc" }).ctx);
  expect(fs.existsSync(metaPath())).toBe(false);

  startMain();
  const meta = readMeta();
  expect(meta).toMatchObject({ version: PROTOCOL_VERSION, pid: process.pid, cwd: dir, session: "test session" });
  expect(fs.statSync(meta.socket).isSocket()).toBe(true);
});

test("idle prompts start a turn; busy prompts queue instead of steering", async () => {
  const omp = startMain();
  const client = await connect(readMeta().socket);

  client.send({ type: "prompt", text: "first" });
  expect(await client.next()).toEqual({ type: "status", event: "prompt_accepted", delivery: "prompt" });

  omp.state.idle = false;
  client.send({ type: "prompt", text: "second" });
  expect(await client.next()).toMatchObject({ delivery: "followUp" });
  client.send({ type: "prompt", text: "third", busy: "steer" });
  expect(await client.next()).toMatchObject({ delivery: "steer" });
  client.send({ type: "prompt", text: "fourth", busy: "constructor" });
  expect(await client.next()).toMatchObject({ delivery: "followUp" });

  expect(omp.sent).toEqual([
    { text: "first", options: undefined },
    { text: "second", options: { deliverAs: "followUp" } },
    { text: "third", options: { deliverAs: "steer" } },
    { text: "fourth", options: { deliverAs: "followUp" } },
  ]);
});

test("submit=false appends to omp's input editor without sending", async () => {
  const omp = startMain();
  omp.state.editor = "draft";
  const client = await connect(readMeta().socket);

  client.send({ type: "prompt", text: "explain @hunk", submit: false });
  expect(await client.next()).toMatchObject({ delivery: "editor" });
  expect(omp.state.editor).toBe("draft\nexplain @hunk");
  expect(omp.sent).toEqual([]);
});

test("tracks turns from events when isIdle is unavailable", async () => {
  const omp = startMain({ isIdle: undefined });
  const client = await connect(readMeta().socket);

  omp.emit("agent_start", omp.ctx);
  expect(await client.next()).toEqual({ type: "status", event: "turn_started" });
  client.send({ type: "prompt", text: "while busy" });
  expect(await client.next()).toMatchObject({ delivery: "followUp" });

  omp.emit("agent_end", omp.ctx);
  expect(await client.next()).toEqual({ type: "status", event: "turn_ended" });
  client.send({ type: "prompt", text: "when idle" });
  expect(await client.next()).toMatchObject({ delivery: "prompt" });
});

test("ignores turn events from subagent sessions", async () => {
  const omp = startMain({ isIdle: undefined });
  const client = await connect(readMeta().socket);

  omp.emit("agent_start", { ...omp.ctx, agent: { kind: "sub" } });
  client.send({ type: "ping" });
  expect(await client.next()).toEqual({ type: "pong" });
});

test("a new main session in the same process takes over the socket", async () => {
  startMain();
  const socket = readMeta().socket;

  const next = fakeOmp("second session");
  const { ctx } = ctxFor();
  next.emit("session_start", ctx);
  shutdowns.push(() => next.emit("session_shutdown", ctx));
  expect(readMeta()).toMatchObject({ socket, session: "second session" });

  const client = await connect(socket);
  client.send({ type: "prompt", text: "hello" });
  await client.next();
  expect(next.sent).toEqual([{ text: "hello", options: undefined }]);
});

test("session_shutdown removes the socket and metadata", () => {
  const omp = startMain();
  const socket = readMeta().socket;
  omp.emit("session_shutdown", omp.ctx);
  expect(fs.existsSync(socket)).toBe(false);
  expect(fs.existsSync(metaPath())).toBe(false);
});

test("prunes entries left by dead omp processes", () => {
  const dead = Bun.spawnSync(["true"]).pid;
  const run = process.env.OMP_NVIM_RUN_DIR ?? "";
  fs.mkdirSync(run, { recursive: true });
  fs.writeFileSync(path.join(run, `${dead}.json`), "{}");
  fs.writeFileSync(path.join(run, `${dead}.sock`), "");

  startMain();
  expect(fs.readdirSync(run).sort()).toEqual([`${process.pid}.json`, `${process.pid}.sock`]);
});
