import 'package:flutter/material.dart';

import '../app.dart';
import '../models/misc.dart';
import '../platform/platform.dart' show pushAvailable;
import '../state/app_state.dart';
import '../widgets/status.dart';

/// Hub URL, paired devices, notifications, unpair.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<Device>? _devices;
  String? _devicesError;
  String? _hubVersion;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_devices == null && _devicesError == null) _load();
  }

  Future<void> _load() async {
    final client = AppScope.read(context).client;
    if (client == null) return;
    try {
      final devices = await client.devices();
      final v = await client.version();
      if (mounted) {
        setState(() {
          _devices = devices;
          _devicesError = null;
          _hubVersion = 'hub ${v['hub']} · api ${v['api']}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _devicesError = '$e');
    }
  }

  Future<bool> _confirm(String title, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  Future<void> _revoke(Device d) async {
    final app = AppScope.read(context);
    if (!await _confirm(d.current ? 'Unpair this $deviceNoun?' : 'Revoke ${d.name}?', 'Revoke')) return;
    try {
      if (d.current) {
        await app.unpair();
        return;
      }
      await app.client!.revokeDevice(d.id);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editUrl() async {
    final app = AppScope.read(context);
    final ctl = TextEditingController(text: app.hubUrl.toString());
    final url = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Hub URL'),
        content: TextField(controller: ctl, keyboardType: TextInputType.url, autocorrect: false),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text), child: const Text('Save')),
        ],
      ),
    );
    ctl.dispose();
    if (url != null && url.trim().isNotEmpty) await app.setHubUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
          children: [
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Hub'),
              subtitle: Text([app.hubUrl.toString(), ?_hubVersion].join('\n')),
              // On web the hub is the one that served the page.
              onTap: app.hubLocked ? null : _editUrl,
            ),
            if (pushAvailable)
              SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Notifications'),
              subtitle: Text(app.pushProblem ?? 'Through the ntfy app (UnifiedPush)'),
              value: app.notifications,
              onChanged: app.setNotifications,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Devices', style: theme.textTheme.titleSmall),
            ),
            if (_devicesError != null)
              ListTile(title: Text(_devicesError!, style: TextStyle(color: theme.colorScheme.error)))
            else if (_devices == null)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
            else
              for (final d in _devices!)
                ListTile(
                  leading: Icon(d.current ? Icons.smartphone : Icons.phone_android_outlined),
                  title: Text(d.current ? '${d.name} (this $deviceNoun)' : d.name),
                  subtitle: Text([
                    if (d.lastSeen != null) 'last seen ${d.lastSeen}',
                    if (d.push) 'push',
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Revoke',
                    onPressed: () => _revoke(d),
                  ),
                ),
            const Divider(),
            ListTile(
              leading: Icon(Icons.link_off, color: theme.colorScheme.error),
              title: Text('Unpair this $deviceNoun', style: TextStyle(color: theme.colorScheme.error)),
              onTap: () async {
                if (await _confirm('Unpair this $deviceNoun?', 'Unpair')) await app.unpair();
              },
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}
