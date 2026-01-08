class LibraryItem {
  final String id;
  final String idCode;
  final String name;

  const LibraryItem({
    required this.id,
    required this.idCode,
    required this.name,
  });

  factory LibraryItem.fromMap(Map<String, dynamic> map) {
    return LibraryItem(
      id: map['id']?.toString() ?? '',
      idCode: map['id_code'] as String,
      name: map['name'] as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'id_code': idCode,
      'name': name,
    };
  }
}
