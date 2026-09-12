#!/usr/bin/env node
/**
 * harness.mjs — integration-test harness for a *patched* Codex executable.
 *
 * What it does (and does NOT do):
 *   * Launches a supplied Codex executable as an isolated `app-server` stdio process
 *     (child_process.spawn with `windowsHide: true`), speaking the documented
 *     newline-delimited JSON-RPC protocol.
 *   * Creates one OpenAI/GPT parent thread (`gpt-5.6-luna`, low effort by default) and asks it,
 *     in exactly one turn, to natively spawn TWO children in parallel with real collaboration
 *     tools (`spawn_agent`):
 *        - child A: project-local role selected by `agent_type` that points at provider
 *          `codex-router` / model `deepseek/deepseek-v4-flash` / effort `high`;
 *        - child B: an ordinary GPT child (inherits the parent's model/provider, no role).
 *     followed by ONE follow-up (`followup_task` / `send_input`) to the SAME child A, and then
 *     a request to close both children.
 *   * Records every JSON-RPC message the harness itself sent/received into a local trace and
 *     writes a deliberately conservative summary: real child thread ids, parent relation,
 *     provider/model read back through `thread/read`, terminal turn statuses, exact output-file
 *     bytes, and the evidence that produced each verdict.
 *
 * Hard rules honoured by this file:
 *   * No synthetic parent ids, no handcrafted agent events: a child thread id must appear in a real
 *     observed record — either the v2 session's own `subAgentActivity` item with kind `started`
 *     (the actual v2 spawn signal: multi_agents_v2/spawn.rs only calls
 *     `AnalyticsClient::record_fact` and publishes NO `collabAgentToolCall` item) or, on v1, the
 *     `collabAgentToolCall`/`spawn_agent` item's `receiverThreadIds`. The harness never invents an
 *     event the server did not emit and never reports a tool call it did not observe.
 *   * Writes happen only inside the directory given by --out (plus nothing else). No global
 *     config edits, no project-trust writes (the `cwd` request field is deliberately NOT sent;
 *     the isolated directory is used as the app-server process working directory instead, which
 *     keeps `thread/start` from persisting a project trust entry).
 *   * Credentials are never read, copied, or printed. `CODEX_HOME` is left untouched so the
 *     child process inherits the existing user's provider configuration and auth as-is.
 *   * No whole-job deadline. `--turn-timeout-ms 0` (default) waits indefinitely for the parent
 *     turn to finish; Ctrl+C cancels with cleanup (`turn/interrupt` best effort + process kill).
 *   * Unknown methods/fields were resolved by reading the generated TypeScript protocol under
 *     the protocol dump directory and the Rust sources (see README.md "Protocol provenance").
 *     The harness never guesses: unimplemented server->client requests are answered with an
 *     explicit JSON-RPC error that is recorded.
 *
 * Usage:
 *   node harness.mjs --codex <ABS_EXE> --out <ABS_NEW_TEST_DIR> [options]
 */

import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import process from 'node:process';

const HARNESS_VERSION = '0.3.0';

// --------------------------------------------------------------------------------------
// arguments
// --------------------------------------------------------------------------------------

const USAGE = `harness.mjs --codex <ABS_EXE> --out <ABS_NEW_TEST_DIR> [options]

Required:
  --codex <ABS_EXE>              absolute path to the Codex executable to test (patched build)
  --out <ABS_NEW_TEST_DIR>       absolute path to a NEW directory for all harness-owned output

Options:
  --codex-args <LIST>            args for the executable (space/comma separated)
                                 default: "app-server --listen stdio://"
  --parent-model <MODEL>         default: gpt-5.6-luna
  --parent-effort <EFFORT>       default: low
  --parent-provider <ID>         default: (empty) = inherit whatever the user config selects
  --role-name <NAME>             default: deepseek-native-test
  --role-provider <ID>           default: codex-router
  --role-model <MODEL>           default: deepseek/deepseek-v4-flash
  --role-effort <EFFORT>         default: high
  --approval-policy <POLICY>     default: never      (thread/start override; test-owned)
  --sandbox <MODE>               default: workspace-write (thread/start override; test-owned)
  --experimental-api             declare experimentalApi capability at initialize (default off)
  --request-timeout-ms <MS>      per-request guard for control-plane calls (default 120000; 0 = none)
  --turn-timeout-ms <MS>         optional guard for the parent turn (default 0 = no deadline)
  --trace-tail-bytes <N>         server stderr tail printed at the end (default 4000)
  --print-prompt                 write the parent prompt and exit WITHOUT launching anything
  -h, --help                     this text
`;

function parseArgs(argv) {
  const opts = {
    codex: null,
    out: null,
    codexArgs: 'app-server --listen stdio://',
    parentModel: 'gpt-5.6-luna',
    parentEffort: 'low',
    parentProvider: '',
    roleName: 'deepseek-native-test',
    roleProvider: 'codex-router',
    roleModel: 'deepseek/deepseek-v4-flash',
    roleEffort: 'high',
    approvalPolicy: 'never',
    sandbox: 'workspace-write',
    experimentalApi: false,
    requestTimeoutMs: 120000,
    turnTimeoutMs: 0,
    traceTailBytes: 4000,
    printPrompt: false,
    help: false,
  };
  const takes = {
    '--codex': 'codex',
    '--out': 'out',
    '--codex-args': 'codexArgs',
    '--parent-model': 'parentModel',
    '--parent-effort': 'parentEffort',
    '--parent-provider': 'parentProvider',
    '--role-name': 'roleName',
    '--role-provider': 'roleProvider',
    '--role-model': 'roleModel',
    '--role-effort': 'roleEffort',
    '--approval-policy': 'approvalPolicy',
    '--sandbox': 'sandbox',
    '--request-timeout-ms': 'requestTimeoutMs',
    '--turn-timeout-ms': 'turnTimeoutMs',
    '--trace-tail-bytes': 'traceTailBytes',
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { opts.help = true; continue; }
    if (a === '--experimental-api') { opts.experimentalApi = true; continue; }
    if (a === '--print-prompt') { opts.printPrompt = true; continue; }
    if (Object.prototype.hasOwnProperty.call(takes, a)) {
      const v = argv[++i];
      if (v === undefined) throw new Error(`missing value for ${a}`);
      const key = takes[a];
      if (key.endsWith('Ms')) opts[key] = Number(v);
      else opts[key] = v;
      continue;
    }
    throw new Error(`unknown argument: ${a}`);
  }
  return opts;
}

const opts = parseArgs(process.argv.slice(2));
if (opts.help) { process.stdout.write(USAGE); process.exit(0); }
if (!opts.codex || !opts.out) {
  process.stderr.write(USAGE);
  process.exit(2);
}
if (!path.isAbsolute(opts.codex)) { process.stderr.write('--codex must be an absolute path\n'); process.exit(2); }
if (!path.isAbsolute(opts.out)) { process.stderr.write('--out must be an absolute path\n'); process.exit(2); }

// --------------------------------------------------------------------------------------
// tiny helpers
// --------------------------------------------------------------------------------------

const nowMs = () => Date.now();
const iso = (ms) => new Date(ms).toISOString();
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex').toUpperCase();
const token = (tag) => `${tag}_${randomBytes(4).toString('hex').toUpperCase()}`;

/** Normalize a text file the way this harness compares "exact content":
 *  CRLF -> LF, then drop exactly one trailing newline. Everything else must match exactly. */
function normalizeFileText(s) {
  let t = s.replace(/\r\n/g, '\n');
  if (t.endsWith('\n')) t = t.slice(0, -1);
  return t;
}

function escapeForReport(s) {
  return JSON.stringify(s);
}

// --------------------------------------------------------------------------------------
// paths
// --------------------------------------------------------------------------------------

const OUT_DIR = path.resolve(opts.out);
const TRACE_DIR = path.join(OUT_DIR, 'trace');
const ARTIFACTS_DIR = path.join(OUT_DIR, 'artifacts');
const ROLE_DIR = path.join(OUT_DIR, '.codex', 'agents'); // project-local agent-role directory
const ROLE_FILE = path.join(ROLE_DIR, `${opts.roleName}.toml`);
const LOG_FILE = path.join(OUT_DIR, 'harness.log');
const SUMMARY_JSON = path.join(OUT_DIR, 'summary.json');
const SUMMARY_MD = path.join(OUT_DIR, 'SUMMARY.md');
const RPC_TRACE = path.join(TRACE_DIR, 'rpc.jsonl');
const NOTIFICATION_TRACE = path.join(TRACE_DIR, 'notifications.jsonl');
const SERVER_STDERR = path.join(TRACE_DIR, 'server-stderr.log');
const EXPECTED_DIR = path.join(OUT_DIR, 'expected');

const DEEPSEEK_FILE = path.join(ARTIFACTS_DIR, 'deepseek_task.txt');
const GPT_FILE = path.join(ARTIFACTS_DIR, 'gpt_task.txt');

const CODE_ARGS = String(opts.codexArgs).split(/[\s,]+/).filter((s) => s.length > 0);

// --------------------------------------------------------------------------------------
// logging / trace
// --------------------------------------------------------------------------------------

const notes = [];          // harness-level log lines (also written to harness.log)
let rpcTraceStream = null;
let notifTraceStream = null;
let stderrStream = null;

function log(line) {
  const text = `[${iso(nowMs())}] ${line}`;
  notes.push(text);
  process.stdout.write(`${text}\n`);
  if (rpcTraceStream) fs.appendFileSync(LOG_FILE, `${text}\n`);
}

function traceRpc(direction, msg) {
  if (!rpcTraceStream) return;
  rpcTraceStream.write(`${JSON.stringify({ t: iso(nowMs()), tMs: nowMs(), dir: direction, msg })}\n`);
}

function traceNotification(msg) {
  if (!notifTraceStream) return;
  notifTraceStream.write(`${JSON.stringify({ t: iso(nowMs()), tMs: nowMs(), msg })}\n`);
}

// --------------------------------------------------------------------------------------
// JSON-RPC client over the app-server stdio transport
// --------------------------------------------------------------------------------------
// Transport framing verified in codex-rs/app-server-transport/src/transport/stdio.rs:
// a JSONRPCMessage per line, LF-terminated, both directions.

class AppServerClient {
  constructor({ exe, args, cwd, env, logFns, requestTimeoutMs }) {
    this.exe = exe;
    this.args = args;
    this.cwd = cwd;
    this.env = env;
    this.requestTimeoutMs = requestTimeoutMs;
    this.nextId = 1;
    this.pending = new Map(); // id -> {resolve, reject, method, timer}
    this.notificationHandlers = new Set();
    this.serverRequestHandler = null;
    this.child = null;
    this.closed = false;
    this.exitInfo = null;
    this.protocolErrors = [];   // malformed lines / unmatched responses
    this.stderrChunks = [];
  }

  start() {
    this.child = spawn(this.exe, this.args, {
      cwd: this.cwd,
      env: this.env,
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
      shell: false,
    });
    this.child.on('error', (err) => {
      this.protocolErrors.push({ kind: 'spawn-error', message: String(err && err.message ? err.message : err) });
    });
    this.child.on('exit', (code, signal) => {
      this.exitInfo = { code, signal, atMs: nowMs() };
      this.closed = true;
      for (const [id, p] of this.pending) {
        this.pending.delete(id);
        p.reject(new Error(`app-server exited (code=${code} signal=${signal}) before responding to ${p.method} (id=${id})`));
      }
    });
    if (this.child.stderr) {
      this.child.stderr.on('data', (chunk) => {
        if (stderrStream) stderrStream.write(chunk);
        const text = chunk.toString('utf8');
        this.stderrChunks.push(text);
        if (this.stderrChunks.length > 400) this.stderrChunks.splice(0, this.stderrChunks.length - 400);
      });
    }
    this.rl = readline.createInterface({ input: this.child.stdout });
    this.rl.on('line', (line) => this._onLine(line));
    return this;
  }

  _onLine(line) {
    const raw = line.trim();
    if (raw.length === 0) return;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch (err) {
      this.protocolErrors.push({ kind: 'malformed-line', line: raw.slice(0, 2000), message: String(err) });
      return;
    }
    traceRpc('in', msg);
    const isRequest = typeof msg.method === 'string' && msg.id !== undefined && msg.id !== null;
    const isResponse = typeof msg.method !== 'string' && msg.id !== undefined && msg.id !== null;
    if (isRequest) { this._onServerRequest(msg); return; }
    if (isResponse) {
      const p = this.pending.get(msg.id);
      if (!p) { this.protocolErrors.push({ kind: 'unmatched-response', id: msg.id }); return; }
      this.pending.delete(msg.id);
      if (p.timer) clearTimeout(p.timer);
      if (msg.error) p.reject(new Error(`${p.method} failed: ${JSON.stringify(msg.error)}`));
      else p.resolve(msg.result);
      return;
    }
    if (typeof msg.method === 'string') {
      traceNotification(msg);
      for (const h of this.notificationHandlers) {
        try { h(msg); } catch (err) { this.protocolErrors.push({ kind: 'notification-handler', message: String(err) }); }
      }
      return;
    }
    this.protocolErrors.push({ kind: 'unrecognized-message', msg });
  }

  _onServerRequest(msg) {
    const method = msg.method;
    // Every server->client request is recorded; only a small, explicitly-known set is answered.
    // Anything else gets a JSON-RPC method-not-found error (never a fabricated success).
    if (this.serverRequestHandler) {
      const answered = this.serverRequestHandler(msg);
      if (answered) return;
    }
    this.send({
      id: msg.id,
      error: { code: -32601, message: `native-provider-harness does not implement ${method}` },
    });
  }

  send(msg) {
    traceRpc('out', msg);
    const line = `${JSON.stringify(msg)}\n`;
    try {
      this.child.stdin.write(line);
    } catch (err) {
      this.protocolErrors.push({ kind: 'stdin-write-failed', message: String(err) });
    }
  }

  request(method, params) {
    const id = this.nextId++;
    const msg = params === undefined ? { id, method } : { id, method, params };
    return new Promise((resolve, reject) => {
      const timeoutMs = this.requestTimeoutMs;
      const timer = timeoutMs > 0
        ? setTimeout(() => {
            this.pending.delete(id);
            reject(new Error(`${method} (id=${id}) timed out after ${timeoutMs} ms`));
          }, timeoutMs)
        : null;
      this.pending.set(id, { resolve, reject, method, timer });
      this.send(msg);
    });
  }

  notify(method, params) {
    this.send(params === undefined ? { method } : { method, params });
  }

  onNotification(handler) { this.notificationHandlers.add(handler); return () => this.notificationHandlers.delete(handler); }
  onServerRequest(handler) { this.serverRequestHandler = handler; }

  async stop({ graceMs = 5000 } = {}) {
    if (!this.child || this.closed) return;
    try { this.child.stdin.end(); } catch { /* ignore */ }
    try { this.child.kill(); } catch { /* ignore */ }
    const deadline = nowMs() + graceMs;
    while (!this.closed && nowMs() < deadline) await new Promise((r) => setTimeout(r, 100));
    if (!this.closed && process.platform === 'win32') {
      // best-effort tree kill of the isolated test process only
      try {
        spawn('taskkill', ['/pid', String(this.child.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
      } catch { /* ignore */ }
      const hardDeadline = nowMs() + 3000;
      while (!this.closed && nowMs() < hardDeadline) await new Promise((r) => setTimeout(r, 100));
    }
  }
}

// --------------------------------------------------------------------------------------
// run state
// --------------------------------------------------------------------------------------

const state = {
  startedAtMs: nowMs(),
  finishedAtMs: null,
  status: 'running', // running | completed | aborted | failed
  interrupted: false,
  parent: {
    threadId: null,
    turnId: null,
    startResponse: null,
    readback: null,
    turnCompleted: null,
    turnTimedOut: false,
  },
  notifications: [],       // every inbound notification: {tMs, method, params}
  serverRequests: [],      // every inbound server request: {tMs, method, params, answer}
  children: [],            // discovered child thread ids + spawn evidence
  protocolErrors: [],      // filled from client + harness-level request failures
  requestFailures: [],     // control-plane request failures (method + message)
  role: {
    name: opts.roleName,
    provider: opts.roleProvider,
    model: opts.roleModel,
    effort: opts.roleEffort,
    file: ROLE_FILE,
    fileSha256: null,
    declaration: 'thread/start config override -> agents.<name>.config_file (absolute)',
  },
  tokens: { ds: token('DS'), gpt: token('GPT'), fu: token('FU') },
  expected: { deepseek: null, gpt: null },
  files: {},
  checks: [],
};

let client = null;
let promptText = '';

function recordNotification(msg) {
  state.notifications.push({ tMs: nowMs(), method: msg.method, params: msg.params ?? null });
}

function childProcessEnv() {
  // Inherit the existing user environment (so the existing provider config + auth are used) and
  // change nothing about CODEX_HOME. Nothing is printed/copied from it.
  return { ...process.env };
}

// --------------------------------------------------------------------------------------
// role file + prompt
// --------------------------------------------------------------------------------------

async function writeRoleFile() {
  const toml = [
    '# Test-owned agent role file written by harness.mjs.',
    '# It is deliberately *not* stored in the user\'s CODEX_HOME; it is only referenced from the',
    '# thread/start `config` override in this run (a session-flags config layer).',
    `name = ${JSON.stringify(opts.roleName)}`,
    `description = ${JSON.stringify('Integration-test role: DeepSeek model served by the codex-router provider.')}`,
    '',
    '# --- role config layer (ConfigToml) ---',
    `model_provider = ${JSON.stringify(opts.roleProvider)}`,
    `model = ${JSON.stringify(opts.roleModel)}`,
    `model_reasoning_effort = ${JSON.stringify(opts.roleEffort)}`,
    `developer_instructions = ${JSON.stringify(
      'You are a small test worker invoked by an automated integration-test harness. ' +
      'Follow the file instructions in your task message literally and add no extra commentary. ' +
      'Do not read credentials, do not run network commands, and touch only the file named in the task.',
    )}`,
    '',
  ].join('\n');
  await fsp.mkdir(ROLE_DIR, { recursive: true });
  await fsp.writeFile(ROLE_FILE, toml, 'utf8');
  state.role.fileSha256 = sha256(Buffer.from(toml, 'utf8'));
  return toml;
}

function buildParentPrompt() {
  const win = (p) => p.replace(/\//g, '\\');
  const dsFile = process.platform === 'win32' ? win(DEEPSEEK_FILE) : DEEPSEEK_FILE;
  const gptFile = process.platform === 'win32' ? win(GPT_FILE) : GPT_FILE;
  const dsLine = `DEEPSEEK_CHILD_OK ${state.tokens.ds}`;
  const gptLine = `GPT_CHILD_OK ${state.tokens.gpt}`;
  const fuLine = `FOLLOWUP_OK ${state.tokens.fu}`;
  return [
    '=== AUTOMATED INTEGRATION TEST — PARENT AGENT INSTRUCTIONS ===',
    '',
    'This is an automated test harness run with no human available. Perform ONLY the steps below, then stop.',
    'The user and this harness explicitly authorize parallel sub-agent delegation for this task.',
    '',
    'Scope rules',
    `- Work only inside: ${OUT_DIR}`,
    '- Never read, write, or print credentials, auth files, tokens, or environment secrets.',
    '- Do not modify, create, or delete any file other than the two test files named below.',
    '- In the child instructions below, the required file content is shown indented for readability only.',
    '  The written file must NOT contain that indentation: the indentation is not part of the content.',
    '',
    'Step 1 — SPAWN TWO CHILDREN CONCURRENTLY',
    'Issue BOTH spawn calls in the SAME assistant message as two parallel tool calls. Do not wait for the',
    'first child before issuing the second. Use the collaboration spawn tool (spawn_agent).',
    '',
    'Child A — DeepSeek role child:',
    '  * task_name: deepseek_file_task',
    `  * agent_type: ${opts.roleName}   (this selects the project-local DeepSeek role; do NOT pass model or reasoning_effort)`,
    '  * fork_turns: "none"   (do not inherit parent context; if the spawn tool has no fork_turns param, use its equivalent "no forked context" option)',
    '  * message (verbatim instructions for that child):',
    `      Write the file ${dsFile} whose entire content is exactly this one line and nothing else:`,
    `      ${dsLine}`,
    '      No leading or trailing spaces, no extra blank lines, no other text. Then reply with exactly: done',
    '',
    'Child B — ordinary GPT child (inherits this thread\'s model and provider):',
    '  * task_name: gpt_file_task',
    '  * do NOT pass agent_type, model, or reasoning_effort',
    '  * fork_turns: "none"   (do not inherit parent context; if the spawn tool has no fork_turns param, use its equivalent "no forked context" option)',
    '  * message (verbatim instructions for that child):',
    `      Write the file ${gptFile} whose entire content is exactly this one line and nothing else:`,
    `      ${gptLine}`,
    '      No leading or trailing spaces, no extra blank lines, no other text. Then reply with exactly: done',
    '',
    'Step 2 — WAIT for both children to reach a terminal status (use wait_agent if that tool is available).',
    '',
    'Step 3 — ONE FOLLOW-UP to child A only (never to child B)',
    'Use followup_task with target `deepseek_file_task`; if followup_task is unavailable use send_message, then send_input.',
    '  * message (verbatim instructions for that child):',
    `      Append exactly one line to ${dsFile} so that the file content becomes exactly these two lines in this order:`,
    `      ${dsLine}`,
    `      ${fuLine}`,
    '      Keep the first line unchanged and add nothing else. Then reply with exactly: done',
    'Then wait for that follow-up turn to reach a terminal status.',
    '',
    'Step 4 — CLOSE BOTH CHILDREN when they are done and the follow-up has finished.',
    'If a close_agent tool exists, call it for both child A and child B; otherwise use interrupt_agent for both.',
    'Do not leave any child running.',
    '',
    'Step 5 — Final answer: a short factual report (role used for child A, both task names, both file paths,',
    'observed results). The harness verifies success independently — do not claim that tests passed.',
    '=== END INSTRUCTIONS ===',
  ].join('\n');
}

// --------------------------------------------------------------------------------------
// observation helpers
// --------------------------------------------------------------------------------------

function itemsFromThreadRead(threadRead) {
  const out = [];
  const thread = threadRead && threadRead.thread ? threadRead.thread : null;
  if (!thread) return out;
  const turns = Array.isArray(thread.turns) ? thread.turns : [];
  for (const turn of turns) {
    const items = Array.isArray(turn.items) ? turn.items : [];
    for (const item of items) out.push({ turnId: turn.id, item });
  }
  return out;
}

function itemsFromNotifications() {
  const out = [];
  for (const n of state.notifications) {
    if (n.method === 'item/started' && n.params && n.params.item) {
      out.push({ threadId: n.params.threadId, turnId: n.params.turnId, item: n.params.item, startedAtMs: n.params.startedAtMs, source: 'item/started' });
    } else if (n.method === 'item/completed' && n.params && n.params.item) {
      out.push({ threadId: n.params.threadId, turnId: n.params.turnId, item: n.params.item, completedAtMs: n.params.completedAtMs, source: 'item/completed' });
    }
  }
  return out;
}

function collabToolCalls() {
  // CollabAgentToolCall items: tool / status / senderThreadId / receiverThreadIds / model /
  // reasoningEffort / agentsStates  (see protocol/v2/ThreadItem.ts, verified against
  // codex-rs/core/src/tools/handlers/multi_agents_v2/spawn.rs).
  //
  // The same call is observed up to three times: `item/started` (status inProgress, receiverThreadIds
  // still empty), `item/completed` (final status + receiver ids), and the persisted item from
  // `thread/read`. Observations arrive in chronological order here, so later non-empty values win and
  // non-null lifecycle timestamps are preserved.
  const byId = new Map();
  const ordered = [];
  const merge = (item, extra) => {
    if (!item || item.type !== 'collabAgentToolCall') return;
    const key = item.id ? `id:${item.id}` : `anon:${ordered.length}`;
    let entry = byId.get(key);
    if (!entry) {
      entry = {
        itemId: item.id ?? null,
        tool: item.tool ?? null,
        status: item.status ?? null,
        senderThreadId: item.senderThreadId ?? null,
        receiverThreadIds: Array.isArray(item.receiverThreadIds) ? item.receiverThreadIds.slice() : [],
        model: item.model ?? null,
        reasoningEffort: item.reasoningEffort ?? null,
        agentsStates: item.agentsStates ?? null,
        prompt: item.prompt ?? null,
        observedVia: [],
        startedAtMs: null,
        completedAtMs: null,
      };
      byId.set(key, entry);
      ordered.push(entry);
    } else {
      // merge the *latest* item fields; never let an empty/absent value erase a known one
      if (item.tool != null) entry.tool = item.tool;
      if (item.status != null) entry.status = item.status;
      if (item.senderThreadId != null) entry.senderThreadId = item.senderThreadId;
      if (Array.isArray(item.receiverThreadIds) && item.receiverThreadIds.length > 0) {
        entry.receiverThreadIds = item.receiverThreadIds.slice();
      }
      if (item.model != null) entry.model = item.model;
      if (item.reasoningEffort != null) entry.reasoningEffort = item.reasoningEffort;
      if (item.agentsStates != null && Object.keys(item.agentsStates).length > 0) entry.agentsStates = item.agentsStates;
      if (item.prompt != null) entry.prompt = item.prompt;
    }
    if (extra) {
      if (extra.startedAtMs != null) entry.startedAtMs = extra.startedAtMs;
      if (extra.completedAtMs != null) entry.completedAtMs = extra.completedAtMs;
      if (extra.via) entry.observedVia.push(extra.via);
    }
  };
  for (const e of itemsFromNotifications()) {
    // notification item/started + item/completed carry millisecond lifecycles
    merge(e.item, {
      startedAtMs: e.source === 'item/started' ? e.startedAtMs ?? null : null,
      completedAtMs: e.source === 'item/completed' ? e.completedAtMs ?? null : null,
      via: e.source,
    });
  }
  for (const [label, readback] of [['thread/read', state.parent.readback], ['thread/read(after)', state.parent.readbackAfter]]) {
    if (!readback) continue;
    for (const e of itemsFromThreadRead(readback)) merge(e.item, { via: label });
  }
  return ordered;
}

function subAgentActivities() {
  // SubAgentActivity items (TurnItem::SubAgentActivity) are what the *v2* session really publishes
  // for agent work: emit_turn_item_started/emit_turn_item_completed wrap them, so the same item is
  // visible as an `item/started` notification, an `item/completed` notification and the persisted
  // item from `thread/read`. All observations of one item are merged here (keyed by item id, or by
  // kind+thread+path when an id is absent), so a child id is counted exactly once and a record seen
  // only in a readback is still usable as evidence.
  // `kind` is snake_case (protocol SubAgentActivityKind): started | interacted | interrupted |
  // completed. Only items observed on the *parent* thread are used: notifications are filtered by
  // threadId, and readback items come from the parent thread by construction.
  const byKey = new Map();
  const ordered = [];
  const merge = (item, extra) => {
    if (!item || item.type !== 'subAgentActivity') return;
    if (typeof item.agentThreadId !== 'string' || item.agentThreadId.length === 0) return;
    const key = item.id ? `id:${item.id}` : `sig:${item.kind}|${item.agentThreadId}|${item.agentPath ?? ''}`;
    let entry = byKey.get(key);
    if (!entry) {
      entry = {
        id: item.id ?? null,
        itemId: item.id ?? null,
        kind: item.kind ?? null,
        agentThreadId: item.agentThreadId,
        agentPath: item.agentPath ?? null,
        observedVia: [],
        startedAtMs: null,
        completedAtMs: null,
      };
      byKey.set(key, entry);
      ordered.push(entry);
    } else {
      if (item.kind != null) entry.kind = item.kind;
      if (item.agentPath != null) entry.agentPath = item.agentPath;
    }
    if (extra) {
      if (extra.startedAtMs != null) entry.startedAtMs = extra.startedAtMs;
      if (extra.completedAtMs != null) entry.completedAtMs = extra.completedAtMs;
      if (extra.via && !entry.observedVia.includes(extra.via)) entry.observedVia.push(extra.via);
    }
  };
  for (const e of itemsFromNotifications()) {
    if (e.threadId !== state.parent.threadId) continue; // parent-scoped
    merge(e.item, {
      startedAtMs: e.source === 'item/started' ? e.startedAtMs ?? null : null,
      completedAtMs: e.source === 'item/completed' ? e.completedAtMs ?? null : null,
      via: e.source,
    });
  }
  for (const [label, readback] of [['thread/read', state.parent.readback], ['thread/read(after)', state.parent.readbackAfter]]) {
    if (!readback) continue;
    for (const e of itemsFromThreadRead(readback)) merge(e.item, { via: label });
  }
  return ordered;
}

function discoverChildren() {
  // Child thread ids come ONLY from real observed records:
  //   * v2: subAgentActivity(kind=started) on the parent thread — the item the v2 session actually
  //     emits. (multi_agents_v2/spawn.rs `analytics.track_collab_tool_call` only calls
  //     AnalyticsClient::record_fact and publishes NO collabAgentToolCall item, so on v2 no collab
  //     tool call may ever appear: discovery must not depend on one.)
  //   * v1: collabAgentToolCall(tool=spawnAgent).receiverThreadIds.
  // No ids are synthesized, and no tool call is claimed unless it was observed.
  const activities = subAgentActivities();
  const started = activities.filter((a) => a.kind === 'started');
  const spawns = collabToolCalls().filter((c) => c.tool === 'spawnAgent');
  const childIds = [];
  const perChild = new Map();
  const ensure = (id) => {
    if (!perChild.has(id)) {
      perChild.set(id, { id, sources: [], activityItemIds: [], activityKinds: [], spawnItemIds: [], agentPath: null, spawnCall: null });
      childIds.push(id);
    }
    return perChild.get(id);
  };
  for (const a of started) {
    const rec = ensure(a.agentThreadId);
    if (a.itemId != null) rec.activityItemIds.push(a.itemId);
    rec.activityKinds.push(`started${a.agentPath ? ` (${a.agentPath})` : ''}`);
    if (!rec.sources.includes('subAgentActivity(kind=started)')) rec.sources.push('subAgentActivity(kind=started)');
    if (a.agentPath != null) rec.agentPath = a.agentPath;
  }
  for (const s of spawns) {
    for (const id of s.receiverThreadIds) {
      const rec = ensure(id);
      if (s.itemId != null) rec.spawnItemIds.push(s.itemId);
      if (!rec.sources.includes('collabAgentToolCall(spawnAgent)')) rec.sources.push('collabAgentToolCall(spawnAgent)');
      if (!rec.spawnCall) {
        rec.spawnCall = { itemId: s.itemId, status: s.status, model: s.model, reasoningEffort: s.reasoningEffort, agentsStates: s.agentsStates };
      }
    }
  }
  return { childIds, perChild, activities, started, spawns };
}

function agentMessagesFromReadback(threadRead) {
  const msgs = [];
  for (const e of itemsFromThreadRead(threadRead)) {
    if (e.item && e.item.type === 'agentMessage' && typeof e.item.text === 'string') msgs.push(e.item.text);
  }
  return msgs;
}

function spawnIntervals() {
  // Wall-clock interval of each spawn_agent collab tool call as observed on this connection
  // (item/started startedAtMs .. item/completed completedAtMs).
  const calls = collabToolCalls().filter((c) => c.tool === 'spawnAgent');
  return calls.map((c) => ({
    itemId: c.itemId,
    receiverThreadIds: c.receiverThreadIds,
    model: c.model,
    startedAtMs: c.startedAtMs ?? null,
    completedAtMs: c.completedAtMs ?? null,
  }));
}

function overlaps(a, b) {
  if (!a || !b) return null;
  if ([a[0], a[1], b[0], b[1]].some((v) => v === null || v === undefined)) return null;
  return a[0] < b[1] && b[0] < a[1];
}

async function readFileInfo(file) {
  try {
    const buf = await fsp.readFile(file);
    const text = buf.toString('utf8');
    return {
      path: file,
      exists: true,
      bytes: buf.length,
      sha256: sha256(buf),
      rawText: text,
      normalized: normalizeFileText(text),
    };
  } catch (err) {
    return { path: file, exists: false, bytes: null, sha256: null, rawText: null, normalized: null, error: String(err && err.code ? err.code : err) };
  }
}

// --------------------------------------------------------------------------------------
// main
// --------------------------------------------------------------------------------------

let activeTurnWaiter = null;
let gracefulExitStarted = false;

async function gracefulShutdown(reason) {
  if (gracefulExitStarted) return;
  gracefulExitStarted = true;
  state.interrupted = true;
  log(`shutdown requested (${reason})`);
  if (client && state.parent.threadId && state.parent.turnId && !state.parent.turnCompleted) {
    const p = client
      .request('turn/interrupt', { threadId: state.parent.threadId, turnId: state.parent.turnId })
      .then(() => log('turn/interrupt accepted'))
      .catch((err) => log(`turn/interrupt failed: ${err.message}`));
    await Promise.race([p, new Promise((r) => setTimeout(r, 4000))]);
  }
  if (activeTurnWaiter) { activeTurnWaiter.cancel(); activeTurnWaiter = null; }
  if (client) await client.stop();
}

async function main() {
  // ---- --out validation: it must be a NEW directory (or an empty one) -------------------
  if (fs.existsSync(OUT_DIR)) {
    const entries = await fsp.readdir(OUT_DIR);
    if (entries.length > 0) {
      throw new Error(`--out directory already exists and is not empty: ${OUT_DIR}`);
    }
  }
  await fsp.mkdir(OUT_DIR, { recursive: true });
  await fsp.mkdir(TRACE_DIR, { recursive: true });
  await fsp.mkdir(ARTIFACTS_DIR, { recursive: true });
  await fsp.mkdir(EXPECTED_DIR, { recursive: true });
  rpcTraceStream = fs.createWriteStream(RPC_TRACE, { flags: 'a' });
  notifTraceStream = fs.createWriteStream(NOTIFICATION_TRACE, { flags: 'a' });
  stderrStream = fs.createWriteStream(SERVER_STDERR, { flags: 'a' });

  if (!fs.existsSync(opts.codex)) throw new Error(`--codex not found: ${opts.codex}`);
  const exeStat = await fsp.stat(opts.codex);
  if (!exeStat.isFile()) throw new Error(`--codex is not a file: ${opts.codex}`);

  await writeRoleFile();
  promptText = buildParentPrompt();
  await fsp.writeFile(path.join(OUT_DIR, 'parent-prompt.txt'), promptText, 'utf8');

  // expected artifacts, written by the harness (children must reproduce them exactly)
  const expDeepseek = `DEEPSEEK_CHILD_OK ${state.tokens.ds}\nFOLLOWUP_OK ${state.tokens.fu}`;
  const expGpt = `GPT_CHILD_OK ${state.tokens.gpt}`;
  state.expected.deepseek = expDeepseek;
  state.expected.gpt = expGpt;
  await fsp.writeFile(path.join(EXPECTED_DIR, 'expected_deepseek_task.txt'), `${expDeepseek}\n`, 'utf8');
  await fsp.writeFile(path.join(EXPECTED_DIR, 'expected_gpt_task.txt'), `${expGpt}\n`, 'utf8');

  log(`harness ${HARNESS_VERSION} starting`);
  log(`exe      : ${opts.codex}`);
  log(`args     : ${JSON.stringify(CODE_ARGS)}`);
  log(`out      : ${OUT_DIR}`);
  log(`role file: ${ROLE_FILE} (sha256 ${state.role.fileSha256})`);
  log(`parent   : model=${opts.parentModel} effort=${opts.parentEffort} provider=${opts.parentProvider || '(inherited)'}`);
  log(`role     : name=${opts.roleName} provider=${opts.roleProvider} model=${opts.roleModel} effort=${opts.roleEffort}`);
  log('isolation: app-server process cwd = --out dir; the thread/start `cwd` field is deliberately omitted so the app-server cannot persist a project trust entry; CODEX_HOME is inherited untouched');

  if (opts.printPrompt) {
    log('--print-prompt requested: not launching the executable');
    state.status = 'completed';
    return;
  }

  // ---- launch ---------------------------------------------------------------------------
  client = new AppServerClient({
    exe: opts.codex,
    args: CODE_ARGS,
    cwd: OUT_DIR,
    env: childProcessEnv(),
    requestTimeoutMs: opts.requestTimeoutMs,
  });

  // answer the small set of server->client requests this harness understands
  client.onServerRequest((msg) => {
    const method = msg.method;
    let answer = null;
    if (method === 'item/commandExecution/requestApproval') answer = { decision: 'decline' };
    else if (method === 'item/fileChange/requestApproval') answer = { decision: 'decline' };
    else if (method === 'applyPatchApproval') answer = { decision: { denied: { rejection: 'harness does not approve patches' } } };
    else if (method === 'execCommandApproval') answer = { decision: { denied: { rejection: 'harness does not approve exec' } } };
    else if (method === 'currentTime/read') answer = { currentTimeAt: Math.floor(nowMs() / 1000) };
    state.serverRequests.push({ tMs: nowMs(), method, params: msg.params ?? null, answered: answer !== null ? 'declined/handled' : 'jsonrpc-error(-32601)' });
    if (answer === null) return false;
    client.send({ id: msg.id, result: answer });
    return true;
  });

  client.start();
  client.onNotification((msg) => recordNotification(msg));
  log(`spawned pid ${client.child.pid} (windowsHide=true)`);

  // ---- initialize -----------------------------------------------------------------------
  const init = await client.request('initialize', {
    clientInfo: { name: 'native-provider-harness', title: 'Native provider harness', version: HARNESS_VERSION },
    capabilities: { experimentalApi: !!opts.experimentalApi, requestAttestation: false },
  });
  state.initialize = init;
  log(`initialize ok: userAgent=${init && init.userAgent} codexHome=${init && init.codexHome} platform=${init && init.platformOs}`);
  log('note: the codexHome above is the *existing* user home; credentials were not read or copied.');
  // documented handshake: `initialize` request, then the `initialized` notification
  // (see codex-rs/app-server/src/in_process.rs and protocol ClientNotification.ts)
  client.notify('initialized');

  // ---- thread/start (role registration + isolated parent) --------------------------------
  const startParams = {
    model: opts.parentModel,
    approvalPolicy: opts.approvalPolicy,
    sandbox: opts.sandbox,
    // `cwd` is intentionally NOT sent: sending it can make the app-server persist a project
    // trust entry in the user's config. The isolated directory is the child process cwd instead.
    config: {
      agents: {
        [opts.roleName]: {
          description: 'Integration-test role: DeepSeek model served by the codex-router provider.',
          config_file: ROLE_FILE, // absolute: session-flags layers have no config folder to resolve against
        },
      },
    },
  };
  if (opts.parentProvider) startParams.modelProvider = opts.parentProvider;
  if (!opts.experimentalApi) {
    // nothing else experimental is needed
  }
  const started = await client.request('thread/start', startParams);
  state.parent.startResponse = started;
  state.parent.threadId = started.thread.id;
  log(`thread/start ok: thread=${started.thread.id} model=${started.model} provider=${started.modelProvider} effort=${started.reasoningEffort} cwd=${started.cwd}`);

  // ---- one parent turn with everything the test needs -----------------------------------
  const turnStarted = await client.request('turn/start', {
    threadId: state.parent.threadId,
    input: [{ type: 'text', text: promptText, text_elements: [] }],
    effort: opts.parentEffort,
  });
  state.parent.turnId = turnStarted.turn.id;
  log(`turn/start ok: turn=${state.parent.turnId}`);

  // wait for the parent turn to finish (no deadline by default)
  const waiter = waitForTurnCompleted(state.parent.threadId, state.parent.turnId, opts.turnTimeoutMs);
  activeTurnWaiter = waiter;
  const completed = await waiter.promise;
  activeTurnWaiter = null;
  if (completed.timedOut) {
    state.parent.turnTimedOut = true;
    log(`parent turn did not complete within --turn-timeout-ms=${opts.turnTimeoutMs}; continuing with observed state`);
  } else {
    state.parent.turnCompleted = completed.params;
    log(`parent turn completed: status=${completed.params.turn.status}`);
  }

  // ---- read back the parent thread (turns + items) --------------------------------------
  try {
    state.parent.readback = await client.request('thread/read', { threadId: state.parent.threadId, includeTurns: true });
    log(`thread/read(parent) ok: items=${itemsFromThreadRead(state.parent.readback).length}`);
  } catch (err) {
    state.requestFailures.push({ method: 'thread/read(parent)', message: String(err.message) });
    log(`thread/read(parent) FAILED: ${err.message}`);
  }

  // ---- discover children from real observed records (v2 activity items, v1 collab tool calls) ---
  // v2 emits subAgentActivity(kind=started) as a real session item and no collab tool call at all;
  // v1 emits collabAgentToolCall(spawnAgent). Discovery uses whichever of these was observed.
  const discovery = discoverChildren();
  const childIds = discovery.childIds;
  const activities = discovery.activities;
  log(`observed spawn evidence: subAgentActivity(kind=started) records=${discovery.started.length} (deduplicated across notifications/readbacks), spawn_agent collab tool calls=${discovery.spawns.length}; distinct child thread ids: ${childIds.length}`);

  for (const id of childIds) {
    const disc = discovery.perChild.get(id) || null;
    const child = {
      id,
      agentPath: (disc && disc.agentPath) || (activities.find((a) => a.agentThreadId === id) || {}).agentPath || null,
      discovery: disc
        ? {
            sources: disc.sources,
            activityItemIds: disc.activityItemIds,
            activityKinds: disc.activityKinds,
            spawnItemIds: disc.spawnItemIds,
          }
        : { sources: [], activityItemIds: [], activityKinds: [], spawnItemIds: [] },
      spawnCall: disc ? disc.spawnCall : null,
      readback: null,
      readbackError: null,
      thread: null,
      turns: [],
    };
    try {
      child.readback = await client.request('thread/read', { threadId: id, includeTurns: true });
      child.thread = child.readback.thread;
      child.turns = (child.readback.thread.turns || []).map((t) => ({
        id: t.id,
        status: t.status,
        startedAt: t.startedAt ?? null,
        completedAt: t.completedAt ?? null,
        durationMs: t.durationMs ?? null,
        itemsView: t.itemsView ?? null,
        itemCount: Array.isArray(t.items) ? t.items.length : 0,
        error: t.error ?? null,
      }));
      log(`thread/read(child ${id}) ok: model=${child.thread.model} provider=${child.thread.modelProvider} role=${child.thread.agentRole} turns=${child.turns.length}`);
    } catch (err) {
      child.readbackError = String(err.message);
      state.requestFailures.push({ method: `thread/read(child ${id})`, message: String(err.message) });
      log(`thread/read(child ${id}) FAILED: ${err.message}`);
    }
    state.children.push(child);
  }

  // ---- output files ---------------------------------------------------------------------
  const dsInfo = await readFileInfo(DEEPSEEK_FILE);
  const gptInfo = await readFileInfo(GPT_FILE);
  state.files = {
    deepseek: { ...dsInfo, expected: expDeepseek },
    gpt: { ...gptInfo, expected: expGpt },
  };
  log(`artifact deepseek_task.txt: exists=${dsInfo.exists} bytes=${dsInfo.bytes}`);
  log(`artifact gpt_task.txt: exists=${gptInfo.exists} bytes=${gptInfo.bytes}`);

  // ---- request cleanup (async, best effort, recorded) -----------------------------------
  // Children are closed by the MODEL through real collaboration tools (close_agent /
  // interrupt_agent). The harness records whether such tool calls were observed and, if the
  // model did not close them, it says so instead of pretending cleanup happened.
  await new Promise((r) => setTimeout(r, 500));
  try {
    state.parent.readbackAfter = await client.request('thread/read', { threadId: state.parent.threadId, includeTurns: true });
  } catch (err) {
    state.requestFailures.push({ method: 'thread/read(parent, after)', message: String(err.message) });
  }
  for (const child of state.children) {
    try {
      const after = await client.request('thread/read', { threadId: child.id, includeTurns: false });
      child.readbackAfter = after.thread;
      child.statusAfter = after.thread ? after.thread.status : null;
    } catch (err) {
      child.statusAfterError = String(err.message);
    }
  }

  state.status = 'completed';
}

function waitForTurnCompleted(threadId, turnId, timeoutMs) {
  let cancelled = false;
  let timer = null;
  let finished = false;
  let resolveFn;
  const cleanupFns = [];
  const matches = (p) => {
    if (!p || p.threadId !== threadId) return false;
    if (!turnId) return true;
    const id = p.turn && p.turn.id ? p.turn.id : null;
    return id === null ? true : id === turnId;
  };

  const promise = new Promise((resolve) => {
    resolveFn = resolve;
    const done = (value) => {
      if (finished) return;
      finished = true;
      if (timer) clearTimeout(timer);
      for (const fn of cleanupFns) fn();
      resolve(value);
    };

    // Race guard: the turn may already have completed before this listener is installed (the
    // notification recorder is registered before `turn/start`), so check what was already stored.
    const already = state.notifications.find((n) => n.method === 'turn/completed' && matches(n.params));
    if (already) {
      done({ timedOut: false, params: already.params, fromStoredNotifications: true });
      return;
    }

    const off = client.onNotification((msg) => {
      if (cancelled) return;
      if (msg.method !== 'turn/completed') return;
      if (!matches(msg.params)) return;
      done({ timedOut: false, params: msg.params });
    });
    cleanupFns.push(off);
    const onExit = () => done({ timedOut: false, params: null, serverExited: true });
    cleanupFns.push(() => client.child.removeListener('exit', onExit));
    client.child.on('exit', onExit);
    if (timeoutMs > 0) {
      timer = setTimeout(() => done({ timedOut: true, params: null }), timeoutMs);
    }
  });

  return {
    promise,
    cancel: () => { cancelled = true; resolveFn({ timedOut: true, params: null, cancelled: true }); },
  };
}

// --------------------------------------------------------------------------------------
// verdicts
// --------------------------------------------------------------------------------------

function classifyChildren() {
  // Identify child A (DeepSeek role) and child B (ordinary GPT child) from verified API data
  // (thread/read thread objects) primariy, falling back to the spawn call's recorded model.
  const children = state.children;
  const dsMatches = children.filter((c) => {
    const t = c.thread;
    if (!t) return (c.spawnCall && c.spawnCall.model === state.role.model) || false;
    return t.agentRole === state.role.name || t.model === state.role.model;
  });
  const rest = children.filter((c) => !dsMatches.includes(c));
  const parentModel = state.parent.startResponse ? state.parent.startResponse.model : null;
  const parentProvider = state.parent.startResponse ? state.parent.startResponse.modelProvider : null;
  const gptMatches = rest.filter((c) => {
    const t = c.thread;
    if (!t) return false;
    return t.model === parentModel && t.modelProvider === parentProvider;
  });
  return {
    deepseekChild: dsMatches[0] || null,
    deepseekCandidates: dsMatches.map((c) => c.id),
    gptChild: (gptMatches[0] || rest[0] || null),
    gptCandidates: rest.map((c) => c.id),
    parentModel,
    parentProvider,
  };
}

function addCheck(id, label, status, detail, evidence) {
  state.checks.push({ id, label, status, detail, evidence: evidence ?? null });
}

function computeChecks() {
  if (opts.printPrompt) {
    addCheck('no_run', 'no executable was launched (--print-prompt)', 'not_observed',
      'only the role file and the parent prompt were written; nothing was executed and no model request was made', null);
    return;
  }
  const spawns = collabToolCalls().filter((c) => c.tool === 'spawnAgent');
  const intervals = spawnIntervals();
  // SubAgentActivity records (durably deduplicated) are the v2 evidence: kind=started (spawn),
  // interacted (send_message/followup_task), interrupted (interrupt_agent), completed (child done).
  const activityRecords = subAgentActivities();
  const startedActivities = activityRecords.filter((a) => a.kind === 'started');
  const interactedActivities = activityRecords.filter((a) => a.kind === 'interacted');
  const interruptedActivities = activityRecords.filter((a) => a.kind === 'interrupted');
  const completedActivities = activityRecords.filter((a) => a.kind === 'completed');
  const cls = classifyChildren();
  const ds = cls.deepseekChild;
  const gpt = cls.gptChild;
  const parentId = state.parent.threadId;

  const parentTurnStatus = state.parent.turnCompleted && state.parent.turnCompleted.turn
    ? state.parent.turnCompleted.turn.status
    : null;

  // 0. parent turn terminal status
  if (state.parent.turnTimedOut) {
    addCheck('parent_turn_terminal', 'parent turn reached a terminal status', 'unverified',
      `no turn/completed observed (--turn-timeout-ms=${opts.turnTimeoutMs}); the run was not bounded by a whole-job deadline on purpose`,
      { turnId: state.parent.turnId });
  } else if (parentTurnStatus === 'completed') {
    addCheck('parent_turn_terminal', 'parent turn reached a terminal status', 'verified',
      'turn/completed with status=completed', { turnId: state.parent.turnId });
  } else {
    addCheck('parent_turn_terminal', 'parent turn reached a terminal status', 'failed',
      `turn/completed observed with status=${parentTurnStatus}`,
      { turnId: state.parent.turnId, error: state.parent.turnCompleted && state.parent.turnCompleted.turn ? state.parent.turnCompleted.turn.error : null });
  }

  // 0b. the requested parent model was actually used
  const observedParentModel = state.parent.startResponse ? state.parent.startResponse.model : null;
  const observedParentProvider = state.parent.startResponse ? state.parent.startResponse.modelProvider : null;
  if (observedParentModel === null) {
    addCheck('parent_model', 'the parent thread runs the requested model', 'unverified',
      'thread/start did not return a model', { requested: opts.parentModel });
  } else {
    addCheck('parent_model', 'the parent thread runs the requested model',
      observedParentModel === opts.parentModel ? 'verified' : 'failed',
      `requested ${opts.parentModel}; thread/start returned model=${observedParentModel}, modelProvider=${observedParentProvider}` +
      (opts.parentProvider ? '' : ' (provider was inherited from the user config, not forced by the harness)'),
      { requested: opts.parentModel, observed: observedParentModel, provider: observedParentProvider });
  }

  // 1. real creation evidence, named by the record that actually carries it.
  // v2 publishes subAgentActivity(kind=started) items for spawns and no collab tool call at all;
  // v1 publishes collabAgentToolCall(spawnAgent). Both are real observations: the detail text says
  // which one produced the child ids, and a source that emitted nothing is never claimed.
  const v2DiscoveredIds = startedActivities.map((a) => a.agentThreadId);
  const v1DiscoveredIds = spawns.flatMap((s) => s.receiverThreadIds);
  const everyChildHasEvidence = state.children.length >= 2 && state.children.every((c) => c.discovery && c.discovery.sources.length > 0);
  const creationEvidence = {
    subAgentActivityStarted: startedActivities.map((a) => ({
      itemId: a.itemId,
      agentThreadId: a.agentThreadId,
      agentPath: a.agentPath,
      observedVia: a.observedVia,
    })),
    spawnAgentToolCalls: spawns.map((s) => ({ itemId: s.itemId, receiverThreadIds: s.receiverThreadIds, observedVia: s.observedVia })),
    perChild: state.children.map((c) => ({ id: c.id, sources: c.discovery ? c.discovery.sources : [], activityKinds: c.discovery ? c.discovery.activityKinds : [] })),
    note: 'child ids are taken only from these records: nothing was synthesized, and no collab tool call is reported when none was observed',
  };
  if (everyChildHasEvidence) {
    addCheck('children_created_by_real_tools', 'every child thread id comes from a real observed record', 'verified',
      `${state.children.length} distinct child thread id(s); ${v2DiscoveredIds.length} from subAgentActivity(kind=started) item(s); ` +
      `${v1DiscoveredIds.length} from collabAgentToolCall(spawnAgent) receiver id(s)` +
      (spawns.length === 0 ? ' (no collab tool call was observed — expected on v2, where the spawn handler only records an analytics fact)' : '') +
      '; no synthetic ids or handcrafted events were used',
      creationEvidence);
  } else {
    addCheck('children_created_by_real_tools', 'every child thread id comes from a real observed record', 'failed',
      `subAgentActivity(kind=started) records observed: ${startedActivities.length}; spawn_agent collab tool calls observed: ${spawns.length}; ` +
      `distinct child thread ids: ${state.children.length}; at least one child id could not be traced to a real observed record`,
      creationEvidence);
  }

  // 2. parent relation for every child
  const relChecks = state.children.map((c) => ({ id: c.id, parentThreadId: c.thread ? c.thread.parentThreadId : null, err: c.readbackError }));
  const relOk = relChecks.length >= 2 && relChecks.every((r) => r.parentThreadId === parentId);
  addCheck('parent_relation', 'each child thread reports parentThreadId = parent thread id', relOk ? 'verified' : (relChecks.some((r) => r.err) ? 'unverified' : 'failed'),
    relOk ? `all children report parentThreadId=${parentId}` : `observed: ${JSON.stringify(relChecks)}`,
    { parentThreadId: parentId, children: relChecks });

  // 3. two distinct children
  const distinct = state.children.length >= 2 && new Set(state.children.map((c) => c.id)).size >= 2;
  addCheck('two_distinct_children', 'two distinct child threads exist', distinct ? 'verified' : 'failed',
    distinct ? `${state.children.length} distinct child thread ids` : `only ${state.children.length} child thread id(s)`,
    { childIds: state.children.map((c) => c.id) });

  // 4. DeepSeek role child: provider/model/effort from thread/read
  if (!ds) {
    addCheck('deepseek_role_child', 'child A uses the DeepSeek role (provider/model/effort)', 'failed',
      'no child thread matched agentRole or the role model', { expectedRole: state.role });
  } else {
    const t = ds.thread;
    const roleOk = !!t && t.agentRole === state.role.name;
    const providerOk = !!t && t.modelProvider === state.role.provider;
    const modelOk = !!t && t.model === state.role.model;
    const effortOk = !!t && t.reasoningEffort === state.role.effort;
    const all = roleOk && providerOk && modelOk && effortOk;
    addCheck('deepseek_role_child', 'child A uses the DeepSeek role (provider/model/effort)', all ? 'verified' : (t ? 'failed' : 'unverified'),
      `thread/read reports agentRole=${t ? t.agentRole : 'n/a'} modelProvider=${t ? t.modelProvider : 'n/a'} model=${t ? t.model : 'n/a'} reasoningEffort=${t ? t.reasoningEffort : 'n/a'}` +
      (effortOk ? '' : ' — reasoningEffort could not be confirmed from thread/read; do not treat it as verified'),
      { childId: ds.id, expected: state.role, observed: t ? { agentRole: t.agentRole, modelProvider: t.modelProvider, model: t.model, reasoningEffort: t.reasoningEffort } : null });
  }

  // 5. ordinary GPT child
  if (!gpt) {
    addCheck('gpt_child', 'child B is an ordinary GPT child (parent model/provider, no DeepSeek role)', 'failed',
      'no second child thread was available to classify', {});
  } else {
    const t = gpt.thread;
    const ok = !!t && t.model === cls.parentModel && t.modelProvider === cls.parentProvider && t.agentRole !== state.role.name;
    addCheck('gpt_child', 'child B is an ordinary GPT child (parent model/provider, no DeepSeek role)', ok ? 'verified' : (t ? 'failed' : 'unverified'),
      `thread/read reports model=${t ? t.model : 'n/a'} modelProvider=${t ? t.modelProvider : 'n/a'} agentRole=${t ? t.agentRole : 'n/a'} (parent model/provider = ${cls.parentModel}/${cls.parentProvider})`,
      { childId: gpt.id, observed: t ? { model: t.model, modelProvider: t.modelProvider, agentRole: t.agentRole } : null });
  }

  // 6. two providers actually differ (extra evidence)
  if (ds && gpt && ds.thread && gpt.thread) {
    const differ = ds.thread.modelProvider !== gpt.thread.modelProvider || ds.thread.model !== gpt.thread.model;
    addCheck('distinct_model_or_provider', 'the two children differ in model and/or provider', differ ? 'verified' : 'failed',
      `child A ${ds.thread.model}/${ds.thread.modelProvider} vs child B ${gpt.thread.model}/${gpt.thread.modelProvider}`, {});
  }

  // 7. concurrency
  const dsTurnInterval = ds && ds.turns.length > 0 ? [ds.turns[0].startedAt, ds.turns[0].completedAt] : null;
  const gptTurnInterval = gpt && gpt.turns.length > 0 ? [gpt.turns[0].startedAt, gpt.turns[0].completedAt] : null;
  const childOverlap = overlaps(dsTurnInterval, gptTurnInterval);
  const spawnIntervalsUsable = intervals.length >= 2 ? intervals.slice(0, 2).map((i) => [i.startedAtMs, i.completedAtMs]) : null;
  const spawnOverlap = spawnIntervalsUsable ? overlaps(spawnIntervalsUsable[0], spawnIntervalsUsable[1]) : null;

  const concurrencyEvidence = {
    childTurnIntervals: { deepseek: dsTurnInterval, gpt: gptTurnInterval, overlap: childOverlap, unit: 'unix seconds from thread/read turn.startedAt/completedAt' },
    spawnCallIntervals: { calls: intervals, overlap: spawnOverlap, unit: 'milliseconds from item/started.startedAtMs .. item/completed.completedAtMs' },
  };
  if (childOverlap === true) {
    addCheck('concurrency', 'the two child lifecycles overlapped in time', 'verified',
      'the children\'s first-turn [startedAt, completedAt] windows (thread/read) overlap: ' + JSON.stringify({ deepseek: dsTurnInterval, gpt: gptTurnInterval }),
      concurrencyEvidence);
  } else if (spawnOverlap === true) {
    addCheck('concurrency', 'the two child lifecycles overlapped in time', 'unverified',
      'the parent issued the two spawn_agent calls concurrently (their item lifecycles overlap), but the children\'s own turn windows did not overlap or lacked timestamps — child-lifecycle concurrency is NOT proven',
      concurrencyEvidence);
  } else {
    addCheck('concurrency', 'the two child lifecycles overlapped in time', 'unverified',
      'neither the child turn windows nor the spawn-call windows overlapped (or timestamps were missing) — concurrency is NOT proven',
      concurrencyEvidence);
  }

  // 8. follow-up to the SAME DeepSeek child — exact counts, from real records only.
  // v2: a send_message / followup_task to a child surfaces as a SubAgentActivity(kind=interacted)
  //     item (the v2 session publishes no collab tool call for it), so that is the evidence used.
  // v1: collabAgentToolCall(followupTask|sendInput|sendMessage) whose receivers include child A.
  // `interacted` does not say *which* of send_message/followup_task it was, so the harness reports
  // the record it observed and requires exactly one interaction plus exactly two COMPLETED turns on
  // the same child — an interaction alone is not proof that the continued work ran.
  const v1FollowToDs = ds
    ? collabToolCalls().filter((c) => ['followupTask', 'sendInput', 'sendMessage'].includes(c.tool) && c.receiverThreadIds.includes(ds.id))
    : [];
  const v2InteractionsToDs = ds ? interactedActivities.filter((a) => a.agentThreadId === ds.id) : [];
  const interactions = [
    ...v2InteractionsToDs.map((a) => ({ evidence: 'subAgentActivity(kind=interacted)', tool: null, itemId: a.itemId, observedVia: a.observedVia })),
    ...v1FollowToDs.map((c) => ({ evidence: `collabAgentToolCall(${c.tool})`, tool: c.tool, itemId: c.itemId, observedVia: c.observedVia })),
  ];
  const dsTurns = ds ? ds.turns.length : 0;
  const dsTurnsAllCompleted = !!ds && ds.turns.length > 0 && ds.turns.every((t) => t.status === 'completed');
  const followExact = ds !== null && interactions.length === 1 && dsTurns === 2 && dsTurnsAllCompleted;
  const followEvidence = {
    interactions,
    interactedActivityItemIds: v2InteractionsToDs.map((a) => a.itemId),
    v1FollowupCallItemIds: v1FollowToDs.map((c) => c.itemId),
    deepseekTurnIds: ds ? ds.turns.map((t) => t.id) : [],
    deepseekTurnStatuses: ds ? ds.turns.map((t) => t.status) : [],
    note: 'on v2 the interaction record is subAgentActivity(kind=interacted); it does not distinguish send_message from followup_task, and no collab tool call is published for it',
  };
  if (followExact) {
    addCheck('followup_same_deepseek_child', 'exactly one follow-up was delivered to the same DeepSeek child and it produced a second completed turn', 'verified',
      `exactly 1 interaction record for child A — ${interactions[0].evidence}${interactions[0].itemId ? ` (item ${interactions[0].itemId})` : ''}` +
      `${interactions[0].observedVia && interactions[0].observedVia.length ? ` observed via ${interactions[0].observedVia.join(', ')}` : ''} — ` +
      'and child A has exactly 2 turns, both with status=completed',
      followEvidence);
  } else if (!ds) {
    addCheck('followup_same_deepseek_child', 'exactly one follow-up was delivered to the same DeepSeek child and it produced a second completed turn', 'failed',
      'no DeepSeek child thread could be identified, so no follow-up could be attributed', followEvidence);
  } else {
    addCheck('followup_same_deepseek_child', 'exactly one follow-up was delivered to the same DeepSeek child and it produced a second completed turn', 'failed',
      'expected exactly 1 interaction record for child A (subAgentActivity(kind=interacted) on v2, or a followupTask/sendInput/sendMessage collab tool call on v1) ' +
      `and exactly 2 turns on child A, both completed; observed ${interactions.length} interaction record(s) ` +
      `(${interactions.map((i) => i.evidence).join(', ') || 'none'}), ${dsTurns} turn(s) with statuses ${JSON.stringify(followEvidence.deepseekTurnStatuses)}`,
      followEvidence);
  }
  const gptTurnCount = gpt ? gpt.turns.length : 0;
  const gptFirstCompleted = !!gpt && gpt.turns.length === 1 && gpt.turns[0].status === 'completed';
  addCheck('followup_not_sent_to_gpt_child', 'child B ran exactly one turn and it completed', gptFirstCompleted ? 'verified' : 'failed',
    gptFirstCompleted
      ? 'child B has exactly 1 turn with status=completed'
      : `expected exactly 1 turn on child B with status=completed; observed ${gptTurnCount} turn(s) with statuses ${JSON.stringify(gpt ? gpt.turns.map((t) => t.status) : [])}`,
    { gptTurnIds: gpt ? gpt.turns.map((t) => t.id) : [] });

  // 9. terminal statuses of children (weak statement: finished one way or another)
  const childTerminal = state.children.map((c) => ({
    id: c.id,
    turns: c.turns.map((t) => ({ id: t.id, status: t.status })),
    lastTurnStatus: c.turns.length > 0 ? c.turns[c.turns.length - 1].status : null,
    threadStatus: c.thread ? c.thread.status : null,
  }));
  const allTerminal = childTerminal.length >= 2 && childTerminal.every((c) => c.turns.length > 0 && c.turns.every((t) => ['completed', 'failed', 'interrupted'].includes(t.status)));
  addCheck('children_terminal_statuses', 'every observed child turn reached a terminal status', allTerminal ? 'verified' : 'unverified',
    allTerminal ? 'all child turns report completed/failed/interrupted' : 'not all child turns report a terminal status', { childTerminal });

  // 9b. successful completion (stronger statement: completed, not merely terminal)
  const childTurns = state.children.map((c) => ({ id: c.id, statuses: c.turns.map((t) => t.status), turnCount: c.turns.length }));
  const readbackMissing = state.children.some((c) => !c.thread);
  const allCompleted = !readbackMissing && childTurns.length >= 2 && childTurns.every((c) => c.turnCount > 0 && c.statuses.every((s) => s === 'completed'));
  addCheck('children_turns_completed', 'all required child turns completed successfully (status=completed)', allCompleted ? 'verified' : (readbackMissing ? 'unverified' : 'failed'),
    allCompleted
      ? `every child turn reports status=completed (${JSON.stringify(childTurns)})`
      : readbackMissing
        ? 'at least one child thread could not be read back, so successful completion cannot be established'
        : `not every child turn reports status=completed (${JSON.stringify(childTurns)})`,
    { childTurns });

  // 10. exact output file content
  for (const [key, label] of [['deepseek', 'child A + follow-up output file content'], ['gpt', 'child B output file content']]) {
    const f = state.files[key] || {
      path: key === 'deepseek' ? DEEPSEEK_FILE : GPT_FILE,
      exists: false, bytes: null, sha256: null, normalized: null,
    };
    const exp = state.expected[key] || null;
    const exact = f.exists && exp !== null && f.normalized === normalizeFileText(exp);
    addCheck(`file_content_${key}`, `${label} matches the exact expected content`, exact ? 'verified' : 'failed',
      exact
        ? `exact match after CRLF normalization (sha256 ${f.sha256}, ${f.bytes} bytes)`
        : `content mismatch or missing file (exists=${f.exists}, bytes=${f.bytes}). actual=${f.exists ? escapeForReport(f.normalized) : 'n/a'} expected=${escapeForReport(exp)}`,
      { path: f.path, sha256: f.sha256, bytes: f.bytes });
  }

  // 11. cleanup — only native, observed, terminal evidence counts.
  // v1: the model closes children through collabAgentToolCall(closeAgent|interruptAgent).
  // v2: there is no close tool; interrupt_agent surfaces as subAgentActivity(kind=interrupted), while natural
  //     completion does not release the child. A v2 interruption is only accepted together with a
  //     terminal observed child turn status. A requested action alone never proves closure, and the
  //     harness never closes children on the model's behalf.
  const closeCalls = collabToolCalls().filter((c) => ['closeAgent', 'interruptAgent'].includes(c.tool));
  const cleanupEvidence = state.children.map((c) => {
    const calls = closeCalls.filter((x) => x.receiverThreadIds.includes(c.id) && x.status === 'completed');
    const interrupted = interruptedActivities.filter((a) => a.agentThreadId === c.id);
    const completedActs = completedActivities.filter((a) => a.agentThreadId === c.id);
    const turns = c.turns || [];
    const lastTurnStatus = turns.length > 0 ? turns[turns.length - 1].status : null;
    const allTurnsCompleted = turns.length > 0 && turns.every((t) => t.status === 'completed');
    const terminalTurn = ['completed', 'failed', 'interrupted'].includes(lastTurnStatus);
    const v2InterruptedOk = interrupted.length > 0 && terminalTurn;
    const nativeEvidence = [];
    if (calls.length > 0 && terminalTurn) nativeEvidence.push(`v1 collabAgentToolCall(${calls.map((x) => x.tool).join(', ')})`);
    if (v2InterruptedOk) nativeEvidence.push('v2 subAgentActivity(kind=interrupted) + terminal child turn status');
    const note = interrupted.length > 0 && !terminalTurn
      ? `subAgentActivity(kind=interrupted) was observed but the last child turn status is ${String(lastTurnStatus)} (not terminal)`
      : null;
    return {
      id: c.id,
      v1CleanupToolCalls: calls.map((x) => x.tool),
      v1CleanupItemIds: calls.map((x) => x.itemId),
      v2InterruptedActivityItemIds: interrupted.map((a) => a.itemId),
      v2CompletedActivityItemIds: completedActs.map((a) => a.itemId),
      lastTurnStatus,
      allTurnsCompleted,
      nativeEvidence,
      closed: nativeEvidence.length > 0,
      note,
    };
  });
  const closedAll = state.children.length > 0 && cleanupEvidence.every((c) => c.closed);
  const anyNativeEvidence = cleanupEvidence.some((c) => c.closed);
  const anyUnconfirmedInterrupt = cleanupEvidence.some((c) => !c.closed && c.v2InterruptedActivityItemIds.length > 0);
  addCheck('children_closed', 'every child shows native observed closure evidence together with a terminal child state',
    closedAll ? 'verified' : anyNativeEvidence ? 'partial' : anyUnconfirmedInterrupt ? 'unverified' : 'not_observed',
    closedAll
      ? `native closure evidence per child: ${JSON.stringify(cleanupEvidence.map((c) => ({ id: c.id, evidence: c.nativeEvidence })))}`
      : anyNativeEvidence
        ? `closure evidence covers only some children: ${JSON.stringify(cleanupEvidence.map((c) => ({ id: c.id, evidence: c.nativeEvidence, note: c.note })))}`
        : anyUnconfirmedInterrupt
          ? `an interruption activity was observed but the child state is not terminal: ${JSON.stringify(cleanupEvidence.map((c) => ({ id: c.id, note: c.note })))}`
          : 'no cleanup evidence was observed (no closeAgent/interruptAgent tool call and no subAgentActivity(kind=interrupted) item) — ' +
            'reported as observed, never fabricated; the harness does not close children on the model\'s behalf',
    { children: cleanupEvidence });
}

// --------------------------------------------------------------------------------------
// summary output
// --------------------------------------------------------------------------------------

function buildSummary() {
  const cls = classifyChildren();
  const parentItems = state.parent.readback ? itemsFromThreadRead(state.parent.readback) : [];
  return {
    harness: {
      name: 'native-provider-harness',
      version: HARNESS_VERSION,
      argv: process.argv.slice(2),
      startedAt: iso(state.startedAtMs),
      finishedAt: state.finishedAtMs ? iso(state.finishedAtMs) : null,
      status: state.status,
      interrupted: state.interrupted,
      note: 'Test-owned observations only. A child thread id must come from a real observed record — a v2 subAgentActivity(kind=started) item or a v1 collabAgentToolCall(spawnAgent) receiver id; the harness never synthesizes agent events or parent ids, and never claims a tool call the server did not publish.',
    },
    invocation: {
      exe: opts.codex,
      args: CODE_ARGS,
      out: OUT_DIR,
      processCwd: OUT_DIR,
      codexHome: (state.initialize && state.initialize.codexHome) || null,
      userAgent: (state.initialize && state.initialize.userAgent) || null,
      credentialsReadOrCopied: false,
      globalConfigModifiedByHarness: false,
      projectTrustWriteAvoided: 'thread/start was called without the `cwd` field so the app-server would not persist a project trust entry',
    },
    role: {
      ...state.role,
      declaration: 'thread/start params.config.agents.<name>.config_file (absolute path); the file also lives in the project-local .codex/agents directory',
    },
    parent: {
      threadId: state.parent.threadId,
      turnId: state.parent.turnId,
      requested: { model: opts.parentModel, effort: opts.parentEffort, provider: opts.parentProvider || '(inherited)' },
      startResponse: state.parent.startResponse
        ? {
            threadId: state.parent.startResponse.thread ? state.parent.startResponse.thread.id : null,
            model: state.parent.startResponse.model,
            modelProvider: state.parent.startResponse.modelProvider,
            reasoningEffort: state.parent.startResponse.reasoningEffort ?? null,
            cwd: state.parent.startResponse.cwd,
            sandbox: state.parent.startResponse.sandbox,
            approvalPolicy: state.parent.startResponse.approvalPolicy,
          }
        : null,
      turnCompleted: state.parent.turnCompleted ? state.parent.turnCompleted.turn : null,
      turnTimedOut: state.parent.turnTimedOut,
      parentItemCount: parentItems.length,
      finalAgentMessages: state.parent.readback ? agentMessagesFromReadback(state.parent.readback).slice(-3) : [],
      finalAgentMessagesNote: 'Informational only. Parent prose is NEVER used as pass/fail evidence.',
    },
    children: state.children.map((c) => ({
      id: c.id,
      agentPath: c.agentPath,
      parentThreadId: c.thread ? c.thread.parentThreadId : null,
      agentRole: c.thread ? c.thread.agentRole : null,
      agentNickname: c.thread ? c.thread.agentNickname : null,
      model: c.thread ? c.thread.model : null,
      modelProvider: c.thread ? c.thread.modelProvider : null,
      reasoningEffort: c.thread ? c.thread.reasoningEffort : null,
      statusAtRead: c.thread ? c.thread.status : null,
      statusAfter: c.statusAfter ?? null,
      ephemeral: c.thread ? c.thread.ephemeral : null,
      turns: c.turns,
      spawnCall: c.spawnCall,
      readbackError: c.readbackError ?? null,
      classification:
        cls.deepseekChild && cls.deepseekChild.id === c.id ? 'deepseek_role_child'
          : cls.gptChild && cls.gptChild.id === c.id ? 'ordinary_gpt_child'
            : 'unclassified',
    })),
    evidence: {
      spawnCalls: collabToolCalls().filter((c) => c.tool === 'spawnAgent'),
      followupAndMessageCalls: collabToolCalls().filter((c) => ['followupTask', 'sendInput', 'sendMessage'].includes(c.tool)),
      cleanupCalls: collabToolCalls().filter((c) => ['closeAgent', 'interruptAgent'].includes(c.tool)),
      otherCollabCalls: collabToolCalls().filter((c) => !['spawnAgent', 'followupTask', 'sendInput', 'sendMessage', 'closeAgent', 'interruptAgent'].includes(c.tool)),
      // SubAgentActivity records are the v2 evidence: kind=started (spawn), interacted
      // (send_message/followup_task), interrupted (interrupt_agent), completed (child finished).
      // Records are deduplicated across item/started, item/completed and thread/read observations.
      subAgentActivities: subAgentActivities(),
      subAgentActivityCountsByKind: subAgentActivities().reduce((acc, a) => {
        const k = String(a.kind);
        acc[k] = (acc[k] || 0) + 1;
        return acc;
      }, {}),
      childDiscovery: state.children.map((c) => ({
        id: c.id,
        agentPath: c.agentPath,
        sources: c.discovery ? c.discovery.sources : [],
        activityKinds: c.discovery ? c.discovery.activityKinds : [],
        activityItemIds: c.discovery ? c.discovery.activityItemIds : [],
      })),
      spawnIntervalsMs: spawnIntervals(),
      childTurnIntervals: state.children.map((c) => ({
        id: c.id,
        firstTurn: c.turns.length > 0 ? { id: c.turns[0].id, startedAt: c.turns[0].startedAt, completedAt: c.turns[0].completedAt } : null,
        turnCount: c.turns.length,
      })),
    },
    files: {
    deepseek_task: {
      ...(state.files.deepseek || { path: DEEPSEEK_FILE, exists: false, bytes: null, sha256: null, normalized: null }),
      expectedNormalized: typeof state.expected.deepseek === 'string' ? normalizeFileText(state.expected.deepseek) : null,
    },
    gpt_task: {
      ...(state.files.gpt || { path: GPT_FILE, exists: false, bytes: null, sha256: null, normalized: null }),
      expectedNormalized: typeof state.expected.gpt === 'string' ? normalizeFileText(state.expected.gpt) : null,
    },
  },
    checks: state.checks,
    protocol: {
      notifications: state.notifications.map((n) => ({ t: iso(n.tMs), method: n.method })),
      notificationCount: state.notifications.length,
      serverRequests: state.serverRequests,
      requestFailures: state.requestFailures,
      protocolErrors: state.protocolErrors,
      distinctNotificationMethods: [...new Set(state.notifications.map((n) => n.method))].sort(),
    },
    traces: {
      rpc: RPC_TRACE,
      notifications: NOTIFICATION_TRACE,
      serverStderr: SERVER_STDERR,
      harnessLog: LOG_FILE,
      parentPrompt: path.join(OUT_DIR, 'parent-prompt.txt'),
    },
    knownLimits: [
      'The harness records what this connection observed. Child threads are read back with thread/read, which works for persisted threads; an unpersisted/ephemeral child would surface as an explicit read error rather than invented data.',
      'Concurrency is only reported as verified when the children\'s own turn intervals (thread/read startedAt/completedAt, unix seconds) overlap. Overlapping parent-side spawn calls alone is reported as unverified.',
      'reasoningEffort on a child thread comes from Thread.reasoningEffort ("current configured reasoning effort when loaded"); when it is null the harness reports the effort as unconfirmed instead of assuming the role value.',
      'If the app-server cannot expose a required field (for example a child thread that was never persisted), the harness records the exact error and marks the dependent check unverified rather than substituting evidence.',
      'The harness never sets CODEX_HOME: the app-server inherits the existing user provider config/auth. When --parent-provider is empty the parent provider is whatever the user config selects (reported as observed); the harness does not claim the parent is natively "openai" beyond what thread/start returns.',
      'Whether the collaboration tools the parent received are the v1 family (multi_agent_v1: spawn_agent/send_input/wait_agent/resume_agent/close_agent) or the v2 family (spawn_agent/send_message/followup_task/wait_agent/interrupt_agent/list_agents) depends on the effective config features; the harness reports the tool names it actually observed instead of assuming one family.',
      'v2 has no close_agent tool, and on v2 a spawn/follow-up/interrupt publishes NO collabAgentToolCall item at all (multi_agents_v2/spawn.rs analytics.track_collab_tool_call only calls AnalyticsClient::record_fact). The real v2 signals are SubAgentActivity items (kind = started | interacted | interrupted | completed). Child discovery therefore uses subAgentActivity(kind=started) records on v2 and collabAgentToolCall(spawnAgent) receivers on v1; the follow-up check uses subAgentActivity(kind=interacted) plus a second completed child turn; and cleanup requires native evidence (a v1 close/interrupt tool call, or a v2 interrupted activity together with a terminal observed child state) instead of a requested action.',
    ],
  };
}

async function writeSummaries() {
  const summary = buildSummary();
  await fsp.writeFile(SUMMARY_JSON, `${JSON.stringify(summary, null, 2)}\n`, 'utf8');
  const md = renderMarkdown(summary);
  await fsp.writeFile(SUMMARY_MD, md, 'utf8');
  return summary;
}

function renderMarkdown(s) {
  const badge = (st) => ({ verified: 'VERIFIED', failed: 'FAILED', unverified: 'UNVERIFIED', partial: 'PARTIAL', not_observed: 'NOT_OBSERVED' }[st] || String(st).toUpperCase());
  const lines = [];
  lines.push('# native-provider-harness run summary');
  lines.push('');
  lines.push(`- status: **${s.harness.status}**${s.harness.interrupted ? ' (interrupted by user)' : ''}`);
  lines.push(`- started: ${s.harness.startedAt}`);
  lines.push(`- finished: ${s.harness.finishedAt}`);
  lines.push(`- exe: \`${s.invocation.exe}\` ${JSON.stringify(s.invocation.args)}`);
  lines.push(`- out: \`${s.invocation.out}\``);
  lines.push(`- codexHome reported by initialize: \`${s.invocation.codexHome}\` (inherited; nothing read/copied/printed)`);
  lines.push('');
  lines.push('## Verdicts (computed only from protocol data + file bytes)');
  lines.push('');
  lines.push('| check | verdict | detail |');
  lines.push('| --- | --- | --- |');
  for (const c of s.checks) {
    lines.push(`| ${c.id} | ${badge(c.status)} | ${String(c.detail).replace(/\|/g, '\\|')} |`);
  }
  lines.push('');
  lines.push('## Role');
  lines.push('');
  lines.push(`- name: \`${s.role.name}\``);
  lines.push(`- file: \`${s.role.file}\` (sha256 ${s.role.fileSha256})`);
  lines.push(`- model_provider: \`${s.role.provider}\`, model: \`${s.role.model}\`, model_reasoning_effort: \`${s.role.effort}\``);
  lines.push(`- registration: ${s.role.declaration}`);
  lines.push('');
  lines.push('## Parent');
  lines.push('');
  lines.push('```json');
  lines.push(JSON.stringify(s.parent, null, 2));
  lines.push('```');
  lines.push('');
  lines.push('## Children');
  lines.push('');
  lines.push('```json');
  lines.push(JSON.stringify(s.children, null, 2));
  lines.push('```');
  lines.push('');
  lines.push('## Output files (exact bytes)');
  lines.push('');
  for (const [k, f] of Object.entries(s.files)) {
    lines.push(`### ${k} — \`${f.path}\``);
    lines.push('');
    lines.push(`- exists: ${f.exists}, bytes: ${f.bytes}, sha256: ${f.sha256}`);
    lines.push(`- actual (normalized): \`${f.exists ? escapeForReport(f.normalized) : 'n/a'}\``);
    lines.push(`- expected (normalized): \`${escapeForReport(f.expectedNormalized)}\``);
    lines.push(`- exact match: **${f.exists && f.normalized === f.expectedNormalized ? 'yes' : 'no'}**`);
    lines.push('');
  }
  lines.push('## Protocol notes');
  lines.push('');
  lines.push(`- inbound notifications: ${s.protocol.notificationCount}`);
  lines.push(`- distinct notification methods: ${s.protocol.distinctNotificationMethods.join(', ') || '(none)'}`);
  lines.push(`- server->client requests: ${s.protocol.serverRequests.length}`);
  if (s.protocol.requestFailures.length) {
    lines.push('- request failures:');
    for (const f of s.protocol.requestFailures) lines.push(`  - ${f.method}: ${f.message}`);
  }
  if (s.protocol.protocolErrors.length) {
    lines.push('- protocol errors:');
    for (const f of s.protocol.protocolErrors) lines.push(`  - ${JSON.stringify(f)}`);
  }
  lines.push('');
  lines.push('## Known limits / honest gaps');
  lines.push('');
  for (const l of s.knownLimits) lines.push(`- ${l}`);
  lines.push('');
  lines.push('## Traces');
  lines.push('');
  for (const [k, v] of Object.entries(s.traces)) lines.push(`- ${k}: \`${v}\``);
  lines.push('');
  return lines.join('\n');
}

// --------------------------------------------------------------------------------------
// entrypoint
// --------------------------------------------------------------------------------------

process.on('SIGINT', () => {
  log('Ctrl+C received — cancelling with cleanup (turn/interrupt best effort, then killing the app-server)');
  gracefulShutdown('SIGINT').then(() => {
    state.status = 'aborted';
    finish().then(() => process.exit(130));
  });
});
process.on('SIGTERM', () => {
  gracefulShutdown('SIGTERM').then(() => {
    state.status = 'aborted';
    finish().then(() => process.exit(143));
  });
});

let finishing = false;
async function finish() {
  if (finishing) return;
  finishing = true;
  try {
    if (client && !state.interrupted) {
      // let late notifications (e.g. thread/closed) arrive before shutting the transport down
      await new Promise((r) => setTimeout(r, 250));
    }
    if (client) {
      const pid = client.child ? client.child.pid : null;
      await client.stop();
      log(`app-server (pid ${pid}) exit: ${JSON.stringify(client.exitInfo)}`);
      state.protocolErrors = client.protocolErrors;
    }
    state.finishedAtMs = nowMs();
    computeChecks();
    const summary = await writeSummaries();
    log(`summary written: ${SUMMARY_JSON}`);
    log(`summary written: ${SUMMARY_MD}`);
    const counts = summary.checks.reduce((acc, c) => { acc[c.status] = (acc[c.status] || 0) + 1; return acc; }, {});
    log(`check verdicts: ${JSON.stringify(counts)}`);
  } catch (err) {
    process.stderr.write(`harness finalization error: ${err && err.stack ? err.stack : err}\n`);
  } finally {
    if (rpcTraceStream) rpcTraceStream.end();
    if (notifTraceStream) notifTraceStream.end();
    if (stderrStream) stderrStream.end();
  }
}

main()
  .then(async () => {
    await finish();
    const tail = (client && client.stderrChunks.join('')) || '';
    if (tail && opts.traceTailBytes > 0) {
      process.stdout.write(`\n--- app-server stderr tail (last ${opts.traceTailBytes} bytes; full log: ${SERVER_STDERR}) ---\n`);
      process.stdout.write(`${tail.slice(-opts.traceTailBytes)}\n`);
    }
    const verified = opts.printPrompt || (state.checks.length > 0 && state.checks.every((check) => check.status === 'verified'));
    process.exit(state.status !== 'completed' ? 3 : verified ? 0 : 4);
  })
  .catch(async (err) => {
    state.status = 'failed';
    state.protocolErrors.push({ kind: 'harness-error', message: String(err && err.message ? err.message : err) });
    process.stderr.write(`harness error: ${err && err.stack ? err.stack : err}\n`);
    await gracefulShutdown('error');
    await finish();
    process.exit(1);
  });
