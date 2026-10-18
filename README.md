# Household OS

Native SwiftUI household coordination for iPhone and iPad (iOS 18+), with a Supabase backend.

## Current implementation

- Today / Lists / Tasks / Money / Household navigation with semantic typography, accessible controls, native swipe actions and adaptive colors.
- Email/password registration, six-digit email confirmation, resend, password recovery, Keychain sessions and refresh-token rotation.
- Household creation, email-bound expiring invitations, owner/member/child roles, removal, leaving and ownership transfer. Invitations are shared using the system share sheet; the app does not send invitations from your personal email.
- Shared records protected by database permissions, durable per-user/per-household offline queues, optimistic versions, explicit conflict resolution, tombstones and Realtime invalidation with foreground refresh/recovery.
- Grocery lists with rapid inline entry, quantities/notes/aisles, duplicate suggestions, shopping claims, reusable list copies and item-deletion undo.
- Assigned tasks, subtasks, recurrence, household rotation, completion history, due-date agenda and calendar snapshot export.
- Manual bills with integer-cent amounts, equal household shares and attributed payment records. Recording a bill as paid does not move money.
- Home records with notes and secure manual/receipt links; explicit import from the original on-device SwiftData store.
- Local reminders after each device sync, persisted notification preference, export and account deletion controls.
- Server adapters for Plaid Link/exchange/transaction sync, Instacart shopping-list links, Stripe Connect quote checkout/verified settlement/refunds, and App Store household subscription verification.

The original prototype views remain in the source tree for migration/reference; they are not the application's root navigation. Their simulated integrations are disabled. Existing SwiftData data is preserved and can be imported from Household → Home records.

## Deployment status and external blockers

Source implementation does not mean hosted services are connected. No Supabase project was created during implementation: the connected plugin was visible as installed but its account tools were unavailable, so the organization's free plan and project quota could not be verified. No billing plan was changed. Stripe and App Store account access were similarly not exposed as callable administration tools.

See [docs/IMPLEMENTATION_STATUS.md](docs/IMPLEMENTATION_STATUS.md) for remaining work, limits and verification requirements. The app can be used in on-device mode without service configuration.

## Local checks

```sh
npm ci --ignore-scripts
npm test
npm run check
```

The backend suite runs actual PostgreSQL policies/functions in PGlite and exercises provider boundaries with mocked HTTP. It does not contact production services or create payments.

On a Mac with Xcode 16.3 or later (iOS 18 SDK):

```sh
swift test
xcodebuild -project HouseholdOS.xcodeproj -scheme HouseholdOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions runs these checks without signing or service credentials. LinkKit is pinned to 6.5.4, whose package is compiled with Xcode 16.1 and supports newer toolchains. Confirm updates before a production release.

## Supabase setup, keeping the account free

1. First inspect the actual organization subscription and active free-project count. Supabase plans apply to organizations; its published free allowance is two active projects across organizations where the user is an owner/admin. A new project in a paid organization is not a free project.
2. Create `HouseholdOS` only inside a verified Free organization with an available free slot. Do not upgrade the plan, enable paid add-ons, pause/delete unrelated projects, or assume `nano` size alone proves a project is free. If account tools cannot verify this, leave creation pending.
3. Link the new project using a scoped management credential, then apply the migrations and deploy the Edge Function:

```sh
supabase link --project-ref YOUR_VERIFIED_FREE_PROJECT_REF
supabase db push
supabase secrets set --env-file .env.local
supabase functions deploy household-api
```

These commands target an existing explicitly linked project. They do not create or change a subscription. Keep managed credentials in the environment/secret store, never in Git.

4. `supabase/config.toml` configures local Auth. Hosted Auth must also be configured through the project's Auth settings or Management API: confirm email ON, password minimum 12, six-digit OTP, one-hour OTP expiry, and the supplied confirmation/recovery templates. Copy `supabase/templates/confirmation.html` and `recovery.html` to their corresponding hosted email templates.
5. For the requested limited test sender, add each test recipient's email as a project organization team member. The default sender refuses other addresses and has low rate limits. This setup is for testing; a public sign-up launch needs custom SMTP.
6. Confirm Realtime replication is enabled for `household_records` and `household_members`; the migration adds them to Supabase's existing `supabase_realtime` publication.

Free usage has service quotas and inactivity behavior. Stay within those limits; this repository does not enable usage upgrades or paid infrastructure.

## iOS project configuration

Provide the existing registered App Store bundle ID rather than registering a replacement:

```sh
python3 scripts/configure-ios.py \
  --url https://YOUR_PROJECT.supabase.co \
  --publishable-key YOUR_PUBLIC_PUBLISHABLE_KEY \
  --bundle-id YOUR_EXISTING_REGISTERED_BUNDLE_ID \
  --app-link-domain YOUR_OWNED_DOMAIN
```

This writes gitignored `Config/Local.xcconfig` and, if a domain is supplied, `Config/Local.entitlements`. It rejects service-role/server keys. Only a public Supabase project URL and public anon/publishable key belong in the app. Choose the existing Apple team in Xcode. App Store API private keys and signing credentials remain outside the repository.

For Plaid OAuth, serve an `apple-app-site-association` file at the configured domain, with your actual Apple team/application prefix and bundle ID, and the `/plaid/*` path. Register the same HTTPS redirect in Plaid and set `PLAID_REDIRECT_URI`. Custom URL schemes cannot substitute for Plaid Universal Links. Household invitations use `householdos://invite?token=...` and remain bound to the invited verified email.

## Server secrets

`.env.example` lists configuration names without values. The user's supplied Plaid sandbox credentials are stored only in the ignored, permission-restricted local `.env.local`; a random bank-token encryption key was generated there. They have not been uploaded to a hosted project or verified against Plaid. Preserve `BANK_TOKEN_ENCRYPTION_KEY` when redeploying; rotating it requires migrating stored ciphertext.

Supabase automatically provides its project URL and server/anon keys to hosted Edge Functions. Configure additional secrets with the CLI/managed secret settings. Never commit `.env.local`, `Config/Local.xcconfig`, `Config/Local.entitlements`, or a private signing key.

### Plaid

- Set `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV=sandbox`, `BANK_TOKEN_ENCRYPTION_KEY` and the allowed redirect URI.
- Enable the Transactions product for the project. The server creates Link tokens, exchanges public tokens, encrypts access tokens, and stores bank data per user.
- Sync pagination restarts from its original cursor if Plaid invalidates a page sequence. Only a fully fetched sequence is committed with the expected cursor in a database transaction.
- The Debug-only sandbox button uses the documented `user_transactions_dynamic` Transactions persona at `ins_109508`. The supplied `user_bank_income` persona belongs to the separate Bank Income testing flow; no income-verification product is silently enabled.
- Snapshot data is private and limited to the most recent 200 transactions. Refresh is explicit. Bank-side webhooks, institution-name enrichment, recurring-stream detection and large-history UI pagination remain follow-up work.
- No production banking is enabled by default.

### Stripe service payments

- Configure a test `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and an owned HTTPS `PAYMENT_RETURN_URL`.
- Provision a real/test connected provider account and a platform-issued row in `service_quotes`. Application users cannot create or change quotes directly. Quote amounts, currency and destination come from the database.
- Checkout verifies the connected account can charge and receive payouts. Retries use the quote ID as Stripe's idempotency key. A browser redirect does not establish payment completion.
- Configure Stripe events `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `checkout.session.async_payment_failed`, `checkout.session.expired`, and `charge.refunded` to `/functions/v1/household-api/stripe/webhook`.
- Webhooks verify signature and timestamp, match amount/currency, deduplicate events and preserve settled/refunded state against stale events.
- Live keys are rejected unless `ENABLE_LIVE_SERVICE_PAYMENTS=true` is deliberately configured. No digital subscriptions or household utility bill/EFT transfers run through Stripe.
- Provider discovery/onboarding, quoting operations and booking calendars still require an actual marketplace workflow; there is no fake provider list in the active app.

### Instacart

The supplied Fulfillment and Post-checkout endpoints are Instacart Connect retailer APIs. A household grocery-list handoff uses the Developer Platform's `POST /idp/v1/products/products_link` instead. Set `INSTACART_API_KEY` and `INSTACART_ENV=development` initially. The adapter creates a shopping-list link using the authenticated household's pending items; it never invents an order or marks items purchased.

The key and partner access have not been supplied. Direct fulfillment, delivery reservations, post-checkout chat and substitutions are not enabled without a retailer agreement and their complete endpoint contracts.

### App Store subscriptions

The existing product IDs remain `com.householdos.premium.monthly` and `com.householdos.premium.annual`. Purchases use the household UUID as `appAccountToken`.

Configure the App Store Server API issuer/key/private key, actual bundle ID, environment, and DER Apple root CA certificates as base64 strings. Production also needs the numeric App Store app ID. Apple's official server library verifies signed transactions and notifications. The backend checks bundle, product and household association, rejects reassignment, respects expiration/refund/revocation, and rejects stale updates.

Configure App Store Server Notifications V2 at `/functions/v1/household-api/storekit/notifications`. Purchasing stays unavailable until `PREMIUM_LAUNCH_ENABLED=true`; do not enable it until product benefits, pricing, legal disclosures and App Store configuration are complete. Restore and household entitlement display are implemented. Premium-only feature enforcement must accompany the final product definition; basic coordination features currently remain available.

## Architecture

- `HouseholdOS/Core`: Codable domain models, exact money parsing, calendar export and Swift package tests.
- `BackendClient`: Auth HTTP boundary, verified-email session handling and Keychain persistence.
- `HouseholdStore`: per-user cache/outbox, scoped selection, optimistic mutation versions and conflict handling.
- `Shared*View`, `Household*View`: active application flows.
- `supabase/migrations`: household/RLS schema, versioned mutation RPC, private integration tables, recurring occurrences, Realtime publication and entitlement/payment state.
- `supabase/functions/_shared`: provider adapters, signed-event processing and tested computation.
- `supabase/functions/household-api`: one authenticated Edge Function router with separate signature-verified webhook routes.

Direct application table writes are denied. Security-definer functions use empty search paths and explicit execution grants. Bank credentials, integration events and subscription grants live outside the public API schema.

## Before release

Verify two users on two devices, an unrelated household, offline edits/conflicts, membership removal, invitation expiry, timezone/DST/month-end recurrence, notification permission changes, bank reconnect, duplicate payment retries, refunds and subscription expiration. Test large text, VoiceOver, dark mode and small/large devices. Add a real app icon, published privacy/terms/support URLs and production store metadata. See the implementation status document for remaining features and operational work.
