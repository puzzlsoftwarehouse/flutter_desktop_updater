import "package:desktop_updater/updater_controller.dart";
import "package:flutter/material.dart";

class DesktopUpdaterInheritedNotifier
    extends InheritedNotifier<DesktopUpdaterController> {
  const DesktopUpdaterInheritedNotifier({
    super.key,
    required super.child,
    required DesktopUpdaterController controller,
  }) : super(notifier: controller);

  static DesktopUpdaterInheritedNotifier? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<DesktopUpdaterInheritedNotifier>();
  }
}
