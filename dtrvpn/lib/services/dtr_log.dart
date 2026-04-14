import 'package:flutter/foundation.dart';

/// Централизованный кольцевой буфер логов (только debug-сборка).
/// В release все вызовы — no-op.
///
/// API:
///   DtrLog.d(tag, msg)              — debug
///   DtrLog.i(tag, msg)              — info
///   DtrLog.w(tag, msg)              — warning
///   DtrLog.e(tag, msg)              — error
///   DtrLog.ex(tag, msg, err, [st])  — exception (error + stackTrace)
class DtrLog {
  DtrLog._();

  static const int _maxEntries = 600;
  static final List<DtrLogEntry> _entries = [];

  static List<DtrLogEntry> get entries => List.unmodifiable(_entries);

  static void _add(DtrLogLevel level, String tag, String msg) {
    if (!kDebugMode) return;
    _entries.add(DtrLogEntry(level: level, tag: tag, message: msg, time: DateTime.now()));
    if (_entries.length > _maxEntries) _entries.removeAt(0);
    // Продублируем в консоль как FlClashX
    debugPrint('[DTR ${_levelChar(level)}/$tag] $msg');
  }

  static String _levelChar(DtrLogLevel l) => switch (l) {
    DtrLogLevel.debug => 'D',
    DtrLogLevel.info  => 'I',
    DtrLogLevel.warn  => 'W',
    DtrLogLevel.error => 'E',
  };

  static void d(String tag, String msg) => _add(DtrLogLevel.debug, tag, msg);
  static void i(String tag, String msg) => _add(DtrLogLevel.info,  tag, msg);
  static void w(String tag, String msg) => _add(DtrLogLevel.warn,  tag, msg);
  static void e(String tag, String msg) => _add(DtrLogLevel.error, tag, msg);

  /// Лог исключения с опциональным стектрейсом.
  /// Сигнатура: ex(tag, msg, error, [stackTrace])
  static void ex(String tag, String msg, Object error, [StackTrace? stackTrace]) {
    final buf = StringBuffer('$msg: $error');
    if (stackTrace != null) {
      buf.write('\n${stackTrace.toString().split('\n').take(5).join('\n')}');
    }
    _add(DtrLogLevel.error, tag, buf.toString());
  }

  static void clear() => _entries.clear();
}

enum DtrLogLevel { debug, info, warn, error }

class DtrLogEntry {
  const DtrLogEntry({
    required this.level,
    required this.tag,
    required this.message,
    required this.time,
  });

  final DtrLogLevel level;
  final String tag;
  final String message;
  final DateTime time;

  String get levelLabel => switch (level) {
    DtrLogLevel.debug => 'D',
    DtrLogLevel.info  => 'I',
    DtrLogLevel.warn  => 'W',
    DtrLogLevel.error => 'E',
  };

  @override
  String toString() {
    final t = time;
    final ts = '${t.hour.toString().padLeft(2,'0')}:'
               '${t.minute.toString().padLeft(2,'0')}:'
               '${t.second.toString().padLeft(2,'0')}';
    return '$ts $levelLabel/$tag: $message';
  }
}
