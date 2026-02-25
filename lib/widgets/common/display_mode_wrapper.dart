import 'package:flutter/widgets.dart';
import 'package:flick/services/display_mode_service.dart';

class DisplayModeWrapper extends StatefulWidget {
  final Widget child;
  final bool enableOnMount;

  const DisplayModeWrapper({
    super.key,
    required this.child,
    this.enableOnMount = true,
  });

  @override
  State<DisplayModeWrapper> createState() => _DisplayModeWrapperState();
}

class _DisplayModeWrapperState extends State<DisplayModeWrapper>
    with WidgetsBindingObserver {
  final DisplayModeService _displayModeService = DisplayModeService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.enableOnMount) {
      _setHighRefreshRate();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setHighRefreshRate();
    }
  }

  Future<void> _setHighRefreshRate() async {
    await _displayModeService.setHighRefreshRate();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
