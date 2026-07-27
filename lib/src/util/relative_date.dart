/// A date a reader can place at a glance.
///
/// A time today, a weekday this week, a date beyond that. Deliberately not
/// "3 days ago": relative phrasing reads well in a feed and badly in a list
/// someone is scanning for the thing they wrote on Sunday.
String formatWhen(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(when.year, when.month, when.day);
  final difference = today.difference(day).inDays;

  if (difference == 0) {
    final hour = when.hour % 12 == 0 ? 12 : when.hour % 12;
    final minute = when.minute.toString().padLeft(2, '0');
    return '$hour:$minute ${when.hour < 12 ? 'am' : 'pm'}';
  }
  if (difference == 1) return 'Yesterday';
  if (difference < 7) return _weekdays[when.weekday - 1];
  if (when.year == now.year) return '${when.day} ${_months[when.month - 1]}';
  return '${when.day} ${_months[when.month - 1]} ${when.year}';
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
