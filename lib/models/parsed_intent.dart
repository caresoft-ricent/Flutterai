class ParsedIntentResult {
  final String intent;
  final String? regionText;
  final String? regionCode;
  final String? libraryName;
  final String? libraryCode;

  const ParsedIntentResult({
    required this.intent,
    this.regionText,
    this.regionCode,
    this.libraryName,
    this.libraryCode,
  });
}
