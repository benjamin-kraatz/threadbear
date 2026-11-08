// Blueprints' plain parts (src/blueprints.ts): the state file, the scan of
// project folders, slugs, rounds and answers checked, and the messages the
// runner writes (docs/protocol.md, "Blueprints").
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tmpDir } from '../helpers/fakes.ts';
import {
  BlueprintStore,
  answersMessage,
  blueprintInstructions,
  blueprintsHome,
  buildMessage,
  changesMessage,
  checkAnswers,
  checkDir,
  checkRound,
  compactRounds,
  editedMessage,
  findingsRound,
  foundId,
  mergeAnswers,
  parseSpec,
  publicBlueprint,
  scanBlueprints,
  sideChatMessage,
  slugify,
  templateText,
  uniqueSlug,
  unansweredNeedsYou,
  type BlueprintRecord,
} from '../../src/blueprints.ts';
import { diffLines } from '../../src/diff.ts';

const ROUND = {
  title: 'Scope',
  summary: 'A dark mode for the app.',
  questions: [
    { id: 'q1', text: 'Which screens?', kind: 'multi', options: [{ id: 'a', label: 'Settings' }, { id: 'b', label: 'Sidebar' }] },
    { id: 'q2', text: 'Follow the system?', options: [{ id: 'yes', label: 'Yes' }, { id: 'no', label: 'No' }], recommended: { option: 'yes', why: 'Most apps do' } },
    { id: 'q3', text: 'What should it be called?', kind: 'text', youDecide: false },
  ],
  assumptions: [{ text: 'Colours come from the asset catalog', why: 'They all do today' }],
};

function record(extra: Partial<BlueprintRecord> = {}): BlueprintRecord {
  return { id: '11111111-2222-4333-8444-555555555555', projectId: 'p_1', folder: '/repo', path: '/repo/.threadbear/blueprints/dark-mode', slug: 'dark-mode', title: 'Dark mode', status: 'drafting', rounds: [], steps: [], builds: [], sideChats: {}, description: 'Add a dark mode', createdAt: 't', updatedAt: 't', ...extra };
}

test('the state file keeps blueprints and their snapshot across a fresh store', () => {
  const home = tmpDir();
  const store = new BlueprintStore(home);
  store.put(record());
  store.writeSnapshot(record().id, '# Dark mode\n');
  const again = new BlueprintStore(home);
  assert.equal(again.get(record().id)?.title, 'Dark mode');
  assert.equal(again.readSnapshot(record().id), '# Dark mode\n');
  assert.ok(fs.existsSync(path.join(home, 'blueprints.json')));
  assert.equal(again.snapshotPath(record().id), path.join(home, 'blueprints', record().id, 'spec.snapshot.md'));
  again.remove(record().id);
  assert.equal(new BlueprintStore(home).get(record().id), undefined);
  assert.ok(!fs.existsSync(path.join(home, 'blueprints', record().id)), 'the snapshot goes with it');
});

test('slugs come from the title, and a taken one gets -2, -3', () => {
  assert.equal(slugify('Add a dark mode to the app!'), 'add-a-dark-mode-to-the-app');
  assert.equal(slugify('  '), 'blueprint');
  assert.ok(slugify('word '.repeat(40)).length <= 40);
  const taken = new Set(['dark-mode', 'dark-mode-2']);
  assert.equal(uniqueSlug('dark-mode', (s) => taken.has(s)), 'dark-mode-3');
  assert.equal(uniqueSlug('other', (s) => taken.has(s)), 'other');
});

test("a project's blueprints go in its chosen folder, else its first, under a dir that stays inside", () => {
  assert.deepEqual(blueprintsHome({ title: 'A', folders: ['/a', '/b'] }), { folder: '/a', dir: '.threadbear/blueprints' });
  assert.deepEqual(blueprintsHome({ title: 'A', folders: ['/a', '/b'], blueprints: { folder: '/b', dir: 'docs/plans/' } }), { folder: '/b', dir: 'docs/plans' });
  assert.deepEqual(blueprintsHome({ title: 'A', folders: ['/a'], blueprints: { folder: '/gone' } }).folder, '/a');
  assert.throws(() => blueprintsHome({ title: 'A', folders: [] }), /no folder/);
  for (const bad of ['../up', '/abs', '.', 'a/../../b']) assert.throws(() => checkDir(bad), /inside the project folder/, bad);
});

test('the scan finds blueprint folders with a spec.md, and a found one keeps its id', () => {
  const repo = tmpDir();
  const base = path.join(repo, '.threadbear/blueprints');
  fs.mkdirSync(path.join(base, 'one'), { recursive: true });
  fs.writeFileSync(path.join(base, 'one', 'spec.md'), '# One\n');
  fs.mkdirSync(path.join(base, 'no-spec'), { recursive: true });
  fs.writeFileSync(path.join(base, 'template.md'), 'Always settle telemetry.');
  assert.deepEqual(scanBlueprints(repo, '.threadbear/blueprints'), [{ slug: 'one', path: path.join(base, 'one') }]);
  assert.deepEqual(scanBlueprints(tmpDir(), '.threadbear/blueprints'), []);
  assert.equal(foundId(path.join(base, 'one')), foundId(path.join(base, 'one')));
  assert.match(foundId(path.join(base, 'one')), /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/);
});

test("a spec's title and Steps checklist are read from it", () => {
  const spec = '# Dark mode\n\n## Overview\n- [ ] not a step\n\n## Steps\n- [ ] Add colours\n  files: a.swift\n- [x] Settings toggle\n\n## Open points\n- [ ] not one either\n';
  const { title, steps } = parseSpec(spec);
  assert.equal(title, 'Dark mode');
  assert.deepEqual(steps.map((s) => [s.id, s.title, Boolean(s.done)]), [['s1', 'Add colours', false], ['s2', 'Settings toggle', true]]);
});

test("templates are ~'s and the project folder's, in that order", () => {
  const home = tmpDir();
  const repo = tmpDir();
  assert.equal(templateText(repo, home), '');
  fs.mkdirSync(path.join(home, '.threadbear/blueprints'), { recursive: true });
  fs.writeFileSync(path.join(home, '.threadbear/blueprints/template.md'), 'Always settle telemetry.\n');
  fs.mkdirSync(path.join(repo, '.threadbear/blueprints'), { recursive: true });
  fs.writeFileSync(path.join(repo, '.threadbear/blueprints/template.md'), 'Say which docs change.');
  assert.equal(templateText(repo, home), 'Always settle telemetry.\n\nSay which docs change.');
  const brief = blueprintInstructions(record(), templateText(repo, home));
  assert.match(brief, /Say which docs change\./);
  assert.match(brief, /\/repo\/\.threadbear\/blueprints\/dark-mode/);
  assert.match(brief, /too_small/);
  assert.match(brief, /## Overview, ## Decisions, ## Assumptions, ## Steps/);
  assert.doesNotMatch(brief, /—/, 'no em dashes');
});

test('a round is checked: question ids made unique, options and recommendations must fit', () => {
  const r = checkRound(ROUND, 'r1', '/repo');
  assert.deepEqual(r.questions.map((q) => q.id), ['r1.q1', 'r1.q2', 'r1.q3']);
  assert.equal(r.questions[1].kind, 'single');
  assert.equal(r.questions[2].youDecide, false);
  assert.equal(r.assumptions[0].id, 'r1.a1');
  const nine = { title: 'Too many', questions: Array.from({ length: 9 }, (_, i) => ({ id: `q${i}`, text: 'x', kind: 'text' })) };
  assert.throws(() => checkRound(nine, 'r1', '/'), /at most 8/);
  assert.throws(() => checkRound({ title: 'Dup', questions: [{ id: 'q', text: 'x', options: [{ id: 'a', label: 'A' }, { id: 'a', label: 'B' }] }] }, 'r1', '/'), /two options with the id a/);
  assert.throws(() => checkRound({ title: 'Rec', questions: [{ id: 'q', text: 'x', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], recommended: { option: 'c', why: 'w' } }] }, 'r1', '/'), /names no option: c/);
  assert.throws(() => checkRound({ title: 'Same', questions: [{ id: 'q', text: 'x', kind: 'text' }, { id: 'q', text: 'y', kind: 'text' }] }, 'r1', '/'), /Two questions have the id q/);
});

test('answers are checked against their question, and needs-you ones must be there', () => {
  const r = checkRound(ROUND, 'r1', '/repo');
  assert.deepEqual(checkAnswers(r, { 'r1.q1': { value: ['a', 'b'] }, 'r1.q2': { youDecide: true } }), { 'r1.q1': { value: ['a', 'b'] }, 'r1.q2': { youDecide: true } });
  assert.throws(() => checkAnswers(r, { 'r1.q1': { value: ['z'] } }), /names no option: z/);
  assert.throws(() => checkAnswers(r, { 'r1.q3': { youDecide: true } }), /needs the user's own answer/);
  assert.throws(() => checkAnswers(r, { nope: { value: 'x' } }), /no question nope/);
  assert.deepEqual(unansweredNeedsYou(r).map((q) => q.id), ['r1.q3']);
  r.answers = { 'r1.q3': { value: 'Night' } };
  assert.deepEqual(unansweredNeedsYou(r), []);
});

test("a round's answers read as text: you decide, recommendations, unanswered, asks and the note", () => {
  const r = checkRound(ROUND, 'r1', '/repo');
  r.answers = { 'r1.q1': { value: ['a'] }, 'r1.q2': { youDecide: true }, 'r1.q3': { value: 'Night', fromSideChat: true } };
  const text = answersMessage(r, { note: 'Keep it small.', asks: r.assumptions });
  assert.match(text, /My answers to "Scope"/);
  assert.match(text, /1\. Which screens\?\n {3}Settings/);
  assert.match(text, /you decide, so your recommendation: Yes/);
  assert.match(text, /Night \(worked out in a side chat\)/);
  assert.match(text, /Ask me instead.*\n- Colours come from the asset catalog/);
  assert.match(text, /Note: Keep it small\./);
  r.answers = { 'r1.q3': { value: 'Night' } };
  assert.match(answersMessage(r), /1\. Which screens\?\n {3}unanswered/);
  assert.match(answersMessage(r, { writeNow: true }), /Write the spec now with what you have/);
});

test('a round sent before sends only its changes, as "was A, now B"', () => {
  const r = checkRound(ROUND, 'r1', '/repo');
  r.answers = { 'r1.q2': { value: 'yes' }, 'r1.q3': { value: 'Night' } };
  r.sentAt = 't0';
  r.sent = structuredClone(r.answers);
  assert.equal(changesMessage([r]), undefined, 'nothing changed');
  r.answers = mergeAnswers(r, { 'r1.q2': { value: 'no' }, 'r1.q3': { value: 'Night' } }, 't1');
  assert.equal(r.answers['r1.q2'].changedAt, 't1');
  assert.equal(r.answers['r1.q3'].changedAt, undefined);
  const text = changesMessage([r])!;
  assert.match(text, /Question 2 \("Follow the system\?"\) was Yes, now No\./);
  assert.doesNotMatch(text, /Question 3/);
  assert.match(changesMessage([r], { updateSpec: true })!, /Update the spec and answers.md/);
});

test("the check's findings become a round, a bare one a text question", () => {
  const r = findingsRound([{ text: 'Step 2 misses the tests.' }, { text: 'The sidebar has its own colours.', question: { id: 'x', text: 'Which wins?', options: [{ id: 'a', label: 'Sidebar' }, { id: 'b', label: 'App' }] } }], 'r3', 'Check: Dark mode', '/repo');
  assert.equal(r.kind, 'check');
  assert.match(r.title, /Check: Dark mode/);
  assert.equal(r.questions[0].kind, 'text');
  assert.match(r.questions[0].text, /Step 2 misses the tests\.\n\nWhat should the spec do about this\?/);
  assert.equal(r.questions[1].id, 'r3.x');
  assert.match(r.questions[1].text, /own colours\.\n\nWhich wins\?/);
  r.answers = { 'r3.f1': { value: 'Add them' } };
  assert.match(answersMessage(r), /Update the spec with these/);
});

test('side chats get the description, the rounds so far and the one question', () => {
  const r = checkRound(ROUND, 'r1', '/repo');
  r.answers = { 'r1.q1': { value: ['a'] } };
  const bp = record({ rounds: [r] });
  assert.match(compactRounds(bp.rounds), /- Which screens\?: Settings\n- Follow the system\?: unanswered/);
  const text = sideChatMessage(bp, r.questions[1]);
  assert.match(text, /The feature:\nAdd a dark mode/);
  assert.match(text, /propose_answer/);
  assert.match(text, /- yes: Yes\n- no: No/);
  assert.match(text, /recommends Yes: Most apps do/);
});

test('the build message points at the spec by absolute path, and subagents add a paragraph', () => {
  const one = buildMessage(record(), 'thread');
  assert.match(one, /^Build the blueprint at \/repo\/\.threadbear\/blueprints\/dark-mode\/spec\.md\. Read answers\.md beside it/);
  assert.match(one, /update_blueprint/);
  const many = buildMessage(record(), 'subagents');
  assert.ok(many.startsWith(one));
  assert.match(many, /subagents/);
});

test('edited by hand sends the hunks and asks for answers.md to be brought into line', () => {
  const text = editedMessage(diffLines('# A\nold\n', '# A\nnew\n'));
  assert.match(text, /-old\n\+new/);
  assert.match(text, /Bring answers.md into line, or ask me\./);
});

test('the public blueprint drops internal fields and adds the cost', () => {
  const r = { ...checkRound(ROUND, 'r1', '/repo'), sent: { 'r1.q3': { value: 'Night' } }, askSent: ['r1.a1'], turnId: 't', lastNote: 'n', lastWriteNow: true as const };
  const out = publicBlueprint(record({ rounds: [r], threadId: 'th', children: ['c'], proposals: {} }), 0.1234567, false);
  assert.equal(out.costUsd, 0.123457);
  assert.equal(out.threadId, undefined, 'its thread is gone');
  assert.ok(!('description' in out) && !('children' in out) && !('proposals' in out));
  assert.ok(!('turnId' in out.rounds[0]) && !('askSent' in out.rounds[0]) && !('lastNote' in out.rounds[0]) && !('lastWriteNow' in out.rounds[0]));
  assert.deepEqual(out.rounds[0].sent, { 'r1.q3': { value: 'Night' } }, 'the answers as last sent stay, for "was A, now B"');
});

test('tb blueprint finds blueprints and questions by short names, and reads answers typed in', async () => {
  const { pickBlueprint, pickQuestion, parseAnswer, blueprintText, blueprintLine } = await import('../../src/tb-blueprint.ts');
  const r = checkRound(ROUND, 'r1', '/repo');
  r.answers = { 'r1.q1': { value: ['a'] } };
  const bp = publicBlueprint(record({ rounds: [r], threadId: 'th' }), 0.5, true);
  const other = { ...bp, id: '99999999-0000-4000-8000-000000000000', slug: 'other' };
  assert.equal(pickBlueprint([bp, other], '1111').id, bp.id);
  assert.equal(pickBlueprint([bp, other], 'other').id, other.id);
  assert.throws(() => pickBlueprint([bp, other], 'nope'), /No blueprint nope/);
  assert.equal(pickQuestion(bp, '1', 'q2').question.id, 'r1.q2');
  assert.equal(pickQuestion(bp, 'r1', '3').question.id, 'r1.q3');
  assert.throws(() => pickQuestion(bp, 'r2', 'q1'), /no round r2/);
  assert.deepEqual(parseAnswer(r.questions[0], 'a, b'), { value: ['a', 'b'] });
  assert.deepEqual(parseAnswer(r.questions[1], 'You decide'), { youDecide: true });
  assert.deepEqual(parseAnswer(r.questions[2], 'Night mode'), { value: 'Night mode' });
  const text = blueprintText(bp);
  assert.match(text, /r1 {2}Scope \(open\)/);
  assert.match(text, /1\. \[q1\] Which screens\?\n {7}a: Settings/);
  assert.match(text, /> Settings/);
  assert.match(text, /3\. \[q3\] What should it be called\? \(needs you\)/);
  assert.match(blueprintLine(bp), /^11111111 {2}Dark mode {2}\[drafting, \$0\.50\]/);
});

test('two runners on one data dir (a handover) never wipe each other: each write changes only its own record, read fresh', async () => {
  const { BlueprintStore: Store } = await import('../../src/blueprints.ts');
  const home = tmpDir();
  const a = new Store(home);
  const b = new Store(home);
  a.put(record());
  b.put(record({ id: '22222222-2222-4333-8444-555555555555', slug: 'other', path: '/repo/x/other', title: 'Other' }));
  // b read the file before a's next change; its own next write keeps it.
  const mine = b.get(record().id)!;
  a.put({ ...a.get(record().id)!, title: 'Dark mode, renamed' });
  b.put({ ...b.get('22222222-2222-4333-8444-555555555555')!, status: 'waiting' });
  assert.equal(new Store(home).get(record().id)?.title, 'Dark mode, renamed');
  assert.equal(new Store(home).get('22222222-2222-4333-8444-555555555555')?.status, 'waiting');
  assert.equal(b.get(record().id)?.title, 'Dark mode, renamed', 'a read after the other wrote sees it');
  assert.equal(mine.title, 'Dark mode', 'an object read before is only stale, not written back');
  assert.ok(!fs.existsSync(path.join(home, 'blueprints.json.lock')), 'the lock is let go');
  // A lock left by a process that died holding it is taken after a while.
  fs.writeFileSync(path.join(home, 'blueprints.json.lock'), '1');
  const old = new Date(Date.now() - 60_000);
  fs.utimesSync(path.join(home, 'blueprints.json.lock'), old, old);
  a.remove('22222222-2222-4333-8444-555555555555');
  assert.equal(new Store(home).all().length, 1);
});

test("ticking the Steps checklist isn't an edit, and moot marks an earlier question by its id", async () => {
  const { withoutTicks, applyMoot } = await import('../../src/blueprints.ts');
  assert.equal(withoutTicks('## Steps\n- [x] One\n  - [X] Sub\n- [ ] Two\n'), withoutTicks('## Steps\n- [ ] One\n  - [ ] Sub\n- [ ] Two\n'));
  assert.notEqual(withoutTicks('- [x] One\n'), withoutTicks('- [x] One changed\n'));
  const r1 = checkRound(ROUND, 'r1', '/repo');
  const r2 = checkRound(ROUND, 'r2', '/repo');
  assert.equal(applyMoot([r1], [{ id: 'q2', why: 'The system decides.' }]), 1);
  assert.equal(r1.questions[1].moot, 'The system decides.');
  assert.throws(() => applyMoot([r1, r2], [{ id: 'q1', why: 'x' }]), /more than one round; give it as r1\.q1 or r2\.q1/);
  assert.equal(applyMoot([r1, r2], [{ id: 'r2.q1', why: 'x' }]), 1);
  assert.throws(() => applyMoot([r1], [{ id: 'nope', why: 'x' }]), /no earlier question nope/);
  r1.answers = {};
  r1.questions[2].moot = 'Named elsewhere';
  assert.deepEqual(unansweredNeedsYou(r1), [], 'a moot needs-you question needs nothing');
  assert.doesNotMatch(answersMessage(r1), /What should it be called/);
});

test('a slug ends on a whole word, never a stop word, within about 40 characters', () => {
  assert.equal(slugify('Add snooze presets per project, each with its own times'), 'add-snooze-presets-per-project');
  assert.equal(slugify('Add snooze presets per project each'), 'add-snooze-presets-per-project');
  assert.equal(slugify('Rename the save button to keep the label and'), 'rename-the-save-button-to-keep-the-label');
  for (const s of [slugify('A really very extraordinarily long description of the feature we want'), slugify('Make the sidebar and the composer share one font size setting')]) {
    assert.ok(s.length <= 40, s);
    assert.ok(!/-(a|the|each|and|of|to|for|with)$/.test(s), s);
  }
  assert.equal(slugify('The'), 'the', 'a lone stop word is kept rather than nothing');
  assert.equal(slugify('First line\nSecond line'), 'first-line');
});

test("a check round's answers name each finding by its first sentence", async () => {
  const { firstSentence } = await import('../../src/blueprints.ts');
  assert.equal(firstSentence('Step 2 has no tests. It touches the sidebar, which has none either.'), 'Step 2 has no tests.');
  const long = 'The spec says the presets live in the project settings but ' + 'the code keeps settings per thread '.repeat(6);
  const cut = firstSentence(long);
  assert.ok(cut.length <= 120 && cut.endsWith('…'), cut);
  assert.ok(!/\s…$/.test(cut));
  const r = findingsRound([{ text: 'Step 2 has no tests. It touches the sidebar, which has none either, so a builder would have to guess what to cover.' }], 'r3', 'Check', '/repo');
  r.answers = { 'r3.f1': { value: 'Add a UI test.' } };
  const text = answersMessage(r);
  assert.match(text, /1\. Step 2 has no tests\.\n {3}Add a UI test\./);
  assert.doesNotMatch(text, /which has none either/);
  assert.doesNotMatch(text, /What should the spec do about this/);
});

test('a choice question may take a written Other, which the agent reads as "Other: ..."', () => {
  const r = checkRound({ title: 'T', questions: [
    { id: 'one', text: 'Which?', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], other: true, youDecide: false },
    { id: 'many', text: 'Which ones?', kind: 'multi', options: [{ id: 'a', label: 'A' }, { id: 'b', label: 'B' }], other: true },
    { id: 'plain', text: 'Name?', kind: 'text', other: true },
  ] }, 'r1', '/repo');
  assert.deepEqual(r.questions.map((q) => q.other), [true, true, undefined], 'only single and multi');
  const a = checkAnswers(r, { 'r1.one': { other: 'Something in between' }, 'r1.many': { value: ['a'], other: 'and C' } });
  assert.deepEqual(a, { 'r1.one': { other: 'Something in between' }, 'r1.many': { value: ['a'], other: 'and C' } });
  assert.throws(() => checkAnswers(r, { 'r1.plain': { value: 'x', other: 'y' } }), /no Other to write in/);
  r.answers = a;
  assert.deepEqual(unansweredNeedsYou(r), [], "a written Other answers a needs-you question");
  const text = answersMessage(r);
  assert.match(text, /Which\?\n {3}Other: Something in between/);
  assert.match(text, /Which ones\?\n {3}A; Other: and C/);
  // Changing only the Other is a change.
  r.sentAt = 't';
  r.sent = structuredClone(r.answers);
  r.answers = mergeAnswers(r, { ...r.answers, 'r1.one': { other: 'Neither' } }, 't2');
  assert.match(changesMessage([r])!, /was Other: Something in between, now Other: Neither/);
});

test('tb blueprint answer echoes the question by its first sentence', async () => {
  const { blueprintCommand } = await import('../../src/tb-blueprint.ts');
  const r = checkRound({ title: 'T', questions: [{ id: 'q1', text: 'Where should the presets live? The project page has room, and so does the snooze menu itself, though it is already long.', kind: 'text' }] }, 'r1', '/repo');
  const bp = publicBlueprint(record({ rounds: [r], threadId: 'th' }), 0, true);
  const client = {
    call: async (method: string, params: Record<string, unknown>) => {
      if (method === 'blueprints.list') return { blueprints: [bp] };
      const answers = params.answers as Record<string, unknown>;
      return { blueprint: { ...bp, rounds: [{ ...bp.rounds[0], answers }] } };
    },
  };
  const printed: string[] = [];
  const log = console.log;
  console.log = (s: string) => printed.push(s);
  try {
    await blueprintCommand(client as never, ['answer', '1111', '1', 'q1', 'On', 'the', 'project', 'page'], {}, async (q) => q);
  } finally {
    console.log = log;
  }
  assert.deepEqual(printed, ['Where should the presets live?: On the project page']);
});

test('the instructions keep most questions open: needs-you only for taste or scope', () => {
  const brief = blueprintInstructions(record(), '');
  assert.match(brief, /leave it open so the user can say "you decide"/);
  assert.match(brief, /youDecide false is only for taste or scope the user alone can settle; most stay open/);
});
