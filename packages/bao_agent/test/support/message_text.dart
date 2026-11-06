/// The message among [messages] that names [path], as text.
String messageWithPath(List<Object?> messages, String path) =>
    _messageContaining(messages, path);

String _messageContaining(Object? value, String path) {
  switch (value) {
    case final String string when string.contains(path):
      return string;
    case final String _:
    case null:
      return '';
    case final List<Object?> list:
      for (final item in list) {
        final found = _messageContaining(item, path);
        if (found.isNotEmpty) return found;
      }
    case final Map<Object?, Object?> map:
      for (final item in map.values) {
        final found = _messageContaining(item, path);
        if (found.isNotEmpty) return found;
      }
  }
  return '';
}

/// Every string in [value], joined without JSON escaping.
String messageText(Object? value) {
  final text = StringBuffer();

  void collect(Object? value) {
    switch (value) {
      case final String string:
        text
          ..writeln(string)
          ..writeln();
      case final List<Object?> list:
        list.forEach(collect);
      case final Map<Object?, Object?> map:
        map.values.forEach(collect);
    }
  }

  collect(value);
  return '$text';
}
