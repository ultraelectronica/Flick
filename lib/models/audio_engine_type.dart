enum AudioEngineType {
  normalAndroid,
  usbDacExperimental,
  dapInternalHighRes;

  bool get usesRustBackend => this != AudioEngineType.normalAndroid;

  bool get isDirectUsbExperimental =>
      this == AudioEngineType.usbDacExperimental;

  bool get isAndroidManaged => this != AudioEngineType.usbDacExperimental;

  String get logLabel => switch (this) {
    AudioEngineType.normalAndroid => 'NORMAL_ANDROID',
    AudioEngineType.usbDacExperimental => 'USB_DAC_EXPERIMENTAL',
    AudioEngineType.dapInternalHighRes => 'DAP_INTERNAL_HIGH_RES',
  };

  String get userFacingLabel => switch (this) {
    AudioEngineType.normalAndroid => 'Android output',
    AudioEngineType.usbDacExperimental => 'Bit-perfect USB',
    AudioEngineType.dapInternalHighRes => 'Android high-res output',
  };
}
