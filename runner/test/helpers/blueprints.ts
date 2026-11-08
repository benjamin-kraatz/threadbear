// A runner with projects, a project with one repo folder, and the
// threadbear tools as a given thread's agent has them, for the blueprint
// tests (blueprint-tools.test.ts, blueprint-flow.test.ts).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { makeHarness, tmpDir } from './fakes.ts';
import { Projects } from '../../src/projects.ts';
import { FakeClock } from '../../src/clock.ts';
import { nullLogger } from '../../src/log.ts';
import { buildThreadbearTools } from '../../src/threadbear-mcp.ts';

export function blueprintSetup() {
  const root = tmpDir(); // the user's home, for ~/.threadbear/blueprints/template.md
  const repo = fs.realpathSync(tmpDir());
  const home = tmpDir();
  const projects = new Projects({ home, clock: new FakeClock(), log: nullLogger, userHome: root });
  const h = makeHarness(home, {}, { projects, panelsRoot: root });
  projects.start(h.runner);
  const project = projects.create({ title: 'App', folders: [repo], by: 'mike' });
  const session = (threadId: string) => {
    const s = h.adapter.sessions.filter((x) => x.opts.threadId === threadId).at(-1);
    assert.ok(s, `a session for ${threadId}`);
    return s;
  };
  const tools = (threadId: string) => {
    const list = buildThreadbearTools(h.runner, threadId, Date.now, undefined, undefined, undefined, { sleep: async () => {} });
    const call = async (name: string, args: Record<string, unknown> = {}) => {
      const t = list.find((x) => x.name === name);
      assert.ok(t, `tool ${name}`);
      const r = (await t.handler(args as never, {})) as { content: { text: string }[]; isError?: boolean };
      return { text: r.content.map((c) => c.text).join('\n'), error: Boolean(r.isError) };
    };
    return { names: list.map((t) => t.name), call };
  };
  const create = (text = 'Add a dark mode to the app') => {
    const r = h.runner.createBlueprint({ projectId: project.id, text, accountId: 'claude-3' });
    session(r.thread.id).init();
    return r;
  };
  const writeSpec = (bpPath: string, spec = '# Dark mode\n\n## Overview\nDark.\n\n## Steps\n- [ ] Colours\n- [ ] Toggle\n') => {
    fs.mkdirSync(bpPath, { recursive: true });
    fs.writeFileSync(path.join(bpPath, 'spec.md'), spec);
    fs.writeFileSync(path.join(bpPath, 'answers.md'), '# Answers\n');
  };
  const events = (threadId: string) => h.events(threadId);
  return { h, projects, project, repo, root, session, tools, create, writeSpec, events };
}

export const ROUND = {
  title: 'Scope',
  summary: 'A dark mode for the app.',
  questions: [
    { id: 'q1', text: 'Which screens?', kind: 'multi', options: [{ id: 'a', label: 'Settings' }, { id: 'b', label: 'Sidebar' }] },
    { id: 'q2', text: 'Follow the system?', options: [{ id: 'yes', label: 'Yes' }, { id: 'no', label: 'No' }], recommended: { option: 'yes', why: 'Most apps do' } },
    { id: 'q3', text: 'What should it be called?', kind: 'text', youDecide: false },
  ],
  assumptions: [{ id: 'a1', text: 'Colours come from the asset catalog', why: 'They all do today' }],
};

export const STEPS = [{ id: 's1', title: 'Colours' }, { id: 's2', title: 'Toggle' }];
