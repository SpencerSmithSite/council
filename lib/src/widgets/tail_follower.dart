import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// Decides whether a growing transcript should pull the view along with it.
///
/// Extracted from the chat screen because the rule is not obvious and the bug
/// it fixes was not either. Every streamed chunk used to scroll the transcript
/// to the end unconditionally; chunks arrive faster than a 300 ms animation can
/// finish, so a reader scrolling up was dragged back several times a second and
/// could not read the beginning of a long answer until it had stopped growing.
///
/// The rule: follow the end until the reader scrolls away from it, and follow
/// again the moment they come back.
class TailFollower {
  TailFollower({this.slack = 80});

  /// How close to the end still counts as "reading the latest".
  ///
  /// Not zero: an answer arriving a few characters at a time moves the end away
  /// constantly, and a reader who has stayed put should not be treated as
  /// having deliberately scrolled off because the text grew under them.
  final double slack;

  bool _following = true;
  bool _dragging = false;

  /// Whether new content should scroll the view.
  bool get following => _following;

  /// Follow again — for the moments the reader caused directly, like asking a
  /// question or opening a thread.
  void reattach() => _following = true;

  /// Feed a scroll notification in. Returns true when [following] changed, so
  /// the caller can rebuild only then.
  bool handle(ScrollNotification notification) {
    final before = _following;

    if (notification is UserScrollNotification) {
      // A drag or fling has begun. Only the reader's own scrolling is allowed
      // to change the decision — see below.
      if (notification.direction != ScrollDirection.idle) _dragging = true;
    } else if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      // Gated on `_dragging` because growing content also emits scroll
      // notifications: while an answer streams, `maxScrollExtent` moves ahead
      // of `pixels` every frame, and reading that as "the reader scrolled up"
      // would switch following off a moment after it was switched on — which
      // is the same bug in reverse.
      if (_dragging) {
        final m = notification.metrics;
        _following = m.pixels >= m.maxScrollExtent - slack;
      }
      if (notification is ScrollEndNotification) _dragging = false;
    }

    return _following != before;
  }
}
