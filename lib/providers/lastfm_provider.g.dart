// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'lastfm_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(lastFmCredentials)
final lastFmCredentialsProvider = LastFmCredentialsProvider._();

final class LastFmCredentialsProvider
    extends
        $FunctionalProvider<
          LastFmCredentials,
          LastFmCredentials,
          LastFmCredentials
        >
    with $Provider<LastFmCredentials> {
  LastFmCredentialsProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmCredentialsProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmCredentialsHash();

  @$internal
  @override
  $ProviderElement<LastFmCredentials> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LastFmCredentials create(Ref ref) {
    return lastFmCredentials(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LastFmCredentials value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LastFmCredentials>(value),
    );
  }
}

String _$lastFmCredentialsHash() => r'e568da1fafea3ee39bb67142deb46e552c090172';

@ProviderFor(lastFmApiClient)
final lastFmApiClientProvider = LastFmApiClientProvider._();

final class LastFmApiClientProvider
    extends
        $FunctionalProvider<LastFmApiClient, LastFmApiClient, LastFmApiClient>
    with $Provider<LastFmApiClient> {
  LastFmApiClientProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmApiClientProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmApiClientHash();

  @$internal
  @override
  $ProviderElement<LastFmApiClient> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  LastFmApiClient create(Ref ref) {
    return lastFmApiClient(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LastFmApiClient value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LastFmApiClient>(value),
    );
  }
}

String _$lastFmApiClientHash() => r'fb047fb25d496165abebd10ac2c370da9e53a1f2';

@ProviderFor(lastFmAuthService)
final lastFmAuthServiceProvider = LastFmAuthServiceProvider._();

final class LastFmAuthServiceProvider
    extends
        $FunctionalProvider<
          LastFmAuthService,
          LastFmAuthService,
          LastFmAuthService
        >
    with $Provider<LastFmAuthService> {
  LastFmAuthServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmAuthServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmAuthServiceHash();

  @$internal
  @override
  $ProviderElement<LastFmAuthService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LastFmAuthService create(Ref ref) {
    return lastFmAuthService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LastFmAuthService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LastFmAuthService>(value),
    );
  }
}

String _$lastFmAuthServiceHash() => r'6159aa18da97dd5f6fc0220678ce5d057c5e2543';

@ProviderFor(lastFmScrobbleService)
final lastFmScrobbleServiceProvider = LastFmScrobbleServiceProvider._();

final class LastFmScrobbleServiceProvider
    extends
        $FunctionalProvider<
          LastFmScrobbleService,
          LastFmScrobbleService,
          LastFmScrobbleService
        >
    with $Provider<LastFmScrobbleService> {
  LastFmScrobbleServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmScrobbleServiceProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmScrobbleServiceHash();

  @$internal
  @override
  $ProviderElement<LastFmScrobbleService> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LastFmScrobbleService create(Ref ref) {
    return lastFmScrobbleService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LastFmScrobbleService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LastFmScrobbleService>(value),
    );
  }
}

String _$lastFmScrobbleServiceHash() =>
    r'ef5dca6fa94741dd588a82b35a1f52839d1260e5';

@ProviderFor(lastFmScrobbleQueue)
final lastFmScrobbleQueueProvider = LastFmScrobbleQueueProvider._();

final class LastFmScrobbleQueueProvider
    extends
        $FunctionalProvider<
          LastFmScrobbleQueue,
          LastFmScrobbleQueue,
          LastFmScrobbleQueue
        >
    with $Provider<LastFmScrobbleQueue> {
  LastFmScrobbleQueueProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmScrobbleQueueProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmScrobbleQueueHash();

  @$internal
  @override
  $ProviderElement<LastFmScrobbleQueue> $createElement(
    $ProviderPointer pointer,
  ) => $ProviderElement(pointer);

  @override
  LastFmScrobbleQueue create(Ref ref) {
    return lastFmScrobbleQueue(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(LastFmScrobbleQueue value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<LastFmScrobbleQueue>(value),
    );
  }
}

String _$lastFmScrobbleQueueHash() =>
    r'ec36f014fd6d9432725bcaa2d0e70b8a5d4a2b5d';

/// Watches the current Last.fm session (null = not connected).

@ProviderFor(lastFmSession)
final lastFmSessionProvider = LastFmSessionProvider._();

/// Watches the current Last.fm session (null = not connected).

final class LastFmSessionProvider
    extends
        $FunctionalProvider<
          AsyncValue<LastFmSession?>,
          LastFmSession?,
          FutureOr<LastFmSession?>
        >
    with $FutureModifier<LastFmSession?>, $FutureProvider<LastFmSession?> {
  /// Watches the current Last.fm session (null = not connected).
  LastFmSessionProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmSessionProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmSessionHash();

  @$internal
  @override
  $FutureProviderElement<LastFmSession?> $createElement(
    $ProviderPointer pointer,
  ) => $FutureProviderElement(pointer);

  @override
  FutureOr<LastFmSession?> create(Ref ref) {
    return lastFmSession(ref);
  }
}

String _$lastFmSessionHash() => r'0b91a2b5f984e8954ab0abf2560253fb6ed98b85';

/// Handles Last.fm scrobbling lifecycle hooks from playback events.

@ProviderFor(LastFmScrobbleNotifier)
final lastFmScrobbleProvider = LastFmScrobbleNotifierProvider._();

/// Handles Last.fm scrobbling lifecycle hooks from playback events.
final class LastFmScrobbleNotifierProvider
    extends $NotifierProvider<LastFmScrobbleNotifier, void> {
  /// Handles Last.fm scrobbling lifecycle hooks from playback events.
  LastFmScrobbleNotifierProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'lastFmScrobbleProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$lastFmScrobbleNotifierHash();

  @$internal
  @override
  LastFmScrobbleNotifier create() => LastFmScrobbleNotifier();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(void value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<void>(value),
    );
  }
}

String _$lastFmScrobbleNotifierHash() =>
    r'b2655ed5ad08fc709f125c98c202a7d9b0c0a18e';

/// Handles Last.fm scrobbling lifecycle hooks from playback events.

abstract class _$LastFmScrobbleNotifier extends $Notifier<void> {
  void build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<void, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<void, void>,
              void,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
