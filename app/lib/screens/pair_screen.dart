import 'package:flutter/material.dart';

import '../app.dart';

/// Hub URL and the one-time code from `roster-hub pair`.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  final _form = GlobalKey<FormState>();
  late final _url = TextEditingController(text: AppScope.read(context).hubUrl.toString());
  final _code = TextEditingController();
  final _name = TextEditingController(text: 'Android phone');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).pair(_url.text, _code.text, _name.text);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reason = AppScope.of(context).unpairedReason;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Pair with a hub')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (reason != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(reason, style: TextStyle(color: theme.colorScheme.error)),
                ),
              Text('Run `roster-hub pair` on the hub machine and enter the code it prints.',
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
              TextFormField(
                controller: _url,
                decoration: const InputDecoration(labelText: 'Hub URL', border: OutlineInputBorder()),
                keyboardType: TextInputType.url,
                autocorrect: false,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'The hub URL' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('code'),
                controller: _code,
                decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder()),
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                maxLength: 8,
                validator: (v) => (v == null || v.trim().length != 8) ? 'The 8-character code' : null,
              ),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name for this phone', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              FilledButton(
                onPressed: _busy ? null : _pair,
                child: _busy
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Pair'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
