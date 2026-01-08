import '../utils/constants.dart';

class AcceptanceRecord {
  final int? id;
  final String regionCode;
  final String regionText;
  final String libraryCode;
  final String libraryName;
  final String targetCode;
  final String targetName;
  final AcceptanceResult result;
  final String? photoPath;
  final String? remark;
  final DateTime createdAt;
  final bool uploaded;

  const AcceptanceRecord({
    this.id,
    required this.regionCode,
    required this.regionText,
    required this.libraryCode,
    required this.libraryName,
    required this.targetCode,
    required this.targetName,
    required this.result,
    this.photoPath,
    this.remark,
    required this.createdAt,
    this.uploaded = false,
  });

  AcceptanceRecord copyWith({
    int? id,
    AcceptanceResult? result,
    String? photoPath,
    String? remark,
    bool? uploaded,
  }) {
    return AcceptanceRecord(
      id: id ?? this.id,
      regionCode: regionCode,
      regionText: regionText,
      libraryCode: libraryCode,
      libraryName: libraryName,
      targetCode: targetCode,
      targetName: targetName,
      result: result ?? this.result,
      photoPath: photoPath ?? this.photoPath,
      remark: remark ?? this.remark,
      createdAt: createdAt,
      uploaded: uploaded ?? this.uploaded,
    );
  }

  factory AcceptanceRecord.fromMap(Map<String, dynamic> map) {
    return AcceptanceRecord(
      id: map['id'] as int?,
      regionCode: map['region_code'] as String,
      regionText: map['region_text'] as String,
      libraryCode: map['library_code'] as String,
      libraryName: map['library_name'] as String,
      targetCode: map['target_code'] as String,
      targetName: map['target_name'] as String,
      result: AcceptanceResult.values[map['result'] as int],
      photoPath: map['photo_path'] as String?,
      remark: map['remark'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      uploaded: (map['uploaded'] as int) == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'region_code': regionCode,
      'region_text': regionText,
      'library_code': libraryCode,
      'library_name': libraryName,
      'target_code': targetCode,
      'target_name': targetName,
      'result': result.index,
      'photo_path': photoPath,
      'remark': remark,
      'created_at': createdAt.toIso8601String(),
      'uploaded': uploaded ? 1 : 0,
    };
  }
}
