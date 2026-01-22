import 'dart:convert';

class BackendAcceptanceRecord {
  final int id;
  final String regionText;
  final String? buildingNo;
  final int? floorNo;
  final String? zone;

  final String? division;
  final String? subdivision;
  final String? item;
  final String? indicator;

  final String result;
  final String? photoPath;
  final String? remark;

  final DateTime createdAt;
  final DateTime? clientCreatedAt;

  final String? clientRecordId;

  String get resultZh => acceptanceResultZh(result);

  const BackendAcceptanceRecord({
    required this.id,
    required this.regionText,
    required this.buildingNo,
    required this.floorNo,
    required this.zone,
    required this.division,
    required this.subdivision,
    required this.item,
    required this.indicator,
    required this.result,
    required this.photoPath,
    required this.remark,
    required this.createdAt,
    required this.clientCreatedAt,
    required this.clientRecordId,
  });

  factory BackendAcceptanceRecord.fromJson(Map<String, dynamic> json) {
    return BackendAcceptanceRecord(
      id: (json['id'] as num).toInt(),
      regionText: (json['region_text'] as String?)?.trim() ?? '',
      buildingNo: json['building_no'] as String?,
      floorNo: (json['floor_no'] as num?)?.toInt(),
      zone: json['zone'] as String?,
      division: json['division'] as String?,
      subdivision: json['subdivision'] as String?,
      item: json['item'] as String?,
      indicator: json['indicator'] as String?,
      result: (json['result'] as String?)?.trim() ?? '',
      photoPath: json['photo_path'] as String?,
      remark: json['remark'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      clientCreatedAt: (json['client_created_at'] as String?) == null
          ? null
          : DateTime.parse(json['client_created_at'] as String),
      clientRecordId: json['client_record_id'] as String?,
    );
  }
}

String acceptanceResultZh(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'qualified':
      return '合格';
    case 'unqualified':
      return '不合格';
    case 'pending':
      return '甩项';
    default:
      return raw.trim().isEmpty ? '—' : raw.trim();
  }
}

class AcceptanceRecordGroup {
  final String regionText;
  final String? division;
  final String? subdivision;
  final String? item;
  final List<BackendAcceptanceRecord> records;

  const AcceptanceRecordGroup({
    required this.regionText,
    required this.division,
    required this.subdivision,
    required this.item,
    required this.records,
  });

  int get representativeId => records.isEmpty ? 0 : records.first.id;

  DateTime get latestAt {
    if (records.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    DateTime best = records.first.clientCreatedAt ?? records.first.createdAt;
    for (final r in records.skip(1)) {
      final t = r.clientCreatedAt ?? r.createdAt;
      if (t.isAfter(best)) best = t;
    }
    return best;
  }

  String get overallResultRaw {
    // Priority: unqualified > pending > qualified
    bool hasQualified = false;
    bool hasPending = false;
    bool hasUnqualified = false;

    for (final r in records) {
      final v = r.result.trim().toLowerCase();
      if (v == 'unqualified') {
        hasUnqualified = true;
      } else if (v == 'pending') {
        hasPending = true;
      } else if (v == 'qualified') {
        hasQualified = true;
      }
    }

    if (hasUnqualified) return 'unqualified';
    if (hasPending) return 'pending';
    if (hasQualified) return 'qualified';
    return records.isEmpty ? '' : records.first.result;
  }

  String get overallResultZh => acceptanceResultZh(overallResultRaw);

  ({int qualified, int unqualified, int pending, int total}) get counts {
    var qualified = 0;
    var unqualified = 0;
    var pending = 0;

    for (final r in records) {
      final v = r.result.trim().toLowerCase();
      if (v == 'qualified') {
        qualified++;
      } else if (v == 'unqualified') {
        unqualified++;
      } else if (v == 'pending') {
        pending++;
      }
    }
    return (
      qualified: qualified,
      unqualified: unqualified,
      pending: pending,
      total: records.length,
    );
  }

  static AcceptanceRecordGroup single(BackendAcceptanceRecord r) {
    return AcceptanceRecordGroup(
      regionText: r.regionText,
      division: r.division,
      subdivision: r.subdivision,
      item: r.item,
      records: [r],
    );
  }

  static List<AcceptanceRecordGroup> groupBySubitem(
    List<BackendAcceptanceRecord> records,
  ) {
    final Map<String, List<BackendAcceptanceRecord>> buckets = {};

    String keyOf(BackendAcceptanceRecord r) {
      final a = r.regionText.trim();
      final b = (r.division ?? '').trim();
      final c = (r.subdivision ?? '').trim();
      final d = (r.item ?? '').trim();
      return '$a|$b|$c|$d';
    }

    for (final r in records) {
      final k = keyOf(r);
      (buckets[k] ??= []).add(r);
    }

    final groups = buckets.values.map((list) {
      list.sort((a, b) {
        final ta = a.clientCreatedAt ?? a.createdAt;
        final tb = b.clientCreatedAt ?? b.createdAt;
        return tb.compareTo(ta);
      });
      final head = list.first;
      return AcceptanceRecordGroup(
        regionText: head.regionText,
        division: head.division,
        subdivision: head.subdivision,
        item: head.item,
        records: List.unmodifiable(list),
      );
    }).toList();

    groups.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return groups;
  }
}

class BackendIssueReport {
  final int id;
  final String regionText;
  final String? buildingNo;
  final int? floorNo;
  final String? zone;

  final String? division;
  final String? subdivision;
  final String? item;
  final String? indicator;
  final String? libraryId;

  final String description;
  final String? severity;
  final int? deadlineDays;
  final String? responsibleUnit;
  final String? responsiblePerson;
  final String status;

  final String? photoPath;

  final DateTime createdAt;
  final DateTime? clientCreatedAt;

  final String? clientRecordId;

  const BackendIssueReport({
    required this.id,
    required this.regionText,
    required this.buildingNo,
    required this.floorNo,
    required this.zone,
    required this.division,
    required this.subdivision,
    required this.item,
    required this.indicator,
    required this.libraryId,
    required this.description,
    required this.severity,
    required this.deadlineDays,
    required this.responsibleUnit,
    required this.responsiblePerson,
    required this.status,
    required this.photoPath,
    required this.createdAt,
    required this.clientCreatedAt,
    required this.clientRecordId,
  });

  factory BackendIssueReport.fromJson(Map<String, dynamic> json) {
    return BackendIssueReport(
      id: (json['id'] as num).toInt(),
      regionText: (json['region_text'] as String?)?.trim() ?? '',
      buildingNo: json['building_no'] as String?,
      floorNo: (json['floor_no'] as num?)?.toInt(),
      zone: json['zone'] as String?,
      division: json['division'] as String?,
      subdivision: json['subdivision'] as String?,
      item: json['item'] as String?,
      indicator: json['indicator'] as String?,
      libraryId: json['library_id'] as String?,
      description: (json['description'] as String?)?.trim() ?? '',
      severity: json['severity'] as String?,
      deadlineDays: (json['deadline_days'] as num?)?.toInt(),
      responsibleUnit: json['responsible_unit'] as String?,
      responsiblePerson: json['responsible_person'] as String?,
      status: (json['status'] as String?)?.trim() ?? '',
      photoPath: json['photo_path'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      clientCreatedAt: (json['client_created_at'] as String?) == null
          ? null
          : DateTime.parse(json['client_created_at'] as String),
      clientRecordId: json['client_record_id'] as String?,
    );
  }
}

class BackendRectificationAction {
  final int id;
  final int projectId;
  final String targetType;
  final int targetId;
  final String actionType;
  final String? content;
  final String? photoUrlsRaw; // backend stores JSON string
  final String? actorRole;
  final String? actorName;
  final DateTime createdAt;

  const BackendRectificationAction({
    required this.id,
    required this.projectId,
    required this.targetType,
    required this.targetId,
    required this.actionType,
    required this.content,
    required this.photoUrlsRaw,
    required this.actorRole,
    required this.actorName,
    required this.createdAt,
  });

  List<String> get photoUrls {
    final raw = (photoUrlsRaw ?? '').trim();
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList(growable: false);
      }
      return const [];
    } catch (_) {
      return const [];
    }
  }

  factory BackendRectificationAction.fromJson(Map<String, dynamic> json) {
    return BackendRectificationAction(
      id: (json['id'] as num).toInt(),
      projectId: (json['project_id'] as num).toInt(),
      targetType: (json['target_type'] as String?)?.trim() ?? '',
      targetId: (json['target_id'] as num).toInt(),
      actionType: (json['action_type'] as String?)?.trim() ?? '',
      content: json['content'] as String?,
      photoUrlsRaw: json['photo_urls'] as String?,
      actorRole: json['actor_role'] as String?,
      actorName: json['actor_name'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
