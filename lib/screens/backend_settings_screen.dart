import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/context_l10n.dart';
import '../services/backend_api_service.dart';

class BackendSettingsScreen extends ConsumerStatefulWidget {
  static const routeName = 'backend-settings';

  const BackendSettingsScreen({super.key});

  @override
  ConsumerState<BackendSettingsScreen> createState() =>
      _BackendSettingsScreenState();
}

class _BackendSettingsScreenState extends ConsumerState<BackendSettingsScreen> {
  final _controller = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool? _reachable;
  String? _effectiveBaseUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final current = await BackendApiService.getBaseUrlOverride();
    final effective = await BackendApiService.getEffectiveBaseUrl();
    if (!mounted) return;

    setState(() {
      _controller.text = current ?? '';
      _effectiveBaseUrl = effective;
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;

    final raw = _controller.text.trim();
    setState(() {
      _saving = true;
    });

    try {
      await BackendApiService.setBaseUrlOverride(raw.isEmpty ? null : raw);
      final effective = await BackendApiService.getEffectiveBaseUrl();
      if (!mounted) return;
      setState(() {
        _effectiveBaseUrl = effective;
      });
      await _checkHealth();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.backendSaved)),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _reset() async {
    await BackendApiService.setBaseUrlOverride(null);
    await _load();
    if (!mounted) return;
    setState(() {
      _reachable = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.backendResetDone)),
    );
  }

  Future<void> _checkHealth() async {
    final api = ref.read(backendApiServiceProvider);
    final ok = await api.health();
    if (!mounted) return;
    setState(() {
      _reachable = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final statusText = _reachable == null
        ? l10n.backendStatusUnknown
        : (_reachable!
            ? l10n.backendStatusConnected
            : l10n.backendStatusDisconnected);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.backendSettingsTitle),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _reset,
            child: Text(l10n.backendReset),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.backendCurrentEffective(_effectiveBaseUrl ?? ''),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _controller,
                      decoration: InputDecoration(
                        labelText: l10n.backendBaseUrlLabel,
                        hintText: l10n.backendBaseUrlHint,
                        border: const OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _save(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: _saving ? null : _save,
                            child: Text(_saving
                                ? l10n.backendSaving
                                : l10n.backendSave),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving ? null : _checkHealth,
                            child: Text(
                              l10n.backendConnectivityCheck(statusText),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(l10n.backendTipLan),
                  ],
                ),
              ),
      ),
    );
  }
}
