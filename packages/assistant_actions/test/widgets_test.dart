import 'package:assistant_actions/assistant_actions.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssistantSiriTip & AssistantShortcutsLink', () {
    testWidgets('embed UiKitView on iOS with creationParams', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        const tip = AssistantSiriTip(
          actionId: 'pinNote',
          style: AssistantSiriTipStyle.dark,
          height: 80,
        );
        const link = AssistantShortcutsLink(
          style: AssistantShortcutsLinkStyle.lightOutline,
          height: 48,
        );
        expect(tip.creationParams, {
          'actionId': 'pinNote',
          'isVisible': true,
          'style': 'dark',
        });
        expect(link.creationParams, {'style': 'lightOutline'});

        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(children: [tip, link]),
          ),
        );
        final uiKitViews = tester.widgetList<UiKitView>(find.byType(UiKitView)).toList();
        expect(uiKitViews, hasLength(2));
        expect(uiKitViews[0].viewType, AssistantSiriTip.viewType);
        expect(uiKitViews[1].viewType, AssistantShortcutsLink.viewType);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('embed AppKitView on macOS', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                AssistantSiriTip(actionId: 'pinNote'),
                AssistantShortcutsLink(),
              ],
            ),
          ),
        );
        final appKitViews = tester.widgetList<AppKitView>(find.byType(AppKitView)).toList();
        expect(appKitViews, hasLength(2));
        expect(appKitViews[0].viewType, AssistantSiriTip.viewType);
        expect(appKitViews[1].viewType, AssistantShortcutsLink.viewType);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('render nothing when hidden or on non-Apple platforms', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: AssistantSiriTip(actionId: 'pinNote', isVisible: false),
          ),
        );
        expect(find.byType(UiKitView), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                AssistantSiriTip(actionId: 'pinNote'),
                AssistantShortcutsLink(),
              ],
            ),
          ),
        );
        expect(find.byType(UiKitView), findsNothing);
        expect(find.byType(AppKitView), findsNothing);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
