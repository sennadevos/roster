// A pretend roster-hub for looking at the web app: serves build/web and
// answers /v1/* (docs/hub-api.md) with made-up but realistic data: agents on
// three machines in every status, a blocked one with a form dialog, a
// stalled one, unread mail, an unreachable peer and long transcripts. Any
// bearer token is accepted. Node only, no packages.
//
//   node tool/preview/fake_hub.mjs [port] [build/web]
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const port = Number(process.argv[2] ?? 8790);
const root = path.resolve(process.argv[3] ?? 'build/web');

function stamp(minutesAgo) {
  const d = new Date(Date.now() - minutesAgo * 60000 + 2 * 3600000);
  return d.toISOString().slice(0, 19) + '+0200';
}

const machines = [
  { name: 'srv-agents-01', local: true, reachable: true, error: null },
  { name: 'hp-probook', local: false, reachable: true, error: null },
  { name: 'pi-lab', local: false, reachable: false, error: 'timed out after 5 s' },
];

const rows = [
  ['infra', 'srv-agents-01', 'working', 'Keeps the servers, the reverse proxy and the backups in order', 3, 1, { model: 'opus', effort: 'high' }],
  ['infra/backups', 'srv-agents-01', 'idle', 'Restic snapshots of every host, nightly, with a restore drill each month', 22, 0, {}],
  ['infra/proxy', 'srv-agents-01', 'done', 'Caddy config for every public name, certificates and redirects', 48, 2, {}],
  ['roster', 'srv-agents-01', 'working', 'The roster CLI, its hub and the app', 1, 0, { model: 'opus', effort: 'xhigh', subagents: [
    { id: 'a1', type: 'Explore', label: 'Find where the hub debounces agent events', status: 'running', started_at: stamp(1.5), ended_at: null },
    { id: 'a2', type: 'general-purpose', label: 'Write tests for the subagents field in list --json', status: 'running', started_at: stamp(0.8), ended_at: null },
    { id: 'a3', type: 'Explore', label: 'List every caller of reconcile()', status: 'done', started_at: stamp(4), ended_at: stamp(1) },
  ] }],
  ['roster/app', 'srv-agents-01', 'blocked', 'Flutter app for Android and the web: list, chat, dialogs', 2, 4, { model: 'sonnet' }],
  ['roster/hub', 'srv-agents-01', 'idle', 'roster-hub: HTTP API, event stream and push', 95, 0, {}],
  ['sms-gateway', 'srv-agents-01', 'idle', 'Pixel SMS gateway → ntfy, with signed webhooks', 180, 0, { stalled: { error: 'billing_error', at: stamp(30), message: 'Your credit balance is too low' } }],
  ['rator-firmware', 'hp-probook', 'working', 'Rator 1 firmware lead: releases, reviews, the build', 6, 0, { model: 'opus', effort: 'max' }],
  ['rator-firmware/ui', 'hp-probook', 'blocked', 'LVGL screens for the touch display', 0.5, 1, {}],
  ['rator-firmware/ble', 'hp-probook', 'working', 'BLE pairing and the bridge protocol', 12, 0, { subagents: [
    { id: 'b1', type: 'Explore', label: 'How does the bridge acknowledge a bond?', status: 'running', started_at: stamp(3), ended_at: null },
  ] }],
  ['rator-firmware/tests', 'hp-probook', 'idle', 'HIL test rig and the nightly run', 300, 0, { stalled: { error: 'overloaded', at: stamp(4) } }],
  ['cad', 'hp-probook', 'done', 'Enclosure for the Pico restouch, v3 with the lid clips', 70, 0, {}],
  ['scratch-7f3a', 'hp-probook', 'unknown', null, 0.2, 0, { temp: true }],
  ['homelab', 'pi-lab', 'idle', 'Home Assistant, Zigbee and the heating schedule', 600, 0, {}],
  ['camera', 'pi-lab', 'working', 'Frigate on the Pi, motion zones', 40, 0, {}],
];

function agentRows(all) {
  const out = rows.map(([name, m, status, role, mins, unread, extra]) => {
    const mach = machines.find((x) => x.name === m);
    const r = {
      name, role, status, status_at: stamp(mins), joined_at: stamp(mins + 400), ended_at: null,
      unread, machine: m, local: mach.local, agent: `${name}@${m}`, harness: 'claude', backend: 'tmux',
      cwd: `/home/senna/src/${name.split('/')[0]}`, ...extra,
    };
    if (!mach.reachable) r.stale = mach.error;
    return r;
  });
  if (all) {
    out.push({ name: 'old-experiment', role: 'Tried the Matter bridge', status: 'gone', status_at: stamp(3000),
      ended_at: stamp(3000), unread: 0, machine: 'srv-agents-01', local: true, agent: 'old-experiment@srv-agents-01' });
  }
  return { agents: out, machines };
}

// --- transcripts -------------------------------------------------------------

const longReply = `Done. The list now groups by machine and sorts the agents that need you to the top.

## What changed

- \`AgentsSnapshot.grouped()\` keeps hub order, local first
- a **blocked** row gets a tinted background and a pill
- unread mail shows as a badge with the count

\`\`\`dart
List<(Machine, List<Agent>)> grouped() {
  final order = [...machines];
  order.sort((a, b) => a.local == b.local ? 0 : (a.local ? -1 : 1));
  return [for (final m in order) (m, agents.where((a) => a.machine == m.name).toList())];
}
\`\`\`

Tests pass (\`flutter test\`: 14 passed). One thing I was unsure of: whether *stalled* agents should sort above **blocked** ones. I kept blocked first, since a dialog is the one thing only you can answer.

> The hub debounces events by 300 ms, so a burst of status changes arrives as one snapshot.

| Status | Glyph | Colour |
|---|---|---|
| working | ● | amber |
| blocked | ▲ | red |
| idle | ○ | green |
`;

const tools = [
  ['Bash', 'git status --short', ' M app/lib/screens/agents_screen.dart\n M app/lib/widgets/status.dart\n?? app/tool/preview/'],
  ['Read', 'app/lib/screens/agents_screen.dart', '     1\timport \'package:flutter/material.dart\';\n     2\t\n     3\timport \'../app.dart\';\n…'],
  ['Grep', 'statusLook', 'app/lib/widgets/status.dart:4\napp/lib/screens/agents_screen.dart:212'],
  ['Edit', 'app/lib/widgets/status.dart', 'The file app/lib/widgets/status.dart has been updated.'],
  ['Bash', 'tool/flutter.sh flutter analyze', 'Analyzing app...\nNo issues found! (ran in 4.1s)'],
  ['Bash', 'tool/flutter.sh flutter test', '00:06 +14: All tests passed!'],
  ['Glob', 'app/lib/**/*.dart', 'app/lib/app.dart\napp/lib/main.dart\napp/lib/api/hub_client.dart\n… 19 files'],
  ['WebFetch', 'https://pub.dev/packages/flutter_markdown_plus', 'flutter_markdown_plus 1.0.12 — A markdown renderer for Flutter.'],
  ['Write', 'app/test/agents_test.dart', 'File created successfully at: app/test/agents_test.dart'],
  ['TodoWrite', '4 todos', 'Todos have been modified successfully.'],
  ['Task', 'Explore: where is the SSE parser', 'lib/api/sse.dart: SseParser, a StreamTransformer…'],
];

function transcriptFor(agent) {
  const msgs = [];
  let i = 1;
  let minutes = 240;
  const push = (m) => { msgs.push({ i, at: stamp(minutes), ...m }); i += 1 + (i % 3); minutes -= 0.7; };
  const rounds = agent.startsWith('roster/app') || agent.startsWith('rator-firmware/ui') ? 26 : 8;
  for (let r = 0; r < rounds; r++) {
    push({ role: 'user', text: [
      'The agents list feels flat. Can you make blocked agents stand out and put them at the top?',
      'Looks good. Now the conversation: tool calls take a lot of room, make them compact.',
      'Run the tests and commit when green.',
      'What does the hub send when a peer is unreachable?',
      'ok, go ahead',
    ][r % 5] });
    push({ role: 'assistant', text: r % 4 === 0 ? 'Let me look at how the list is built first.' : 'I\'ll check the current state, then make the change.' });
    const n = 2 + (r % 4);
    for (let k = 0; k < n; k++) {
      const [tool, text, result] = tools[(r * 3 + k) % tools.length];
      push({ role: 'tool', tool, text, result, error: tool === 'Bash' && r % 7 === 3 && k === 0 });
    }
    push({ role: 'assistant', text: r % 3 === 0 ? longReply : `Updated \`status.dart\`: each status now has a colour that reads in both themes, and *working* pulses gently.\n\nNext I'll wire the search field to \`/\`.` });
  }
  if (agent.startsWith('rator-firmware/ui') || agent.startsWith('roster/app')) {
    push({ role: 'user', text: 'Before you change the settings screen: ask me what I want there.' });
    push({ role: 'tool', tool: 'AskUserQuestion', text: '2 questions', result: null });
  } else if (agent.startsWith('infra@') || agent.startsWith('roster@')) {
    push({ role: 'tool', tool: 'Bash', text: 'journalctl -u roster-hub --since -10m', result: null });
  }
  return msgs;
}
const transcripts = new Map();
function transcript(agent) {
  if (!transcripts.has(agent)) transcripts.set(agent, transcriptFor(agent));
  return transcripts.get(agent);
}

const formDialog = {
  title: 'Which sections should Settings have?', multi: true,
  options: [
    { key: '1', label: 'Hub', detail: 'The hub URL and its version', checked: true },
    { key: '2', label: 'Devices', detail: 'Paired phones and browsers, with revoke', checked: true },
    { key: '3', label: 'Notifications', detail: 'Per type: blocked, finished, errors', checked: false },
    { key: '4', label: 'Appearance', detail: 'Light, dark or follow the system', checked: false },
  ],
  tabs: [{ label: 'Sections', done: false }, { label: 'Order', done: false }, { label: 'Submit', done: false }],
  actions: [{ label: 'Back', keys: ['Left'] }, { label: 'Next', keys: ['Right'] }],
};
const editDialog = {
  title: 'Do you want to make this edit to screens/home.c?',
  options: [
    { key: '1', label: 'Yes' },
    { key: '2', label: "Yes, and don't ask again this session", detail: 'shift+tab' },
    { key: '3', label: 'No, and tell Claude what to do differently' },
  ],
};

// --- server ------------------------------------------------------------------

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
  '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.otf': 'font/otf', '.css': 'text/css' };

function json(res, code, body) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

const clients = new Set();
let eventId = 0;

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  if (!p.startsWith('/v1/')) {
    let file = path.join(root, decodeURIComponent(p));
    if (!file.startsWith(root)) return json(res, 403, { error: 'no' });
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) return json(res, 404, { error: 'not found' });
    res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream' });
    return fs.createReadStream(file).pipe(res);
  }
  if (p === '/v1/version') return json(res, 200, { hub: '0.3.0', api: 1 });
  if (p === '/v1/pair') return json(res, 200, { token: 'tok-preview', device_id: 'dev-1' });
  if (!(req.headers.authorization ?? '').startsWith('Bearer ')) return json(res, 401, { error: 'unauthorized' });
  const delay = Number(process.env.FAKE_DELAY ?? 150);
  setTimeout(() => {
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      const q = Object.fromEntries(url.searchParams);
      const data = body ? JSON.parse(body) : {};
      switch (`${req.method} ${p}`) {
        case 'GET /v1/agents': return json(res, 200, agentRows(q.all === '1'));
        case 'GET /v1/transcript': {
          const all = transcript(q.agent);
          const limit = Number(q.limit ?? 200);
          let out;
          if (q.before) out = all.filter((m) => m.i < Number(q.before)).slice(-limit);
          else if (q.after) out = all.filter((m) => m.i > Number(q.after)).slice(0, limit);
          else out = all.slice(-limit);
          const last = all.at(-1)?.i ?? 0;
          return json(res, 200, { agent: q.agent, session_id: 's-' + q.agent, messages: out,
            next: out.length ? out.at(-1).i : (q.after ? Number(q.after) : last) });
        }
        case 'GET /v1/screen': {
          const row = agentRows(false).agents.find((a) => a.agent === q.agent);
          const dialog = row?.status !== 'blocked' ? null : q.agent.startsWith('roster/app') ? formDialog : editDialog;
          return json(res, 200, { agent: q.agent, status: row?.status ?? 'unknown', text: '', dialog });
        }
        case 'POST /v1/prompt': {
          const all = transcript(data.agent);
          all.push({ i: (all.at(-1)?.i ?? 0) + 1, at: stamp(0), role: 'user', text: data.text });
          return json(res, 200, { ok: true });
        }
        case 'POST /v1/keys': case 'POST /v1/resume': case 'POST /v1/kill': case 'POST /v1/push':
          return json(res, 200, { ok: true });
        case 'POST /v1/new': return json(res, 200, { agent: `${data.name || 'new-agent'}@${data.machine}` });
        case 'GET /v1/devices': return json(res, 200, { devices: [
          { id: 'dev-1', name: 'Web browser', created: stamp(3000), last_seen: stamp(0), push: false, current: true },
          { id: 'dev-2', name: 'Pixel 9', created: stamp(9000), last_seen: stamp(12), push: true, current: false },
        ] });
        case 'GET /v1/events': {
          res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
          res.write(`id: ${++eventId}\nevent: agents\ndata: ${JSON.stringify(agentRows(false))}\n\n`);
          clients.add(res);
          req.on('close', () => clients.delete(res));
          return undefined;
        }
        default: return json(res, 404, { error: 'not found' });
      }
    });
  }, p === '/v1/events' ? 0 : delay);
}).listen(port, () => console.log(`fake hub on http://127.0.0.1:${port}/ serving ${root}`));

setInterval(() => {
  for (const c of clients) c.write(`id: ${++eventId}\nevent: ping\ndata: {}\n\n`);
}, 25000);
