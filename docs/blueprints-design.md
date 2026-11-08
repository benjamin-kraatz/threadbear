# Blueprints: plan a feature by answering questions (8 Nov 2026)

Benjamin's design, settled in conversation on 8 Nov 2026. This is the
source of truth while it's being built; the contract lands in
`docs/protocol.md` ("Blueprints") and the user's view in `docs/guide.md`.
Mockups are in `docs/blueprints-design/`.

## The idea

When Benjamin asks an agent for a big feature, the good threads start the
same way: the agent asks questions, he answers, and the answers together
are the feature. Blueprints makes that a thing in the app rather than a
habit.

You describe a feature, in a line or at length. The agent reads the code
and puts a round of questions: single choice, several choices, free text,
a number, files from the repo, a file from your Mac. You answer, or press
"you decide", or open a side chat about one question with an agent that
has the context and can read the code. The agent reads the round, asks
more if it needs to, and when it's clear writes a spec into the repo. From
there you save it for later, start a thread to build it, or start a thread
that orchestrates subagents to build it. The spec stays in the repo and
the panel until you delete it, and the thread that builds it ticks the
steps off as it goes.

## What it isn't

- Not a plan gate. The spec is the plan; a build thread never asks you to
  approve a second one (see "Starting a build").
- Not a phone feature yet. The iPhone app shows one line and tells you to
  open it on your Mac.
- Not an experiment. It's on in every copy; "Show Blueprints" in Settings
  > General (on by default) hides the button. `docs/forking.md` says
  where it lives and how to take it out.

## Words

- **Blueprint**: the thing. A folder in the repo with a spec, and a thread
  that wrote it. "New blueprint", "Blueprints" (the panel), "Start from
  blueprint".
- **Round**: one batch of questions the agent puts, answered together.
- **Side chat**: a small read-only thread about one question.
- **Check**: the cheap pass that reads the finished spec against the code.
- **Build thread**: a thread started from a blueprint.

Plain words in the UI, no eyebrow labels, no em dashes.

## Where it shows

**The Blueprints button** sits on the activity bar under the Librarian's
(`ActivityBar.swift`, after the Librarian button; `sidebarMode =
.blueprints`). It opens a sidebar list grouped by project, then by state:
Waiting for you, Drafting, Ready, Building, Done. A row shows the title,
the state in words ("Round 2 waiting", "Ready", "Step 2 of 5"), and the
cost so far. "New blueprint" is at the top of the list, and the form for
it lives in the centre column, where the empty state sits when nothing is
selected: project (or "New project…" with a title and a folder chosen
through the open panel), the description, Start. It was a popover first,
and the open panel closed it (Benjamin, 8 Nov), so it's a page.

**A blueprint is a thread** (`kind: "blueprint"` on its summary), so it
gets the event log, Usage, Needs you, accounts, models and restarts for
free. It also shows in the Inbox like any thread when it needs you, as a
row that opens the form. Opening it shows the form in the detail column
where the transcript would be (`DetailView.swift`, the last branch), with
a toggle in its header to see the transcript underneath. The composer
stays below the form.

**Side chats** are threads too, with `parentThreadId` set. The Inbox skips
threads with a parent; the form opens them in the pane beside the thread.

**Hiding it.** Nothing on the activity bar can be hidden on its own, so
"Show Blueprints" in Settings > General (on by default) hides the button.
A blueprint thread opened from the Inbox still shows its form. There's no
flag in the runner.

## The form

Rounds stack, newest at the bottom, each with its title and the agent's
"what I understood so far" line. A two-state switch in the form's header
shows one round at a time instead; the app remembers it. Earlier rounds
stay editable (see "Changing an answer").

Each question has a kind, and the agent picks how to put it:

| Kind | Draws as | Stores |
|---|---|---|
| `single` | radio buttons, or a menu past 6 options; with `other`, a written Other too | option id, or none with a written `other` |
| `multi` | checkboxes; with `other`, a written Other too | option ids, and any written `other` |
| `text` | a text field, multi-line | string |
| `number` | a field, with a slider when `min` and `max` are set | number |
| `files` | a picker rooted at the project folder, several allowed | paths relative to the project folder |
| `upload` | a drop target and a Choose button | files copied to `<blueprint>/attachments/`, paths relative to the blueprint folder |

A question may carry an `image` (a path the agent wrote or found) shown
above it, for "like this?". Every option may carry a `note`, one line
under its label.

Three ways to put a question, the agent's choice per question:

- **Needs you** (`youDecide: false`): no default. For taste and scope.
- **Open** (the default): "You decide" is a button on the question. If
  the agent sent a `recommended` option with a `why`, it shows as a muted
  line under the options with "Use" as a plain link-style control at its
  end, not a button (Benjamin, 8 Nov: a button looks too big against the
  text), and "You decide" means use the
  recommendation. Without one, the agent chooses when it reads the round.
- **Assumed**: not a question. Assumptions collect in a collapsed
  "Assumptions (4)" strip at the foot of the round, each with its one-line
  why. Expand one and press "Ask me instead" and it becomes an open
  question in the next round's message.

The agent is told: assume when the code or an earlier answer decides it,
recommend when you have a preference, ask plainly when it's taste.

An answer that came from a side chat is marked "from side chat" so you can
tell which ones you wrote yourself.

### Continue and the composer

One submit, "Continue", under the last question of the open round. It's
enabled once every needs-you question has an answer (an open question
with nothing in it counts as "you decide"). It shows a spinner and stops
taking clicks until the runner has the answers (`whileBusy`).

While a round is open the composer's placeholder is "Add a note for the
agent". Its text rides along with the answers when you press Continue.
Return in the composer does what Continue does when it's enabled;
otherwise it keeps the note and moves focus to the first unanswered
needs-you question. Pasted images in the composer go with the note as in
any thread.

From round two on, a muted "Write it now" button sits next to Continue: it
submits the round with a flag that tells the agent to write the spec with
what it has and treat the rest as "you decide".

### Changing an answer

Every answer stays editable; the agent works out what a change breaks.

- **Before the spec is written.** The answer shows "changed", Continue
  reads "Continue with changes", and the message carries the diff
  ("Question 2 was A, now B"). The agent re-checks later questions and
  re-asks the ones that moved.
- **Ready.** The blueprint goes back to Drafting with a banner, "The spec
  is older than your answers", and an "Update the spec" button, which
  sends the diff. The start buttons go until the agent has written the
  spec again. The previous spec is in git history.
- **Building or Done.** Answers lock. The control becomes "Send a change
  to the build thread", which is `threads.send` to the newest build
  thread, with the question and both answers in the text.

### Side chats

"Ask about this" on a question opens a side chat in the pane. The
per-question buttons ("Ask about this", "You decide") stay visible but
small and quiet, text not icons (Benjamin, 8 Nov: hover-only hurts
discoverability; they won't be used often). It's a real
thread: `parentThreadId` the blueprint's, `permissionMode: "plan"` so it
can read and not edit, the cheaper model by default (the project's
`defaults.models` for titles and the librarian; changeable from its
composer like any thread), in the project folder. Its first message is
built by the runner: the feature description, the rounds so far in
compact form (question, answer, or "unanswered"), and the one question
with its options. One side chat per question; opening it again resumes
the same thread.

The side chat has one extra tool, `propose_answer`, which draws a card in
the side chat with the proposed answer and a Use button. Use writes the
answer into the form, marked "from side chat". Nothing moves without
that click.

### Too small

The blueprint agent's first move is either a round or `too_small`. The
second draws a card in place of the form: "This looks like a small
change. Start it as a normal thread?" with "Start a thread" first (a
normal thread in the project folder with your description, and the
blueprint is deleted) and a muted "Ask me anyway" (sends "Ask me anyway"
and the agent must put a round).

## The files

In the project folder, under `.threadbear/blueprints/<slug>/`:

- `spec.md`. Agent-written, for the builder. Sections in this order:
  the title, Overview, Decisions, Assumptions, Steps (a checklist, each
  step with the files it expects to touch and the tests that cover it),
  Open points. The only file a build thread is pointed at.
- `answers.md`. Every question with your answer and the choices you
  didn't pick, verbatim, round by round. Read only when the spec leaves
  something unclear.
- `attachments/`. Files from `upload` answers.

Nothing of the runner's goes in the repo. Status, rounds, steps, which
threads built it and the spec snapshot live in the data dir
(`<home>/blueprints.json`, `<home>/blueprints/<id>/spec.snapshot.md`), so
marking a step never dirties the working tree, and a thread in a worktree
on another branch isn't confused by it. Progress still reaches the repo as
content: the build thread ticks the checkboxes in the spec's Steps section
as it works, and that's committed with the code.

The runner makes the slug from the description when the blueprint is
made (the agent has to know the folder before it writes), adding `-2` on a
collision. The folder is the project's first folder unless the project
says otherwise (see "Project settings").

**Worktrees.** A build thread is pointed at the spec by absolute path in
the project folder, so it works whether or not the spec is committed yet
(a worktree made from main doesn't have an uncommitted `.threadbear/`).

**Edited by hand.** The runner keeps a snapshot of `spec.md` as the agent
last wrote it. When it next reads the blueprint (the same lazy re-read as
patches, 15 seconds at most, and on `blueprints.list`) and the file
differs, the blueprint shows "edited by hand" with "Show changes" (a diff,
`diffLines` on the runner, the app's `DiffBuilder` to draw it) and "Tell
the agent" (sends the diff to the blueprint thread, which brings
`answers.md` into line or asks about it). The snapshot moves when the
agent next writes the spec. No git needed.

**Found blueprints.** A `spec.md` under a project folder with no state in
the data dir (a clone, a blueprint from another Mac) is listed as Ready
with no thread. Starting a build from it works; changing answers doesn't,
as there are none.

**Templates.** `.threadbear/blueprints/template.md` in a project folder,
and `~/.threadbear/blueprints/template.md` for every project, found the
way patches are. The text is guidance to the agent ("always settle:
telemetry, settings, docs to update"), not literal questions; it's
appended to the blueprint thread's instructions, and the agent folds it
into rounds where it fits.

## The check

The check runs once per rewrite that isn't itself the answer to a check
round, so check rounds end. Once a build has started its findings are a
round to read; answers stay locked.

When the spec is written and the project has the check on (default), the
runner starts a check thread: a child like a side chat, cheaper model,
plan mode, told to read `spec.md` against the code and report
contradictions and gaps with one tool, `report_check`. The runner turns
its findings into one more round in the blueprint (kind `check`, with the
check thread's name on it) and the blueprint waits for you. Your answers
go to the blueprint agent as a message with the findings, and it updates
the spec. So the check costs one cheap turn plus the spec update that was
needed anyway. A check with no findings shows "Checked, nothing found" in
the header. "Check the spec" in the header runs it again by hand, and the
project setting turns the automatic one off.

## Starting a build

Three buttons when a blueprint is Ready, and "Save for later" is just
leaving it there:

- **Start a thread.** A normal thread in the project folder, in the
  thread's normal permission mode (Plan first stays on the composer menu,
  never the default here). Its first message, built by the runner:

  > Build the blueprint at `<absolute path>/spec.md`. Read `answers.md`
  > beside it only where the spec leaves something unclear. Before
  > changing anything, say in a few lines how you'll go about step one:
  > the files you'll touch and the tests you'll run. When the spec
  > doesn't cover something, ask, don't guess. Mark each step done with
  > `update_blueprint` as you finish it, with a sentence on what you did,
  > and tick it in the spec's Steps section.

- **Start with subagents.** The same thread and message, plus a paragraph
  telling the lead agent to work the steps with subagents (one per step
  where they're independent), in this one worktree, and to mark steps
  itself.
- **Start as threads** (version two, not built yet). One thread per step,
  each its own worktree, landed in order. Needs steps with dependencies.

When a blueprint is Ready the rounds are folded (the check's round among
them) and the spec's steps show as a checklist card, with the start
buttons and "Check the spec" at the foot of that card (Benjamin's pick, 8
Nov). The banners (edited by hand, spec older than answers) stay in the
header.

A build thread gets `update_blueprint` and nothing else extra, a
`startedBy` of kind `blueprint` naming the blueprint, and `blueprintId`
on its record so the tool knows which blueprint it is. The blueprint is
Building while any build thread is live or has steps left, Done when the
builder marks it done or every step is done. Done blueprints move to the
Done group and stay in the repo until you delete them.

**Readback, not a gate.** The builder's first lines say what it will do
for step one. You read them in the transcript and interrupt if they're
wrong. Zero extra turns.

## Delete

"Delete blueprint" asks "Delete <title>? This removes
`.threadbear/blueprints/<slug>` from <folder> and archives its thread."
Then it removes `spec.md`, `answers.md` and `attachments/` from that
folder, then the folder if it's empty, and archives the thread and its
side chats. A folder with anything else in it is refused and left alone,
so a stray `dir` setting can never delete other work. There's no separate
"remove from the list": the files are the list.

## Cost

The form's header shows the blueprint's cost so far: its own thread plus
every side chat and check thread (`costUsd` summed over the children;
`blueprint.costUsd` on the summary).

## Project settings

Two new fields on `Project`, set from the project page and
`update_project`:

```ts
blueprints?: {
  folder?: string   // which project folder holds them; default the first
  dir?: string      // relative to it; default ".threadbear/blueprints"
  check?: boolean   // run the check when a spec is written; default true
}
```

## Models

The blueprint thread runs on the account's default model like any thread.
Side chats and the check thread default to the cheaper model
(`cfg.defaults.models` has a per-provider default; runner.json's
`defaults.smallModels` is the same for these children; Haiku when unset).
Both are changeable per thread from the composer's model chip.

## Protocol

The contract goes into `docs/protocol.md` under a new "Blueprints"
section; this is its content. Both sides stay tolerant of unknown fields.

### Types

```ts
type BlueprintStatus = "drafting" | "waiting" | "ready" | "building" | "done"

type Blueprint = {
  id: string                 // uuid
  projectId: string
  folder: string             // absolute, the project folder it lives in
  path: string               // absolute, the blueprint folder
  slug: string
  title: string
  status: BlueprintStatus
  threadId?: string          // the blueprint thread; absent for a found one
  rounds: Round[]
  steps: Step[]              // from blueprint_written and update_blueprint
  builds: { threadId: string; mode: "thread" | "subagents"; at: string }[]
  sideChats: Record<string, string>   // questionId -> threadId
  checkThreadId?: string
  checked?: { at: string; findings: number }
  editedByHand?: true        // spec.md differs from the agent's snapshot
  specStale?: true           // answers changed after the spec was written
  tooSmall?: { why: string; at: string }  // the agent's too_small, until it puts a round
  costUsd: number            // thread + children
  createdAt: string
  updatedAt: string
}

type Round = {
  id: string
  kind: "questions" | "check"
  title: string
  summary?: string           // "what I understood so far"
  questions: Question[]
  assumptions: { id: string; text: string; why: string }[]
  askInstead?: string[]      // assumption ids marked "Ask me instead"
  answers: Record<string, Answer>   // by question id; a draft until sent
  sent?: Record<string, Answer>     // the answers as last sent (no drafts), for "was A, now B"
  note?: string              // the composer's text, sent with the answers
  sentAt?: string            // set when Continue reached the runner
  writeNow?: true
}

type Question = {
  id: string
  text: string
  kind: "single" | "multi" | "text" | "number" | "files" | "upload"
  options?: { id: string; label: string; note?: string }[]   // single, multi
  recommended?: { option?: string; text?: string; why: string }
  youDecide: boolean         // default true; false means needs you
  min?: number; max?: number; step?: number                 // number
  several?: boolean          // files, upload: more than one
  other?: true               // single, multi: a written "Other" beside the options
  image?: string             // absolute path, shown above the question
  moot?: string              // set by a later round: why it no longer applies
}

type Answer = {
  value?: string | string[] | number   // by kind; files and upload: paths
  other?: string             // the written Other (question has other); single's value may be absent
  youDecide?: true
  usedRecommendation?: true
  fromSideChat?: true
  changedAt?: string         // changed since the round was last sent; cleared when it's sent
}

type Step = { id: string; title: string; done?: { at: string; note: string; threadId: string } }
```

`ThreadSummary` gains `kind?: "blueprint" | "sideChat" | "check"`,
`parentThreadId?: string`, and `blueprint?: Blueprint` on a blueprint
thread. `startedBy.kind` gains `"blueprint"` (label "Blueprint",
`threadId` the blueprint thread, `threadTitle` its title). `Project`
gains `blueprints?` (above).

### Requests (app to runner)

| method | params | result |
|---|---|---|
| `blueprints.list` | `{ projectId? }` | `{ blueprints: Blueprint[] }`. Scans the projects' folders for `.threadbear/blueprints/*/spec.md` (lazily, as patches are read) and merges with the data dir's state; found ones have no `threadId` |
| `blueprints.create` | `{ projectId?, newProject?: { title, folder }, text, images?, accountId?, model? }` | `{ blueprint, thread }`. Makes the blueprint thread in the project's blueprints folder and sends `text` as its first message. `newProject` makes the project first. `-32602` without one of `projectId` or `newProject` |
| `blueprints.saveDraft` | `{ id, roundId, answers, note? }` | `{ blueprint }`. Autosave of unsent answers; survives restarts |
| `blueprints.continue` | `{ id, roundId, answers, note?, writeNow? }` | `{ blueprint, turnId? }`. Marks the round sent and sends the answers to the blueprint thread as one `user.message` (see "Messages"). A round already sent: the changed answers go as a diff. `-32602` when a needs-you question has no answer |
| `blueprints.askInstead` | `{ id, roundId, assumptionId }` | `{ blueprint }`. Marks an assumption to be asked in the next message |
| `blueprints.sideChat` | `{ id, questionId }` | `{ threadId }`. Makes the side chat, or returns the one it has |
| `blueprints.useProposal` | `{ id, questionId, answer }` | `{ blueprint }`. Writes a side chat's proposed answer into the draft, `fromSideChat` |
| `blueprints.check` | `{ id }` | `{ threadId }`. Starts a check thread; `-32020` while one is running |
| `blueprints.start` | `{ id, mode: "thread" \| "subagents", accountId?, model?, permissionMode? }` | `{ threadId }`. Makes the build thread, with `blueprintId` on its record so `update_blueprint` finds the blueprint; `-32020` unless `ready`, `building` or `done`; `-32602` for a mode it doesn't know (`threads` is version two) |
| `blueprints.diff` | `{ id }` | `{ hunks }`. The agent's snapshot against `spec.md` on disk, in the shape `edit.diff` uses |
| `blueprints.tellAgent` | `{ id }` | `{ turnId }`. Sends the diff to the blueprint thread |
| `blueprints.updateSpec` | `{ id }` | `{ turnId }`. Sends the changed answers to the blueprint thread with "update the spec" |
| `blueprints.tooSmallStart` | `{ id }` | `{ threadId }`. Starts a normal thread with the description, removes the blueprint's state and folder (if the agent made one) and archives the blueprint thread |
| `blueprints.delete` | `{ id }` | `{}`. Removes the folder from the repo and archives the thread and its children |

Every one of these changes something on the runner, so the app wraps each
in `whileBusy` and the control shows it (EveryClickShowsTests).

### Events

Persisted in the blueprint thread's log:

| type | fields |
|---|---|
| `blueprint.round` | `round: Round` (without answers; the summary's `blueprint.rounds` carry the answers, drafts included, so the form renders from the summary). The agent put a round, or the check's findings became one |
| `blueprint.answered` | `roundId, answers, note?, writeNow?`. The user's submission; the same content goes to the agent as a `user.message` with `roundId` |
| `blueprint.tooSmall` | `why` |
| `blueprint.written` | `steps, path`. The agent said the spec is written |
| `blueprint.step` | `stepId, done: { at, note, threadId }` or `all: true`. Also on the build thread's log as a `system.note` |

State changes come through `thread.updated` with the new `blueprint` on
the summary. Clients that don't know these events see the `user.message`
rows and the `system.note`s, so a transcript still reads.

### Messages the runner writes

- **A round's answers**, to the blueprint agent, as the user: the round's
  title, then each question's text and answer ("you decide" where that was
  pressed, "unanswered" for an open question left empty, "Ask me instead:
  <assumption>" for those), the note, and "Write the spec now with what
  you have" when `writeNow`. A round sent before: only the changes, as
  "Question 2 was A, now B".
- **The check's findings**, as one round of kind `check`, and after
  the user answers, to the blueprint agent with "Update the spec".
- **Edited by hand**, to the blueprint agent: the hunks and "Bring
  answers.md into line, or ask me".
- **The build thread's first message**, as above.

### Tools for agents

Given only to the threads named (every other thread's one change is
`update_project`'s `blueprints` argument),
and `context-budget.json` measures each.

- Blueprint thread: `ask_round { title, summary?, questions, assumptions?, moot? }`
  (returns at once; the agent ends its turn; the answers arrive as a
  message), `too_small { why }`, `blueprint_written { title, steps:
  { id, title }[] }` (checks `spec.md` and `answers.md` exist in the
  blueprint folder, takes the snapshot, makes the blueprint Ready and
  starts the check if the project has it on).
- Side chat: `propose_answer { answer }` (an `Answer.value` by the
  question's kind; draws the card).
- Check thread: `report_check { findings: { text, question?: Partial<Question> }[] }`
  (each finding becomes a question of the check round; a finding without
  a `question` becomes a `text` one asking what to do).
- Build thread: `update_blueprint { step?, note, done?: true }` (`step`
  omitted with `done` marks the whole blueprint done).

The blueprint thread also gets instructions appended (`briefFor`): what a
blueprint is, the three ways to put a question, the file layout and the
spec's sections, the template text if any, and the too-small rule.

## In the app

- `BlueprintsList` in the sidebar (`sidebarMode = .blueprints`), grouped
  as above; `ActivityBar` button under the Librarian's.
- `BlueprintForm` in `DetailView`'s last branch when the thread's `kind`
  is `blueprint`: header (title, state, cost, layout switch, transcript
  toggle, Check the spec, the three start buttons when Ready, Delete in
  the ... menu), the rounds, the assumptions strip, Continue and Write it
  now, the too-small card, the edited-by-hand and spec-stale banners.
- Side chats open in the pane (`PaneSection.thread(id)` or the existing
  way a sub-agent is shown).
- While the thread's status is running or starting
  (`BlueprintRules.agentWorking`), the form shows the agent is at work in
  three places: a working line under the last round ("Working for 12s ·
  Read snooze.ts", the transcript's live action from
  `TranscriptModel.liveAction`, which the round replaces when it lands),
  the sidebar's turning arc before the state word in the header, and the
  same arc on the blueprint's row in the list. Benjamin asked for it on
  8 Nov after having to turn Transcript on to see anything happening.
- `ComposerView` placeholder and Return while a round is open.
- The Inbox skips threads with `parentThreadId`; a blueprint thread's
  row opens the form.
- Every control has a `.tip`. Every runner call is in `whileBusy`.
- The mock runner gets a `demo-blueprint` fixture with two rounds, one
  check round and a Ready spec, so the form is built against it.

## Build order

Each slice usable on its own.

1. **Runner.** Types, `blueprints.json` state, the blueprint thread kind
   and its tools, rounds in and answers out, `blueprint_written` and the
   snapshot, side chats and `propose_answer`, the check thread and
   `report_check`, the start modes and `update_blueprint`, the lazy scan
   and edited-by-hand diff, templates, project settings, `tb blueprint`
   (list, new, answer, continue, start) so a form can be answered from a
   terminal. Tests beside each.
2. **App.** The Blueprints list, the form with every field kind,
   Continue and the composer, Needs you rows, start buttons, delete.
3. **Side chats and the check** in the app: the pane, the Use card, the
   check round.
4. **Too small, edited by hand, spec stale** cards and banners.
5. **Polish and docs.** Cost in the header, step notes in the list, the
   guide, on-your-mac (the runner now writes files inside repos),
   forking, the protocol section proofread against the code.

## Open for version two

- Start as threads (one per step, own worktrees, landed in order).
- The form on the phone.
- A blueprint on another runner's project.
- Reusing a Done blueprint as the template for the next one.
