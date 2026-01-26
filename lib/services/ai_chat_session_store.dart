import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class AiChatSession {
  final String id;
  final String title;
  final int updatedAtMs;
  final List<Map<String, dynamic>> messages;

  const AiChatSession({
    required this.id,
    required this.title,
    required this.updatedAtMs,
    required this.messages,
  });

  AiChatSession copyWith({
    String? title,
    int? updatedAtMs,
    List<Map<String, dynamic>>? messages,
  }) {
    return AiChatSession(
      id: id,
      title: title ?? this.title,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      messages: messages ?? this.messages,
    );
  }

  factory AiChatSession.fromJson(Map<String, dynamic> json) {
    final id = (json['id']?.toString() ?? '').trim();
    final title = (json['title']?.toString() ?? '').trim();
    final updatedAtMs = int.tryParse(json['updatedAtMs']?.toString() ?? '') ??
        DateTime.now().millisecondsSinceEpoch;

    final rawMessages = json['messages'];
    final messages = <Map<String, dynamic>>[];
    if (rawMessages is List) {
      for (final m in rawMessages) {
        if (m is Map) {
          messages.add(m.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    }

    return AiChatSession(
      id: id.isEmpty ? _newId() : id,
      title: title,
      updatedAtMs: updatedAtMs,
      messages: messages,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'updatedAtMs': updatedAtMs,
      'messages': messages,
    };
  }

  static String _newId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    return 's_$now';
  }

  static AiChatSession newSession(
      {String? title, List<Map<String, dynamic>>? seed}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final t = (title ?? '').trim();
    return AiChatSession(
      id: _newId(),
      title: t,
      updatedAtMs: now,
      messages: seed ?? const [],
    );
  }
}

class AiChatSessionStore {
  static const _kSessions = 'ai_chat_sessions_v1';
  static const _kCurrentId = 'ai_chat_current_session_id_v1';

  static Future<List<AiChatSession>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessions);
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final out = <AiChatSession>[];
      for (final x in decoded) {
        if (x is Map) {
          out.add(AiChatSession.fromJson(
              x.map((k, v) => MapEntry(k.toString(), v))));
        }
      }
      out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(List<AiChatSession> sessions) async {
    final prefs = await SharedPreferences.getInstance();
    final data = sessions.map((s) => s.toJson()).toList(growable: false);
    await prefs.setString(_kSessions, jsonEncode(data));
  }

  static Future<String?> getCurrentId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_kCurrentId);
    return (id ?? '').trim().isEmpty ? null : id!.trim();
  }

  static Future<void> setCurrentId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentId, id);
  }

  static Future<AiChatSession> upsert(AiChatSession session) async {
    final sessions = await loadAll();
    final idx = sessions.indexWhere((s) => s.id == session.id);
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = session.copyWith(updatedAtMs: now);
    if (idx >= 0) {
      sessions[idx] = next;
    } else {
      sessions.insert(0, next);
    }
    await saveAll(sessions);
    await setCurrentId(next.id);
    return next;
  }

  static Future<void> deleteById(String id) async {
    final sessions = await loadAll();
    sessions.removeWhere((s) => s.id == id);
    await saveAll(sessions);

    final cur = await getCurrentId();
    if (cur == id) {
      final nextId = sessions.isNotEmpty ? sessions.first.id : '';
      final prefs = await SharedPreferences.getInstance();
      if (nextId.isEmpty) {
        await prefs.remove(_kCurrentId);
      } else {
        await prefs.setString(_kCurrentId, nextId);
      }
    }
  }
}
