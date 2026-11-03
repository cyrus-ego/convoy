import 'dart:io';

import 'package:geolocator/geolocator.dart';

enum LocationAccess { granted, serviceDisabled, denied, deniedForever }

/// GPS cho cả chuyến đi. Chỉ cần quyền "khi đang dùng app": phiên theo dõi bắt đầu lúc app
/// đang mở, sau đó vẫn chạy khi khoá màn hình hoặc chuyển app
/// (Android: foreground service + thông báo cố định; iOS: background mode location + chấm xanh).
class LocationService {
  Future<LocationAccess> ensureAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceDisabled;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    return switch (permission) {
      LocationPermission.denied => LocationAccess.denied,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      _ => LocationAccess.granted,
    };
  }

  /// distanceFilter = 0: đứng yên vẫn có vị trí định kỳ, để server biết mình còn sóng.
  /// Việc giảm số lần gửi lên server do SendPolicy lo.
  Stream<Position> positions() => Geolocator.getPositionStream(locationSettings: _settings());

  LocationSettings _settings() {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 2),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Bám Đoàn đang chia sẻ vị trí',
          notificationText: 'Đồng đội đang thấy bạn trên bản đồ. Rời chuyến đi để dừng.',
          notificationChannelName: 'Chia sẻ vị trí',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
  }

  Future<void> openSettings() => Geolocator.openAppSettings();
}
