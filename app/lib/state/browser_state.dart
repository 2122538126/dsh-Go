import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the built-in browser is showing over the chat.
///
/// The browser is not a pushed route: it stays mounted in the shell's Stack and
/// this only hides it, so leaving for the chat keeps every tab's page — its
/// scroll position, forms and running scripts — and coming back costs nothing.
final browserVisibleProvider = StateProvider<bool>((ref) => false);
