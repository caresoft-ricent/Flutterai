class TargetItem {
  final String id;
  final String idCode;
  final String libraryCode;
  final String name;
  final String description;

  const TargetItem({
    required this.id,
    required this.idCode,
    required this.libraryCode,
    required this.name,
    required this.description,
  });

  factory TargetItem.fromMap(Map<String, dynamic> map) {
    return TargetItem(
      id: map['id']?.toString() ?? '',
      idCode: map['id_code'] as String,
      libraryCode: map['library_code'] as String,
      name: map['name'] as String,
      description: map['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'id_code': idCode,
      'library_code': libraryCode,
      'name': name,
      'description': description,
    };
  }
}
