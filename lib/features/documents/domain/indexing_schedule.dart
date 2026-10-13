/// Formats the existing local-time indexing window for settings and status.
String _formatIndexingClock(int totalMinutes) {
  final minuteOfDay = totalMinutes % (24 * 60);
  final hour24 = minuteOfDay ~/ 60;
  final minute = minuteOfDay % 60;
  final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
  final suffix = hour24 >= 12 ? 'PM' : 'AM';
  final minuteText = minute == 0 ? '' : ':${minute.toString().padLeft(2, '0')}';
  return '$hour12$minuteText $suffix';
}

String formatIndexingWindow(int startMinute, int endMinute) =>
    '${_formatIndexingClock(startMinute)}–${_formatIndexingClock(endMinute)}';
