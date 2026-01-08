class Region {
  final String id;
  final String idCode;
  final String name;
  final String parentIdCode;

  const Region({
    required this.id,
    required this.idCode,
    required this.name,
    required this.parentIdCode,
  });

  factory Region.fromMap(Map<String, dynamic> map) {
    return Region(
      id: map['id']?.toString() ?? '',
      idCode: map['id_code'] as String,
      name: map['name'] as String,
      parentIdCode: map['parent_id_code'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'id_code': idCode,
      'name': name,
      'parent_id_code': parentIdCode,
    };
  }
}
