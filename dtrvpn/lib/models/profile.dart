class Profile {
  final String id;
  String name;
  String url;
  DateTime? lastUpdated;
  int? proxyCount;
  bool isActive;
  String? rawConfig;
  // Remnawave / Mihomo subscription info
  String? username;
  int? trafficUsed;   // bytes (upload + download)
  int? trafficTotal;  // bytes, null = unlimited
  DateTime? expireDate;
  // FlClashX provider headers (NEW)
  String? supportUrl;         // support-url header (e.g. t.me/...)
  String? announceMsg;        // announce header (server message/banner)
  int?    updateIntervalHours; // profile-update-interval

  Profile({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdated,
    this.proxyCount,
    this.isActive = false,
    this.rawConfig,
    this.username,
    this.trafficUsed,
    this.trafficTotal,
    this.expireDate,
    this.supportUrl,
    this.announceMsg,
    this.updateIntervalHours,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'url': url,
        'lastUpdated': lastUpdated?.toIso8601String(),
        'proxyCount': proxyCount,
        'isActive': isActive ? 1 : 0,
        'rawConfig': rawConfig,
        'username': username,
        'trafficUsed': trafficUsed,
        'trafficTotal': trafficTotal,
        'expireDate': expireDate?.toIso8601String(),
        'supportUrl': supportUrl,
        'announceMsg': announceMsg,
        'updateIntervalHours': updateIntervalHours,
      };

  factory Profile.fromMap(Map<String, dynamic> m) => Profile(
        id: m['id'],
        name: m['name'],
        url: m['url'],
        lastUpdated:
            m['lastUpdated'] != null ? DateTime.tryParse(m['lastUpdated']) : null,
        proxyCount: m['proxyCount'],
        isActive: m['isActive'] == 1,
        rawConfig: m['rawConfig'],
        username: m['username'],
        trafficUsed: m['trafficUsed'],
        trafficTotal: m['trafficTotal'],
        expireDate:
            m['expireDate'] != null ? DateTime.tryParse(m['expireDate']) : null,
        supportUrl: m['supportUrl'],
        announceMsg: m['announceMsg'],
        updateIntervalHours: m['updateIntervalHours'],
      );

  Profile copyWith({
    String? name,
    String? url,
    DateTime? lastUpdated,
    int? proxyCount,
    bool? isActive,
    String? rawConfig,
    String? username,
    int? trafficUsed,
    int? trafficTotal,
    DateTime? expireDate,
    String? supportUrl,
    String? announceMsg,
    int? updateIntervalHours,
  }) =>
      Profile(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        lastUpdated: lastUpdated ?? this.lastUpdated,
        proxyCount: proxyCount ?? this.proxyCount,
        isActive: isActive ?? this.isActive,
        rawConfig: rawConfig ?? this.rawConfig,
        username: username ?? this.username,
        trafficUsed: trafficUsed ?? this.trafficUsed,
        trafficTotal: trafficTotal ?? this.trafficTotal,
        expireDate: expireDate ?? this.expireDate,
        supportUrl: supportUrl ?? this.supportUrl,
        announceMsg: announceMsg ?? this.announceMsg,
        updateIntervalHours: updateIntervalHours ?? this.updateIntervalHours,
      );
}
