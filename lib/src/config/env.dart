/// Optics environment configuration.
///
/// Live Supabase project: https://onoewmuzkyjtgastydla.supabase.co
/// The anon key is safe to ship to clients; sensitive keys never go here.
class OpticsEnv {
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://onoewmuzkyjtgastydla.supabase.co',
  );

  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9ub2V3bXV6a3lqdGdhc3R5ZGxhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzg3MDQxNTUsImV4cCI6MjA5NDI4MDE1NX0.5viaaGJ1uV-VN9WZPrqb3CLute9FQAs8zLC7zCtzZC0',
  );
}
