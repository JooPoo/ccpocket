import 'package:ccpocket/features/claude_session/widgets/rewind_action_sheet.dart';
import 'package:ccpocket/models/messages.dart';
import 'package:ccpocket/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('codex rewind sheet only shows conversation mode', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: RewindActionSheet(
            userMessage: UserChatEntry(
              'first codex turn',
              messageUuid: 'codex:user-turn:1',
            ),
            availableModes: const [RewindMode.conversation],
            showPreview: false,
            onRewind: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Restore conversation only'), findsOneWidget);
    expect(find.text('Restore code only'), findsNothing);
    expect(find.text('Restore conversation & code'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('file'), findsNothing);
  });
}
