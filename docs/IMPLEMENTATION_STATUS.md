# Implementation status

This document distinguishes source implementation from a deployed, validated product.

| Recommended stage | Implemented in this change | Still required |
| --- | --- | --- |
| 1. Usable local core | New navigation, functional Today actions, grocery editing/inline entry/undo/list reuse, task assignment/subtasks/rotation, manual bills/shares, home records, local reminders, export and agenda. Adaptive palette and semantic text styles. Xcode simulator build and launch/capture of all five tabs passed. | Physical-device testing, VoiceOver/large-text testing, signed TestFlight build and user acceptance. |
| 2. Shared household | Auth/email-code verification/recovery, memberships/invitations/roles, ownership transfer, scoped RLS, durable queues, versions, conflict choices, tombstones and Realtime invalidation. | Provision verified-free Supabase project, apply hosted settings/migrations, enable test recipients, and verify end-to-end with two accounts/devices. |
| 3. Coordination | Attribution/activity feed, assigned recurring occurrences, subtasks/rotation, household shares, local reminders, agenda and calendar export. | Server push/APNs delivery, multi-device notification preferences, custom allocation and partial reimbursement workflow, two-way external calendar sync, comments and uploaded documents. |
| 4. Banking | Native LinkKit dependency, server Link/exchange, real Transactions sandbox flow, encrypted bank tokens, private account/transaction snapshots, cursor-based atomic sync and disconnection. Legacy financial assumptions corrected/disabled. | Hosted secrets/network, actual sandbox calls, registered Universal Link domain, transaction pagination UI, recurring invoice matching, configurable forecast inputs and production-product approval. |
| 5. Payments/subscriptions | Stripe test-mode quote checkout, signed settlement/refund events and replay protection. StoreKit household association and Apple server transaction/notification verification. | Actual Stripe account secrets/provider quotes; provider onboarding/booking operations; App Store product/API/signing setup. VoPay/EFT funding, mandates, biller registry, scheduled execution, returns, dual approvals and AutoPay are not implemented or enabled. Premium sales are disabled until a finished product definition and configuration exist. |
| 6. Optional commerce | Instacart shopping-list handoff adapter. Active app shows genuine configured data rather than mocked orders/providers/rewards. | Instacart key/partner approval, retailer Fulfillment/Post-checkout contracts if intended; actual rewards partner/enrollment/ledger/redemption; marketplace provider vetting/availability/support; meal plans/pantry, widgets and weather/delivery services. |

## External access observed

Supabase and Stripe plugins were reported installed, including after explicit plugin mentions, but no corresponding tools were available to this chat. The cloud environment contained no Supabase/Stripe/App Store runtime credentials or outbound identities. No hosted project was created, no billing upgraded, no real payment initiated, no email sent from the user's Gmail, and no application deployed.

The supplied Plaid credentials were kept in an ignored local server configuration file. They were not placed in source or iOS build configuration. This is not proof of a working hosted Plaid connection.

## Verification

All 28 backend policy/provider tests passed locally and in CI using PGlite and mocked HTTP. All five Swift core tests, the unsigned Xcode simulator build, and simulator launch/capture of the Today, Lists, Tasks, Money and Household tabs passed in macOS CI. The five captured screens were visually reviewed. Edge Function imports and repository secret/configuration checks passed. The Swift unit suite covers exact money validation, sparse payload defaults, date decoding, record round trips and calendar escaping/folding.

These checks do not validate hosted authentication, two-device sync, real provider requests, physical-device accessibility or a signed release. Swift, Xcode and Apple SDKs are unavailable in the Linux workspace; native validation runs in CI.

## Known implementation limits

- Realtime invalidates snapshots; a periodic foreground reconciliation recovers missed changes. This first implementation pulls household records in pages instead of maintaining an incremental change cursor.
- Reminders are local notifications based on the last device sync. They are not remotely delivered APNs pushes while the app is closed.
- Conflict review currently operates on full record versions. Unrelated changes to the same record can require a choice rather than automatically merging fields.
- Existing SwiftData import copies data and preserves originals. Review imported schedules; historic daily streaks do not become verified household completion events.
- On-device mode and signed-in household data are separate. Explicit imports support the original SwiftData records and the saved on-device JSON household. Stable import IDs prevent duplicates when retrying partial imports.
- Attachments are HTTPS links, not uploaded files. Document upload storage and access policies are not enabled.
- Supabase's limited sender only works for project-team addresses and is rate limited. The confirmation/recovery templates and hosted Auth settings must be applied remotely.
- An existing registered bundle ID is required. The repository cannot infer App Store credentials, app identity, production legal URLs or signing setup from an Apple team ID.
- The old prototype source is retained but not used for active navigation. No mock cash balance or reward is presented as real data by the new root app.

## Sources used for API contracts

- [Supabase billing and free-project limits](https://supabase.com/docs/guides/platform/billing-on-supabase)
- [Supabase SMTP restrictions](https://supabase.com/docs/guides/auth/auth-smtp)
- [Supabase Auth endpoints](https://github.com/supabase/auth)
- [Supabase Realtime protocol](https://supabase.com/docs/guides/realtime/protocol)
- [Plaid native iOS integration](https://plaid.com/docs/link/ios/)
- [Plaid transaction synchronization](https://plaid.com/docs/api/products/transactions/)
- [Instacart shopping-list API](https://docs.instacart.com/developer_platform_api/api/products/create_shopping_list_page)
- [Instacart Connect scope](https://docs.instacart.com/connect)
- [Stripe marketplace checkout](https://docs.stripe.com/connect/marketplace/quickstart)
- [Apple App Store Server Library](https://github.com/apple/app-store-server-library-node)
