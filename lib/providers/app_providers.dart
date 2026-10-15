import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/security/lock_controller.dart';
import '../repositories/messenger_repository.dart';

final lockProvider = Provider<LockController>(
  (ref) => throw StateError('Lock must be injected at startup'),
);
final supabaseProvider = Provider<SupabaseClient>(
  (ref) => Supabase.instance.client,
);
final messengerProvider = Provider<MessengerRepository>(
  (ref) => MessengerRepository(ref.watch(supabaseProvider)),
);
