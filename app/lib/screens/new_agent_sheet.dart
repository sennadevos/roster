import 'package:flutter/material.dart';

import '../app.dart';
import '../widgets/status.dart';

/// A bottom sheet on a phone, a dialog on a wide window.
Future<void> showNewAgentSheet(BuildContext context) => MediaQuery.sizeOf(context).width >= splitViewWidth
    ? showDialog<void>(
        context: context,
        builder: (_) => const Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 560, child: NewAgentSheet()),
        ),
      )
    : showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const NewAgentSheet(),
      );

/// `POST /v1/new`: machine, directory, name, role and a first prompt.
class NewAgentSheet extends StatefulWidget {
  const NewAgentSheet({super.key});

  @override
  State<NewAgentSheet> createState() => _NewAgentSheetState();
}

class _NewAgentSheetState extends State<NewAgentSheet> {
  final _cwd = TextEditingController();
  final _name = TextEditingController();
  final _role = TextEditingController();
  final _prompt = TextEditingController();
  final _customModel = TextEditingController();
  String? _machine;

  /// null: the default model; [_other]: whatever is typed in [_customModel].
  String? _model;
  String? _effort;
  static const _other = '';
  static const _models = ['opus', 'sonnet', 'fable'];
  static const _efforts = ['low', 'medium', 'high', 'xhigh', 'max'];
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_cwd, _name, _role, _prompt, _customModel]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _create(String machine) async {
    final app = AppScope.read(context);
    setState(() => _busy = true);
    try {
      final agent = await app.client!.newAgent(
        machine: machine,
        cwd: _cwd.text,
        name: _name.text,
        role: _role.text,
        prompt: _prompt.text,
        model: _model == _other ? _customModel.text : _model,
        effort: _effort,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      openAgent(agent);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final machines = [
      for (final m in app.snapshot.machines)
        if (m.reachable) m.name,
    ];
    final local = app.snapshot.machines.where((m) => m.local).map((m) => m.name).firstOrNull;
    final machine = _machine ?? local ?? machines.firstOrNull;
    InputDecoration deco(String label, [String? hint]) =>
        InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder());
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New agent', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('It starts on that machine and joins the roster.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: machine,
              decoration: deco('Machine'),
              items: [for (final m in machines) DropdownMenuItem(value: m, child: Text(m))],
              onChanged: (v) => setState(() => _machine = v),
            ),
            const SizedBox(height: 12),
            TextField(controller: _cwd, decoration: deco('Directory', 'on that machine'), autocorrect: false),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: deco('Name', 'a random id when empty'), autocorrect: false),
            const SizedBox(height: 12),
            TextField(controller: _role, decoration: deco('Role')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _model,
              decoration: deco('Model'),
              items: [
                const DropdownMenuItem(value: null, child: Text('Default')),
                for (final m in _models) DropdownMenuItem(value: m, child: Text(m)),
                const DropdownMenuItem(value: _other, child: Text('Other…')),
              ],
              onChanged: (v) => setState(() => _model = v),
            ),
            if (_model == _other) ...[
              const SizedBox(height: 12),
              TextField(controller: _customModel, decoration: deco('Model name'), autocorrect: false),
            ],
            const SizedBox(height: 12),
            Text('Effort', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: [for (final e in _efforts) ButtonSegment(value: e, label: Text(e))],
                selected: {?_effort},
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _effort = s.firstOrNull),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _prompt, decoration: deco('First prompt'), minLines: 3, maxLines: 8),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || machine == null ? null : () => _create(machine),
              child: _busy
                  ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Start'),
            ),
          ],
        ),
      ),
    );
  }
}
