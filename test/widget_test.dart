import 'package:flutter_test/flutter_test.dart';
import 'package:flick/app/app.dart';

void main() {
  testWidgets('Flick Player app smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const FlickPlayerApp());

    // Verify that the Songs screen is displayed initially
    expect(find.text('Your Library'), findsOneWidget);
    expect(find.text('Songs'), findsOneWidget);
  });
}
