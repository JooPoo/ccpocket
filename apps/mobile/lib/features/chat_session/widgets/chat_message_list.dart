import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import '../../../models/messages.dart';
import '../../../providers/bridge_cubits.dart';
import '../../../services/bridge_service.dart';
import '../../../widgets/message_bubble.dart';
import '../../file_peek/file_peek_sheet.dart';
import '../../message_images/message_images_screen.dart';
import '../state/chat_session_cubit.dart';
import '../state/streaming_state.dart';
import '../state/streaming_state_cubit.dart';

/// Offset (in logical pixels) above the bottom past which the user is
/// considered to be "reading older content". Mirrors the threshold in
/// `useScrollTracking` so scroll-position compensation and the
/// scroll-to-bottom FAB agree on what "scrolled up" means.
const double _kScrolledUpThreshold = 100;

/// Minimum change in maxScrollExtent (logical pixels) to treat as a real
/// layout shift rather than floating-point rounding noise.
const double _kExtentChangeTolerance = 1.0;

@visibleForTesting
bool shouldShowForkForAssistant(List<ChatEntry> entries, int entryIndex) {
  if (entryIndex < 0 || entryIndex >= entries.length) return false;
  final entry = entries[entryIndex];
  if (entry is! ServerChatEntry || entry.message is! AssistantServerMessage) {
    return false;
  }

  for (var i = entryIndex + 1; i < entries.length; i++) {
    final next = entries[i];
    if (next is UserChatEntry) return false;
    if (next is ServerChatEntry) {
      final message = next.message;
      if (message is AssistantServerMessage) return false;
      if (message is ResultMessage) return true;
    }
  }
  return false;
}

/// Displays the chat message list with [ListView.builder] (reverse: true).
///
/// Reads entries directly from [ChatSessionCubit] state (SSOT).
/// With reverse list, offset 0 = bottom of chat, so new messages appear
/// immediately without scroll adjustment, and history prepend does not
/// shift the viewport.
class ChatMessageList extends StatefulWidget {
  final String sessionId;
  final AutoScrollController scrollController;
  final String? httpBaseUrl;
  final void Function(UserChatEntry)? onRetryMessage;
  final void Function(UserChatEntry)? onRewindMessage;
  final void Function(AssistantServerMessage)? onForkMessage;
  final ValueNotifier<int>? collapseToolResults;
  final double bottomPadding;
  final bool isCodex;
  final ValueChanged<String>? onFilePeekOpened;

  /// Project path for file peek (reading files from Bridge).
  final String? projectPath;

  /// When set (non-null), the list scrolls to the given [UserChatEntry].
  /// The notifier is reset to null after scrolling.
  final ValueNotifier<UserChatEntry?>? scrollToUserEntry;

  const ChatMessageList({
    super.key,
    required this.sessionId,
    required this.scrollController,
    required this.httpBaseUrl,
    required this.onRetryMessage,
    this.onRewindMessage,
    this.onForkMessage,
    required this.collapseToolResults,
    this.scrollToUserEntry,
    this.bottomPadding = 8,
    this.projectPath,
    this.isCodex = false,
    this.onFilePeekOpened,
  });

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  /// Last observed maxScrollExtent, used to detect bottom growth/shrink for
  /// read-position compensation. Null until the first metrics notification.
  double? _prevMaxScrollExtent;

  /// Guards against re-entrant compensation while a jumpTo is in flight.
  bool _compensating = false;

  @override
  void initState() {
    super.initState();
    widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollToUserEntry != widget.scrollToUserEntry) {
      oldWidget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
      widget.scrollToUserEntry?.addListener(_onScrollToUserEntry);
    }
    // Switching sessions reuses this State with a different list; drop the
    // stale extent so the next notification re-establishes a baseline instead
    // of compensating against the previous session's height.
    if (oldWidget.sessionId != widget.sessionId) {
      _prevMaxScrollExtent = null;
    }
  }

  @override
  void dispose() {
    widget.scrollToUserEntry?.removeListener(_onScrollToUserEntry);
    super.dispose();
  }

  void _onScrollToUserEntry() {
    final entry = widget.scrollToUserEntry?.value;
    if (entry == null) return;
    // Reset the notifier
    widget.scrollToUserEntry?.value = null;
    _scrollToUserEntry(entry);
  }

  // ---------------------------------------------------------------------------
  // Scroll to user entry
  // ---------------------------------------------------------------------------

  /// Scrolls the chat list to make the given [UserChatEntry] visible.
  ///
  /// Uses [AutoScrollController.scrollToIndex] which handles both on-screen
  /// and off-screen items correctly with variable-height widgets.
  void _scrollToUserEntry(UserChatEntry entry) {
    final entries = context.read<ChatSessionCubit>().state.entries;
    final idx = entries.indexOf(entry);
    if (idx < 0) return;
    widget.scrollController.scrollToIndex(
      idx,
      preferPosition: AutoScrollPosition.middle,
      duration: const Duration(milliseconds: 300),
    );
  }

  // ---------------------------------------------------------------------------
  // Plan text resolution
  // ---------------------------------------------------------------------------

  /// For entries with ExitPlanMode, search all entries for a Write tool
  /// targeting `.claude/plans/` to resolve the plan text.
  String? _resolvePlanText(ChatEntry entry) {
    if (entry is! ServerChatEntry) return null;
    final msg = entry.message;
    if (msg is! AssistantServerMessage) return null;
    final hasExitPlan = msg.message.content.any(
      (c) => c is ToolUseContent && c.name == 'ExitPlanMode',
    );
    if (!hasExitPlan) return null;
    return _findPlanFromWriteTool();
  }

  /// Search all entries in reverse for a Write tool targeting `.claude/plans/`.
  String? _findPlanFromWriteTool() {
    final entries = context.read<ChatSessionCubit>().state.entries;
    for (var i = entries.length - 1; i >= 0; i--) {
      final entry = entries[i];
      if (entry is! ServerChatEntry) continue;
      final msg = entry.message;
      if (msg is! AssistantServerMessage) continue;
      for (final c in msg.message.content) {
        if (c is! ToolUseContent || c.name != 'Write') continue;
        final filePath = c.input['file_path']?.toString() ?? '';
        if (!filePath.contains('.claude/plans/')) continue;
        final content = c.input['content']?.toString();
        if (content != null && content.isNotEmpty) return content;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Read-position compensation
  // ---------------------------------------------------------------------------

  /// Keeps the content the user is reading visually fixed while new output
  /// streams in at the bottom.
  ///
  /// The list is `reverse: true`, so it is anchored to the bottom. When the
  /// bottom region (streaming bubble + freshly appended entries) grows while
  /// the user has scrolled up, everything above it is pushed within the
  /// viewport and the read position jumps. We counter that by shifting the
  /// scroll offset by the same delta.
  ///
  /// [ScrollMetricsNotification] (unlike scroll-position listeners) fires on
  /// pure content-dimension changes, which is exactly the streaming case.
  ///
  /// Gated on `isStreaming` so this never fights history prepend, which grows
  /// the *top* (far end) of a reverse list and must not move the viewport.
  bool _onScrollMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;
    final prev = _prevMaxScrollExtent;
    _prevMaxScrollExtent = metrics.maxScrollExtent;

    if (prev == null || _compensating) return false;

    final delta = metrics.maxScrollExtent - prev;
    if (delta.abs() <= _kExtentChangeTolerance) return false;

    // Near the bottom we want the list to keep following new output.
    if (metrics.pixels <= _kScrolledUpThreshold) return false;

    if (!context.read<StreamingStateCubit>().state.isStreaming) return false;

    final controller = widget.scrollController;
    if (!controller.hasClients) return false;

    final double target = (metrics.pixels + delta)
        .clamp(metrics.minScrollExtent, metrics.maxScrollExtent)
        .toDouble();
    final sessionId = widget.sessionId;

    _compensating = true;
    void apply() {
      if (!mounted || widget.sessionId != sessionId) {
        _compensating = false;
        return;
      }
      if (controller.hasClients) controller.jumpTo(target);
      _compensating = false;
    }

    // jumpTo during the layout/build phase would assert; defer if needed.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      apply();
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final chatState = context.watch<ChatSessionCubit>().state;
    final hiddenToolUseIds = chatState.hiddenToolUseIds;
    final allEntries = chatState.entries;

    // Watch only the isStreaming flag (not the full streaming text) so the
    // list rebuilds when streaming starts/stops (to adjust itemCount) but NOT
    // on every text delta. The actual streaming text is rendered inside a
    // scoped BlocBuilder on the streaming item only.
    final hasStreaming = context.select<StreamingStateCubit, bool>(
      (cubit) => cubit.state.isStreaming,
    );
    final totalCount = allEntries.length + (hasStreaming ? 1 : 0);

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: _onScrollMetrics,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          // Only unfocus when user drags the list (not programmatic scroll).
          // This prevents the keyboard from being dismissed during automatic
          // scroll-to-bottom triggered by streaming updates.
          if (notification is UserScrollNotification &&
              notification.direction != ScrollDirection.idle) {
            FocusScope.of(context).unfocus();
          }
          return false;
        },
        child: ListView.builder(
          controller: widget.scrollController,
          reverse: true,
          padding: EdgeInsets.only(top: 36, bottom: widget.bottomPadding),
          itemCount: totalCount,
          itemBuilder: (context, index) {
            // index 0 = newest entry (bottom of chat)
            // Map to actual entry index:
            final entryIndex = totalCount - 1 - index;

            // Streaming entry is at totalCount - 1 (index 0 in reverse)
            if (hasStreaming && entryIndex == allEntries.length) {
              // Scoped BlocBuilder: only this widget rebuilds on streaming deltas
              return BlocBuilder<StreamingStateCubit, StreamingState>(
                builder: (context, streamingState) {
                  if (!streamingState.isStreaming) {
                    return const SizedBox.shrink();
                  }
                  return ChatEntryWidget(
                    entry: StreamingChatEntry(text: streamingState.text),
                    previous: null,
                    httpBaseUrl: widget.httpBaseUrl,
                    onRetryMessage: null,
                    collapseToolResults: null,
                    hiddenToolUseIds: const {},
                    isCodex: widget.isCodex,
                  );
                },
              );
            }

            final entry = allEntries[entryIndex];
            final previous = entryIndex > 0 ? allEntries[entryIndex - 1] : null;
            final onForkMessage =
                widget.isCodex &&
                    shouldShowForkForAssistant(allEntries, entryIndex)
                ? widget.onForkMessage
                : null;

            Widget child = ChatEntryWidget(
              entry: entry,
              previous: previous,
              httpBaseUrl: widget.httpBaseUrl,
              onRetryMessage: widget.onRetryMessage,
              onRewindMessage: widget.onRewindMessage,
              onForkMessage: onForkMessage,
              collapseToolResults: widget.collapseToolResults,
              resolvedPlanText: _resolvePlanText(entry),
              hiddenToolUseIds: hiddenToolUseIds,
              onFileTap: (filePath) {
                final projectPath = widget.projectPath;
                if (projectPath == null || projectPath.isEmpty) return;
                openFilePeek(
                  context,
                  bridge: context.read<BridgeService>(),
                  projectPath: projectPath,
                  filePath: filePath,
                  projectFiles: context.read<FileListCubit>().state,
                  onResolvedFilePath: widget.onFilePeekOpened,
                );
              },
              onImageTap: (user) {
                final claudeSessionId = context
                    .read<ChatSessionCubit>()
                    .state
                    .claudeSessionId;
                final httpBaseUrl = widget.httpBaseUrl;
                if (claudeSessionId == null ||
                    claudeSessionId.isEmpty ||
                    httpBaseUrl == null) {
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => MessageImagesScreen(
                      bridge: context.read<BridgeService>(),
                      httpBaseUrl: httpBaseUrl,
                      claudeSessionId: claudeSessionId,
                      messageUuid: user.messageUuid!,
                      imageCount: user.imageCount,
                    ),
                  ),
                );
              },
              isCodex: widget.isCodex,
            );
            // Wrap with AutoScrollTag for scroll-to-index support.
            // Use entryIndex (not reverse index) as the AutoScrollTag index.
            child = AutoScrollTag(
              key: ValueKey(_entryKey(entry, entryIndex)),
              controller: widget.scrollController,
              index: entryIndex,
              child: child,
            );
            return child;
          },
        ),
      ),
    );
  }

  String _entryKey(ChatEntry entry, int index) {
    return switch (entry) {
      ServerChatEntry(:final message) => switch (message) {
        ToolResultMessage(:final toolUseId) => 'tool_result:$toolUseId',
        AssistantServerMessage(:final messageUuid, :final message) =>
          messageUuid != null && messageUuid.isNotEmpty
              ? 'assistant_uuid:$messageUuid'
              : message.id.isNotEmpty
              ? 'assistant_id:${message.id}'
              : 'assistant_ts:${entry.timestamp.microsecondsSinceEpoch}:$index',
        PermissionRequestMessage(:final toolUseId) => 'permission:$toolUseId',
        ToolUseSummaryMessage() =>
          'tool_summary:${entry.timestamp.microsecondsSinceEpoch}:$index',
        _ =>
          '${message.runtimeType}:${entry.timestamp.microsecondsSinceEpoch}:$index',
      },
      UserChatEntry(:final messageUuid, :final clientMessageId, :final text) =>
        messageUuid != null && messageUuid.isNotEmpty
            ? 'user_uuid:$messageUuid'
            : clientMessageId != null && clientMessageId.isNotEmpty
            ? 'user_client:$clientMessageId'
            : 'user_ts:${entry.timestamp.microsecondsSinceEpoch}:${text.hashCode}:$index',
      StreamingChatEntry() => 'streaming',
    };
  }
}
