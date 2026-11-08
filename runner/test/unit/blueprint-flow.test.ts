// A blueprint from start to built (docs/protocol.md, "Blueprints"): the
// thread and its instructions, a round and its answers, the message the
// agent gets, the spec written and checked, a build and its steps, and the
// status and cost along the way. Then side chats, edited by hand, a stale
// spec, found blueprints, too small and delete.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { blueprintSetup, ROUND, STEPS } from '../helpers/blueprints.ts';
import { HAIKU } from '../../src/models/index.ts';
import { ErrorCode } from '../../src/protocol.ts';
import { blueprintMethods } from '../../src/runner/blueprints.ts';

const code = (fn: () => unknown): number | undefined => {
  try {
    fn();
  } catch (e) {
    return (e as { code?: number }).code;
  }
  return undefined;
};

test('a blueprint from description to done', async () => {
  const b = blueprintSetup();
  fs.mkdirSync(path.join(b.root, '.threadbear/blueprints'), { recursive: true });
  fs.writeFileSync(path.join(b.root, '.threadbear/blueprints/template.md'), 'Always settle telemetry.');
  const { blueprint, thread } = b.create('Add a dark mode to the app');
  const s = b.session(thread.id);

  // The thread: a blueprint, in the project folder and the project, told its job.
  assert.equal(thread.kind, 'blueprint');
  assert.equal(thread.cwd, b.repo);
  assert.equal(blueprint.status, 'drafting');
  assert.equal(blueprint.path, path.join(b.repo, '.threadbear/blueprints/add-a-dark-mode-to-the-app'));
  assert.equal(blueprint.threadId, thread.id);
  assert.ok(thread.projects?.some((p) => p.id === b.project.id), 'in its project');
  assert.equal(s.sent[0].text, 'Add a dark mode to the app');
  assert.match(s.opts.instructions ?? '', /\[Threadbear blueprint\]/);
  assert.match(s.opts.instructions ?? '', /Always settle telemetry\./);
  assert.equal(thread.worktree, undefined);

  // A round: waiting, and Needs you once the turn is over.
  await b.tools(thread.id).call('ask_round', ROUND);
  assert.equal(b.h.runner.get(thread.id).blueprint!.status, 'waiting');
  s.result('completed', 0.5);
  b.h.runner.markSeen(thread.id, b.h.runner.get(thread.id).lastSeq);
  assert.equal(b.h.runner.get(thread.id).needsYou, true, 'a round open needs the user');

  // Continue needs every needs-you question answered.
  assert.equal(code(() => b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q1': { value: ['a'] } })), ErrorCode.badParams);
  const sentBefore = s.sent.length;
  const r = b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q1': { value: ['a', 'b'] }, 'r1.q2': { youDecide: true }, 'r1.q3': { value: 'Night' } }, 'Keep it small.');
  assert.ok(r.turnId);
  assert.equal(s.sent.length, sentBefore + 1);
  const message = s.sent.at(-1)!.text;
  assert.match(message, /My answers to "Scope"/);
  assert.match(message, /Settings, Sidebar/);
  assert.match(message, /you decide, so your recommendation: Yes/);
  assert.match(message, /Note: Keep it small\./);
  const user = b.events(thread.id).filter((e) => e.type === 'user.message').at(-1);
  assert.equal(user.roundId, 'r1');
  const answered = b.events(thread.id).find((e) => e.type === 'blueprint.answered');
  assert.equal(answered.roundId, 'r1');
  assert.equal(answered.note, 'Keep it small.');
  let bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'drafting');
  assert.ok(bp.rounds[0].sentAt);
  assert.equal(bp.rounds[0].note, undefined, 'the note went with the answers');

  // Sent twice (a dropped reply): nothing more goes.
  const twice = b.h.runner.continueBlueprint(blueprint.id, 'r1', undefined);
  assert.equal(twice.turnId, r.turnId);
  assert.equal(s.sent.length, sentBefore + 1);

  // A changed answer before the spec: only the change goes.
  s.result('completed', 0.75);
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { ...bp.rounds[0].answers, 'r1.q2': { value: 'no' } });
  assert.ok(b.h.runner.get(thread.id).blueprint!.rounds[0].answers['r1.q2'].changedAt);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', undefined);
  const change = s.sent.at(-1)!.text;
  assert.match(change, /Question 2 \("Follow the system\?"\) was you decide, so your recommendation: Yes, now No\./);
  assert.doesNotMatch(change, /Which screens/);

  // Not ready yet: no build.
  assert.equal(code(() => b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' })), ErrorCode.busy);
  assert.equal(code(() => b.h.runner.startBlueprint({ id: blueprint.id, mode: 'threads' })), ErrorCode.badParams);

  // The spec, then the check: a cheap plan-mode child of the blueprint.
  b.writeSpec(bp.path);
  const written = await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  assert.match(written.text, /A check of the spec/);
  bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'ready');
  const check = b.h.runner.get(bp.checkThreadId!);
  assert.equal(check.kind, 'check');
  assert.equal(check.parentThreadId, thread.id);
  assert.equal(check.permissionMode, 'plan');
  assert.equal(check.model, HAIKU);
  assert.match(b.session(check.id).sent[0].text, new RegExp(`Read the spec at ${path.join(bp.path, 'spec.md').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`));
  s.result('completed', 1);
  const cs = b.session(check.id);
  cs.init();
  await b.tools(check.id).call('report_check', { findings: [{ text: 'Step 2 has no tests.' }] });
  cs.result('completed', 0.05);
  assert.equal(b.h.runner.get(check.id).needsYou, false, "a check's finished turn isn't Needs you");
  bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'waiting');
  assert.equal(bp.costUsd, 1.05, "the thread's cost and its children's");

  // The check's round answered: the agent is told to update the spec.
  const checkRound = bp.rounds.at(-1)!;
  b.h.runner.continueBlueprint(blueprint.id, checkRound.id, { [checkRound.questions[0].id]: { value: 'Add a UI test.' } });
  assert.match(s.sent.at(-1)!.text, /Step 2 has no tests\.[\s\S]*Add a UI test\.[\s\S]*Update the spec with these/);
  assert.equal(b.h.runner.get(thread.id).blueprint!.status, 'drafting');
  // Written again in answer to the check: not checked again, or check
  // rounds would never stop. The check's count stays.
  const threadsBefore = b.h.runner.list(['inbox', 'snoozed', 'archived']).length;
  const rewritten = await b.tools(thread.id).call('blueprint_written', { title: 'Dark mode', steps: STEPS });
  assert.doesNotMatch(rewritten.text, /check/i);
  s.result('completed', 1.25);
  assert.equal(b.h.runner.list(['inbox', 'snoozed', 'archived']).length, threadsBefore, 'no new check thread');
  assert.equal(b.h.runner.get(thread.id).blueprint!.checkThreadId, check.id);
  assert.equal(b.h.runner.get(thread.id).blueprint!.checked?.findings, 1);
  assert.equal(b.h.runner.get(thread.id).blueprint!.status, 'ready');

  // Start a build: a normal thread, started by the blueprint, pointed at the spec.
  const { threadId: buildId } = b.h.runner.startBlueprint({ id: blueprint.id, mode: 'subagents' });
  const build = b.h.runner.get(buildId);
  assert.equal(build.kind, undefined);
  assert.equal(build.parentThreadId, undefined);
  assert.equal(build.cwd, b.repo);
  assert.equal(build.permissionMode, 'full');
  assert.deepEqual(build.startedBy, { kind: 'blueprint', label: 'Blueprint', threadId: thread.id, threadTitle: b.h.runner.get(thread.id).title });
  const first = b.session(buildId).sent[0].text;
  assert.ok(first.startsWith(`Build the blueprint at ${path.join(bp.path, 'spec.md')}.`));
  assert.match(first, /subagents/);
  bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'building');
  assert.deepEqual(bp.builds.map((x) => [x.threadId, x.mode]), [[buildId, 'subagents']]);
  // Answers lock while it builds.
  assert.equal(code(() => b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', {})), ErrorCode.busy);

  b.session(buildId).init();
  await b.tools(buildId).call('update_blueprint', { step: 's1', note: 'Colours in.' });
  await b.tools(buildId).call('update_blueprint', { step: 's2', note: 'Toggle in.' });
  bp = b.h.runner.get(thread.id).blueprint!;
  assert.equal(bp.status, 'done');
  assert.ok(bp.steps.every((x) => x.done?.threadId === buildId));
  // Done stays startable, and in the repo until deleted.
  assert.ok(fs.existsSync(path.join(bp.path, 'spec.md')));
  assert.ok(b.h.runner.listBlueprints().blueprints.some((x) => x.id === blueprint.id && x.status === 'done'));
});

test('side chats: one per question, plan mode on the small model, about that question', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const first = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q2').threadId;
  assert.equal(b.h.runner.blueprintSideChat(blueprint.id, 'r1.q2').threadId, first, 'opening it again resumes it');
  const side = b.h.runner.get(first);
  assert.deepEqual([side.kind, side.parentThreadId, side.permissionMode, side.model, side.cwd], ['sideChat', thread.id, 'plan', HAIKU, b.repo]);
  const text = b.session(first).sent[0].text;
  assert.match(text, /The feature:\nAdd a dark mode to the app/);
  assert.match(text, /The question:\nFollow the system\?/);
  assert.equal(b.h.runner.get(thread.id).blueprint!.sideChats['r1.q2'], first);
  assert.equal(code(() => b.h.runner.blueprintSideChat(blueprint.id, 'r1.nope')), ErrorCode.badParams);
});

test('edited by hand: spotted on list, shown as a diff, told to the agent', () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  b.session(thread.id).result();
  assert.equal(b.h.runner.listBlueprints().blueprints[0].editedByHand, undefined);
  assert.equal(code(() => b.h.runner.tellAgentBlueprint(blueprint.id)), ErrorCode.busy, 'nothing to tell');
  const spec = path.join(blueprint.path, 'spec.md');
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace('Dark.', 'Dark, and high contrast.'));
  const listed = b.h.runner.listBlueprints(b.project.id).blueprints[0];
  assert.equal(listed.editedByHand, true);
  const { hunks } = b.h.runner.blueprintDiff(blueprint.id);
  assert.ok(hunks.some((h) => h.lines.includes('-Dark.') && h.lines.includes('+Dark, and high contrast.')));
  b.h.runner.tellAgentBlueprint(blueprint.id);
  assert.match(b.session(thread.id).sent.at(-1)!.text, /\+Dark, and high contrast\.[\s\S]*Bring answers.md into line, or ask me\./);
  // The agent writes it again: the snapshot moves.
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  assert.equal(b.h.runner.listBlueprints().blueprints[0].editedByHand, undefined);
});

test('a changed answer after the spec makes it stale until Update the spec is answered', () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  b.session(thread.id).result();
  assert.equal(code(() => b.h.runner.updateSpecBlueprint(blueprint.id)), ErrorCode.busy, 'nothing changed');
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Dusk' } });
  let bp = b.h.runner.get(thread.id).blueprint!;
  assert.deepEqual([bp.status, bp.specStale], ['drafting', true]);
  assert.equal(code(() => b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' })), ErrorCode.busy, 'no build from a stale spec');
  b.h.runner.updateSpecBlueprint(blueprint.id);
  assert.match(b.session(thread.id).sent.at(-1)!.text, /was Night, now Dusk\.[\s\S]*Update the spec and answers.md/);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  bp = b.h.runner.get(thread.id).blueprint!;
  assert.deepEqual([bp.status, bp.specStale], ['ready', undefined]);
});

test('an assumption asked instead goes as an open question in the next message', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  b.h.runner.askInsteadBlueprint(blueprint.id, 'r1', 'r1.a1');
  assert.deepEqual(b.h.runner.get(thread.id).blueprint!.rounds[0].askInstead, ['r1.a1']);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } }, undefined, true);
  const text = b.session(thread.id).sent.at(-1)!.text;
  assert.match(text, /Ask me instead, as open questions in your next round:\n- Colours come from the asset catalog/);
  assert.match(text, /Write the spec now with what you have/);
  assert.equal(b.h.runner.get(thread.id).blueprint!.rounds[0].writeNow, true);
});

test('a blueprint found in the repo with no state here is ready, and can be built', () => {
  const b = blueprintSetup();
  const dir = path.join(b.repo, '.threadbear/blueprints/from-elsewhere');
  b.writeSpec(dir, '# From elsewhere\n\n## Steps\n- [ ] One\n- [x] Two\n');
  const found = b.h.runner.listBlueprints().blueprints.find((x) => x.slug === 'from-elsewhere')!;
  assert.deepEqual([found.status, found.threadId, found.title, found.steps.length], ['ready', undefined, 'From elsewhere', 2]);
  assert.equal(code(() => b.h.runner.saveBlueprintDraft(found.id, 'r1', {})), ErrorCode.badParams, 'it has no answers to change');
  const { threadId } = b.h.runner.startBlueprint({ id: found.id, mode: 'thread' });
  assert.deepEqual(b.h.runner.get(threadId).startedBy, { kind: 'blueprint', label: 'Blueprint' });
  const now = b.h.runner.listBlueprints().blueprints.filter((x) => x.slug === 'from-elsewhere');
  assert.equal(now.length, 1, 'listed once, with state now');
  assert.equal(now[0].status, 'building');
});

test('slugs get -2 on a collision, and the project can say where blueprints go', () => {
  const b = blueprintSetup();
  const one = b.create('Dark mode').blueprint;
  const two = b.create('Dark mode').blueprint;
  assert.deepEqual([one.slug, two.slug], ['dark-mode', 'dark-mode-2']);
  b.projects.update(b.project.id, { blueprints: { dir: 'docs/plans' } });
  const three = b.create('Dark mode').blueprint;
  assert.equal(three.path, path.join(b.repo, 'docs/plans/dark-mode'));
  assert.throws(() => b.projects.update(b.project.id, { blueprints: { folder: '/not/its/own' } }), /one of the project's folders/);
  assert.throws(() => b.projects.update(b.project.id, { blueprints: { dir: '../out' } }), /inside the project folder/);
  assert.deepEqual(b.projects.update(b.project.id, { blueprints: null }).blueprints, undefined);
});

test('too small: Start a thread makes a normal one with the description and the blueprint goes', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create('Rename the Save button');
  b.h.runner.tooSmall(thread.id, 'One string.');
  const { threadId } = b.h.runner.tooSmallStart(blueprint.id);
  const t = b.h.runner.get(threadId);
  assert.equal(t.kind, undefined);
  assert.equal(b.session(threadId).sent[0].text, 'Rename the Save button');
  assert.ok(b.h.runner.get(thread.id).archivedAt, 'the blueprint thread is archived');
  assert.equal(b.h.runner.listBlueprints().blueprints.length, 0);
});

test('delete removes the folder from the repo, archives the threads and drops the state', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId;
  b.writeSpec(blueprint.path);
  fs.mkdirSync(path.join(blueprint.path, 'attachments'));
  b.h.runner.deleteBlueprint(blueprint.id);
  assert.ok(!fs.existsSync(blueprint.path));
  assert.ok(fs.existsSync(path.join(b.repo, '.threadbear/blueprints')), 'only its own folder');
  assert.ok(b.h.runner.get(thread.id).archivedAt);
  assert.ok(b.h.runner.get(side).archivedAt);
  assert.equal(b.h.runner.get(thread.id).blueprint, undefined);
  assert.equal(b.h.runner.listBlueprints().blueprints.length, 0);
  assert.ok(!fs.existsSync(path.join(b.h.home, 'blueprints', blueprint.id)));
});

test("the app's requests: create needs a project, start a known mode", () => {
  const b = blueprintSetup();
  const m = blueprintMethods(b.h.runner);
  assert.equal(code(() => m['blueprints.create']({ text: 'x' })), ErrorCode.badParams);
  const folder = fs.realpathSync(b.root);
  const made = m['blueprints.create']({ newProject: { title: 'New one', folder }, text: 'A feature', accountId: 'claude-3' }) as { blueprint: { projectId: string; folder: string } };
  assert.equal(made.blueprint.folder, folder);
  assert.ok(b.projects.list().some((p) => p.id === made.blueprint.projectId && p.title === 'New one'));
  const listed = m['blueprints.list']({ projectId: made.blueprint.projectId }) as { blueprints: unknown[] };
  assert.equal(listed.blueprints.length, 1);
  assert.equal(code(() => m['blueprints.start']({ id: 'nope', mode: 'thread' })), ErrorCode.badParams);
});

test('an upload is copied into attachments/, and files are kept relative to the project folder', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, {
    title: 'Files',
    questions: [
      { id: 'look', text: 'Like this?', kind: 'upload', several: true },
      { id: 'where', text: 'Which files?', kind: 'files', several: true },
    ],
  });
  const mac = path.join(b.root, 'mockup.png');
  fs.writeFileSync(mac, 'png');
  fs.writeFileSync(path.join(b.repo, 'a.swift'), '');
  const saved = b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.look': { value: [mac, mac] }, 'r1.where': { value: [path.join(b.repo, 'a.swift')] } }).blueprint;
  assert.deepEqual(saved.rounds[0].answers['r1.look'].value, ['attachments/mockup.png', 'attachments/mockup-2.png']);
  assert.equal(fs.readFileSync(path.join(blueprint.path, 'attachments/mockup.png'), 'utf8'), 'png');
  assert.deepEqual(saved.rounds[0].answers['r1.where'].value, ['a.swift']);
  assert.equal(code(() => b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.where': { value: ['/etc/hosts'] } })), ErrorCode.badParams);
  // Saved again as it came back: nothing copied twice.
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', saved.rounds[0].answers);
  assert.deepEqual(fs.readdirSync(path.join(blueprint.path, 'attachments')).sort(), ['mockup-2.png', 'mockup.png']);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', undefined);
  assert.match(b.session(thread.id).sent.at(-1)!.text, /attachments\/mockup\.png, attachments\/mockup-2\.png \(in the blueprint folder\)/);
});

test("a blueprint's side chats and checks never need the user from the Inbox", () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const side = b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId;
  const s = b.session(side);
  s.init();
  s.text('t1', 'Settings alone, I think.');
  s.result();
  assert.equal(b.h.runner.get(side).needsYou, false);
  assert.equal(b.h.runner.get(side).parentThreadId, thread.id);
});

test('a handover: the draining runner and the new one share blueprints.json, and events reach the thread where it is', async () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  b.writeSpec(blueprint.path);
  const check = b.h.runner.blueprintChild(b.h.runner.blueprintStore().get(blueprint.id)!, 'check', 'Check it', 'Check');
  b.h.runner.blueprintStore().put({ ...b.h.runner.blueprintStore().get(blueprint.id)!, checkThreadId: check });
  // The new runner, on the same data dir, has the blueprint thread; the old
  // one keeps only the check thread, still finishing its turn.
  const primary = b.h.restart();
  primary.runner.threads.delete(check);
  const old = b.h.runner;
  old.threads.delete(thread.id);
  old.draining = { keep: new Set([check]), going: new Set(), gone: new Set([thread.id]), onHandedOver: () => {}, since: 0, backgroundMs: 0, agentMs: 0, checkMs: 0, checkQueued: false, ready: () => true } as never;
  // The app saves a draft on the new one; the old one's check reports.
  primary.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  const before = b.h.notes.length;
  old.reportCheck(check, [{ text: 'Step 2 has no tests.' }]);
  const saved = JSON.parse(fs.readFileSync(path.join(b.h.home, 'blueprints.json'), 'utf8')).blueprints[0];
  assert.deepEqual(saved.rounds[0].answers['r1.q3'], { value: 'Night' }, "the new runner's draft is kept");
  assert.equal(saved.rounds.at(-1).kind, 'check', "and the old runner's check round");
  // The round's event goes to the new runner, which has the thread.
  const sent = b.h.notes.slice(before).find((n) => n.method === 'drain.blueprints') as { params: { threadId: string; events: { type: string }[] } } | undefined;
  assert.ok(sent, 'drain.blueprints');
  assert.equal(sent.params.threadId, thread.id);
  primary.runner.blueprintDrain(sent.params);
  assert.ok(primary.events(thread.id).some((e) => e.type === 'blueprint.round' && e.round.kind === 'check'));
  const bp = primary.runner.get(thread.id).blueprint!;
  assert.equal(bp.rounds.at(-1)!.kind, 'check', 'its summary reads the file afresh');
  assert.deepEqual(bp.rounds[0].answers['r1.q3'], { value: 'Night' });
  // A draining runner makes no threads: an automatic check goes to the primary.
  old.startBlueprintCheck(old.blueprintStore().get(blueprint.id)!);
  assert.ok(b.h.notes.some((n) => n.method === 'drain.blueprints' && (n.params as { check?: string }).check === blueprint.id));
});

test("during a handover a blueprint's request goes to the runner that has its thread", async () => {
  const { RpcServer } = await import('../../src/rpc.ts');
  const { RunnerClient } = await import('../../src/client.ts');
  const { nullLogger } = await import('../../src/log.ts');
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const calls: { threadId: string; method: string }[] = [];
  const remote = { owns: (id: string) => id === thread.id, call: async (threadId: string, method: string) => (calls.push({ threadId, method }), { blueprint: {} }), summaries: () => [], search: async () => [] };
  const server = new RpcServer({ host: '127.0.0.1', port: 0, token: 'test-token-0123456789', runner: b.h.runner, log: nullLogger, methods: blueprintMethods(b.h.runner), remote: remote as never });
  const { port } = await server.listen();
  const c = await RunnerClient.connect(`ws://127.0.0.1:${port}/rpc`, 'test-token-0123456789');
  try {
    // Here while this runner has the thread.
    await c.call('blueprints.saveDraft', { id: blueprint.id, roundId: 'r1', answers: {} });
    assert.deepEqual(calls, []);
    const st = b.h.runner.threads.get(thread.id)!;
    b.h.runner.threads.delete(thread.id);
    await c.call('blueprints.saveDraft', { id: blueprint.id, roundId: 'r1', answers: {} });
    await c.call('blueprints.continue', { id: blueprint.id, roundId: 'r1' });
    await c.call('blueprints.list', {});
    assert.deepEqual(calls, [{ threadId: thread.id, method: 'blueprints.saveDraft' }, { threadId: thread.id, method: 'blueprints.continue' }], 'list stays here');
    b.h.runner.threads.set(thread.id, st);
  } finally {
    c.close();
    await server.close();
  }
});

test("a build ticking the spec's boxes isn't an edit by hand, nor is the agent writing it again", () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  const spec = path.join(blueprint.path, 'spec.md');
  const original = fs.readFileSync(spec, 'utf8');
  // Ticks alone, while ready: not an edit.
  fs.writeFileSync(spec, original.replace('- [ ] Colours', '- [x] Colours'));
  assert.equal(b.h.runner.listBlueprints().blueprints[0].editedByHand, undefined);
  fs.writeFileSync(spec, original);
  // Update the spec sent: the agent rewriting it isn't flagged before it says it's written.
  b.session(thread.id).result();
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Dusk' } });
  b.h.runner.updateSpecBlueprint(blueprint.id);
  fs.writeFileSync(spec, original.replace('Dark.', 'Dark, at dusk.'));
  assert.equal(b.h.runner.listBlueprints().blueprints[0].editedByHand, undefined);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  // Building: the builder edits and ticks as it goes.
  b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' });
  fs.writeFileSync(spec, fs.readFileSync(spec, 'utf8').replace('- [ ] Colours', '- [x] Colours') + '\nA note the builder added.\n');
  assert.equal(b.h.runner.listBlueprints().blueprints[0].editedByHand, undefined);
});

test('an answer changed after the spec and then changed back leaves it ready', () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Dusk' } });
  assert.deepEqual([b.h.runner.get(thread.id).blueprint!.status, b.h.runner.get(thread.id).blueprint!.specStale], ['drafting', true]);
  const back = b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } }).blueprint;
  assert.deepEqual([back.status, back.specStale], ['ready', undefined]);
  assert.ok(b.h.runner.startBlueprint({ id: blueprint.id, mode: 'thread' }).threadId, 'and it can be built');
});

test('Continue sent again with the same note and nothing changed sends nothing more', () => {
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const s = b.session(thread.id);
  s.result();
  const answers = { 'r1.q3': { value: 'Night' } };
  const first = b.h.runner.continueBlueprint(blueprint.id, 'r1', answers, 'Keep it small.', true);
  const count = s.sent.length;
  const again = b.h.runner.continueBlueprint(blueprint.id, 'r1', answers, 'Keep it small.', true);
  assert.equal(again.turnId, first.turnId);
  assert.equal(s.sent.length, count, 'no second message');
  assert.equal(b.events(thread.id).filter((e) => e.type === 'blueprint.answered').length, 1);
  // A new note is new: it goes.
  s.result();
  const third = b.h.runner.continueBlueprint(blueprint.id, 'r1', answers, 'One more thing.');
  assert.notEqual(third.turnId, first.turnId);
  assert.match(s.sent.at(-1)!.text, /Note: One more thing\./);
});

test("a blueprint's children carry kind and parentThreadId to the phone and other Macs, behind the backend's version", async () => {
  const { toThreadDoc, forBackend, BLUEPRINT_KIND_API_VERSION } = await import('../../src/sync.ts');
  const { toIndexRow } = await import('../../src/thread-index.ts');
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const side = b.h.runner.get(b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId);
  const doc = toThreadDoc(side, 'runner-1', Date.now());
  assert.deepEqual([doc.kind, doc.parentThreadId], ['sideChat', thread.id]);
  assert.deepEqual([forBackend(doc, BLUEPRINT_KIND_API_VERSION, Date.now()).kind, forBackend(doc, BLUEPRINT_KIND_API_VERSION - 1, Date.now()).kind], ['sideChat', undefined]);
  assert.equal(forBackend(doc, BLUEPRINT_KIND_API_VERSION - 1, Date.now()).parentThreadId, undefined);
  const row = toIndexRow(side);
  assert.deepEqual([row.kind, row.parentThreadId], ['sideChat', thread.id]);
  assert.equal(toIndexRow(side, true, true, true, false).kind, undefined);
  assert.equal(toIndexRow(b.h.runner.get(thread.id)).kind, 'blueprint');
  assert.equal(doc.needsYou, false);
});

test("a check made after the blueprint's thread is gone is still its child", () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  b.h.runner.delete(thread.id);
  const check = b.h.runner.get(b.h.runner.checkBlueprint(blueprint.id).threadId);
  assert.deepEqual([check.kind, check.parentThreadId], ['check', thread.id]);
});

test('delete takes only the blueprint\'s own files, and refuses a folder with anything else', () => {
  const b = blueprintSetup();
  // A dir setting that points at real code: packages/app has a spec.md.
  b.projects.update(b.project.id, { blueprints: { dir: 'packages' } });
  const app = path.join(b.repo, 'packages/app');
  b.writeSpec(app, '# App\n');
  fs.writeFileSync(path.join(app, 'index.ts'), 'export {}\n');
  const found = b.h.runner.listBlueprints().blueprints.find((x) => x.slug === 'app')!;
  assert.equal(code(() => b.h.runner.deleteBlueprint(found.id)), ErrorCode.busy);
  assert.match((() => { try { b.h.runner.deleteBlueprint(found.id); } catch (e) { return (e as Error).message; } return ''; })(), /has files a blueprint doesn't make \(index\.ts\)/);
  assert.ok(fs.existsSync(path.join(app, 'spec.md')) && fs.existsSync(path.join(app, 'index.ts')), 'nothing removed');
  // Its own files only: removed, folder and all.
  fs.rmSync(path.join(app, 'index.ts'));
  fs.mkdirSync(path.join(app, 'attachments'));
  fs.writeFileSync(path.join(app, 'attachments/shot.png'), 'png');
  b.h.runner.deleteBlueprint(found.id);
  assert.ok(!fs.existsSync(app));
  assert.ok(fs.existsSync(path.join(b.repo, 'packages')));
});

test('changedAt means changed since last sent, and the round carries what was sent', () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const s = b.session(thread.id);
  s.result();
  let r = b.h.runner.get(thread.id).blueprint!.rounds[0];
  assert.equal(r.sent, undefined, 'nothing sent yet');
  b.h.runner.continueBlueprint(blueprint.id, 'r1', { 'r1.q3': { value: 'Night' } });
  r = b.h.runner.get(thread.id).blueprint!.rounds[0];
  assert.deepEqual(r.sent, { 'r1.q3': { value: 'Night' } });
  // A change, autosaved: changedAt, and sent still says what the agent has.
  s.result();
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Dusk' } });
  r = b.h.runner.get(thread.id).blueprint!.rounds[0];
  assert.ok(r.answers['r1.q3'].changedAt);
  assert.deepEqual(r.sent, { 'r1.q3': { value: 'Night' } }, 'drafts are not in sent');
  // Sent: no answer is changed any more, and sent moves.
  b.h.runner.continueBlueprint(blueprint.id, 'r1', undefined);
  r = b.h.runner.get(thread.id).blueprint!.rounds[0];
  assert.deepEqual(r.answers['r1.q3'], { value: 'Dusk' });
  assert.deepEqual(r.sent, { 'r1.q3': { value: 'Dusk' } });
  // Likewise through Update the spec.
  b.writeSpec(blueprint.path);
  b.h.runner.blueprintWritten(thread.id, { title: 'Dark mode', steps: STEPS });
  s.result();
  b.h.runner.saveBlueprintDraft(blueprint.id, 'r1', { 'r1.q3': { value: 'Dawn' } });
  assert.ok(b.h.runner.get(thread.id).blueprint!.rounds[0].answers['r1.q3'].changedAt);
  b.h.runner.updateSpecBlueprint(blueprint.id);
  r = b.h.runner.get(thread.id).blueprint!.rounds[0];
  assert.deepEqual([r.answers['r1.q3'], r.sent], [{ value: 'Dawn' }, { 'r1.q3': { value: 'Dawn' } }]);
  assert.equal(JSON.parse(fs.readFileSync(path.join(b.h.home, 'blueprints.json'), 'utf8')).blueprints[0].rounds[0].answers['r1.q3'].changedAt, undefined, 'saved that way');
});

test("the backend's validators take every field a blueprint child's rows carry, from the version that sends them", async () => {
  const { toThreadDoc, BLUEPRINT_KIND_API_VERSION, BACKEND_API_VERSION } = await import('../../src/sync.ts');
  const { toIndexRow } = await import('../../src/thread-index.ts');
  const convex = path.join(import.meta.dirname, '..', '..', '..', 'convex');
  const schema = fs.readFileSync(path.join(convex, 'schema.ts'), 'utf8');
  const sync = fs.readFileSync(path.join(convex, 'sync.ts'), 'utf8');
  // The fields a validator block declares, by its first lines.
  const fields = (src: string, start: string, end: string) => {
    const from = src.indexOf(start);
    assert.ok(from >= 0, start);
    return new Set([...src.slice(from, src.indexOf(end, from)).matchAll(/^\s+(\w+): v\./gm)].map((m) => m[1]));
  };
  const threadFields = fields(schema, 'export const threadFields = {', '\n};');
  const indexTable = fields(schema, 'threadIndex: defineTable({', '\n  })');
  const indexDoc = fields(sync, 'const indexDoc = v.object({', '\n});');
  const b = blueprintSetup();
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const side = b.h.runner.get(b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId);
  for (const k of Object.keys(toThreadDoc(side, 'runner-1', Date.now())).filter((k) => !['threadId', 'runnerId', 'view'].includes(k))) assert.ok(threadFields.has(k), `threadFields has ${k}`);
  for (const k of Object.keys(toIndexRow(side))) {
    assert.ok(indexDoc.has(k), `sync.ts indexDoc has ${k}`);
    assert.ok(indexTable.has(k), `the threadIndex table has ${k}`);
  }
  assert.ok(threadFields.has('kind') && threadFields.has('parentThreadId'));
  assert.ok(BLUEPRINT_KIND_API_VERSION <= BACKEND_API_VERSION, 'the backend this runner is built for takes them');
});

test("a side chat started once the spec is written names the spec's path", () => {
  const b = blueprintSetup();
  b.projects.update(b.project.id, { blueprints: { check: false } });
  const { blueprint, thread } = b.create();
  b.h.runner.askRound(thread.id, ROUND);
  const before = b.session(b.h.runner.blueprintSideChat(blueprint.id, 'r1.q1').threadId).sent[0].text;
  assert.doesNotMatch(before, /spec\.md/, 'no spec yet');
  b.writeSpec(blueprint.path);
  const after = b.session(b.h.runner.blueprintSideChat(blueprint.id, 'r1.q2').threadId).sent[0].text;
  assert.ok(after.includes(`The spec as written so far is ${path.join(blueprint.path, 'spec.md')}.`), after);
});

test('a blueprint made from a long description gets a slug cut at a word', () => {
  const b = blueprintSetup();
  const { blueprint } = b.create('Add snooze presets per project each with its own times, shown in the snooze menu');
  assert.equal(blueprint.slug, 'add-snooze-presets-per-project');
});
