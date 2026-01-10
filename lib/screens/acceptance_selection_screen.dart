import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/library.dart';
import '../models/region.dart';
import '../services/procedure_acceptance_library_service.dart';
import 'acceptance_guide_screen.dart';

class AcceptanceSelectionScreen extends ConsumerStatefulWidget {
  static const routeName = 'acceptance-selection';

  const AcceptanceSelectionScreen({super.key});

  @override
  ConsumerState<AcceptanceSelectionScreen> createState() =>
      _AcceptanceSelectionScreenState();
}

class _AcceptanceSelectionScreenState
    extends ConsumerState<AcceptanceSelectionScreen> {
  bool _loading = true;
  List<LibraryItem> _libraries = [];

  @override
  void initState() {
    super.initState();
    _loadLibraries();
  }

  Future<void> _loadLibraries() async {
    final service = ref.read(procedureAcceptanceLibraryServiceProvider);
    await service.ensureLoaded();
    final libraries = await service.getAllLibraries();
    if (mounted) {
      setState(() {
        _libraries = libraries;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择工序验收分项'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '请选择要验收的分部分项：',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _libraries.length,
                      itemBuilder: (context, index) {
                        final library = _libraries[index];
                        return Card(
                          child: ListTile(
                            title: Text(library.name),
                            onTap: () {
                              // Create a default region for acceptance
                              final defaultRegion = Region(
                                id: '',
                                idCode: 'default_acceptance',
                                name: '验收部位',
                                parentIdCode: '',
                              );
                              context.goNamed(
                                AcceptanceGuideScreen.routeName,
                                extra: {
                                  'region': defaultRegion,
                                  'library': library,
                                },
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
