// Unit fixtures for the observer only. This never launches Codex or proves a live agent run.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('./harness.mjs', import.meta.url), 'utf8').replace(/\r\n/g, '\n');
const section = (start, end) => {
  const from = source.indexOf(start);
  const to = source.indexOf(end, from);
  assert.ok(from >= 0 && to > from, 'Observer function section must exist');
  return source.slice(from, to);
};
const activity = (id, kind, child) => ({
  type: 'subAgentActivity', id, kind, agentThreadId: child, agentPath: '/root/' + child,
});
const notification = (item, method = 'item/completed', threadId = 'parent') => ({
  method, params: { threadId, turnId: 'parent-turn', item, startedAtMs: 1000, completedAtMs: 1100 },
});
const dsStart = activity('spawn-ds', 'started', 'ds');
const gptStart = activity('spawn-gpt', 'started', 'gpt');
const state = {
  parent: {
    threadId: 'parent', turnId: 'parent-turn',
    startResponse: { model: 'gpt', modelProvider: 'openai' },
    turnCompleted: { turn: { status: 'completed' } },
    readback: { thread: { turns: [{ id: 'parent-turn', items: [dsStart, gptStart] }] } },
  },
  notifications: [
    notification(dsStart, 'item/started'), notification(dsStart),
    notification(activity('foreign', 'started', 'foreign'), 'item/completed', 'another-parent'),
  ],
  role: { name: 'deepseek-role', model: 'deepseek', provider: 'router', effort: 'high' },
  children: [], files: {}, expected: {}, checks: [],
};
const context = vm.createContext({
  state, opts: { parentModel: 'gpt', printPrompt: false },
  DEEPSEEK_FILE: 'fixture-ds.txt', GPT_FILE: 'fixture-gpt.txt',
});
vm.runInContext(
  section('function normalizeFileText(', 'function escapeForReport(') +
  section('function escapeForReport(', '// --------------------------------------------------------------------------------------\n// paths') +
  section('function itemsFromThreadRead(', 'async function readFileInfo(') +
  section('function classifyChildren(', 'function buildSummary('), context,
);
const evaluate = (expression) => vm.runInContext(expression, context);
const plain = (value) => JSON.parse(JSON.stringify(value));
const discovery = evaluate('discoverChildren()');
assert.deepEqual(plain(discovery.childIds), ['ds', 'gpt']);
const records = plain(evaluate('subAgentActivities()'));
assert.equal(records.length, 2);
assert.equal(records[0].startedAtMs, 1000);
assert.equal(records[0].completedAtMs, 1100);
assert.equal(records[0].observedVia.length, 3);

for (const id of discovery.childIds) {
  const deepseek = id === 'ds';
  state.children.push({
    id, discovery: discovery.perChild.get(id),
    thread: {
      parentThreadId: 'parent', model: deepseek ? 'deepseek' : 'gpt',
      modelProvider: deepseek ? 'router' : 'openai',
      agentRole: deepseek ? 'deepseek-role' : null, reasoningEffort: 'high',
    },
    turns: deepseek ? [
      { id: 'ds-1', status: 'completed', startedAt: 10, completedAt: 20 },
      { id: 'ds-2', status: 'completed', startedAt: 30, completedAt: 40 },
    ] : [{ id: 'gpt-1', status: 'completed', startedAt: 11, completedAt: 21 }],
  });
}
const interaction = activity('follow-ds', 'interacted', 'ds');
state.notifications.push(notification(interaction, 'item/started'), notification(interaction));
state.notifications.push(notification(activity('done-ds', 'completed', 'ds')));
state.notifications.push(notification(activity('done-gpt', 'completed', 'gpt')));
const check = (id) => state.checks.find((entry) => entry.id === id).status;
const recompute = () => { state.checks = []; evaluate('computeChecks()'); };
recompute();
assert.equal(check('followup_same_deepseek_child'), 'verified');
assert.notEqual(check('children_closed'), 'verified', 'Natural completion is not explicit cleanup');

state.notifications.push(notification(activity('close-ds', 'interrupted', 'ds')));
state.notifications.push(notification(activity('close-gpt', 'interrupted', 'gpt')));
recompute();
assert.equal(check('children_closed'), 'verified');
state.notifications.push(notification(activity('extra-follow', 'interacted', 'ds')));
recompute();
assert.equal(check('followup_same_deepseek_child'), 'failed');
console.log('Observer fixtures passed: v2 discovery, deduplication, parent scope, follow-up counts, explicit cleanup. No live agents were run.');
