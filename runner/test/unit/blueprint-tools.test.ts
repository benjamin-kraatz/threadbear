// The blueprint tools (docs/protocol.md, "Blueprints", "Tools"): each given
// only to the thread it's for, checked, and kept across a restart.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { blueprintSetup, ROUND, STEPS } from '../helpers/blueprints.ts';
import { NEVER_ASK_TOOLS, buildThreadbearTools } from '../../src/threadbear-mcp.ts';

const BLUEPRINT_TOOLS = ['ask_round', 'too_small', 'blueprint_written', 'propose_answer', 'report_check', 'update_blueprint'];
const has = (names: string[]) => BLUEPRINT_TOOLS.filter((n) => names.includes(n));

test('only the threads named get the blueprint tools', async () => {
  const b = blueprintSetup();
  const plain = b.h.runner.create({ text: 'Fix the tests', accountId: 'claude-3' }).thread;
  assert.deepEqual(has(b.tools(plain.id).names), [], 'an ordinary thread is unchanged');
  const { blueprint, thread } = b.create();
  assert.equal(thread.kind, 'blueprint');
  assert.deepEqual(has(b.tools(thread.id).names), ['ask_round', 'too_small', 'blueprint_written']);
  await b.tools(thread.id).call('ask_round', ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q2').threadId;
  assert.deepEqual(has(b.tools(side).names), ['propose_answer']);
  b.writeSpec(blueprint.path);
  await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  assert.deepEqual(has(b.tools(check).names), ['report_check']);
  const build = b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' }).threadId;
  assert.deepEqual(has(b.tools(build).names), ['update_blueprint']);
  for (const n of BLUEPRINT_TOOLS) assert.ok(NEVER_ASK_TOOLS.has(`mcp__threadbear__${n}`), `${n} never asks`);
});

test('ask_round stores the round, says to end the turn, and checks what it is given', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  const { call } = b.tools(thread.id);
  const nine = { title: 'Lots', questions: Array.from({ length: 9 }, (_, i) => ({ id: `q${i}`, text: 'Why?', kind: 'text' })) };
  const tooMany = await call('ask_round', nine);
  assert.ok(tooMany.error);
  assert.match(tooMany.text, /at most 8/);
  const badRec = await call('ask_round', { title: 'R', questions: [{ id: 'q', text: 'x', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], recommended: { option: 'c', why: 'w' } }] });
  assert.ok(badRec.error);
  assert.match(badRec.text, /names no option: c/);
  const r = await call('ask_round', ROUND);
  assert.ok(!r.error, r.text);
  assert.match(r.text, /End your turn now; the answers come as the next message/);
  const bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'waiting');
  assert.equal(bp.rounds.length, 1);
  assert.deepEqual(bp.rounds[0].questions.map((q) => q.id), ['r1.q1', 'r1.q2', 'r1.q3']);
  const ev = b.events(thread.id).find((e) => e.type === 'blueprint.round');
  assert.equal(ev.round.id, 'r1');
  assert.deepEqual(ev.round.answers, {});
  assert.equal(bp.id, blueprint.id);
});

test('too_small is only a first move, and draws its card from the summary and an event', async () => {
  const b = blueprintSetup();
  const { thread } = b.create('Rename a button');
  const { call } = b.tools(thread.id);
  const r = await call('too_small', { why: 'It is one string.' });
  assert.ok(!r.error, r.text);
  assert.equal(b.h.runner.get(thread.id).blueprint!.tooSmall?.why, 'It is one string.');
  assert.ok(b.events(thread.id).some((e) => e.type === 'blueprint.tooSmall' && e.why === 'It is one string.'));
  await call('ask_round', ROUND);
  assert.equal(b.h.runner.get(thread.id).blueprint!.tooSmall, undefined, 'a round takes the card away');
  const again = await call('too_small', { why: 'Still small' });
  assert.ok(again.error);
  assert.match(again.text, /first move/);
});

test('blueprint_written needs spec.md and answers.md, takes the snapshot and makes it ready', async () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  const { call } = b.tools(thread.id);
  const early = await call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  assert.ok(early.error);
  assert.match(early.text, /spec\.md and answers\.md aren't in .*dark-mode/);
  b.writeSpec(blueprint.path);
  const r = await call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  assert.ok(!r.error, r.text);
  assert.doesNotMatch(r.text, /check/, 'the project has the check off');
  const bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'ready');
  assert.equal(bp.title, 'Dark mode');
  assert.deepEqual(bp.steps, STEPS);
  assert.equal(bp.checkThreadId, undefined);
  assert.equal(fs.readFileSync(path.join(b.h.home, 'blueprints', bp.id, 'spec.snapshot.md'), 'utf8'), fs.readFileSync(path.join(bp.path, 'spec.md'), 'utf8'));
  assert.ok(b.events(thread.id).some((e) => e.type === 'blueprint.written' && e.path === bp.path));
  assert.ok(!fs.existsSync(path.join(b.repo, '.threadbear', 'blueprints', bp.slug, 'blueprint.json')), "nothing of the runner's in the repo");
});

test('propose_answer checks the answer by its question and draws a card; Use puts it in the draft', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  await b.tools(thread.id).call('ask_round', ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q2').threadId;
  const { call } = b.tools(side);
  const wrong = await call('propose_answer', { answer: 'maybe' });
  assert.ok(wrong.error);
  assert.match(wrong.text, /must be one of yes, no/);
  const r = await call('propose_answer', { answer: 'no' });
  assert.ok(!r.error, r.text);
  assert.match(r.text, /Proposed: No/);
  const ev = b.events(side).find((e) => e.type === 'blueprint.proposal');
  assert.deepEqual([ev.blueprintId, ev.questionId, ev.answer], [blueprint.id, 'r1.q2', { value: 'no' }]);
  assert.equal(b.h.runner.get(thread.id).blueprint!.rounds[0].answers['r1.q2'], undefined, 'nothing moves without Use');
  const used = b.h.runner.useBlueprintProposal(blueprint.id, 'r1.q2').blueprint;
  assert.deepEqual(used.rounds[0].answers['r1.q2'], { value: 'no', fromSideChat: true });
});

test('report_check turns findings into a check round; none sets checked', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  const r = await b.tools(check).call('report_check', { findings: [{ text: 'Step 2 has no tests.' }, { text: 'Two colour sets.', question: { id: 'which', text: 'Which wins?', options: [{ id: 'a', label: 'App' }, { id: 'b', label: 'Sidebar' }] } }] });
  assert.ok(!r.error, r.text);
  const bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'waiting');
  assert.deepEqual(bp.checked && bp.checked.findings, 2);
  const round = bp.rounds.at(-1)!;
  assert.equal(round.kind, 'check');
  assert.deepEqual(round.questions.map((q) => q.kind), ['text', 'single']);
  assert.ok(b.events(thread.id).some((e) => e.type === 'blueprint.round' && e.round.kind === 'check'), 'on the blueprint thread');
  // Nothing found: checked, and nothing more.
  b.h.adapter.sessions.filter((s) => s.opts.threadId === check).at(-1)!.result();
  const again = b.h.runner.checkBlueprint(blueprint.id).threadId;
  b.session(again).init();
  const rounds = b.h.runner.get(thread.id).blueprint!.rounds.length;
  const none = await b.tools(again).call('report_check', { findings: [] });
  assert.ok(!none.error, none.text);
  const after = b.h.runner.get(thread.id).blueprint!;
  assert.equal(after.rounds.length, rounds);
  assert.equal(after.checked?.findings, 0);
});

test('update_blueprint marks steps by id or number, and the whole blueprint with done', async () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  const build = b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' }).threadId;
  const { call } = b.tools(build);
  const noNote = await call('update_blueprint', { step: 's1', note: '' });
  assert.ok(noNote.error);
  const missing = await call('update_blueprint', { step: 's9', note: 'x' });
  assert.ok(missing.error);
  assert.match(missing.text, /No step s9\. The steps: 1 \(s1\) Colours; 2 \(s2\) Toggle/);
  const one = await call('update_blueprint', { step: 1, note: 'Added the colours.' });
  assert.ok(!one.error, one.text);
  assert.match(one.text, /1 to go/);
  assert.ok(b.events(build).some((e) => e.type === 'system.note' && /Step 1 of 2 done: Colours\. Added the colours\./.test(e.text)));
  assert.ok(b.events(thread.id).some((e) => e.type === 'blueprint.step' && e.stepId === 's1' && e.done.threadId === build));
  assert.equal(b.h.runner.get(thread.id).blueprint!.status, 'building');
  const all = await call('update_blueprint', { done: true, note: 'All in.' });
  assert.ok(!all.error, all.text);
  assert.equal(b.h.runner.get(thread.id).blueprint!.status, 'done');
  assert.ok(b.events(thread.id).some((e) => e.type === 'blueprint.step' && e.all === true));
});

test('a blueprint, its rounds and drafts survive a restart', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  await b.tools(thread.id).call('ask_round', ROUND);
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q1': { value: ['a'] } }, 'Draft note');
  const again = b.h.restart();
  const bp = again.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'waiting');
  assert.deepEqual(bp.rounds[0].answers, { 'r1.q1': { value: ['a'] } });
  assert.equal(bp.rounds[0].note, 'Draft note');
  assert.equal(again.runner.blueprintRole(thread.id), 'blueprint');
});

test('ask_round is refused once a build has started, and report_check then leaves it building', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' });
  const r = await b.tools(thread.id).call('ask_round', ROUND);
  assert.ok(r.error);
  assert.match(r.text, /being built, so its answers are locked/);
  await b.tools(check).call('report_check', { findings: [{ text: 'Step 2 has no tests.' }] });
  const bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'building', 'still building: start still works and answers stay locked');
  assert.equal(bp.rounds.at(-1)!.kind, 'check', 'the findings are there to read');
  b.session(thread.id).result();
  b.h.runner.markSeen(thread.id, b.h.runner.get(thread.id).lastSeq);
  assert.equal(b.h.runner.get(thread.id).needsYou, false, "a round it can't answer isn't Needs you");
});

test('ask_round marks earlier questions moot, and a bad moot id changes nothing', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  const { call } = b.tools(thread.id);
  const first = await call('ask_round', ROUND);
  assert.match(first.text, /r1\.q1, r1\.q2, r1\.q3/, 'the result names the ids moot takes');
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  const bad = await call('ask_round', { title: 'Next', questions: [{ id: 'q1', text: 'More?', kind: 'text' }], moot: [{ id: 'r9.q1', why: 'x' }] });
  assert.ok(bad.error);
  assert.equal(b.h.runner.get(thread.id).blueprint!.rounds.length, 1, 'no round put');
  const ok = await call('ask_round', { title: 'Next', questions: [{ id: 'q1', text: 'More?', kind: 'text' }], moot: [{ id: 'r1.q2', why: 'Settings decide it now.' }] });
  assert.ok(!ok.error, ok.text);
  assert.match(ok.text, /1 earlier marked moot/);
  assert.equal(b.h.runner.get(thread.id).blueprint!.rounds[0].questions[1].moot, 'Settings decide it now.');
});

test('a side chat may only propose an upload in words, and Use takes only files already in the blueprint', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, { title: 'Look', questions: [{ id: 'look', text: 'Like this?', kind: 'upload' }] });
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.look').threadId;
  const { call } = b.tools(side);
  for (const answer of [['/etc/hosts'], '/Users/someone/.ssh/id_ed25519', '~/secret.txt']) {
    const r = await call('propose_answer', { answer });
    assert.ok(r.error, JSON.stringify(answer));
    assert.match(r.text, /Propose it in words instead/);
  }
  const words = await call('propose_answer', { answer: 'A screenshot of the sidebar in light mode' });
  assert.ok(!words.error, words.text);
  assert.throws(() => b.h.runner.useBlueprintProposal(blueprint.id, 'r1.look'), /isn't a file in/);
  assert.throws(() => b.h.runner.useBlueprintProposal(blueprint.id, 'r1.look', { value: ['/etc/hosts'] }), /isn't a file in/);
  assert.ok(!fs.existsSync(path.join(blueprint.path, 'attachments')), 'nothing copied into the repo');
  fs.mkdirSync(path.join(blueprint.path, 'attachments'), { recursive: true });
  fs.writeFileSync(path.join(blueprint.path, 'attachments/shot.png'), 'png');
  const used = b.h.runner.useBlueprintProposal(blueprint.id, 'r1.look', { value: ['attachments/shot.png'] }).blueprint;
  assert.deepEqual(used.rounds[0].answers['r1.look'], { value: ['attachments/shot.png'], fromSideChat: true });
});

test('report_check takes a partial question: the runner fills in its id and text', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  const r = await b.tools(check).call('report_check', { findings: [{ text: 'Two colour sets.', question: { options: [{ id: 'a', label: 'App' }, { id: 'b', label: 'Sidebar' }] } }] });
  assert.ok(!r.error, r.text);
  const q = b.h.runner.get(thread.id).blueprint!.rounds.at(-1)!.questions[0];
  assert.deepEqual([q.id.endsWith('.f1'), q.text, q.kind], [true, 'Two colour sets.', 'single']);
});

test("a side chat or check that calls ExitPlanMode is turned down at once, and never needs the user", async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId;
  const s = b.session(side);
  s.init();
  assert.match(s.sent[0].text, /never with a plan or ExitPlanMode/);
  s.out({ kind: 'planProposed', itemId: 'tu-plan', text: '1. Change things' });
  const answer = await s.sink.requestApproval({ toolUseId: 'tu-plan', name: 'ExitPlanMode', title: 'Finish the plan', input: { plan: '...' }, canAlwaysAllow: false, signal: new AbortController().signal });
  assert.equal(answer.decision, 'deny');
  assert.match(answer.message ?? '', /side chat changes nothing/);
  const t = b.h.runner.get(side);
  assert.equal(t.status === 'waiting', false);
  assert.equal(t.needsYou, false);
  assert.ok(!b.events(side).some((e) => e.type === 'plan.proposed' || e.type === 'approval.requested'), 'no plan card');
  s.result();
  assert.equal(b.h.runner.get(side).needsYou, false);
});

test('a tool called with the shape it had before still works (a resumed session keeps the old definition)', async () => {
  const { z } = await import('zod');
  const { buildThreadbearTools } = await import('../../src/threadbear-mcp.ts');
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  const shape = (threadId: string, name: string) =>
    buildThreadbearTools(b.h.runner, threadId, Date.now, undefined, undefined, undefined, {}).find((t) => t.name === name)!.inputSchema as never;
  // As commit 48834318 defined them.
  const oldAskRound = { title: 'Scope', summary: 'x', questions: [{ id: 'q1', text: 'Which?', kind: 'single', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], recommended: { option: 'a', why: 'w' }, youDecide: true }], assumptions: [{ id: 'a1', text: 't', why: 'w' }] };
  assert.ok(z.object(shape(thread.id, 'ask_round')).safeParse(oldAskRound).success);
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  const oldFindings = { findings: [{ text: 'x', question: { id: 'q', text: 'Which?', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }] } }] };
  assert.ok(z.object(shape(check, 'report_check')).safeParse(oldFindings).success);
  const r = await b.tools(check).call('report_check', oldFindings);
  assert.ok(!r.error, r.text);
});

// Found in a run against the real CLI (8 Nov): the agent repeated the
// whole round in its reply, a check sent `question: null` and was refused,
// and then parked its findings on a card of asks nobody opens.
test('the tools tell the agent where the user answers, and report_check takes a null question', async () => {
  const { z } = await import('zod');
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  const asked = await b.tools(thread.id).call('ask_round', ROUND);
  assert.match(asked.text, /The form shows the round, so keep your reply to a line or two/);
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  const check = b.h.runner.get(thread.id).blueprint!.checkThreadId!;
  const shape = buildThreadbearTools(b.h.runner, check, Date.now, undefined, undefined, undefined, {}).find((t) => t.name === 'report_check')!.inputSchema as never;
  const withNull = { findings: [{ text: 'Step 2 has no tests.', question: null }] };
  assert.ok(z.object(shape).safeParse(withNull).success, 'null is no question');
  const r = await b.tools(check).call('report_check', withNull);
  assert.ok(!r.error, r.text);
  assert.match(r.text, /End your turn with needs "nothing" and no asks/);
  const q = b.h.runner.get(thread.id).blueprint!.rounds.at(-1)!.questions[0];
  assert.equal(q.kind, 'text');
});

test("a proposal that ends in a full stop doesn't get a second", async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  await b.tools(thread.id).call('ask_round', ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q3').threadId;
  const r = await b.tools(side).call('propose_answer', { answer: 'Night mode.' });
  assert.ok(!r.error, r.text);
  assert.match(r.text, /^Proposed: Night mode\. The user presses Use/);
});

test('a too-small card waits on the user until a round replaces it', async () => {
  const b = blueprintSetup();
  const { thread } = b.create('Rename a button');
  const s = b.session(thread.id);
  await b.tools(thread.id).call('too_small', { why: 'It is one string.' });
  s.result('completed', 0.1);
  b.h.runner.markSeen(thread.id, b.h.runner.get(thread.id).lastSeq);
  assert.equal(b.h.runner.get(thread.id).needsYou, true, 'start a thread or ask me anyway is theirs to pick');
  b.h.runner.send(thread.id, 'Ask me anyway');
  b.session(thread.id).init();
  await b.tools(thread.id).call('ask_round', ROUND);
  assert.equal(b.h.runner.get(thread.id).blueprint!.tooSmall, undefined);
});

test("while it's drafting, a blueprint goes by its thread's title rather than the cut description", async () => {
  const b = blueprintSetup();
  const text = 'Add snooze presets per project: each project can have its own list of snooze lengths';
  const { blueprint, thread } = b.create(text);
  assert.equal(b.h.runner.listBlueprints().blueprints[0].title, blueprint.title, 'no better title yet');
  b.h.runner.update({ threadId: thread.id, title: 'Per-project snooze presets' });
  assert.equal(b.h.runner.listBlueprints().blueprints[0].title, 'Per-project snooze presets');
  assert.equal(b.h.runner.get(thread.id).blueprint!.title, 'Per-project snooze presets');
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Snooze presets', steps: STEPS });
  assert.equal(b.h.runner.listBlueprints().blueprints[0].title, 'Snooze presets', "the agent's title wins once written");
});

test('ask_round takes other: true on a choice question', async () => {
  const b = blueprintSetup();
  const { thread } = b.create();
  const r = await b.tools(thread.id).call('ask_round', { title: 'T', questions: [{ id: 'q1', text: 'Which?', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], other: true }] });
  assert.ok(!r.error, r.text);
  assert.equal(b.h.runner.get(thread.id).blueprint!.rounds[0].questions[0].other, true);
});
