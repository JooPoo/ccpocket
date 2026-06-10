import 'package:flutter/foundation.dart' show ValueGetter, clampDouble;
import 'package:flutter/widgets.dart';

/// Keeps the content the user is currently reading visually pinned while new
/// output streams in at the bottom of a `reverse: true` list.
///
/// The list is anchored to the bottom, so when the bottom region (streaming
/// bubble + freshly appended entries) grows while the user has scrolled up,
/// everything above it is pushed within the viewport and the read position
/// jumps. This physics counters that *inside the layout pass* — before the
/// frame is painted — by shifting the resting offset by the same delta, so no
/// intermediate "pushed up" frame is ever drawn.
///
/// This is deliberately done in [adjustPositionForNewDimensions] (which the
/// framework calls during layout) rather than via a post-frame `jumpTo` in a
/// [ScrollMetricsNotification] listener: the latter corrects one frame too late
/// and visibly flickers as the view is pushed up and then yanked back.
///
/// Gated on [shouldMaintain] (wired to the streaming flag) so it never fights
/// history prepend, which grows the *top* (far end) of a reverse list and must
/// not move the viewport.
class MaintainReadingPositionPhysics extends ScrollPhysics {
  const MaintainReadingPositionPhysics({
    required this.shouldMaintain,
    super.parent,
  });

  /// Whether read-position compensation should currently apply. Wired to the
  /// streaming flag so compensation only runs while output is being appended
  /// to the bottom of the list.
  final ValueGetter<bool> shouldMaintain;

  /// Offset (logical px) above the bottom past which the user is considered to
  /// be reading older content. At or under this the list keeps following new
  /// output. Mirrors the threshold used by `useScrollTracking`.
  static const double scrolledUpThreshold = 100;

  /// Minimum maxScrollExtent change treated as a real layout shift rather than
  /// floating-point rounding noise.
  static const double extentChangeTolerance = 1.0;

  @override
  MaintainReadingPositionPhysics applyTo(ScrollPhysics? ancestor) {
    return MaintainReadingPositionPhysics(
      shouldMaintain: shouldMaintain,
      parent: buildParent(ancestor),
    );
  }

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final adjusted = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );

    if (isScrolling) return adjusted;
    if (!shouldMaintain()) return adjusted;

    // Near the bottom we want the list to keep following new output.
    if (oldPosition.pixels <= scrolledUpThreshold) return adjusted;

    final delta = newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (delta <= extentChangeTolerance) return adjusted;

    // Shift the resting offset by the growth so the read position stays
    // visually fixed. Clamp to the new scrollable range.
    return clampDouble(
      adjusted + delta,
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
  }
}
