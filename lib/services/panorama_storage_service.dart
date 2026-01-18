import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/panorama_session.dart';

final panoramaStorageServiceProvider = Provider<PanoramaStorageService>((ref) {
  return PanoramaStorageService();
});

class PanoramaStorageService {
  Future<Directory> _rootDir() async {
    final doc = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(doc.path, 'panorama_sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> sessionDir(String sessionId) async {
    final root = await _rootDir();
    final dir = Directory(p.join(root.path, sessionId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _sessionJsonFile(String sessionId) async {
    final dir = await sessionDir(sessionId);
    return File(p.join(dir.path, 'session.json'));
  }

  String _newId() => DateTime.now().millisecondsSinceEpoch.toString();

  Future<PanoramaSession> createNewSession({String? title}) async {
    final id = _newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final session = PanoramaSession(
      id: id,
      createdAtMillis: now,
      title: title?.trim().isNotEmpty == true ? title!.trim() : '全景巡检-$id',
      floorPlan: null,
      nodes: const [],
      stage: 'capture',
    );
    await saveSession(session);
    return session;
  }

  Future<void> saveSession(PanoramaSession session) async {
    final f = await _sessionJsonFile(session.id);
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
      flush: true,
    );
  }

  Future<PanoramaSession?> loadSession(String sessionId) async {
    final f = await _sessionJsonFile(sessionId);
    if (!await f.exists()) return null;
    final text = await f.readAsString();
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return PanoramaSession.fromJson(decoded.cast<String, dynamic>());
  }

  Future<List<PanoramaSession>> listSessions() async {
    final root = await _rootDir();
    final out = <PanoramaSession>[];
    if (!await root.exists()) return out;

    final children = await root.list(followLinks: false).toList();
    for (final e in children) {
      if (e is! Directory) continue;
      final sessionId = p.basename(e.path);
      final s = await loadSession(sessionId);
      if (s != null) out.add(s);
    }

    out.sort((a, b) => b.createdAtMillis.compareTo(a.createdAtMillis));
    return out;
  }

  Future<File> copyIntoSession(
    String sessionId,
    File source, {
    required String relativeTargetName,
  }) async {
    final dir = await sessionDir(sessionId);
    final target = File(p.join(dir.path, relativeTargetName));
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    return source.copy(target.path);
  }

  Future<File> createNodeFile(
    String sessionId,
    String nodeId, {
    required String fileName,
  }) async {
    final dir = await sessionDir(sessionId);
    final nodeDir = Directory(p.join(dir.path, 'nodes', nodeId));
    if (!await nodeDir.exists()) {
      await nodeDir.create(recursive: true);
    }
    return File(p.join(nodeDir.path, fileName));
  }

  Future<void> deleteSession(String sessionId) async {
    final dir = await sessionDir(sessionId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<void> deleteAllSessions() async {
    final root = await _rootDir();
    if (!await root.exists()) return;

    final children = await root.list(followLinks: false).toList();
    for (final e in children) {
      if (e is Directory) {
        await e.delete(recursive: true);
      } else if (e is File) {
        await e.delete();
      }
    }
  }

  Future<void> deleteNodeArtifacts(String sessionId, String nodeId) async {
    final dir = await sessionDir(sessionId);

    final nodeDir = Directory(p.join(dir.path, 'nodes', nodeId));
    if (await nodeDir.exists()) {
      await nodeDir.delete(recursive: true);
    }

    // Also remove any legacy pano file stored at session root.
    if (await dir.exists()) {
      final entries = await dir.list(followLinks: false).toList();
      for (final e in entries) {
        if (e is! File) continue;
        final base = p.basename(e.path);
        if (base.startsWith('node_${nodeId}_pano')) {
          await e.delete();
        }
      }
    }
  }
}
