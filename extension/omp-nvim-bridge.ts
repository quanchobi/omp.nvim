// omp.nvim bridge — loaded by omp from an extensions directory.
//
// One bridge per omp process, owned by the main interactive (TUI) session;
// subagent sessions and non-TUI modes never bind. The bridge listens on
// <run>/<pid>.sock and advertises itself in <run>/<pid>.json so nvim can
// discover every live omp, match it to its working directory, and let the
// user pick when several qualify.
//
// Wire protocol (one JSON object per line):
//   in:  {"type":"ping"}
//   in:  {"type":"prompt","text":"...","submit":true,"busy":"followUp"}
//          submit=false fills omp's input editor and waits for Enter.
//          busy picks the delivery while a turn is running:
//          "followUp" (default, queued after the turn) | "steer" | "aside".
//   out: {"type":"pong"}
//   out: {"type":"status","event":"ready"|"turn_started"|"turn_ended"}
//   out: {"type":"status","event":"prompt_accepted","delivery":"prompt"|"editor"|"followUp"|"steer"|"aside"}
//   out: {"type":"error","message":"..."}
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** Bumped on any wire or metadata change; nvim ignores bridges with another version. */
export const PROTOCOL_VERSION = 2;

type Busy = "followUp" | "steer" | "aside";
const BUSY_MODES: Record<string, Busy> = { followUp: "followUp", steer: "steer", aside: "aside" };

interface Ctx {
  mode?: string;
  hasUI?: boolean;
  cwd?: string;
  agent?: { kind?: string };
  isIdle?(): boolean;
  ui?: {
    getEditorText(): string;
    setEditorText(text: string): void;
  };
}

interface Pi {
  sendUserMessage(content: string, options?: { deliverAs?: Busy }): void;
  on(event: string, handler: (event: unknown, ctx: Ctx) => void): void;
  getSessionName?(): string | undefined;
}

interface Client {
  write(data: string): unknown;
}

interface Bridge {
  pi: Pi;
  ctx: Ctx;
  busy: boolean;
  /** Set once the socket is bound. */
  server?: { stop(closeActiveConnections?: boolean): void };
  clients: Set<Client>;
  socketPath: string;
  metaPath: string;
  started: number;
}

interface PromptFrame {
  type: "prompt";
  text: string;
  submit?: boolean;
  busy?: string;
}

const STATE = Symbol.for("omp-nvim-bridge");
// Process-wide singleton: omp re-runs this factory for every (sub)agent session.
const registry = globalThis as unknown as { [STATE]?: Bridge };

export function runDir(): string {
  return process.env.OMP_NVIM_RUN_DIR || path.join(os.homedir(), ".omp", "run", "omp-nvim");
}

/** Interactive main session: not a subagent, and not print/rpc/json mode. */
function isMainTui(ctx: Ctx): boolean {
  return ctx.agent?.kind !== "sub" && (ctx.mode === undefined || ctx.mode === "tui");
}

function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error instanceof Error && "code" in error && error.code === "EPERM";
  }
}

function removeQuietly(file: string): void {
  try {
    fs.unlinkSync(file);
  } catch {
    // already gone
  }
}

/** Drop metadata and sockets left behind by omp processes that died without cleanup. */
function pruneStale(dir: string): void {
  for (const name of fs.readdirSync(dir)) {
    const match = /^(\d+)\.(json|sock)$/.exec(name);
    if (!match) continue;
    const pid = Number(match[1]);
    if (pid !== process.pid && !isAlive(pid)) removeQuietly(path.join(dir, name));
  }
}

function realCwd(ctx: Ctx): string {
  const cwd = ctx.cwd ?? process.cwd();
  try {
    return fs.realpathSync(cwd);
  } catch {
    return cwd;
  }
}

function sessionName(pi: Pi): string | null {
  try {
    return pi.getSessionName?.() || null;
  } catch {
    return null;
  }
}

function writeMeta(bridge: Bridge): void {
  const meta = {
    version: PROTOCOL_VERSION,
    pid: process.pid,
    cwd: realCwd(bridge.ctx),
    socket: bridge.socketPath,
    started: bridge.started,
    session: sessionName(bridge.pi),
  };
  const tmp = `${bridge.metaPath}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(meta), { mode: 0o600 });
  fs.renameSync(tmp, bridge.metaPath);
}

function send(client: Client, frame: object): void {
  client.write(`${JSON.stringify(frame)}\n`);
}

function broadcast(bridge: Bridge, frame: object): void {
  for (const client of bridge.clients) send(client, frame);
}

function isPromptFrame(value: unknown): value is PromptFrame {
  return (
    typeof value === "object" &&
    value !== null &&
    "type" in value &&
    value.type === "prompt" &&
    "text" in value &&
    typeof value.text === "string"
  );
}

/** Deliver a prompt; returns how it was delivered. */
function deliver(bridge: Bridge, frame: PromptFrame): string {
  const { ctx, pi } = bridge;
  if (frame.submit === false && ctx.hasUI && ctx.ui) {
    const current = ctx.ui.getEditorText();
    ctx.ui.setEditorText(current ? `${current}\n${frame.text}` : frame.text);
    return "editor";
  }
  const busy = typeof ctx.isIdle === "function" ? !ctx.isIdle() : bridge.busy;
  if (!busy) {
    pi.sendUserMessage(frame.text);
    return "prompt";
  }
  // Omitting deliverAs while a turn runs would steer (interrupt) it.
  const deliverAs = frame.busy && Object.hasOwn(BUSY_MODES, frame.busy) ? BUSY_MODES[frame.busy] : "followUp";
  pi.sendUserMessage(frame.text, { deliverAs });
  return deliverAs;
}

function handleLine(bridge: Bridge, client: Client, line: string): void {
  if (!line.trim()) return;
  let frame: unknown;
  try {
    frame = JSON.parse(line);
  } catch {
    send(client, { type: "error", message: "malformed frame" });
    return;
  }
  if (isPromptFrame(frame)) {
    try {
      send(client, { type: "status", event: "prompt_accepted", delivery: deliver(bridge, frame) });
    } catch (error) {
      send(client, { type: "error", message: String(error) });
    }
  } else if (typeof frame === "object" && frame !== null && "type" in frame && frame.type === "ping") {
    send(client, { type: "pong" });
  }
}

function start(pi: Pi, ctx: Ctx): Bridge | undefined {
  const dir = runDir();
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  pruneStale(dir);
  const socketPath = path.join(dir, `${process.pid}.sock`);
  removeQuietly(socketPath);

  const decoders = new WeakMap<Client, { decoder: TextDecoder; buf: string }>();
  const bridge: Bridge = {
    pi,
    ctx,
    busy: false,
    clients: new Set<Client>(),
    socketPath,
    metaPath: path.join(dir, `${process.pid}.json`),
    started: Date.now(),
  };

  try {
    bridge.server = Bun.listen<undefined>({
      unix: socketPath,
      socket: {
        open(client) {
          bridge.clients.add(client);
          decoders.set(client, { decoder: new TextDecoder(), buf: "" });
          send(client, { type: "status", event: "ready" });
        },
        data(client, chunk) {
          const state = decoders.get(client);
          if (!state) return;
          const lines = (state.buf + state.decoder.decode(chunk, { stream: true })).split("\n");
          state.buf = lines.pop() ?? "";
          for (const line of lines) handleLine(bridge, client, line);
        },
        close(client) {
          bridge.clients.delete(client);
        },
        error(client) {
          bridge.clients.delete(client);
        },
      },
    });
  } catch (error) {
    console.error(`[omp-nvim] bridge disabled: cannot bind ${socketPath}: ${String(error)}`);
    return undefined;
  }
  try {
    fs.chmodSync(socketPath, 0o600);
  } catch {
    // non-fatal; the run dir is user-private
  }
  writeMeta(bridge);
  process.once("exit", () => stop(bridge));
  return bridge;
}

function stop(bridge: Bridge): void {
  if (registry[STATE] === bridge) delete registry[STATE];
  try {
    bridge.server?.stop(true);
  } catch {
    // already stopped
  }
  removeQuietly(bridge.socketPath);
  removeQuietly(bridge.metaPath);
}

/** The bridge, when this runner's main session owns it. */
function owned(pi: Pi, ctx: Ctx): Bridge | undefined {
  const bridge = registry[STATE];
  return bridge && bridge.pi === pi && isMainTui(ctx) ? bridge : undefined;
}

export default function ompNvimBridge(pi: Pi): void {
  pi.on("session_start", (_event, ctx) => {
    if (!isMainTui(ctx)) return;
    const bridge = registry[STATE];
    if (bridge) {
      // New main session in this process (e.g. /new): retarget the existing socket.
      bridge.pi = pi;
      bridge.ctx = ctx;
      bridge.busy = false;
      writeMeta(bridge);
      return;
    }
    const started = start(pi, ctx);
    if (started) registry[STATE] = started;
  });
  pi.on("agent_start", (_event, ctx) => {
    const bridge = owned(pi, ctx);
    if (!bridge) return;
    bridge.busy = true;
    broadcast(bridge, { type: "status", event: "turn_started" });
  });
  pi.on("agent_end", (_event, ctx) => {
    const bridge = owned(pi, ctx);
    if (!bridge) return;
    bridge.busy = false;
    writeMeta(bridge); // the session may have been titled during the turn
    broadcast(bridge, { type: "status", event: "turn_ended" });
  });
  pi.on("session_shutdown", (_event, ctx) => {
    const bridge = owned(pi, ctx);
    if (bridge) stop(bridge);
  });
}
