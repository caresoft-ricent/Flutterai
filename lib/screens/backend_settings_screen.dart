import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
        const SnackBar(content: Text('后端地址已保存')),
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
      const SnackBar(content: Text('已恢复默认后端地址')),
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
    final statusText =
        _reachable == null ? '未检测' : (_reachable! ? '已连接' : '未连接');

    return Scaffold(
      appBar: AppBar(
        title: const Text('后端设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _reset,
            child: const Text('恢复默认'),
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
                      '当前生效：${_effectiveBaseUrl ?? ''}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        labelText: '后端 API Base URL（可留空使用默认）',
                        hintText: 'http://192.168.1.10:8000',
                        border: OutlineInputBorder(),
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
                            child: Text(_saving ? '保存中…' : '保存'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _saving ? null : _checkHealth,
                            child: Text('连通性检测：$statusText'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '提示：真机联调时通常需要填写 Mac 的局域网 IP，例如 http://192.168.x.x:8000',
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
