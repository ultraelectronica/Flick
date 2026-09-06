import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flick/services/uac2_preferences_service.dart';
import 'package:flick/services/uac2_service.dart';
import 'package:flick/widgets/uac2/usb_bit_perfect_prompt.dart';

Uac2DeviceStatus status({
  Uac2State state = Uac2State.connected,
  Uac2RouteType routeType = Uac2RouteType.externalUsb,
  bool isExternalRoute = false,
}) {
  return Uac2DeviceStatus(
    device: Uac2DeviceInfo(
      vendorId: 1,
      productId: 2,
      productName: 'Test DAC',
      manufacturer: 'Test',
    ),
    state: state,
    routeType: routeType,
    isExternalRoute: isExternalRoute,
  );
}

void main() {
  test('prompts for external USB route in live states with bit-perfect off', () {
    expect(shouldPromptBitPerfect(status(), bitPerfectEnabled: false), isTrue);
    expect(
      shouldPromptBitPerfect(
        status(state: Uac2State.streaming),
        bitPerfectEnabled: false,
      ),
      isTrue,
    );
    expect(
      shouldPromptBitPerfect(
        status(state: Uac2State.prewarming),
        bitPerfectEnabled: false,
      ),
      isTrue,
    );
  });

  test('no prompt when bit-perfect already on', () {
    expect(shouldPromptBitPerfect(status(), bitPerfectEnabled: true), isFalse);
  });

  test('no prompt for internal route or non-live states', () {
    expect(
      shouldPromptBitPerfect(
        status(routeType: Uac2RouteType.internalDac),
        bitPerfectEnabled: false,
      ),
      isFalse,
    );
    expect(
      shouldPromptBitPerfect(
        status(state: Uac2State.idle),
        bitPerfectEnabled: false,
      ),
      isFalse,
    );
    expect(
      shouldPromptBitPerfect(
        status(state: Uac2State.error),
        bitPerfectEnabled: false,
      ),
      isFalse,
    );
  });

  test('isExternalRoute flag alone qualifies as USB route', () {
    expect(
      shouldPromptBitPerfect(
        status(routeType: Uac2RouteType.unknown, isExternalRoute: true),
        bitPerfectEnabled: false,
      ),
      isTrue,
    );
  });

  test('prompt key is stable per device and dedupable', () {
    final a = usbDevicePromptKey(
      Uac2DeviceInfo(
        vendorId: 1,
        productId: 2,
        productName: 'DAC',
        manufacturer: 'M',
        serial: 'S1',
      ),
    );
    final b = usbDevicePromptKey(
      Uac2DeviceInfo(
        vendorId: 1,
        productId: 2,
        productName: 'DAC',
        manufacturer: 'M',
        serial: 'S1',
      ),
    );
    final noSerial = usbDevicePromptKey(
      Uac2DeviceInfo(
        vendorId: 1,
        productId: 2,
        productName: 'DAC',
        manufacturer: 'M',
        deviceName: '/dev/bus/usb/001/002',
      ),
    );
    expect(a, b);
    expect(<String>{}..add(a)..add(b), {a});
    expect(noSerial, '1:2:/dev/bus/usb/001/002');
  });

  test('prompted devices persist across sessions', () async {
    SharedPreferences.setMockInitialValues({});
    final service = Uac2PreferencesService();

    expect(await service.getPromptedUsbDevices(), isEmpty);

    await service.addPromptedUsbDevice('1:2:S1');
    await service.addPromptedUsbDevice('1:2:S1');
    await service.addPromptedUsbDevice('3:4:S2');

    final persisted = await service.getPromptedUsbDevices();
    expect(persisted, {'1:2:S1', '3:4:S2'});

    await service.clearAllPreferences();
    expect(await service.getPromptedUsbDevices(), isEmpty);
  });
}
