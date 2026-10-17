import 'package:firebase_core/firebase_core.dart';

class AppConfig {
  // Phase 1 is a local, explicitly labelled UI preview. Backend mode must be
  // selected deliberately; fixture data never enters production repositories.
  static const localPreview = bool.fromEnvironment(
    'LOCAL_UI_PREVIEW',
    defaultValue: true,
  );
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const accountAuthGatewayUrl = String.fromEnvironment('ACCOUNT_AUTH_GATEWAY_URL');
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
  );
  static bool get firebaseConfigured => [
    firebaseApiKey,
    firebaseAppId,
    firebaseSenderId,
    firebaseProjectId,
  ].every((s) => s.isNotEmpty);
  static FirebaseOptions get firebaseOptions => const FirebaseOptions(
    apiKey: firebaseApiKey,
    appId: firebaseAppId,
    messagingSenderId: firebaseSenderId,
    projectId: firebaseProjectId,
  );
  static bool get configured =>
      Uri.tryParse(supabaseUrl)?.scheme == 'https' && supabaseKey.isNotEmpty;
}
