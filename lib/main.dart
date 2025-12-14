import 'package:flutter/material.dart';
import 'package:flick_player/src/rust/frb_generated.dart';
import 'package:flick_player/app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Rust library
  await RustLib.init();

  runApp(const FlickPlayerApp());
}
