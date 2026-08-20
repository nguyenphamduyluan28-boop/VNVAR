class StationIdentity {
  final String courtId;
  final String cameraId;
  final String deviceId;
  final String cameraName;
  final String cameraPosition;

  const StationIdentity({
    required this.courtId,
    required this.cameraId,
    required this.deviceId,
    required this.cameraName,
    required this.cameraPosition,
  });

  String get namespace => '$courtId/$cameraId';

  StationIdentity copyWith({
    String? courtId,
    String? cameraId,
    String? deviceId,
    String? cameraName,
    String? cameraPosition,
  }) {
    return StationIdentity(
      courtId: courtId ?? this.courtId,
      cameraId: cameraId ?? this.cameraId,
      deviceId: deviceId ?? this.deviceId,
      cameraName: cameraName ?? this.cameraName,
      cameraPosition: cameraPosition ?? this.cameraPosition,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'courtId': courtId,
      'cameraId': cameraId,
      'deviceId': deviceId,
      'cameraName': cameraName,
      'cameraPosition': cameraPosition,
    };
  }

  factory StationIdentity.fromJson(Map<String, dynamic> json) {
    final courtId = (json['courtId'] as String? ?? '').trim();
    final cameraId = (json['cameraId'] as String? ?? '').trim();
    final deviceId = (json['deviceId'] as String? ?? '').trim();
    final cameraName = (json['cameraName'] as String? ?? cameraId).trim();
    final cameraPosition =
        (json['cameraPosition'] as String? ?? 'Chưa cấu hình').trim();

    if (courtId.isEmpty || cameraId.isEmpty || deviceId.isEmpty) {
      throw const FormatException('Station identity is incomplete.');
    }

    return StationIdentity(
      courtId: courtId,
      cameraId: cameraId,
      deviceId: deviceId,
      cameraName: cameraName.isEmpty ? cameraId : cameraName,
      cameraPosition: cameraPosition.isEmpty ? 'Chưa cấu hình' : cameraPosition,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is StationIdentity &&
            other.courtId == courtId &&
            other.cameraId == cameraId &&
            other.deviceId == deviceId &&
            other.cameraName == cameraName &&
            other.cameraPosition == cameraPosition;
  }

  @override
  int get hashCode =>
      Object.hash(courtId, cameraId, deviceId, cameraName, cameraPosition);
}
