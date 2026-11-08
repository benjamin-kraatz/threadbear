// Blueprints (docs/protocol.md, "Blueprints"; docs/blueprints-design.md):
// a feature planned by answering rounds of questions, then a spec in the
// repo to build from. This file is the plain part: the state file, the
// scan of project folders, checking what agents and the app send, and the
// text of every message the runner writes. runner/blueprints.ts is where
// it meets threads.
//
// Nothing of the runner's goes in the repo: status, rounds, steps and the
// spec's snapshot are in the data dir (<home>/blueprints.json and
// <home>/blueprints/<id>/spec.snapshot.md). The agent writes spec.md and
// answers.md in the blueprint's folder; the runner only reads them, and
// removes the folder when the blueprint is deleted.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import type {
  Blueprint,
  BlueprintAnswer,
  BlueprintAnswerValue,
  BlueprintAssumption,
  BlueprintQuestion,
  BlueprintRound,
  BlueprintStep,
  Hunk,
} from './protocol.ts';
import { BLUEPRINT_QUESTION_KINDS, ErrorCode, RpcError } from './protocol.ts';
import { atomicWriteFileSync, readJsonSync } from './fsutil.ts';
import { FolderCache } from './folder-cache.ts';

export const DEFAULT_BLUEPRINT_DIR = '.threadbear/blueprints';
// Found the way patches are: in each project folder, and in ~ for every project.
export const TEMPLATE_FILE = path.join('.threadbear', 'blueprints', 'template.md');
export const MAX_QUESTIONS = 8;
export const MAX_OPTIONS = 12;
const TEXT_MAX = 4000;
const SHORT_MAX = 300;
const SLUG_MAX = 40;

// What the state file keeps of a round: the round, plus what was last sent
// of it (so a later Continue sends only the changes) and the assumptions
// already asked about.
export type RoundRecord = BlueprintRound & {
  askSent?: string[];
  turnId?: string; // the message its answers went in, for a Continue sent twice
  lastNote?: string; // the note and writeNow that message carried, likewise
  lastWriteNow?: true;
};

export type BlueprintRecord = Omit<Blueprint, 'costUsd' | 'rounds'> & {
  rounds: RoundRecord[];
  description: string; // what the user first wrote, for side chats and Start a thread
  children?: string[]; // side chats and check threads, for cost and delete
  proposals?: Record<string, { answer: BlueprintAnswer; threadId: string; at: string }>;
  roundsAtWrite?: number; // how many rounds there were at the last blueprint_written
  awaitingSpec?: true; // the agent was asked to write the spec again and hasn't yet
};

function bad(message: string): never {
  throw new RpcError(ErrorCode.badParams, message);
}

// ------------------------------------------------------------ the state file

// Two runner processes can have it open at once: during a handover the old
// one finishes a busy thread's turn (and its blueprint tools) while the new
// one answers the app. So reads take the file again whenever it changed,
// and each write takes a lock, reads the file afresh and changes only its
// own record, never the whole file from memory.
export class BlueprintStore {
  readonly file: string;
  readonly dir: string;
  private items?: Map<string, BlueprintRecord>;
  private seen?: string; // the file's mtime and size when last read

  constructor(home: string) {
    this.file = path.join(home, 'blueprints.json');
    this.dir = path.join(home, 'blueprints');
  }

  private stamp(): string | undefined {
    try {
      const st = fs.statSync(this.file);
      return `${st.mtimeMs}:${st.size}`;
    } catch {
      return undefined;
    }
  }

  private read(): Map<string, BlueprintRecord> {
    const saved = readJsonSync<{ blueprints?: BlueprintRecord[] }>(this.file);
    const items = new Map<string, BlueprintRecord>();
    for (const b of saved?.blueprints ?? []) {
      if (b && typeof b.id === 'string' && typeof b.path === 'string') items.set(b.id, { ...b, rounds: b.rounds ?? [], steps: b.steps ?? [], builds: b.builds ?? [], sideChats: b.sideChats ?? {} });
    }
    return items;
  }

  private load(): Map<string, BlueprintRecord> {
    const stamp = this.stamp();
    if (this.items && stamp === this.seen) return this.items;
    this.items = this.read();
    this.seen = stamp;
    return this.items;
  }

  all(): BlueprintRecord[] {
    return [...this.load().values()];
  }

  get(id: string): BlueprintRecord | undefined {
    return this.load().get(id);
  }

  put(rec: BlueprintRecord): void {
    this.change((items) => items.set(rec.id, rec));
  }

  remove(id: string): void {
    this.change((items) => items.delete(id));
    fs.rmSync(path.join(this.dir, safeId(id)), { recursive: true, force: true });
  }

  snapshotPath(id: string): string {
    return path.join(this.dir, safeId(id), 'spec.snapshot.md');
  }

  readSnapshot(id: string): string | undefined {
    try {
      return fs.readFileSync(this.snapshotPath(id), 'utf8');
    } catch {
      return undefined;
    }
  }

  writeSnapshot(id: string, text: string): void {
    fs.mkdirSync(path.dirname(this.snapshotPath(id)), { recursive: true });
    atomicWriteFileSync(this.snapshotPath(id), text);
  }

  // One record changed against the file as it is now, under the lock.
  private change(fn: (items: Map<string, BlueprintRecord>) => void): void {
    const release = lockFile(`${this.file}.lock`);
    try {
      const items = this.read();
      fn(items);
      atomicWriteFileSync(this.file, JSON.stringify({ blueprints: [...items.values()] }, null, 2) + '\n');
      this.items = items;
      this.seen = this.stamp();
    } finally {
      release();
    }
  }
}

// A lock file made with O_EXCL. Writes take milliseconds, so one older than
// a few seconds was left by a process that died holding it.
const LOCK_WAIT_MS = 3000;
const LOCK_STALE_MS = 5000;
function lockFile(file: string): () => void {
  const until = Date.now() + LOCK_WAIT_MS;
  for (;;) {
    try {
      fs.writeFileSync(file, String(process.pid), { flag: 'wx' });
      return () => fs.rmSync(file, { force: true });
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== 'EEXIST') throw e;
      let age = 0;
      try {
        age = Date.now() - fs.statSync(file).mtimeMs;
      } catch {
        continue; // just released
      }
      if (age > LOCK_STALE_MS) fs.rmSync(file, { force: true });
      else if (Date.now() > until) throw new Error(`blueprints.json is locked by another process (${file}).`);
      else Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
}

// The round as clients see it: `sent` stays (the answers as last sent, so
// the app can show "was A, now B"), the rest of what's kept for messages goes.
export function publicRound(r: RoundRecord): BlueprintRound {
  const { askSent: _a, turnId: _t, lastNote: _n, lastWriteNow: _w, ...shown } = r;
  return structuredClone(shown);
}

// The round's answers have gone to the agent: they're what was sent, and
// none is "changed since last sent" any more.
export function markSent(r: RoundRecord): void {
  for (const a of Object.values(r.answers)) delete a.changedAt;
  r.sent = structuredClone(r.answers);
}

// spec.md as it compares for "edited by hand": a builder ticking its Steps
// checklist hasn't edited it.
export function withoutTicks(text: string): string {
  return text.replace(/^(\s*[-*]\s+)\[[xX]\]/gm, '$1[ ]');
}

// ask_round's moot: earlier questions that no longer apply, by their full
// id ("r1.q2") or, when that's unambiguous, the id the agent gave ("q2").
export function applyMoot(rounds: BlueprintRound[], moot: unknown): number {
  if (moot === undefined || moot === null) return 0;
  if (!Array.isArray(moot)) bad('moot must be a list of { id, why }.');
  let n = 0;
  for (const [i, m] of moot.entries()) {
    const r = (m ?? {}) as Record<string, unknown>;
    const id = str(r.id, `moot[${i}].id`, 80, true)!;
    const why = str(r.why, `moot[${i}].why`, SHORT_MAX, true)!;
    const all = rounds.flatMap((x) => x.questions);
    const exact = all.filter((q) => q.id === id);
    const hits = exact.length ? exact : all.filter((q) => q.id.slice(q.id.indexOf('.') + 1) === id);
    if (hits.length !== 1) bad(hits.length ? `moot[${i}]: ${id} is in more than one round; give it as ${hits.map((q) => q.id).join(' or ')}.` : `moot[${i}]: no earlier question ${id}.`);
    hits[0].moot = why;
    n++;
  }
  return n;
}

function safeId(id: string): string {
  if (!/^[A-Za-z0-9-]+$/.test(id)) throw new Error(`Bad blueprint id: ${id}`);
  return id;
}

// The blueprint as clients see it: no internal fields, the cost added.
export function publicBlueprint(rec: BlueprintRecord, costUsd: number, threadThere: boolean): Blueprint {
  const { description: _d, children: _c, proposals: _p, roundsAtWrite: _w, awaitingSpec: _a, rounds, ...rest } = rec;
  const out: Blueprint = {
    ...structuredClone(rest),
    rounds: rounds.map((r) => publicRound(r)),
    costUsd: Math.round(costUsd * 1e6) / 1e6,
  };
  if (!threadThere) delete out.threadId;
  return out;
}

// ------------------------------------------------------------ folders and slugs

// Where a project's blueprints go: its chosen folder (else its first) and
// the folder under it.
export function blueprintsHome(project: { title: string; folders: string[]; blueprints?: { folder?: string; dir?: string } }): { folder: string; dir: string } {
  const folder = project.blueprints?.folder && project.folders.includes(project.blueprints.folder) ? project.blueprints.folder : project.folders[0];
  if (!folder) bad(`${project.title} has no folder to keep blueprints in. Add one to the project first.`);
  return { folder, dir: checkDir(project.blueprints?.dir ?? DEFAULT_BLUEPRINT_DIR) };
}

// A blueprints folder relative to the project folder, never out of it.
export function checkDir(dir: unknown): string {
  if (typeof dir !== 'string' || !dir.trim()) bad('blueprints.dir must be a folder inside the project folder');
  const d = path.normalize(dir.trim());
  if (path.isAbsolute(d) || d === '.' || d.split(path.sep).includes('..')) bad('blueprints.dir must be a folder inside the project folder, such as .threadbear/blueprints');
  return d.replace(/\/+$/, '');
}

// Words a slug doesn't end on: "add-snooze-presets-per-project-each" reads
// as cut off.
const SLUG_TAIL_STOP = new Set(['a', 'an', 'the', 'each', 'and', 'or', 'of', 'to', 'for', 'with', 'in', 'on', 'per', 'by']);

// Whole words of the text's first line, up to SLUG_MAX characters, never
// ending on a stop word.
export function slugify(text: string): string {
  const words = (text.split('\n')[0] ?? '').toLowerCase().normalize('NFKD').replace(/[^\p{L}\p{N}]+/gu, ' ').trim().split(/\s+/).filter(Boolean);
  const kept: string[] = [];
  for (const w of words) {
    if ([...kept, w].join('-').length > SLUG_MAX) break;
    kept.push(w);
  }
  while (kept.length > 1 && SLUG_TAIL_STOP.has(kept[kept.length - 1])) kept.pop();
  return kept.join('-') || (words[0] ?? '').slice(0, SLUG_MAX) || 'blueprint';
}

// A long text's first sentence, for a line that names it (a check's
// finding, tb's echo): up to the first full stop, cut at a word near max.
export function firstSentence(text: string, max = 120): string {
  const flat = text.replace(/\s+/g, ' ').trim();
  const stop = flat.search(/[.!?](\s|$)/);
  const sentence = stop >= 0 ? flat.slice(0, stop + 1) : flat;
  if (sentence.length <= max) return sentence;
  const cut = sentence.slice(0, max - 1);
  const space = cut.lastIndexOf(' ');
  return `${space > max / 2 ? cut.slice(0, space) : cut}…`;
}

// The slug, or with -2, -3... when it's taken.
export function uniqueSlug(base: string, taken: (slug: string) => boolean): string {
  if (!taken(base)) return base;
  for (let n = 2; ; n++) if (!taken(`${base}-${n}`)) return `${base}-${n}`;
}

// The blueprint folders under a project folder's blueprints folder that
// have a spec.md, through the runner's FolderCache like patches.
export function scanBlueprints(folder: string, dir: string, cache: FolderCache = new FolderCache()): { slug: string; path: string }[] {
  const base = path.join(folder, dir);
  if (!cache.isDir(base)) return [];
  return cache
    .names(base)
    .filter((n) => !n.startsWith('.') && cache.isDir(path.join(base, n)) && cache.kind(path.join(base, n, 'spec.md')) === 'file')
    .sort()
    .map((slug) => ({ slug, path: path.join(base, slug) }));
}

// A found blueprint's id (one with no state here): the same every time for
// the same folder, in a uuid's shape.
export function foundId(blueprintPath: string): string {
  const h = crypto.createHash('sha256').update(path.resolve(blueprintPath)).digest('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-8${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

// The title (its first "# " line) and the Steps checklist of a spec.md.
export function parseSpec(text: string): { title?: string; steps: BlueprintStep[] } {
  const lines = text.split('\n');
  const title = lines.find((l) => /^#\s+\S/.test(l))?.replace(/^#\s+/, '').trim();
  const steps: BlueprintStep[] = [];
  let inSteps = false;
  for (const line of lines) {
    if (/^##\s+/.test(line)) {
      inSteps = /^##\s+steps\b/i.test(line);
      continue;
    }
    const m = inSteps && /^\s{0,1}[-*]\s+\[([ xX])\]\s+(.+)$/.exec(line);
    if (m) steps.push({ id: `s${steps.length + 1}`, title: m[2].trim(), ...(m[1] !== ' ' ? { done: { at: '', note: 'Ticked in the spec.', threadId: '' } } : {}) });
  }
  return { ...(title ? { title } : {}), steps };
}

// The template text for blueprints in this folder: ~'s, then the project
// folder's. Guidance for the agent, not questions.
export function templateText(folder: string, userHome: string, cache: FolderCache = new FolderCache()): string {
  const files = [path.join(userHome, TEMPLATE_FILE), path.join(folder, TEMPLATE_FILE)];
  return [...new Set(files)].map((f) => cache.text(f)?.trim()).filter((t): t is string => Boolean(t)).join('\n\n');
}

// Whether `p` is inside `dir` (and isn't `dir` itself).
export function strictlyInside(p: string, dir: string): boolean {
  const rel = path.relative(dir, p);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

// ------------------------------------------------------------ rounds in

type RawQuestion = {
  id?: unknown;
  text?: unknown;
  kind?: unknown;
  options?: unknown;
  recommended?: unknown;
  youDecide?: unknown;
  min?: unknown;
  max?: unknown;
  step?: unknown;
  several?: unknown;
  other?: unknown;
  image?: unknown;
};

function str(v: unknown, name: string, max: number, required = false): string | undefined {
  if (v === undefined || v === null) {
    if (required) bad(`${name} is required.`);
    return undefined;
  }
  if (typeof v !== 'string') bad(`${name} must be text.`);
  const t = v.trim();
  if (required && !t) bad(`${name} is required.`);
  if (t.length > max) bad(`${name} must be at most ${max} characters.`);
  return t || undefined;
}

function num(v: unknown, name: string): number | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'number' || !Number.isFinite(v)) bad(`${name} must be a number.`);
  return v;
}

// One question as an agent put it, checked. Its id is made unique across
// the blueprint by the round's id in front ("r2.q1"), so side chats and
// answers keyed by it never clash with an earlier round's q1.
export function checkQuestion(raw: unknown, roundId: string, at: string, cwd: string): BlueprintQuestion {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) bad(`${at} must be an object.`);
  const q = raw as RawQuestion;
  const given = str(q.id, `${at}.id`, 60, true)!;
  const text = str(q.text, `${at}.text`, TEXT_MAX, true)!;
  const kind = q.kind ?? (Array.isArray(q.options) && q.options.length ? 'single' : 'text');
  if (typeof kind !== 'string' || !(BLUEPRINT_QUESTION_KINDS as readonly string[]).includes(kind)) bad(`${at}.kind must be one of ${BLUEPRINT_QUESTION_KINDS.join(', ')}.`);
  const out: BlueprintQuestion = { id: `${roundId}.${given}`, text, kind: kind as BlueprintQuestion['kind'], youDecide: q.youDecide !== false };
  if (kind === 'single' || kind === 'multi') {
    if (!Array.isArray(q.options) || q.options.length < 2 || q.options.length > MAX_OPTIONS) bad(`${at} (${kind}) needs between 2 and ${MAX_OPTIONS} options.`);
    const ids = new Set<string>();
    out.options = q.options.map((o, i) => {
      if (!o || typeof o !== 'object') bad(`${at}.options[${i}] must be an object.`);
      const r = o as Record<string, unknown>;
      const id = str(r.id, `${at}.options[${i}].id`, 60, true)!;
      if (ids.has(id)) bad(`${at} has two options with the id ${id}.`);
      ids.add(id);
      const note = str(r.note, `${at}.options[${i}].note`, SHORT_MAX);
      return { id, label: str(r.label, `${at}.options[${i}].label`, SHORT_MAX, true)!, ...(note ? { note } : {}) };
    });
  } else if (q.options !== undefined && !(Array.isArray(q.options) && !q.options.length)) {
    bad(`${at} (${kind}) takes no options.`);
  }
  if (q.recommended !== undefined && q.recommended !== null) {
    if (typeof q.recommended !== 'object') bad(`${at}.recommended must be an object.`);
    const r = q.recommended as Record<string, unknown>;
    const option = str(r.option, `${at}.recommended.option`, 60);
    const rtext = str(r.text, `${at}.recommended.text`, TEXT_MAX);
    const why = str(r.why, `${at}.recommended.why`, SHORT_MAX, true)!;
    if (option && !out.options?.some((o) => o.id === option)) bad(`${at}.recommended.option names no option: ${option}.`);
    if (!option && !rtext) bad(`${at}.recommended needs an option or a text.`);
    out.recommended = { ...(option ? { option } : {}), ...(rtext ? { text: rtext } : {}), why };
  }
  if (kind === 'number') {
    const min = num(q.min, `${at}.min`);
    const max = num(q.max, `${at}.max`);
    const step = num(q.step, `${at}.step`);
    if (min !== undefined && max !== undefined && min > max) bad(`${at}.min is more than its max.`);
    if (step !== undefined && step <= 0) bad(`${at}.step must be more than 0.`);
    Object.assign(out, min !== undefined ? { min } : {}, max !== undefined ? { max } : {}, step !== undefined ? { step } : {});
  }
  if ((kind === 'files' || kind === 'upload') && q.several === true) out.several = true;
  // A free-text "Other" beside the options, on every choice question: the
  // user, not the agent, decides whether an answer is in their own words
  // (Benjamin, 8 Nov, on a question whose options all missed). The
  // agent's `other` flag is still taken and ignored. Stored as true so an
  // app from before this draws the row too.
  if (kind === 'single' || kind === 'multi') out.other = true;
  const image = str(q.image, `${at}.image`, 4096);
  if (image) out.image = path.resolve(cwd, image);
  return out;
}

// A round from ask_round (or the check's findings), checked as a whole.
export function checkRound(
  raw: { title?: unknown; summary?: unknown; questions?: unknown; assumptions?: unknown },
  roundId: string,
  cwd: string,
  kind: 'questions' | 'check' = 'questions',
): RoundRecord {
  const title = str(raw.title, 'title', 200, true)!;
  const summary = str(raw.summary, 'summary', TEXT_MAX);
  const qs = raw.questions;
  if (!Array.isArray(qs)) bad('questions must be a list.');
  if (qs.length > MAX_QUESTIONS) bad(`A round has at most ${MAX_QUESTIONS} questions; put the rest in the next round.`);
  const assumptionsRaw = raw.assumptions ?? [];
  if (!Array.isArray(assumptionsRaw)) bad('assumptions must be a list.');
  if (!qs.length && !assumptionsRaw.length) bad('A round needs a question or an assumption.');
  const questions = qs.map((q, i) => checkQuestion(q, roundId, `questions[${i}]`, cwd));
  const seen = new Set<string>();
  for (const q of questions) {
    if (seen.has(q.id)) bad(`Two questions have the id ${q.id.slice(roundId.length + 1)}.`);
    seen.add(q.id);
  }
  const aIds = new Set<string>();
  const assumptions: BlueprintAssumption[] = assumptionsRaw.map((a, i) => {
    if (!a || typeof a !== 'object') bad(`assumptions[${i}] must be an object.`);
    const r = a as Record<string, unknown>;
    const id = `${roundId}.${str(r.id, `assumptions[${i}].id`, 60) ?? `a${i + 1}`}`;
    if (aIds.has(id)) bad(`Two assumptions have the id ${id.slice(roundId.length + 1)}.`);
    aIds.add(id);
    return { id, text: str(r.text, `assumptions[${i}].text`, TEXT_MAX, true)!, why: str(r.why, `assumptions[${i}].why`, SHORT_MAX, true)! };
  });
  return { id: roundId, kind, title, ...(summary ? { summary } : {}), questions, assumptions, answers: {} };
}

// The check's findings as a round: each one a question, and one with no
// question of its own a text one asking what to do.
export function findingsRound(findings: { text: string; question?: unknown }[], roundId: string, checkTitle: string, cwd: string): RoundRecord {
  const questions = findings.map((f, i) => {
    const text = str(f.text, `findings[${i}].text`, TEXT_MAX, true)!;
    if (f.question === undefined || f.question === null) return { id: `f${i + 1}`, text: `${text}\n\nWhat should the spec do about this?`, kind: 'text' };
    const q = { ...(f.question as Record<string, unknown>) };
    q.id ??= `f${i + 1}`;
    q.text = typeof q.text === 'string' && q.text.trim() && q.text.trim() !== text ? `${text}\n\n${q.text.trim()}` : text;
    return q;
  });
  return checkRound({ title: `What the check found (${checkTitle})`, questions }, roundId, cwd, 'check');
}

// ------------------------------------------------------------ answers

function filled(v: BlueprintAnswerValue | undefined): boolean {
  if (v === undefined) return false;
  if (typeof v === 'number') return true;
  if (typeof v === 'string') return v.trim() !== '';
  return v.length > 0;
}

function checkValue(q: BlueprintQuestion, v: unknown, at: string): BlueprintAnswerValue | undefined {
  if (v === undefined || v === null) return undefined;
  const list = (x: unknown): string[] => {
    const arr = typeof x === 'string' ? [x] : x;
    if (!Array.isArray(arr) || arr.some((s) => typeof s !== 'string')) bad(`${at} must be a list of text.`);
    return arr as string[];
  };
  switch (q.kind) {
    case 'single':
      if (typeof v !== 'string' || !q.options?.some((o) => o.id === v)) bad(`${at} must be one of ${q.options?.map((o) => o.id).join(', ')}.`);
      return v;
    case 'multi': {
      const ids = list(v);
      for (const id of ids) if (!q.options?.some((o) => o.id === id)) bad(`${at} names no option: ${id}.`);
      return [...new Set(ids)];
    }
    case 'text':
      if (typeof v !== 'string') bad(`${at} must be text.`);
      if (v.length > 20_000) bad(`${at} is too long.`);
      return v;
    case 'number': {
      const n = typeof v === 'string' && v.trim() ? Number(v) : v;
      if (typeof n !== 'number' || !Number.isFinite(n)) bad(`${at} must be a number.`);
      if ((q.min !== undefined && n < q.min) || (q.max !== undefined && n > q.max)) bad(`${at} must be between ${q.min ?? '-'} and ${q.max ?? '-'}.`);
      return n;
    }
    case 'files':
    case 'upload': {
      const paths = list(v);
      if (!q.several && paths.length > 1) bad(`${at} takes one file.`);
      return paths;
    }
  }
}

// One answer from the app or a side chat, checked against its question.
export function checkAnswer(q: BlueprintQuestion, raw: unknown, at = q.id): BlueprintAnswer {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return checkAnswer(q, { value: raw }, at);
  const r = raw as Record<string, unknown>;
  const value = checkValue(q, r.value, `${at}.value`);
  const out: BlueprintAnswer = {};
  if (value !== undefined) out.value = value;
  if (r.other !== undefined && r.other !== null && r.other !== '') {
    if (q.kind !== 'single' && q.kind !== 'multi') bad(`${at} has no Other to write in.`);
    if (typeof r.other !== 'string' || r.other.length > 4000) bad(`${at}.other must be text of at most 4000 characters.`);
    if (r.other.trim()) out.other = r.other;
  }
  if (r.youDecide === true) {
    if (!q.youDecide) bad(`${at} needs the user's own answer.`);
    out.youDecide = true;
  }
  if (r.usedRecommendation === true) out.usedRecommendation = true;
  if (r.fromSideChat === true) out.fromSideChat = true;
  if (typeof r.changedAt === 'string') out.changedAt = r.changedAt;
  return out;
}

// The answers a draft or Continue sends, by question id.
export function checkAnswers(round: BlueprintRound, raw: unknown): Record<string, BlueprintAnswer> {
  if (raw === undefined || raw === null) return {};
  if (typeof raw !== 'object' || Array.isArray(raw)) bad('answers must be an object keyed by question id.');
  const out: Record<string, BlueprintAnswer> = {};
  for (const [id, a] of Object.entries(raw as Record<string, unknown>)) {
    const q = round.questions.find((x) => x.id === id);
    if (!q) bad(`${round.title} has no question ${id}.`);
    const answer = checkAnswer(q, a, id);
    if (Object.keys(answer).length) out[id] = answer;
  }
  return out;
}

// Something in it: a value, or an Other written in.
const answered = (a: BlueprintAnswer | undefined): boolean => filled(a?.value) || Boolean(a?.other?.trim());

// Needs-you questions (not moot) with nothing in them.
export function unansweredNeedsYou(round: BlueprintRound): BlueprintQuestion[] {
  return round.questions.filter((q) => !q.youDecide && !q.moot && !answered(round.answers[q.id]));
}

const sameAnswer = (a: BlueprintAnswer | undefined, b: BlueprintAnswer | undefined): boolean =>
  JSON.stringify([a?.value ?? null, a?.other ?? null, Boolean(a?.youDecide), Boolean(a?.usedRecommendation)]) === JSON.stringify([b?.value ?? null, b?.other ?? null, Boolean(b?.youDecide), Boolean(b?.usedRecommendation)]);

// New answers over the round's, with changedAt on any that differ from
// what was sent (a round never sent has nothing to differ from).
export function mergeAnswers(round: RoundRecord, next: Record<string, BlueprintAnswer>, now: string): Record<string, BlueprintAnswer> {
  const out: Record<string, BlueprintAnswer> = {};
  for (const [id, a] of Object.entries(next)) {
    const { changedAt: _c, ...answer } = a;
    if (round.sent && !sameAnswer(round.sent[id], answer)) out[id] = { ...answer, changedAt: sameAnswer(round.answers[id], answer) && round.answers[id]?.changedAt ? round.answers[id].changedAt! : now };
    else out[id] = answer;
  }
  return out;
}

// The questions whose answer differs from what was sent.
export function changedAnswers(round: RoundRecord): { index: number; question: BlueprintQuestion; before?: BlueprintAnswer; after?: BlueprintAnswer }[] {
  if (!round.sent) return [];
  return round.questions.flatMap((question, index) => (sameAnswer(round.sent![question.id], round.answers[question.id]) ? [] : [{ index, question, before: round.sent![question.id], after: round.answers[question.id] }]));
}

// What's waiting to be asked of the assumptions marked "Ask me instead".
export function pendingAsks(round: RoundRecord): BlueprintAssumption[] {
  const sent = new Set(round.askSent ?? []);
  return round.assumptions.filter((a) => round.askInstead?.includes(a.id) && !sent.has(a.id));
}

// ------------------------------------------------------------ messages out

function optionLabel(q: BlueprintQuestion, id: string): string {
  return q.options?.find((o) => o.id === id)?.label ?? id;
}

function recommendation(q: BlueprintQuestion): string | undefined {
  if (!q.recommended) return undefined;
  return q.recommended.option ? optionLabel(q, q.recommended.option) : q.recommended.text;
}

// An answer as the agent reads it.
export function answerText(q: BlueprintQuestion, a: BlueprintAnswer | undefined): string {
  let out: string;
  if (a && answered(a) && !(a.youDecide && !a.usedRecommendation)) {
    const v = a.value;
    const parts: string[] = [];
    if (filled(v)) {
      if (q.kind === 'single') parts.push(optionLabel(q, String(v)));
      else if (q.kind === 'multi') parts.push((v as string[]).map((id) => optionLabel(q, id)).join(', '));
      else if (q.kind === 'upload') parts.push((v as string[]).join(', ') + ' (in the blueprint folder)');
      else if (Array.isArray(v)) parts.push(v.join(', '));
      else parts.push(String(v));
    }
    if (a.other?.trim()) parts.push(`Other: ${a.other.trim()}`);
    out = parts.join('; ');
    if (a.usedRecommendation) out += ' (your recommendation)';
  } else if (a?.youDecide) {
    const rec = recommendation(q);
    out = rec ? `you decide, so your recommendation: ${rec}` : 'you decide';
  } else {
    out = 'unanswered';
  }
  if (a?.fromSideChat) out += ' (worked out in a side chat)';
  return out;
}

const indent = (text: string) => text.split('\n').join('\n   ');

// One question and its answer, numbered as in the round.
// A check round's question is a whole finding, which the agent was sent
// already: its first sentence names it.
function qa(index: number, q: BlueprintQuestion, a: BlueprintAnswer | undefined, short = false): string {
  return `${index + 1}. ${short ? firstSentence(q.text) : indent(q.text)}\n   ${indent(answerText(q, a))}`;
}

function asksBlock(asks: BlueprintAssumption[]): string | undefined {
  return asks.length ? `Ask me instead, as open questions in your next round:\n${asks.map((a) => `- ${a.text}`).join('\n')}` : undefined;
}

// A round's answers, the first time they're sent.
export function answersMessage(round: RoundRecord, opts: { note?: string; writeNow?: boolean; asks?: BlueprintAssumption[]; earlier?: string[] } = {}): string {
  const head = round.kind === 'check' ? `My answers to what the check found:` : `My answers to "${round.title}":`;
  const lines = round.questions.filter((q) => !q.moot).map((q) => qa(round.questions.indexOf(q), q, round.answers[q.id], round.kind === 'check'));
  const tail =
    round.kind === 'check'
      ? 'Update the spec with these, then call blueprint_written again.'
      : opts.writeNow
        ? 'Write the spec now with what you have, and treat anything still open as "you decide".'
        : 'Put the next round, or write the spec if it is clear.';
  const earlier = opts.earlier?.length ? `I also changed earlier answers:\n${opts.earlier.join('\n')}` : undefined;
  return [head, lines.join('\n\n'), earlier, asksBlock(opts.asks ?? []), opts.note?.trim() ? `Note: ${opts.note.trim()}` : undefined, tail].filter(Boolean).join('\n\n');
}

export function changeLines(round: RoundRecord): string[] {
  return changedAnswers(round).map(({ index, question, before, after }) => `- Question ${index + 1} ("${firstSentence(question.text)}") was ${answerText(question, before)}, now ${answerText(question, after)}.`);
}

function oneLine(text: string, max = 120): string {
  const t = text.replace(/\s+/g, ' ').trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

// Changed answers, round by round: a Continue on a round sent before, or
// Update the spec. Undefined when nothing changed and nothing's to say.
export function changesMessage(rounds: RoundRecord[], opts: { note?: string; writeNow?: boolean; updateSpec?: boolean } = {}): string | undefined {
  const blocks = rounds.flatMap((r) => {
    const lines = changeLines(r);
    const asks = pendingAsks(r);
    if (!lines.length && !asks.length) return [];
    return [[lines.length ? `In "${r.title}":\n${lines.join('\n')}` : undefined, asksBlock(asks)].filter(Boolean).join('\n\n')];
  });
  if (!blocks.length && !opts.note?.trim() && !opts.writeNow) return undefined;
  const tail = opts.updateSpec
    ? 'Update the spec and answers.md to match, then call blueprint_written again.'
    : opts.writeNow
      ? 'Write the spec now with what you have, and treat anything still open as "you decide".'
      : 'Check what depends on these and ask again where something moved.';
  return [blocks.length ? `I changed some answers.\n\n${blocks.join('\n\n')}` : undefined, opts.note?.trim() ? `Note: ${opts.note.trim()}` : undefined, tail].filter(Boolean).join('\n\n');
}

// The rounds so far, short: for side chats.
export function compactRounds(rounds: BlueprintRound[]): string {
  if (!rounds.length) return 'No rounds yet.';
  return rounds
    .map((r) => [`${r.title}:`, ...r.questions.filter((q) => !q.moot).map((q) => `- ${oneLine(q.text)}: ${answered(r.answers[q.id]) || r.answers[q.id]?.youDecide ? answerText(q, r.answers[q.id]) : 'unanswered'}`), ...r.assumptions.map((a) => `- Assumed: ${oneLine(a.text)}`)].join('\n'))
    .join('\n\n');
}

function questionBlock(q: BlueprintQuestion): string {
  const kinds: Record<BlueprintQuestion['kind'], string> = {
    single: 'pick one option (its id)',
    multi: 'pick any of the options (their ids)',
    text: 'text',
    number: `a number${q.min !== undefined || q.max !== undefined ? ` from ${q.min ?? 'any'} to ${q.max ?? 'any'}` : ''}`,
    files: `${q.several ? 'files' : 'a file'} in the project, as paths relative to its folder`,
    upload: 'a file from their Mac, which they add in the form',
  };
  const options = q.options?.map((o) => `- ${o.id}: ${o.label}${o.note ? ` (${o.note})` : ''}`).join('\n');
  const rec = q.recommended ? `The planner recommends ${recommendation(q)}: ${q.recommended.why}` : undefined;
  return [q.text, options, `Answer: ${kinds[q.kind]}.`, rec].filter(Boolean).join('\n');
}

// A side chat's first message.
export function sideChatMessage(bp: Pick<BlueprintRecord, 'description' | 'folder' | 'rounds' | 'path'>, q: BlueprintQuestion): string {
  const spec = path.join(bp.path, 'spec.md');
  return [
    `The user wants to talk through one question of a blueprint, a feature being planned in ${bp.folder}. Read the code if it helps, and change nothing: answer in messages, never with a plan or ExitPlanMode. When you settle on an answer together, call propose_answer with it; the user presses Use to put it in the form.`,
    `The feature:\n${bp.description}`,
    ...(fs.existsSync(spec) ? [`The spec as written so far is ${spec}.`] : []),
    `The rounds so far:\n${compactRounds(bp.rounds)}`,
    `The question:\n${questionBlock(q)}`,
  ].join('\n\n');
}

// The check thread's first message.
export function checkMessage(bp: Pick<BlueprintRecord, 'path' | 'folder'>): string {
  return [
    `Read the spec at ${path.join(bp.path, 'spec.md')} against the code in ${bp.folder}, and change nothing.`,
    "Look for what the spec gets wrong about the code, steps that miss files or tests they'll need, and gaps a builder would have to guess at. Leave out matters of taste.",
    'Then call report_check once with your findings, one each, most important first, and end your turn; never make a plan or call ExitPlanMode. Give a finding a question when the user has to choose. With nothing found, call it with no findings.',
  ].join(' ');
}

// The build thread's first message (docs/protocol.md, "Starting a build").
export function buildMessage(bp: Pick<BlueprintRecord, 'path'>, mode: 'thread' | 'subagents'): string {
  const spec = path.join(bp.path, 'spec.md');
  const text =
    `Build the blueprint at ${spec}. Read answers.md beside it only where the spec leaves something unclear. ` +
    "Before changing anything, say in a few lines how you'll go about step one: the files you'll touch and the tests you'll run. " +
    "When the spec doesn't cover something, ask, don't guess. " +
    "Mark each step done with update_blueprint as you finish it, with a sentence on what you did, and tick it in the spec's Steps section.";
  if (mode === 'thread') return text;
  return (
    text +
    '\n\nWork the steps with subagents: one per step where steps are independent, in order where one needs another. ' +
    "They all work in this thread's folder, so give each its step, the spec's path and the files it may touch. " +
    'Check what each one did, then mark its step yourself.'
  );
}

// To the blueprint agent after spec.md was edited by hand.
export function editedMessage(hunks: Hunk[]): string {
  const diff = hunks.map((h) => [`@@ -${h.oldStart},${h.oldLines} +${h.newStart},${h.newLines} @@`, ...h.lines].join('\n')).join('\n');
  return `I edited spec.md by hand. The changes:\n\n\`\`\`diff\n${diff}\n\`\`\`\n\nBring answers.md into line, or ask me.`;
}

// What a blueprint thread's session is told (Runner.briefFor). Kept short:
// it goes in every blueprint thread's context.
export function blueprintInstructions(bp: Pick<BlueprintRecord, 'path'>, template: string): string {
  const parts = [
    `[Threadbear blueprint] This thread plans a feature with the user by rounds of questions, then writes a spec a builder can follow. Write nothing but the blueprint's files, in ${bp.path}.`,
    'Read the code the feature touches, then put a round with ask_round, or call too_small for a change a thread could just do. Usually two or three rounds. "Ask me anyway" means put a round.',
    "Assume a point (in assumptions, with why) when the code or an earlier answer decides it. Otherwise ask, with a recommendation and why if you have one, and leave it open so the user can say \"you decide\". youDecide false is only for taste or scope the user alone can settle; most stay open. A changed answer comes as \"Question N was A, now B\": check what depends on it.",
    'When it is clear, write in that folder spec.md, for the builder, with these sections in order: a "# " title, ## Overview, ## Decisions, ## Assumptions, ## Steps (a "- [ ] " checklist, each step with the files it expects to touch and the tests that cover it), ## Open points; and answers.md, every question with its answer and the choices not picked, round by round. Files from upload answers are in its attachments/. Then call blueprint_written with the title and the steps.',
  ];
  if (template.trim()) parts.push(`The user's guidance for every blueprint here, to fold into rounds where it fits:\n${template.trim()}`);
  return parts.join('\n\n');
}
