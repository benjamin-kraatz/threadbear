// tb blueprint (docs/protocol.md, "Blueprints"): list, make, read, answer
// and start blueprints from a terminal, so a form can be filled without
// the app.
import type { RunnerClient } from './client.ts';
import type { Blueprint, BlueprintAnswer, BlueprintQuestion, BlueprintRound } from './protocol.ts';
import { answerText, firstSentence } from './blueprints.ts';

type Flags = Record<string, string | boolean | string[] | undefined>;

export const BLUEPRINT_HELP = `  tb blueprint list [--project P] [--json]    the blueprints, by project, with their state
  tb blueprint new --project P "text" [--account ID] [--model M]
                                  plans a feature: a blueprint thread in the project's folder
  tb blueprint show <id> [--json] its rounds, questions and answers
  tb blueprint answer <id> <round> <question> <value>
                                  saves a draft answer: an option id (several with commas),
                                  text, a number, paths, or "you decide"
  tb blueprint continue <id> [--write-now] [--text NOTE]
                                  sends the open round's answers (with --write-now: write the
                                  spec with what it has)
  tb blueprint start <id> [--subagents]   a thread that builds it (or works it with subagents)
  tb blueprint check <id>         checks the spec against the code again
  tb blueprint delete <id>        removes its folder from the repo and archives its threads`;

// A blueprint by id, unique id prefix or slug.
export function pickBlueprint(all: Blueprint[], q: string | undefined): Blueprint {
  if (!q) throw new Error('Name a blueprint: its id, an id prefix or its slug. tb blueprint list shows them.');
  const hits = all.filter((b) => b.id === q);
  const byPrefix = hits.length ? hits : all.filter((b) => b.id.startsWith(q));
  const found = byPrefix.length ? byPrefix : all.filter((b) => b.slug === q);
  if (found.length === 1) return found[0];
  throw new Error(found.length ? `${q} could be ${found.map((b) => b.slug).join(' or ')}. Give more of its id.` : `No blueprint ${q}. tb blueprint list shows them.`);
}

// A round by id ("r2") or number ("2"); a question by its id, the part
// after the round's ("q1"), or its number in the round.
export function pickQuestion(bp: Blueprint, roundQ: string, questionQ: string): { round: BlueprintRound; question: BlueprintQuestion } {
  const round = bp.rounds.find((r) => r.id === roundQ) ?? bp.rounds.find((r) => r.id === `r${roundQ}`);
  if (!round) throw new Error(`${bp.title} has no round ${roundQ}. Its rounds: ${bp.rounds.map((r) => r.id).join(', ') || 'none yet'}.`);
  const question =
    round.questions.find((q) => q.id === questionQ) ??
    round.questions.find((q) => q.id === `${round.id}.${questionQ}`) ??
    (/^\d+$/.test(questionQ) ? round.questions[Number(questionQ) - 1] : undefined);
  if (!question) throw new Error(`${round.title} has no question ${questionQ}.`);
  return { round, question };
}

// What `tb blueprint answer` was given, as an answer to the question.
export function parseAnswer(q: BlueprintQuestion, value: string): BlueprintAnswer {
  const v = value.trim();
  if (/^you decide$/i.test(v)) return { youDecide: true };
  const list = () => v.split(',').map((s) => s.trim()).filter(Boolean);
  switch (q.kind) {
    case 'multi':
    case 'files':
    case 'upload':
      return { value: list() };
    case 'number': {
      const n = Number(v);
      if (!Number.isFinite(n)) throw new Error(`${q.text} takes a number.`);
      return { value: n };
    }
    default:
      return { value };
  }
}

export function blueprintLine(b: Blueprint): string {
  const done = b.steps.filter((s) => s.done).length;
  const state =
    b.status === 'waiting' ? `${b.rounds.at(-1)?.title ?? 'a round'} waiting` : b.status === 'building' && b.steps.length ? `building, step ${done} of ${b.steps.length}` : b.status;
  const flags = [state, b.editedByHand ? 'edited by hand' : '', b.specStale ? 'spec older than answers' : '', b.threadId ? '' : 'found', `$${b.costUsd.toFixed(2)}`].filter(Boolean).join(', ');
  return `${b.id.slice(0, 8)}  ${b.title}  [${flags}]  ${b.path}`;
}

export function blueprintText(b: Blueprint): string {
  const out = [`${b.title} (${b.status})`, b.path];
  if (b.tooSmall) out.push(`The agent says it's small enough for a normal thread: ${b.tooSmall.why}`);
  for (const r of b.rounds) {
    out.push('', `${r.id}  ${r.title}${r.kind === 'check' ? ' (the check)' : ''}${r.sentAt ? '' : ' (open)'}`);
    if (r.summary) out.push(`    ${r.summary}`);
    r.questions.forEach((q, i) => {
      const how = q.youDecide ? '' : ' (needs you)';
      out.push(`  ${i + 1}. [${q.id.slice(r.id.length + 1)}] ${q.text.split('\n').join('\n     ')}${how}`);
      for (const o of q.options ?? []) out.push(`       ${o.id}: ${o.label}${o.note ? ` (${o.note})` : ''}`);
      if (q.recommended) out.push(`       recommended: ${q.recommended.option ?? q.recommended.text} (${q.recommended.why})`);
      out.push(`     > ${answerText(q, r.answers[q.id])}`);
    });
    for (const a of r.assumptions) out.push(`  assumed: ${a.text} (${a.why})${r.askInstead?.includes(a.id) ? ', ask instead' : ''}`);
    if (r.note) out.push(`  note: ${r.note}`);
  }
  if (b.steps.length) {
    out.push('', 'Steps:');
    for (const s of b.steps) out.push(`  [${s.done ? 'x' : ' '}] ${s.id}  ${s.title}${s.done?.note ? `: ${s.done.note}` : ''}`);
  }
  return out.join('\n');
}

export async function blueprintCommand(client: RunnerClient, args: string[], f: Flags, projectId: (q: string) => Promise<string>): Promise<number> {
  const [action, ...rest] = args;
  const list = async (project?: string) => (await client.call<{ blueprints: Blueprint[] }>('blueprints.list', project ? { projectId: project } : {})).blueprints;
  switch (action ?? 'list') {
    case 'list': {
      const all = await list(typeof f.project === 'string' ? await projectId(f.project) : undefined);
      if (f.json) console.log(JSON.stringify(all, null, 2));
      else if (!all.length) console.log('No blueprints yet. tb blueprint new --project P "text" starts one.');
      else for (const b of all) console.log(blueprintLine(b));
      return 0;
    }
    case 'new': {
      if (typeof f.project !== 'string') throw new Error('tb blueprint new --project <project> "text"');
      const text = rest.join(' ').trim();
      if (!text) throw new Error('Describe the feature: tb blueprint new --project <project> "text"');
      const r = await client.call<{ blueprint: Blueprint; thread: { id: string } }>('blueprints.create', {
        projectId: await projectId(f.project),
        text,
        ...(typeof f.account === 'string' ? { accountId: f.account } : {}),
        ...(typeof f.model === 'string' ? { model: f.model } : {}),
      });
      console.log(`${r.blueprint.id}  thread ${r.thread.id}  ${r.blueprint.path}`);
      return 0;
    }
    case 'show': {
      const b = pickBlueprint(await list(), rest[0]);
      console.log(f.json ? JSON.stringify(b, null, 2) : blueprintText(b));
      return 0;
    }
    case 'answer': {
      const [id, roundQ, questionQ, ...words] = rest;
      if (!id || !roundQ || !questionQ || !words.length) throw new Error('tb blueprint answer <id> <round> <question> <value>');
      const b = pickBlueprint(await list(), id);
      const { round, question } = pickQuestion(b, roundQ, questionQ);
      const answers = { ...round.answers, [question.id]: parseAnswer(question, words.join(' ')) };
      const r = await client.call<{ blueprint: Blueprint }>('blueprints.saveDraft', { id: b.id, roundId: round.id, answers });
      const saved = r.blueprint.rounds.find((x) => x.id === round.id)?.answers[question.id];
      console.log(`${firstSentence(question.text)}: ${answerText(question, saved)}`);
      return 0;
    }
    case 'continue': {
      const b = pickBlueprint(await list(), rest[0]);
      const round = b.rounds.findLast((r) => !r.sentAt) ?? b.rounds.at(-1);
      if (!round) throw new Error(`${b.title} has no round yet.`);
      const r = await client.call<{ turnId?: string }>('blueprints.continue', {
        id: b.id,
        roundId: round.id,
        ...(typeof f.text === 'string' ? { note: f.text } : {}),
        ...(f['write-now'] ? { writeNow: true } : {}),
      });
      console.log(r.turnId ? `Sent ${round.title} (turn ${r.turnId}).` : 'Nothing new to send.');
      return 0;
    }
    case 'start': {
      const b = pickBlueprint(await list(), rest[0]);
      const r = await client.call<{ threadId: string }>('blueprints.start', { id: b.id, mode: f.subagents ? 'subagents' : 'thread' });
      console.log(r.threadId);
      return 0;
    }
    case 'check': {
      const b = pickBlueprint(await list(), rest[0]);
      const r = await client.call<{ threadId: string }>('blueprints.check', { id: b.id });
      console.log(r.threadId);
      return 0;
    }
    case 'delete': {
      const b = pickBlueprint(await list(), rest[0]);
      await client.call('blueprints.delete', { id: b.id });
      console.log(`Deleted ${b.title} (${b.path}).`);
      return 0;
    }
    default:
      throw new Error(`Unknown: tb blueprint ${action}. It's list, new, show, answer, continue, start, check or delete.`);
  }
}
