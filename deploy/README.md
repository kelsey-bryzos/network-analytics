# Web Deploy Configs

Two ready-to-use static-host configs for the Flutter web build. Pick one — both
give the same UX (HTTPS, SPA fallback, security headers, immutable asset
caching with index.html un-cached). Vercel and Cloudflare Pages are both free
for our traffic volume.

## Vercel

1. `vercel link` from `/program/flutter_app/`.
2. Set project env vars in the Vercel dashboard:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
3. Copy `deploy/vercel.json` to the project root (`/program/flutter_app/vercel.json`)
   *or* let `vercel` use the one in `deploy/` via `--local-config=deploy/vercel.json`.
4. `vercel --prod`.

The `buildCommand` in `vercel.json` runs `flutter build web --release` with the
correct `--dart-define`s for production. Vercel deploys the `build/web`
directory.

## Cloudflare Pages

1. Create a Pages project; set the build command to
   `flutter build web --release --dart-define=SUPABASE_URL=$SUPABASE_URL --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY --dart-define=kProd=true --dart-define=kAllowSelfSignup=false`
   and the build-output directory to `build/web`.
2. Set environment variables `SUPABASE_URL` and `SUPABASE_ANON_KEY` in the
   Pages project settings.
3. Before deploying, copy `deploy/cloudflare/_redirects` and
   `deploy/cloudflare/_headers` into `build/web/` (or add to a pre-build step
   in CI). Cloudflare reads these files at the root of the deployed bundle.
4. Push to the connected git branch; Pages auto-deploys.

## Production Dart-Defines (required either way)

| Define | Value | Notes |
|---|---|---|
| `SUPABASE_URL` | `https://onoewmuzkyjtgastydla.supabase.co` | Public, OK to bake into bundle |
| `SUPABASE_ANON_KEY` | the project's anon key | Public, OK to bake into bundle |
| `kProd` | `true` | Toggles dev-only affordances off |
| `kAllowSelfSignup` | `false` | Locks the sign-in screen to invite-only |

**Never** put `SUPABASE_SERVICE_ROLE_KEY` into a `--dart-define` — it would
end up in the bundle and grant admin access to anyone who views source.
