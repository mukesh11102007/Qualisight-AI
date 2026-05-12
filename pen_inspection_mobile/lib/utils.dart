import 'package:intl/intl.dart';

String formatTimestamp(String iso) {
  final dt = DateTime.parse(iso);
  return DateFormat('yyyy-MM-dd HH:mm').format(dt);
}
