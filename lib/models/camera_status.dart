class CameraStatus {
  final String cameraId;
  final String status;
  final bool recording;

  CameraStatus({
    required this.cameraId,
    required this.status,
    required this.recording,
  });

  Map<String, dynamic> toJson() {
    return {'cameraId': cameraId, 'status': status, 'recording': recording};
  }
}
