class PanoramaSession {
  final String id;
  final int createdAtMillis;
  final String title;

  final PanoramaFloorPlan? floorPlan;
  final List<PanoramaNode> nodes;

  /// capture | ready_to_recognize | recognizing | done
  final String stage;

  const PanoramaSession({
    required this.id,
    required this.createdAtMillis,
    required this.title,
    required this.floorPlan,
    required this.nodes,
    required this.stage,
  });

  PanoramaSession copyWith({
    String? title,
    PanoramaFloorPlan? floorPlan,
    List<PanoramaNode>? nodes,
    String? stage,
  }) {
    return PanoramaSession(
      id: id,
      createdAtMillis: createdAtMillis,
      title: title ?? this.title,
      floorPlan: floorPlan ?? this.floorPlan,
      nodes: nodes ?? this.nodes,
      stage: stage ?? this.stage,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'createdAtMillis': createdAtMillis,
      'title': title,
      'stage': stage,
      'floorPlan': floorPlan?.toJson(),
      'nodes': nodes.map((e) => e.toJson()).toList(),
    };
  }

  static PanoramaSession fromJson(Map<String, dynamic> json) {
    final nodesJson = (json['nodes'] as List?) ?? const [];
    return PanoramaSession(
      id: (json['id'] ?? '').toString(),
      createdAtMillis: (json['createdAtMillis'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      stage: (json['stage'] ?? 'capture').toString(),
      floorPlan: json['floorPlan'] is Map
          ? PanoramaFloorPlan.fromJson(
              (json['floorPlan'] as Map).cast<String, dynamic>(),
            )
          : null,
      nodes: [
        for (final n in nodesJson)
          if (n is Map) PanoramaNode.fromJson(n.cast<String, dynamic>()),
      ],
    );
  }
}

class PanoramaFloorPlan {
  /// local path in app documents
  final String localPath;

  /// pdf | image
  final String type;

  const PanoramaFloorPlan({
    required this.localPath,
    required this.type,
  });

  Map<String, dynamic> toJson() {
    return {
      'localPath': localPath,
      'type': type,
    };
  }

  static PanoramaFloorPlan fromJson(Map<String, dynamic> json) {
    return PanoramaFloorPlan(
      localPath: (json['localPath'] ?? '').toString(),
      type: (json['type'] ?? 'image').toString(),
    );
  }
}

class PanoramaNode {
  final String id;
  final int createdAtMillis;
  final String name;

  /// Normalized [0..1] coordinates on the floor plan image (if available).
  final double? x;
  final double? y;

  /// local file paths
  final String? panoImagePath;
  final String? thumbnailPath;

  /// pending_capture | captured | recognizing | done | failed
  final String status;

  final List<PanoramaFinding> findings;

  const PanoramaNode({
    required this.id,
    required this.createdAtMillis,
    required this.name,
    required this.x,
    required this.y,
    required this.panoImagePath,
    required this.thumbnailPath,
    required this.status,
    required this.findings,
  });

  PanoramaNode copyWith({
    String? name,
    double? x,
    double? y,
    String? panoImagePath,
    String? thumbnailPath,
    String? status,
    List<PanoramaFinding>? findings,
  }) {
    return PanoramaNode(
      id: id,
      createdAtMillis: createdAtMillis,
      name: name ?? this.name,
      x: x ?? this.x,
      y: y ?? this.y,
      panoImagePath: panoImagePath ?? this.panoImagePath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      status: status ?? this.status,
      findings: findings ?? this.findings,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'createdAtMillis': createdAtMillis,
      'name': name,
      'x': x,
      'y': y,
      'panoImagePath': panoImagePath,
      'thumbnailPath': thumbnailPath,
      'status': status,
      'findings': findings.map((e) => e.toJson()).toList(),
    };
  }

  static PanoramaNode fromJson(Map<String, dynamic> json) {
    final findingsJson = (json['findings'] as List?) ?? const [];
    return PanoramaNode(
      id: (json['id'] ?? '').toString(),
      createdAtMillis: (json['createdAtMillis'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      x: (json['x'] as num?)?.toDouble(),
      y: (json['y'] as num?)?.toDouble(),
      panoImagePath: (json['panoImagePath'] ?? '').toString().trim().isEmpty
          ? null
          : (json['panoImagePath'] ?? '').toString(),
      thumbnailPath: (json['thumbnailPath'] ?? '').toString().trim().isEmpty
          ? null
          : (json['thumbnailPath'] ?? '').toString(),
      status: (json['status'] ?? 'pending_capture').toString(),
      findings: [
        for (final f in findingsJson)
          if (f is Map) PanoramaFinding.fromJson(f.cast<String, dynamic>()),
      ],
    );
  }
}

class PanoramaFinding {
  /// front | left | right | up | down
  final String view;

  /// Result of online vision structured analysis
  final Map<String, dynamic>? rawJson;
  final String type;
  final String summary;
  final String defectType;
  final String severity;
  final String rectifySuggestion;
  final String matchId;

  const PanoramaFinding({
    required this.view,
    required this.rawJson,
    required this.type,
    required this.summary,
    required this.defectType,
    required this.severity,
    required this.rectifySuggestion,
    required this.matchId,
  });

  Map<String, dynamic> toJson() {
    return {
      'view': view,
      'rawJson': rawJson,
      'type': type,
      'summary': summary,
      'defectType': defectType,
      'severity': severity,
      'rectifySuggestion': rectifySuggestion,
      'matchId': matchId,
    };
  }

  static PanoramaFinding fromJson(Map<String, dynamic> json) {
    return PanoramaFinding(
      view: (json['view'] ?? '').toString(),
      rawJson: json['rawJson'] is Map
          ? (json['rawJson'] as Map).cast<String, dynamic>()
          : null,
      type: (json['type'] ?? '').toString(),
      summary: (json['summary'] ?? '').toString(),
      defectType: (json['defectType'] ?? '').toString(),
      severity: (json['severity'] ?? '').toString(),
      rectifySuggestion: (json['rectifySuggestion'] ?? '').toString(),
      matchId: (json['matchId'] ?? '').toString(),
    );
  }
}
