// Blueprints (docs/protocol.md, "Blueprints"): where they meet threads.
// blueprints.ts has the state file, the checks and the messages; this is
// the Runner's side: the blueprint thread and its children (side chats,
// check threads), build threads, the agents' tools and the app's calls.
// Part of the Runner (runner.ts); each method's `this` is the Runner.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import type { Runner, ThreadState } from '../runner.ts';
import type { RunnerPart } from './part.ts';
import type { Blueprint, BlueprintAnswer, BlueprintStep, EventBody, Hunk, ImageRef, PermissionMode, Project, Provider, ThreadSummary } from '../protocol.ts';
import { ErrorCode, RpcError } from '../protocol.ts';
import type { ThreadRecord } from '../store.ts';
import { diffLines } from '../diff.ts';
import { HAIKU } from '../models/index.ts';
import { cutSafely, firstLineSafely } from '../safe-cut.ts';
import { LIMITS } from '../protocol.ts';

// runner.ts's own, written again here: main.ts loads this file for
// blueprintMethods before runner.ts, so it can't take values from there.
const RECHECK_MS = 15_000; // PATCHES_TTL_MS: spec.md is read again as often as patches
const oneLine = (text: string, max: number): string => cutSafely(text.replace(/\s+/g, ' ').trim(), max, '…');
const titleFrom = (text: string): string => firstLineSafely(text, LIMITS.titleChars);
import {
  BlueprintStore,
  MAX_QUESTIONS,
  answerText,
  answersMessage,
  blueprintInstructions,
  blueprintsHome,
  buildMessage,
  changedAnswers,
  changeLines,
  changesMessage,
  checkAnswer,
  markSent,
  checkAnswers,
  checkMessage,
  checkRound,
  editedMessage,
  findingsRound,
  foundId,
  mergeAnswers,
  parseSpec,
  pendingAsks,
  applyMoot,
  publicBlueprint,
  publicRound,
  scanBlueprints,
  withoutTicks,
  sideChatMessage,
  slugify,
  strictlyInside,
  templateText,
  uniqueSlug,
  unansweredNeedsYou,
  type BlueprintRecord,
  type RoundRecord,
} from '../blueprints.ts';

// Which of a blueprint's threads this is, for its tools.
export type BlueprintRole = 'blueprint' | 'sideChat' | 'check' | 'build';
export type BuildMode = 'thread' | 'subagents';
export const BUILD_MODES: readonly BuildMode[] = ['thread', 'subagents'];

const busy = (message: string) => new RpcError(ErrorCode.busy, message);
const bad = (message: string) => new RpcError(ErrorCode.badParams, message);

export const blueprintsPart = {
  blueprintStore(this: Runner): BlueprintStore {
    return (this.bpStore ??= new BlueprintStore(this.cfg.home));
  },

  blueprintRole(this: Runner, threadId: string): BlueprintRole | undefined {
    const rec = this.threads.get(threadId)?.rec;
    if (!rec?.blueprintId) return undefined;
    return rec.kind ?? 'build';
  },

  // The model side chats and checks start on: the runner's small default
  // for the provider (runner.json defaults.smallModels), Haiku for Claude.
  smallModelFor(this: Runner, provider: Provider): string | undefined {
    return this.cfg.defaults.smallModels?.[provider] ?? (provider === 'claude' ? HAIKU : undefined);
  },

  // ------------------------------------------------------------ reading

  blueprintCost(this: Runner, bp: BlueprintRecord): number {
    const ids = [bp.threadId, ...(bp.children ?? [])].filter((id): id is string => Boolean(id));
    return ids.reduce((sum, id) => sum + (this.threads.get(id)?.rec.costUsd ?? 0), 0);
  },

  publicBlueprintOf(this: Runner, bp: BlueprintRecord): Blueprint {
    const out = publicBlueprint(bp, this.blueprintCost(bp), Boolean(bp.threadId && this.threads.has(bp.threadId)));
    // Until blueprint_written names it, its title is the description's
    // first line cut short ("...each project can have its ow"); the
    // thread's, once the namer has given it one, reads better.
    const thread = bp.threadId ? this.threads.get(bp.threadId)?.rec : undefined;
    if (thread?.title && bp.title === titleFrom(bp.description) && thread.title !== bp.title) out.title = thread.title;
    return out;
  },

  // The summary's blueprint, on a blueprint thread: read again lazily, as
  // patches are, so spec.md edited by hand shows within 15 seconds.
  blueprintSummary(this: Runner, rec: ThreadRecord): Blueprint | undefined {
    if (rec.kind !== 'blueprint' || !rec.blueprintId) return undefined;
    const bp = this.blueprintStore().get(rec.blueprintId);
    if (!bp) return undefined;
    this.checkEditedByHand(bp, false);
    return this.publicBlueprintOf(bp);
  },

  // Whether a blueprint thread has a round open for the user, or its
  // too-small card (start a thread, or ask me anyway) is waiting on them.
  blueprintWaiting(this: Runner, rec: ThreadRecord): boolean {
    if (rec.kind !== 'blueprint' || !rec.blueprintId) return false;
    const bp = this.blueprintStore().get(rec.blueprintId);
    if (bp?.tooSmall && !bp.rounds.length) return true;
    return Boolean(bp && bp.status === 'waiting' && bp.rounds.some((r) => !r.sentAt));
  },

  // spec.md against the agent's snapshot; true when editedByHand changed.
  // Not while it's built (the builder ticks the Steps and edits as it goes)
  // or while its agent is writing it again, and ticks never count.
  checkEditedByHand(this: Runner, bp: BlueprintRecord, force: boolean): boolean {
    if (bp.status === 'building' || bp.status === 'done' || bp.awaitingSpec) return false;
    const now = this.clock.now();
    const last = this.bpChecked.get(bp.id);
    if (!force && last && now - last.at < RECHECK_MS) return false;
    const spec = path.join(bp.path, 'spec.md');
    let mtime: number | undefined;
    try {
      mtime = fs.statSync(spec).mtimeMs;
    } catch {
      mtime = undefined;
    }
    this.bpChecked.set(bp.id, { at: now, mtime });
    if (last && last.mtime === mtime && !force) return false;
    const snapshot = this.blueprintStore().readSnapshot(bp.id);
    let edited = false;
    if (snapshot !== undefined && mtime !== undefined) {
      try {
        edited = withoutTicks(fs.readFileSync(spec, 'utf8')) !== withoutTicks(snapshot);
      } catch {
        edited = false;
      }
    }
    if (edited === Boolean(bp.editedByHand)) return false;
    if (edited) bp.editedByHand = true;
    else delete bp.editedByHand;
    this.blueprintStore().put(bp);
    return true;
  },

  // Every blueprint: the data dir's, then ones found in project folders
  // with no state here (a clone, another Mac's), listed as ready.
  listBlueprints(this: Runner, projectId?: string): { blueprints: Blueprint[] } {
    const want = projectId ? this.mustProject(projectId).id : undefined;
    const records = this.blueprintStore().all().filter((b) => !want || b.projectId === want);
    for (const bp of records) {
      if (this.checkEditedByHand(bp, true) && bp.threadId) {
        const st = this.threads.get(bp.threadId);
        if (st) this.markDirty(st);
      }
    }
    return { blueprints: [...records.map((b) => this.publicBlueprintOf(b)), ...this.foundBlueprints(want).map((b) => this.publicBlueprintOf(b))] };
  },

  foundBlueprints(this: Runner, projectId?: string): BlueprintRecord[] {
    if (!this.projects) return [];
    const known = new Set(this.blueprintStore().all().map((b) => path.resolve(b.path)));
    const out: BlueprintRecord[] = [];
    for (const p of this.projects.list()) {
      if (projectId && p.id !== projectId) continue;
      let home: { folder: string; dir: string };
      try {
        home = blueprintsHome(p);
      } catch {
        continue;
      }
      for (const f of scanBlueprints(home.folder, home.dir, this.folderCache)) {
        if (known.has(path.resolve(f.path))) continue;
        known.add(path.resolve(f.path));
        let text = '';
        try {
          text = fs.readFileSync(path.join(f.path, 'spec.md'), 'utf8');
        } catch {
          continue;
        }
        const spec = parseSpec(text);
        let at = this.isoNow();
        try {
          at = fs.statSync(path.join(f.path, 'spec.md')).mtime.toISOString();
        } catch {
          /* now */
        }
        out.push({ id: foundId(f.path), projectId: p.id, folder: home.folder, path: f.path, slug: f.slug, title: spec.title ?? f.slug, status: 'ready', rounds: [], steps: spec.steps, builds: [], sideChats: {}, description: '', createdAt: at, updatedAt: at });
      }
    }
    return out;
  },

  // A blueprint by id: one with state, or a found one.
  findBlueprint(this: Runner, id: string): { bp: BlueprintRecord; found: boolean } {
    if (typeof id !== 'string' || !id) throw bad('id must be a string');
    const bp = this.blueprintStore().get(id);
    if (bp) return { bp, found: false };
    const found = this.foundBlueprints().find((b) => b.id === id);
    if (found) return { bp: found, found: true };
    throw bad(`No blueprint ${id}`);
  },

  // One with state: rounds and answers need its thread.
  mustBlueprint(this: Runner, id: string): BlueprintRecord {
    const { bp, found } = this.findBlueprint(id);
    if (found) throw bad(`${bp.title} was found in ${bp.folder} with no rounds on this Mac, so it has no answers to change.`);
    return bp;
  },

  mustProject(this: Runner, q: string): Project {
    if (!this.projects) throw bad('This runner has no projects.');
    const rec = this.projects.find(q);
    if (!rec) throw new RpcError(ErrorCode.projectNotFound, `No project called ${q}`);
    return this.projects.get(rec.id).project;
  },

  blueprintThread(this: Runner, bp: BlueprintRecord): ThreadState | undefined {
    const st = bp.threadId ? this.threads.get(bp.threadId) : undefined;
    return st && !st.rt.deleted ? st : undefined;
  },

  mustBlueprintThread(this: Runner, bp: BlueprintRecord): ThreadState {
    const st = this.blueprintThread(bp);
    // A draining runner that has just let it go: the primary takes the
    // request instead (rpc.ts, forward).
    if (!st && bp.threadId && this.draining?.gone.has(bp.threadId)) throw new RpcError(ErrorCode.moved, 'This runner has handed that thread over to the new one.');
    if (!st) throw bad(`${bp.title} has no thread on this Mac.`);
    return st;
  },

  // Saves it and sends its thread's summary, which carries it, after
  // `body` on that thread if there's an event to write.
  saveBlueprint(this: Runner, bp: BlueprintRecord, body?: EventBody): void {
    bp.updatedAt = this.isoNow();
    this.blueprintStore().put(bp);
    this.blueprintEmit(bp, body);
  },

  // An event on the blueprint thread, and its summary sent again. During a
  // handover the thread may be on the other runner: a draining runner
  // sends both to the primary (drain.blueprints), which has every thread
  // but the ones kept here.
  blueprintEmit(this: Runner, bp: BlueprintRecord, body?: EventBody): void {
    const st = this.blueprintThread(bp);
    if (st) {
      if (body) this.emit(st, body, st.rt.turn?.turnId);
      this.markDirty(st);
    } else if (this.draining && bp.threadId) {
      this.publish({ method: 'drain.blueprints', params: { threadId: bp.threadId, events: body ? [body] : [] } });
    }
  },

  // The primary's side of drain.blueprints: a draining runner's blueprint
  // tool changed a blueprint whose thread is here, or wants its check
  // started (a draining runner makes no threads).
  blueprintDrain(this: Runner, params: { threadId?: unknown; events?: unknown; check?: unknown }): void {
    const st = typeof params.threadId === 'string' ? this.threads.get(params.threadId) : undefined;
    if (st && !st.rt.deleted) {
      for (const body of Array.isArray(params.events) ? params.events : []) {
        if (body && typeof body === 'object' && typeof (body as { type?: unknown }).type === 'string' && String((body as { type: string }).type).startsWith('blueprint.')) this.emit(st, body as EventBody, st.rt.turn?.turnId);
      }
      this.markDirty(st);
    }
    const bp = typeof params.check === 'string' ? this.blueprintStore().get(params.check) : undefined;
    if (bp) {
      try {
        this.startBlueprintCheck(bp);
      } catch (e) {
        this.log.warn('could not start a blueprint check for a draining runner', { blueprintId: bp.id, error: String(e) });
      }
    }
  },

  // The blueprint thread a blueprints.* request is about, for rpc.ts to
  // pass it on to a draining runner that has it.
  blueprintThreadId(this: Runner, id: unknown): string | undefined {
    return typeof id === 'string' ? this.blueprintStore().get(id)?.threadId : undefined;
  },

  // The blueprint thread's instructions (briefFor): fresh sessions only.
  blueprintBrief(this: Runner, rec: ThreadRecord): string | undefined {
    if (rec.kind !== 'blueprint' || !rec.blueprintId) return undefined;
    const bp = this.blueprintStore().get(rec.blueprintId);
    if (!bp) return undefined;
    return blueprintInstructions(bp, templateText(bp.folder, this.panelsRoot ?? os.homedir(), this.folderCache));
  },

  // A child's turn changed its cost, which its blueprint's summary shows.
  blueprintTurnEnded(this: Runner, st: ThreadState): void {
    const parent = st.rec.parentThreadId ? this.threads.get(st.rec.parentThreadId) : undefined;
    if (parent && !parent.rt.deleted) this.markDirty(parent);
  },

  joinBlueprintProject(this: Runner, threadId: string, projectId: string): void {
    try {
      this.projects?.changeMembership(threadId, { add: [projectId], by: 'mike' });
    } catch (e) {
      this.log.warn('could not put a blueprint thread in its project', { threadId, projectId, error: String(e) });
    }
  },

  // ------------------------------------------------------------ the app's calls

  createBlueprint(this: Runner, params: { projectId?: string; newProject?: { title: string; folder: string }; text: string; images?: ImageRef[]; accountId?: string; model?: string }): { blueprint: Blueprint; thread: ThreadSummary } {
    if (!this.projects) throw bad('This runner has no projects.');
    const text = typeof params.text === 'string' ? params.text.trim() : '';
    if (!text) throw bad('Describe the feature: text is required.');
    if (!params.projectId && !params.newProject) throw bad('projectId or newProject is required.');
    this.checkAccepting();
    const project = params.newProject
      ? this.projects.create({ title: params.newProject.title, folders: [params.newProject.folder], by: 'mike' })
      : this.mustProject(params.projectId!);
    const { folder, dir } = blueprintsHome(project);
    const store = this.blueprintStore();
    const base = path.join(folder, dir);
    // From the whole first line, not the title cut to 60: a cut word would end it.
    const slug = uniqueSlug(slugify(text), (s) => fs.existsSync(path.join(base, s)) || store.all().some((b) => path.resolve(b.path) === path.resolve(base, s)));
    const now = this.isoNow();
    const bp: BlueprintRecord = { id: crypto.randomUUID(), projectId: project.id, folder, path: path.join(base, slug), slug, title: titleFrom(text), status: 'drafting', rounds: [], steps: [], builds: [], sideChats: {}, description: text, createdAt: now, updatedAt: now };
    // Before the thread: its first session reads it for its instructions.
    store.put(bp);
    let thread: ThreadSummary;
    try {
      thread = this.create({ text, images: params.images, cwd: folder, accountId: params.accountId, model: params.model, worktree: false, blueprint: { kind: 'blueprint', blueprintId: bp.id } }).thread;
    } catch (e) {
      store.remove(bp.id);
      throw e;
    }
    bp.threadId = thread.id;
    this.saveBlueprint(bp);
    this.joinBlueprintProject(thread.id, project.id);
    return { blueprint: this.publicBlueprintOf(bp), thread: this.summary(this.mustGet(thread.id)) };
  },

  mustRound(this: Runner, bp: BlueprintRecord, roundId: string): RoundRecord {
    const round = bp.rounds.find((r) => r.id === roundId);
    if (!round) throw bad(`${bp.title} has no round ${roundId}`);
    return round;
  },

  checkUnlocked(this: Runner, bp: BlueprintRecord): void {
    if (bp.status === 'building' || bp.status === 'done') throw busy(`${bp.title} is ${bp.status === 'done' ? 'done' : 'being built'}, so its answers are locked. Send a change to the build thread instead.`);
  },

  // After an answer changed in a round already sent: a written spec is
  // older than the answers now.
  markStale(this: Runner, bp: BlueprintRecord): void {
    if (bp.status === 'ready' || bp.specStale) {
      bp.status = 'drafting';
      bp.specStale = true;
    }
  },

  setAnswers(this: Runner, bp: BlueprintRecord, round: RoundRecord, raw: unknown, note?: unknown): void {
    if (raw !== undefined) round.answers = mergeAnswers(round, placeFiles(bp, round, checkAnswers(round, raw)), this.isoNow());
    if (note !== undefined && note !== null) {
      if (typeof note !== 'string') throw bad('note must be text');
      if (note.trim()) round.note = note;
      else delete round.note;
    }
    if (round.sentAt && changedAnswers(round).length) this.markStale(bp);
    // Changed back to what the spec was written from: ready again.
    else if (bp.specStale && bp.status === 'drafting' && !bp.awaitingSpec && !bp.rounds.some((r) => changedAnswers(r).length || pendingAsks(r).length)) {
      bp.status = 'ready';
      delete bp.specStale;
    }
  },

  saveBlueprintDraft(this: Runner, id: string, roundId: string, answers: unknown, note?: unknown): { blueprint: Blueprint } {
    const bp = this.mustBlueprint(id);
    this.checkUnlocked(bp);
    this.setAnswers(bp, this.mustRound(bp, roundId), answers, note);
    this.saveBlueprint(bp);
    return { blueprint: this.publicBlueprintOf(bp) };
  },

  continueBlueprint(this: Runner, id: string, roundId: string, answers: unknown, note?: unknown, writeNow?: boolean): { blueprint: Blueprint; turnId?: string } {
    const bp = this.mustBlueprint(id);
    this.checkUnlocked(bp);
    const st = this.mustBlueprintThread(bp);
    this.checkAccepting();
    const round = this.mustRound(bp, roundId);
    this.setAnswers(bp, round, answers, note);
    const missing = unansweredNeedsYou(round);
    if (missing.length) {
      // Kept as a draft, so nothing typed is lost.
      this.saveBlueprint(bp);
      throw bad(`These need your answer first: ${missing.map((q) => `"${oneLine(q.text, 80)}"`).join(', ')}.`);
    }
    const wasWritten = Boolean(bp.specStale);
    const asks = bp.rounds.flatMap((r) => pendingAsks(r));
    // Continue again for a round already sent, with the same note and
    // nothing changed (a dropped reply, a second click): nothing goes.
    if (round.sentAt && round.turnId && !asks.length && !bp.rounds.some((r) => changedAnswers(r).length) && (round.note ?? '') === (round.lastNote ?? '') && Boolean(writeNow) === Boolean(round.lastWriteNow)) {
      delete round.note;
      this.saveBlueprint(bp);
      return { blueprint: this.publicBlueprintOf(bp), turnId: round.turnId };
    }
    let text: string | undefined;
    if (!round.sentAt) {
      // The round, with any earlier round's changes and every open ask.
      const earlier = bp.rounds.filter((r) => r !== round && r.sentAt).flatMap((r) => changeLines(r));
      text = answersMessage(round, { note: round.note, writeNow, asks, earlier });
    } else {
      text = changesMessage(bp.rounds, { note: round.note, writeNow, updateSpec: wasWritten });
    }
    // Sent twice (a dropped reply): nothing new, so nothing goes.
    if (!text) return { blueprint: this.publicBlueprintOf(bp), ...(round.turnId ? { turnId: round.turnId } : {}) };
    // Sent first: a message refused leaves the round open as it was.
    const { turnId } = this.send(st.rec.id, text, [], { roundId });
    this.emit(st, { type: 'blueprint.answered', roundId, answers: structuredClone(round.answers), ...(round.note ? { note: round.note } : {}), ...(writeNow ? { writeNow: true as const } : {}) }, st.rt.turn?.turnId ?? turnId);
    // Answers to the check, or changes after the spec: the agent writes it again.
    if (wasWritten || round.kind === 'check') bp.awaitingSpec = true;
    if (round.note) round.lastNote = round.note;
    else delete round.lastNote;
    if (writeNow) round.lastWriteNow = true;
    else delete round.lastWriteNow;
    for (const r of bp.rounds) if (r === round || r.sentAt) markSent(r);
    for (const r of bp.rounds) r.askSent = [...new Set([...(r.askSent ?? []), ...asks.filter((a) => a.id.startsWith(`${r.id}.`)).map((a) => a.id)])];
    round.sentAt ??= this.isoNow();
    if (writeNow) round.writeNow = true;
    if (bp.status === 'waiting' && !bp.rounds.some((r) => !r.sentAt)) bp.status = 'drafting';
    round.turnId = turnId;
    delete round.note;
    this.saveBlueprint(bp);
    return { blueprint: this.publicBlueprintOf(bp), turnId };
  },

  askInsteadBlueprint(this: Runner, id: string, roundId: string, assumptionId: string): { blueprint: Blueprint } {
    const bp = this.mustBlueprint(id);
    this.checkUnlocked(bp);
    const round = this.mustRound(bp, roundId);
    if (!round.assumptions.some((a) => a.id === assumptionId)) throw bad(`${round.title} has no assumption ${assumptionId}`);
    round.askInstead = [...new Set([...(round.askInstead ?? []), assumptionId])];
    this.markStale(bp);
    this.saveBlueprint(bp);
    return { blueprint: this.publicBlueprintOf(bp) };
  },

  updateSpecBlueprint(this: Runner, id: string): { turnId: string } {
    const bp = this.mustBlueprint(id);
    this.checkUnlocked(bp);
    const st = this.mustBlueprintThread(bp);
    const text = changesMessage(bp.rounds, { updateSpec: true });
    if (!text) throw busy('No answer has changed since the spec was written.');
    const { turnId } = this.send(st.rec.id, text, []);
    for (const r of bp.rounds) {
      if (r.sentAt) markSent(r);
      r.askSent = [...new Set([...(r.askSent ?? []), ...pendingAsks(r).map((a) => a.id)])];
    }
    bp.status = 'drafting';
    bp.awaitingSpec = true;
    this.saveBlueprint(bp);
    return { turnId };
  },

  blueprintDiff(this: Runner, id: string): { hunks: Hunk[] } {
    const { bp } = this.findBlueprint(id);
    const snapshot = this.blueprintStore().readSnapshot(bp.id);
    if (snapshot === undefined) throw bad(`${bp.title} has no spec written by its agent to compare with.`);
    let now = '';
    try {
      now = fs.readFileSync(path.join(bp.path, 'spec.md'), 'utf8');
    } catch {
      /* deleted: all of it went */
    }
    return { hunks: diffLines(snapshot, now) };
  },

  tellAgentBlueprint(this: Runner, id: string): { turnId: string } {
    const bp = this.mustBlueprint(id);
    const st = this.mustBlueprintThread(bp);
    const { hunks } = this.blueprintDiff(id);
    if (!hunks.length) throw busy('spec.md is as the agent wrote it.');
    return this.send(st.rec.id, editedMessage(hunks), []);
  },

  // ------------------------------------------------------------ children

  // A child thread of a blueprint: plan mode, the small model, its folder.
  blueprintChild(this: Runner, bp: BlueprintRecord, kind: 'sideChat' | 'check', text: string, title: string, questionId?: string): string {
    const parent = this.blueprintThread(bp);
    const accountId = parent?.rec.accountId ?? this.defaultAccountId();
    const provider = this.accounts.get(accountId)?.provider ?? 'claude';
    const { thread } = this.create({
      text,
      cwd: bp.folder,
      accountId,
      model: this.smallModelFor(provider),
      permissionMode: 'plan',
      worktree: false,
      origin: 'runner',
      title,
      // Its blueprint thread's id even when that thread is gone or on the
      // other runner, so it's never taken for an ordinary thread.
      blueprint: { kind, blueprintId: bp.id, ...(bp.threadId ? { parentThreadId: bp.threadId } : {}), ...(questionId ? { blueprintQuestionId: questionId } : {}) },
    });
    bp.children = [...new Set([...(bp.children ?? []), thread.id])];
    return thread.id;
  },

  blueprintSideChat(this: Runner, id: string, questionId: string): { threadId: string } {
    const bp = this.mustBlueprint(id);
    const there = bp.sideChats[questionId];
    if (there && this.threads.has(there)) return { threadId: there };
    const q = bp.rounds.flatMap((r) => r.questions).find((x) => x.id === questionId);
    if (!q) throw bad(`${bp.title} has no question ${questionId}`);
    const threadId = this.blueprintChild(bp, 'sideChat', sideChatMessage(bp, q), `Side chat: ${oneLine(q.text, 50)}`, questionId);
    bp.sideChats[questionId] = threadId;
    this.saveBlueprint(bp);
    return { threadId };
  },

  useBlueprintProposal(this: Runner, id: string, questionId: string, answer?: unknown): { blueprint: Blueprint } {
    const bp = this.mustBlueprint(id);
    this.checkUnlocked(bp);
    const round = bp.rounds.find((r) => r.questions.some((q) => q.id === questionId));
    if (!round) throw bad(`${bp.title} has no question ${questionId}`);
    const q = round.questions.find((x) => x.id === questionId)!;
    const given = answer ?? bp.proposals?.[questionId]?.answer;
    if (given === undefined) throw bad('No answer was proposed for that question.');
    const a = { ...checkAnswer(q, given), fromSideChat: true as const };
    delete a.changedAt;
    // A side chat can't pick files from the Mac for an upload: Use takes
    // only files already in the blueprint's folder.
    if (q.kind === 'upload' && Array.isArray(a.value)) {
      for (const p of a.value) {
        const abs = path.resolve(bp.path, p);
        if (!strictlyInside(abs, bp.path) || !fs.existsSync(abs)) throw bad(`${p} isn't a file in ${bp.path}; add uploads in the form.`);
      }
    }
    this.setAnswers(bp, round, { ...round.answers, [questionId]: a });
    this.saveBlueprint(bp);
    return { blueprint: this.publicBlueprintOf(bp) };
  },

  startBlueprintCheck(this: Runner, bp: BlueprintRecord): string | undefined {
    // A draining runner makes no threads: the primary starts it.
    if (this.draining) {
      this.publish({ method: 'drain.blueprints', params: { check: bp.id } });
      return undefined;
    }
    const running = bp.checkThreadId ? this.threads.get(bp.checkThreadId) : undefined;
    if (running && (running.rt.turn || running.rec.queue.length || running.rec.status === 'running' || running.rec.status === 'starting')) throw busy('A check of this spec is already running.');
    if (!fs.existsSync(path.join(bp.path, 'spec.md'))) throw busy(`${bp.title} has no spec.md to check yet.`);
    const threadId = this.blueprintChild(bp, 'check', checkMessage(bp), `Check: ${oneLine(bp.title, 50)}`);
    bp.checkThreadId = threadId;
    this.saveBlueprint(bp);
    return threadId;
  },

  checkBlueprint(this: Runner, id: string): { threadId: string } {
    const bp = this.mustBlueprint(id);
    const threadId = this.startBlueprintCheck(bp);
    if (!threadId) throw busy('The runner is handing over to a new one; check again in a moment.');
    return { threadId };
  },

  // ------------------------------------------------------------ building

  startBlueprint(this: Runner, params: { id: string; mode: unknown; accountId?: string; model?: string; permissionMode?: PermissionMode }): { threadId: string } {
    if (typeof params.mode !== 'string' || !(BUILD_MODES as readonly string[]).includes(params.mode)) throw bad(`mode must be ${BUILD_MODES.join(' or ')}`);
    const mode = params.mode as BuildMode;
    const { bp, found } = this.findBlueprint(params.id);
    if (bp.status !== 'ready' && bp.status !== 'building' && bp.status !== 'done') throw busy(`${bp.title} isn't ready to build: its spec isn't written${bp.specStale ? ' for the latest answers' : ''} yet.`);
    if (!fs.existsSync(path.join(bp.path, 'spec.md'))) throw busy(`${bp.title} has no spec.md in ${bp.path}.`);
    this.checkAccepting();
    const parent = this.blueprintThread(bp);
    const { thread } = this.create({
      text: buildMessage(bp, mode),
      cwd: bp.folder,
      accountId: params.accountId,
      model: params.model,
      ...(params.permissionMode ? { permissionMode: params.permissionMode } : {}),
      title: bp.title,
      startedBy: { kind: 'blueprint', label: 'Blueprint', ...(parent ? { threadId: parent.rec.id, threadTitle: parent.rec.title } : {}) },
      blueprint: { blueprintId: bp.id },
    });
    // A found one gets state here from now on, to keep its steps and builds.
    if (found) bp.createdAt = this.isoNow();
    bp.builds.push({ threadId: thread.id, mode, at: this.isoNow() });
    bp.status = 'building';
    this.saveBlueprint(bp);
    this.joinBlueprintProject(thread.id, bp.projectId);
    return { threadId: thread.id };
  },

  // Removes what it can: the files, then the threads, then the state.
  removeBlueprint(this: Runner, bp: BlueprintRecord, found: boolean): void {
    if (fs.existsSync(bp.path)) {
      if (!strictlyInside(bp.path, bp.folder) || path.basename(bp.path) !== bp.slug) throw bad(`Not removing ${bp.path}: it isn't a blueprint folder inside ${bp.folder}.`);
      // Only a blueprint's own files: a folder with anything else in it is
      // someone's work (a blueprints dir set to "packages" finds packages/x).
      const own = new Set(['spec.md', 'answers.md', 'attachments']);
      const others = fs.readdirSync(bp.path).filter((n) => !own.has(n) && n !== '.DS_Store');
      if (others.length) throw busy(`Not deleting ${bp.path}: it has files a blueprint doesn't make (${others.slice(0, 5).join(', ')}${others.length > 5 ? '...' : ''}). Move or remove them first.`);
      for (const n of own) fs.rmSync(path.join(bp.path, n), { recursive: true, force: true });
      fs.rmSync(path.join(bp.path, '.DS_Store'), { force: true });
      fs.rmdirSync(bp.path);
      this.folderCache.clear();
    }
    for (const id of [bp.threadId, ...(bp.children ?? [])]) {
      const st = id ? this.threads.get(id) : undefined;
      if (!st || st.rec.archivedAt) continue;
      try {
        this.update({ threadId: st.rec.id, archived: true, archivedBy: 'threadbear' });
      } catch (e) {
        this.log.warn('could not archive a blueprint thread', { threadId: st.rec.id, error: String(e) });
      }
    }
    if (!found) this.blueprintStore().remove(bp.id);
    this.bpChecked.delete(bp.id);
  },

  deleteBlueprint(this: Runner, id: string): Record<string, never> {
    const { bp, found } = this.findBlueprint(id);
    this.removeBlueprint(bp, found);
    return {};
  },

  // "Start a thread" on the too-small card: the description as a normal
  // thread, and the blueprint goes.
  tooSmallStart(this: Runner, id: string): { threadId: string } {
    const bp = this.mustBlueprint(id);
    const { thread } = this.create({ text: bp.description, cwd: bp.folder });
    this.joinBlueprintProject(thread.id, bp.projectId);
    this.removeBlueprint(bp, false);
    return { threadId: thread.id };
  },

  // ------------------------------------------------------------ agents' tools

  toolBlueprint(this: Runner, threadId: string, role: BlueprintRole): { st: ThreadState; bp: BlueprintRecord } {
    const st = this.mustGet(threadId);
    if (this.blueprintRole(threadId) !== role) throw new Error(`This tool is only for a blueprint's ${role === 'build' ? 'build' : role === 'sideChat' ? 'side chat' : role} thread.`);
    const bp = this.blueprintStore().get(st.rec.blueprintId!);
    if (!bp) throw new Error("This thread's blueprint has been deleted.");
    return { st, bp };
  },

  askRound(this: Runner, threadId: string, raw: { title?: unknown; summary?: unknown; questions?: unknown; assumptions?: unknown; moot?: unknown }): string {
    const { bp } = this.toolBlueprint(threadId, 'blueprint');
    if (bp.status === 'building' || bp.status === 'done') throw new Error(`${bp.title} is ${bp.status === 'done' ? 'built' : 'being built'}, so its answers are locked. Tell the user what you'd ask instead; a change goes to the build thread.`);
    const round = checkRound(raw, `r${bp.rounds.length + 1}`, bp.folder);
    // Checked on a copy first, so a bad id changes nothing.
    applyMoot(structuredClone(bp.rounds), raw.moot);
    const moot = applyMoot(bp.rounds, raw.moot);
    bp.rounds.push(round);
    bp.status = 'waiting';
    delete bp.tooSmall;
    this.saveBlueprint(bp, { type: 'blueprint.round', round: publicRound(round) });
    const n = round.questions.length;
    const ids = round.questions.map((q) => q.id).join(', ');
    return `${round.title} is up for the user (${n} ${n === 1 ? 'question' : 'questions'}${ids ? `: ${ids}` : ''}, ${round.assumptions.length} assumed${moot ? `, ${moot} earlier marked moot` : ''}). End your turn now; the answers come as the next message. The form shows the round, so keep your reply to a line or two and don't repeat the questions.`;
  },

  tooSmall(this: Runner, threadId: string, why: string): string {
    const { bp } = this.toolBlueprint(threadId, 'blueprint');
    const text = typeof why === 'string' ? why.trim() : '';
    if (!text) throw new Error('Say why in a sentence.');
    if (bp.rounds.length) throw new Error('too_small is for your first move, and this blueprint has rounds already.');
    bp.tooSmall = { why: oneLine(text, 500), at: this.isoNow() };
    this.saveBlueprint(bp, { type: 'blueprint.tooSmall', why: bp.tooSmall.why });
    return 'The user sees that it looks small enough for a normal thread. End your turn: they start one, or say "Ask me anyway" and you put a round.';
  },

  blueprintWritten(this: Runner, threadId: string, raw: { title?: unknown; steps?: unknown }): string {
    const { bp } = this.toolBlueprint(threadId, 'blueprint');
    const missing = ['spec.md', 'answers.md'].filter((f) => !fs.existsSync(path.join(bp.path, f)));
    if (missing.length) throw new Error(`${missing.join(' and ')} ${missing.length === 1 ? "isn't" : "aren't"} in ${bp.path} yet. Write ${missing.length === 1 ? 'it' : 'them'} there first.`);
    const title = typeof raw.title === 'string' ? oneLine(raw.title, 200) : '';
    if (!title) throw new Error('title is required.');
    if (!Array.isArray(raw.steps) || !raw.steps.length || raw.steps.length > 60) throw new Error('steps must list between 1 and 60 steps, as in the spec.');
    const ids = new Set<string>();
    const before = new Map(bp.steps.map((s) => [s.id, s]));
    const steps: BlueprintStep[] = raw.steps.map((s, i) => {
      const r = (s ?? {}) as Record<string, unknown>;
      const id = typeof r.id === 'string' && r.id.trim() ? r.id.trim().slice(0, 60) : `s${i + 1}`;
      const stitle = typeof r.title === 'string' ? oneLine(r.title, 300) : '';
      if (!stitle) throw new Error(`steps[${i}] needs a title.`);
      if (ids.has(id)) throw new Error(`Two steps have the id ${id}.`);
      ids.add(id);
      const done = before.get(id)?.done;
      return { id, title: stitle, ...(done ? { done } : {}) };
    });
    const spec = fs.readFileSync(path.join(bp.path, 'spec.md'), 'utf8');
    this.blueprintStore().writeSnapshot(bp.id, spec);
    this.bpChecked.delete(bp.id);
    // Written in answer to the check's round: it isn't checked again, or
    // check rounds would never stop.
    const afterCheck = bp.rounds.slice(bp.roundsAtWrite ?? 0).some((r) => r.kind === 'check');
    bp.title = title;
    bp.steps = steps;
    bp.status = bp.builds.length ? 'building' : 'ready';
    bp.roundsAtWrite = bp.rounds.length;
    delete bp.specStale;
    delete bp.editedByHand;
    delete bp.awaitingSpec;
    if (!afterCheck) delete bp.checked;
    this.saveBlueprint(bp, { type: 'blueprint.written', steps: structuredClone(steps), path: bp.path });
    let check = '';
    const project = this.projects?.record(bp.projectId);
    if (project?.blueprints?.check !== false && !afterCheck) {
      try {
        this.startBlueprintCheck(bp);
        check = ' A check of the spec against the code has started; what it finds comes to the user as a round, and their answers to you.';
      } catch (e) {
        check = ` The check didn't start: ${(e as Error).message}`;
      }
    }
    return `${title} is ready to build, with ${steps.length} ${steps.length === 1 ? 'step' : 'steps'}.${check} End your turn.`;
  },

  proposeAnswer(this: Runner, threadId: string, answer: unknown): string {
    const { st, bp } = this.toolBlueprint(threadId, 'sideChat');
    const questionId = st.rec.blueprintQuestionId!;
    const q = bp.rounds.flatMap((r) => r.questions).find((x) => x.id === questionId);
    if (!q) throw new Error('The question this side chat is about has gone.');
    const value = answer && typeof answer === 'object' && !Array.isArray(answer) ? answer : { value: answer };
    // Files from the Mac are the user's to add: a side chat that can read
    // anywhere mustn't get one copied into the repo by a Use.
    if (q.kind === 'upload') {
      const v = (value as { value?: unknown }).value;
      if (typeof v !== 'string' || path.isAbsolute(v.trim()) || v.trim().startsWith('~')) throw new Error('An upload is a file the user adds in the form. Propose it in words instead: what file, and why.');
      bp.proposals = { ...bp.proposals, [questionId]: { answer: { value: v.trim() }, threadId, at: this.isoNow() } };
      this.blueprintStore().put(bp);
      this.emit(st, { type: 'blueprint.proposal', blueprintId: bp.id, questionId, answer: { value: v.trim() } }, st.rt.turn?.turnId);
      return 'Proposed in words. The user adds the file in the form themselves.';
    }
    const a = checkAnswer(q, value);
    if (a.value === undefined) throw new Error('answer is required.');
    delete a.changedAt;
    delete a.fromSideChat;
    bp.proposals = { ...bp.proposals, [questionId]: { answer: a, threadId, at: this.isoNow() } };
    this.blueprintStore().put(bp);
    this.emit(st, { type: 'blueprint.proposal', blueprintId: bp.id, questionId, answer: a }, st.rt.turn?.turnId);
    const said = answerText(q, a).trimEnd();
    return `Proposed: ${said}${/[.!?]$/.test(said) ? '' : '.'} The user presses Use to put it in the form; nothing changes until then.`;
  },

  reportCheck(this: Runner, threadId: string, findings: unknown): string {
    const { st, bp } = this.toolBlueprint(threadId, 'check');
    if (!Array.isArray(findings)) throw new Error('findings must be a list (empty when nothing was found).');
    if (findings.length > MAX_QUESTIONS) throw new Error(`At most ${MAX_QUESTIONS} findings, the most important first.`);
    const at = this.isoNow();
    bp.checked = { at, findings: findings.length };
    if (!findings.length) {
      this.saveBlueprint(bp);
      return 'Noted: nothing found. End your turn.';
    }
    const round = findingsRound(findings as { text: string; question?: unknown }[], `r${bp.rounds.length + 1}`, st.rec.title, bp.folder);
    bp.rounds.push(round);
    // Once it's being built, answers are locked: the round is there to
    // read, and the blueprint stays building (or done).
    if (bp.status !== 'building' && bp.status !== 'done') bp.status = 'waiting';
    this.saveBlueprint(bp, { type: 'blueprint.round', round: publicRound(round) });
    return `The user has your ${findings.length} ${findings.length === 1 ? 'finding' : 'findings'} as a round in the blueprint's form; their answers go to the blueprint's agent. End your turn with needs "nothing" and no asks: they answer in the form, not here.`;
  },

  updateBlueprintStep(this: Runner, threadId: string, args: { step?: unknown; note?: unknown; done?: unknown }): string {
    const { st, bp } = this.toolBlueprint(threadId, 'build');
    const note = typeof args.note === 'string' ? oneLine(args.note, 1000) : '';
    if (!note) throw new Error('note is required: a sentence on what you did.');
    const at = this.isoNow();
    let body: EventBody;
    let said: string;
    if (args.step !== undefined && args.step !== null && args.step !== '') {
      const want = String(args.step).trim();
      const index = bp.steps.findIndex((s) => s.id === want);
      const i = index >= 0 ? index : /^\d+$/.test(want) && Number(want) >= 1 && Number(want) <= bp.steps.length ? Number(want) - 1 : bp.steps.findIndex((s) => s.title.toLowerCase() === want.toLowerCase());
      if (i < 0) throw new Error(`No step ${want}. The steps: ${bp.steps.map((s, n) => `${n + 1} (${s.id}) ${s.title}`).join('; ')}.`);
      const step = bp.steps[i];
      step.done = { at, note, threadId };
      const left = bp.steps.filter((s) => !s.done).length;
      if (!left) bp.status = 'done';
      this.emit(st, { type: 'system.note', text: `Step ${i + 1} of ${bp.steps.length} done: ${step.title}. ${note}` }, st.rt.turn?.turnId);
      body = { type: 'blueprint.step', stepId: step.id, done: { ...step.done } };
      said = left ? `Marked step ${i + 1} done; ${left} to go.` : 'Marked the last step done: the blueprint is done.';
    } else if (args.done === true) {
      bp.status = 'done';
      this.emit(st, { type: 'system.note', text: `Blueprint done: ${note}` }, st.rt.turn?.turnId);
      body = { type: 'blueprint.step', all: true };
      said = 'Marked the whole blueprint done.';
    } else {
      throw new Error('Give step (its id or number), or done: true for the whole blueprint.');
    }
    this.saveBlueprint(bp, body);
    return said;
  },
};

export type BlueprintsPart = RunnerPart<typeof blueprintsPart>;

// An upload is copied into the blueprint's attachments/ (the one place the
// runner writes in a repo besides deleting), and kept as a path relative
// to the blueprint folder. A files answer is kept relative to the project
// folder, and must be in it.
const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

function placeFiles(bp: BlueprintRecord, round: RoundRecord, answers: Record<string, BlueprintAnswer>): Record<string, BlueprintAnswer> {
  for (const [id, a] of Object.entries(answers)) {
    const q = round.questions.find((x) => x.id === id);
    if (!q || !Array.isArray(a.value)) continue;
    if (q.kind === 'files') {
      a.value = a.value.map((p) => {
        const abs = path.resolve(bp.folder, p);
        const rel = path.relative(bp.folder, abs);
        if (!rel || rel.startsWith('..') || path.isAbsolute(rel)) throw bad(`${p} isn't in ${bp.folder}.`);
        return rel;
      });
    } else if (q.kind === 'upload') {
      a.value = a.value.map((p) => {
        const abs = path.resolve(bp.path, p);
        if (strictlyInside(abs, bp.path)) return path.relative(bp.path, abs);
        let size: number;
        try {
          const st = fs.statSync(abs);
          if (!st.isFile()) throw new Error();
          size = st.size;
        } catch {
          throw bad(`File not found: ${p}`);
        }
        if (size > MAX_UPLOAD_BYTES) throw bad(`${path.basename(abs)} is over 50 MB.`);
        const dir = path.join(bp.path, 'attachments');
        fs.mkdirSync(dir, { recursive: true });
        const ext = path.extname(abs);
        const base = path.basename(abs, ext).replace(/[^\p{L}\p{N}._ -]+/gu, '-') || 'file';
        let name = `${base}${ext}`;
        for (let n = 2; fs.existsSync(path.join(dir, name)); n++) name = `${base}-${n}${ext}`;
        fs.copyFileSync(abs, path.join(dir, name));
        return path.join('attachments', name);
      });
    }
  }
  return answers;
}

// The app's requests (docs/protocol.md, "Blueprints"), for main.ts's methods.
export function blueprintMethods(runner: Runner): Record<string, (p: Record<string, unknown>) => unknown> {
  const s = (p: Record<string, unknown>, k: string): string => {
    if (typeof p[k] !== 'string' || !p[k]) throw bad(`${k} must be a string`);
    return p[k] as string;
  };
  const opt = (p: Record<string, unknown>, k: string): string | undefined => {
    const v = p[k];
    if (v === undefined || v === null) return undefined;
    if (typeof v !== 'string') throw bad(`${k} must be a string`);
    return v;
  };
  return {
    'blueprints.list': (p) => runner.listBlueprints(opt(p, 'projectId')),
    'blueprints.create': (p) => {
      const np = p.newProject as { title?: unknown; folder?: unknown } | undefined;
      if (np !== undefined && (typeof np !== 'object' || typeof np?.title !== 'string' || typeof np?.folder !== 'string')) throw bad('newProject must have a title and a folder');
      return runner.createBlueprint({
        projectId: opt(p, 'projectId'),
        ...(np ? { newProject: { title: np.title as string, folder: np.folder as string } } : {}),
        text: opt(p, 'text') ?? '',
        images: Array.isArray(p.images) ? (p.images as ImageRef[]) : undefined,
        accountId: opt(p, 'accountId'),
        model: opt(p, 'model'),
      });
    },
    'blueprints.saveDraft': (p) => runner.saveBlueprintDraft(s(p, 'id'), s(p, 'roundId'), p.answers, p.note),
    'blueprints.continue': (p) => runner.continueBlueprint(s(p, 'id'), s(p, 'roundId'), p.answers, p.note, p.writeNow === true),
    'blueprints.askInstead': (p) => runner.askInsteadBlueprint(s(p, 'id'), s(p, 'roundId'), s(p, 'assumptionId')),
    'blueprints.sideChat': (p) => runner.blueprintSideChat(s(p, 'id'), s(p, 'questionId')),
    'blueprints.useProposal': (p) => runner.useBlueprintProposal(s(p, 'id'), s(p, 'questionId'), p.answer),
    'blueprints.check': (p) => runner.checkBlueprint(s(p, 'id')),
    'blueprints.start': (p) => {
      const mode = p.permissionMode;
      if (mode !== undefined && mode !== null && mode !== 'full' && mode !== 'ask' && mode !== 'auto' && mode !== 'plan') throw bad('permissionMode must be "full", "ask", "auto" or "plan"');
      return runner.startBlueprint({ id: s(p, 'id'), mode: p.mode, accountId: opt(p, 'accountId'), model: opt(p, 'model'), ...(mode ? { permissionMode: mode as PermissionMode } : {}) });
    },
    'blueprints.diff': (p) => runner.blueprintDiff(s(p, 'id')),
    'blueprints.tellAgent': (p) => runner.tellAgentBlueprint(s(p, 'id')),
    'blueprints.updateSpec': (p) => runner.updateSpecBlueprint(s(p, 'id')),
    'blueprints.tooSmallStart': (p) => runner.tooSmallStart(s(p, 'id')),
    'blueprints.delete': (p) => runner.deleteBlueprint(s(p, 'id')),
  };
}

