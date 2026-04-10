enum AudioEngineType {
  normalAndroid,
  rustOboe,
  usbDacExperimental,
  dapInternalHighRes;

  bool get usesRustBackend => this != AudioEngineType.normalAndroid;

  bool get isDirectUsbExperimental =>
      this == AudioEngineType.usbDacExperimental;

  bool get isAndroidManaged => this != AudioEngineType.usbDacExperimental;

  String get logLabel => switch (this) {
    AudioEngineType.normalAndroid => 'NORMAL_ANDROID',
    AudioEngineType.rustOboe => 'RUST_OBOE',
    AudioEngineType.usbDacExperimental => 'USB_DAC_EXPERIMENTAL',
    AudioEngineType.dapInternalHighRes => 'DAP_INTERNAL_HIGH_RES',
  };

  String get userFacingLabel => switch (this) {
    AudioEngineType.normalAndroid => 'just_audio / ExoPlayer',
    AudioEngineType.rustOboe => 'Rust via Oboe',
    AudioEngineType.usbDacExperimental => 'Bit-perfect USB',
    AudioEngineType.dapInternalHighRes => 'Rust via Oboe (high-res)',
  };
}
