import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:roster/api/hub_client.dart';
import 'package:roster/models/agent.dart';
import 'package:roster/models/misc.dart';
import 'package:roster/models/transcript.dart';

// Shapes from docs/hub-api.md.
const agentsJson = '''
{"agents": [
  {"name": "infra", "role": "keeps the servers", "status": "working", "unread": 2,
   "machine": "srv-agents-01", "local": true, "agent": "infra@srv-agents-01"},
  {"name": "rator-firmware/ui", "status": "blocked", "unread": 0, "machine": "hp-probook",
   "local": false, "agent": "rator-firmware/ui@hp-probook",
   "stalled": {"error": "billing_error", "at": "2026-10-18T16:32:11+0200", "message": "x"}},
  {"name": "old", "status": "idle", "machine": "laptop", "local": false, "stale": "timed out",
   "agent": "old@laptop"}
 ],
 "machines": [
  {"name": "hp-probook", "local": false, "reachable": true, "error": null},
  {"name": "srv-agents-01", "local": true, "reachable": true, "error": null},
  {"name": "laptop", "local": false, "reachable": false, "error": "timed out"}
 ]}
''';

void main() {
  test('agents and machines', () {
    final s = AgentsSnapshot.fromJson(jsonDecode(agentsJson) as Map<String, dynamic>);
    expect(s.agents, hasLength(3));
    final infra = s.byId('infra@srv-agents-01')!;
    expect((infra.status, infra.unread, infra.local, infra.role), ('working', 2, true, 'keeps the servers'));
    final ui = s.byId('rator-firmware/ui@hp-probook')!;
    expect(ui.stalled!.error, 'billing_error');
    expect(ui.stalled!.gaveUp, isFalse);
    expect(s.byId('old@laptop')!.stale, 'timed out');
    final groups = s.grouped();
    expect(groups.map((g) => g.$1.name), ['srv-agents-01', 'hp-probook', 'laptop']);
    expect(groups.last.$1.reachable, isFalse);
    expect(groups.first.$2.single.name, 'infra');
  });

  test('a changed row has a new fingerprint', () {
    final a = Agent.fromJson({'name': 'a', 'machine': 'm', 'status': 'idle'});
    final b = Agent.fromJson({'name': 'a', 'machine': 'm', 'status': 'working'});
    expect(a.id, 'a@m');
    expect(a.fingerprint == b.fingerprint, isFalse);
  });

  test('transcript', () {
    final page = TranscriptPage.fromJson(jsonDecode('''
      {"agent": "infra@hp-probook", "session_id": "s1", "messages": [
        {"i": 412, "at": "2026-10-18T16:32:11+0200", "role": "user", "text": "hi"},
        {"i": 413, "at": "2026-10-18T16:32:15+0200", "role": "assistant", "text": "**hello**"},
        {"i": 414, "at": "2026-10-18T16:32:20+0200", "role": "tool", "tool": "Bash", "text": "git status", "result": "clean", "error": false}
      ], "next": 415}''') as Map<String, dynamic>);
    expect(page.next, 415);
    expect(page.sessionId, 's1');
    expect(page.messages.map((m) => m.role), ['user', 'assistant', 'tool']);
    expect(page.messages.first.at!.toUtc(), DateTime.utc(2026, 10, 18, 14, 32, 11));
    expect(page.messages.last.tool, 'Bash');
    expect(page.messages.last.result, 'clean');
  });

  test('screen with and without a dialog', () {
    final s = Screen.fromJson(jsonDecode('''
      {"agent": "a@m", "status": "blocked", "text": "…",
       "dialog": {"title": "Do you want to make this edit to viewer.js?",
                  "options": [{"key": "1", "label": "Yes"}, {"key": "3", "label": "No"}]}}''') as Map<String, dynamic>);
    expect(s.dialog!.options.map((o) => o.key), ['1', '3']);
    expect(Screen.fromJson({'status': 'idle', 'text': '', 'dialog': null}).dialog, isNull);
  });

  test('devices and push payloads', () {
    final d = Device.fromJson({'id': 'd1', 'name': 'Pixel', 'created': 'x', 'last_seen': 'y', 'push': true, 'current': true});
    expect((d.id, d.push, d.current, d.lastSeen), ('d1', true, true, 'y'));
    final p = PushPayload.tryParse(utf8.encode('{"type": "blocked", "agent": "a@m", "title": "a is blocked", "body": "Edit?"}'))!;
    expect((p.type, p.agent, p.title), ('blocked', 'a@m', 'a is blocked'));
    expect(PushPayload.tryParse(utf8.encode('not json')), isNull);
  });

  test('hub URLs', () {
    expect(normalizeHubUrl('roster.example.com/').toString(), 'https://roster.example.com');
    expect(normalizeHubUrl(' http://10.0.0.1:8790 ').toString(), 'http://10.0.0.1:8790');
  });
}
