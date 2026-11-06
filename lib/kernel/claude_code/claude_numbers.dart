/// A count or a time Claude Code wrote, as a number: some models' APIs
/// give their usage as strings (`"input_tokens": "1234"`), which Claude
/// Code passes on as they are. Those read as the numbers they say; what
/// says none, as none.
num? claudeNumber(Object? value) => switch (value) {
  final num value when value.isFinite => value,
  final String text => switch (num.tryParse(text.trim())) {
    final value? when value.isFinite => value,
    _ => null,
  },
  _ => null,
};

/// [claudeNumber], whole.
int? claudeInt(Object? value) => claudeNumber(value)?.toInt();
