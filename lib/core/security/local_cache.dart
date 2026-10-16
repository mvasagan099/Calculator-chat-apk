/// Persistent private history/outbox. Supabase remains the shared source of truth.
abstract interface class LocalCache {
  Map<String, dynamic> get data;
  Future<void> initialize();
  Future<void> save();
  Future<void> forget();
  Future<void> clear();
}
