import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ccpocket/features/chat_session/widgets/maintain_reading_position_physics.dart';

void main() {
  group('MaintainReadingPositionPhysics', () {
    test('keeps read position fixed when content grows during streaming', () {
      final physics = MaintainReadingPositionPhysics(
        shouldMaintain: () => true,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 240, maxScrollExtent: 1000),
        newPosition: _metrics(pixels: 240, maxScrollExtent: 1120),
        isScrolling: false,
        velocity: 0,
      );

      expect(adjusted, 360);
    });

    test('keeps following output near the bottom', () {
      final physics = MaintainReadingPositionPhysics(
        shouldMaintain: () => true,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 80, maxScrollExtent: 1000),
        newPosition: _metrics(pixels: 80, maxScrollExtent: 1120),
        isScrolling: false,
        velocity: 0,
      );

      expect(adjusted, 80);
    });

    test('does not adjust when streaming is not active', () {
      final physics = MaintainReadingPositionPhysics(
        shouldMaintain: () => false,
      );

      final adjusted = physics.adjustPositionForNewDimensions(
        oldPosition: _metrics(pixels: 240, maxScrollExtent: 1000),
        newPosition: _metrics(pixels: 240, maxScrollExtent: 1120),
        isScrolling: false,
        velocity: 0,
      );

      expect(adjusted, 240);
    });
  });
}

FixedScrollMetrics _metrics({
  required double pixels,
  required double maxScrollExtent,
}) {
  return FixedScrollMetrics(
    minScrollExtent: 0,
    maxScrollExtent: maxScrollExtent,
    pixels: pixels,
    viewportDimension: 600,
    axisDirection: AxisDirection.up,
    devicePixelRatio: 1,
  );
}
