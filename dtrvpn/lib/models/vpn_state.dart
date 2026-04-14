import 'proxy_node.dart';

enum VpnStatus { disconnected, connecting, connected, error }

class TrafficStats {
  final int upBytes;    // байт/сек (текущая скорость)
  final int downBytes;  // байт/сек (текущая скорость)

  const TrafficStats({this.upBytes = 0, this.downBytes = 0});

  /// Форматирование скорости (из FlClash: TrafficValue)
  static String formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    int i = 0;
    double val = bytesPerSec.toDouble();
    while (val >= 1024 && i < units.length - 1) {
      val /= 1024;
      i++;
    }
    final str = val < 10
        ? val.toStringAsFixed(1)
        : val.toStringAsFixed(0);
    return '$str ${units[i]}';
  }

  String get upFormatted   => formatSpeed(upBytes);
  String get downFormatted => formatSpeed(downBytes);

  TrafficStats copyWith({int? upBytes, int? downBytes}) => TrafficStats(
        upBytes:   upBytes   ?? this.upBytes,
        downBytes: downBytes ?? this.downBytes,
      );

  @override
  String toString() => '↑${upFormatted} ↓${downFormatted}';
}

class VpnState {
  final VpnStatus status;
  final ProxyNode? activeNode;
  final String? errorMessage;
  final Duration? uptime;
  final int bytesSentTotal;
  final int bytesReceivedTotal;
  final TrafficStats traffic;   // ← FlClash: текущая скорость

  const VpnState({
    this.status = VpnStatus.disconnected,
    this.activeNode,
    this.errorMessage,
    this.uptime,
    this.bytesSentTotal = 0,
    this.bytesReceivedTotal = 0,
    this.traffic = const TrafficStats(),
  });

  bool get isConnected  => status == VpnStatus.connected;
  bool get isConnecting => status == VpnStatus.connecting;

  VpnState copyWith({
    VpnStatus? status,
    ProxyNode? activeNode,
    String? errorMessage,
    Duration? uptime,
    int? bytesSentTotal,
    int? bytesReceivedTotal,
    TrafficStats? traffic,
  }) =>
      VpnState(
        status:              status              ?? this.status,
        activeNode:          activeNode          ?? this.activeNode,
        errorMessage:        errorMessage,
        uptime:              uptime              ?? this.uptime,
        bytesSentTotal:      bytesSentTotal      ?? this.bytesSentTotal,
        bytesReceivedTotal:  bytesReceivedTotal  ?? this.bytesReceivedTotal,
        traffic:             traffic             ?? this.traffic,
      );

  static const disconnected = VpnState(status: VpnStatus.disconnected);
}
