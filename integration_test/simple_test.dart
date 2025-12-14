import 'package:flutter_test/flutter_test.dart';
import 'package:flick_player/app/app.dart';
import 'package:flick_player/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('Flick Player integration test', (WidgetTester tester) async {
    await tester.pumpWidget(const FlickPlayerApp());

    // Verify the app launches with the Songs screen
    expect(find.text('Your Library'), findsOneWidget);
  });
}
