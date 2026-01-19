import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

/// An implementation of [DesktopUpdaterPlatform] that uses method channels.
class MethodChannelDesktopUpdater extends DesktopUpdaterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel("desktop_updater");

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>("getPlatformVersion");
    return version;
  }

  @override
  Future<void> restartApp({int? waitForExitTimeoutMs}) async {
    // send timeout (ms) or null
    return methodChannel.invokeMethod<void>("restartApp", [waitForExitTimeoutMs]);
  }

  @override
  Future<String?> sayHello() async {
    return methodChannel.invokeMethod<String>("sayHello");
  }

  @override
  Future<String?> getExecutablePath() async {
    return methodChannel.invokeMethod<String>("getExecutablePath");
  }

  @override
  Future<void> updateApp({required String remoteUpdateFolder}) async {
    return methodChannel.invokeMethod<void>("updateApp", [remoteUpdateFolder]);
  }

  @override
  Future<String?> getCurrentVersion() async {
    return methodChannel.invokeMethod<String>("getCurrentVersion");
  }
}
