# Reviewer access

Très Fort uses ordinary Sign in with Apple. Reviewers can create their own
account; no invitation, subscription, or developer-supplied Apple password is
required to create and log workouts. Optional personal integrations have their
normal consent and account requirements.

The earlier username/password error came from App Store Connect's required
credential fields, not an Apple reviewer rejecting Sign in with Apple. The owner
cleared the credential requirement and saved Apple-only instructions. Readback on
2026-09-12 confirmed `demoAccountRequired: false` and version 1.0/build 38 in
`READY_FOR_REVIEW` with manual release. This is a draft, not submitted review.

## Replacement candidate

The password disclosure, client login method, server password endpoint and sample
seeding path are removed. Historical sample JWTs cannot access live APIs or renew.
The reserved identity remains excluded from owner bootstrap. Local sample markers
remain solely to protect legacy personal data and deletion-receipt cleanup in
already installed betas. No sample records or owner-managed secrets are deleted
by this change; an old configured password digest no longer enables access.

Deploy the compatible reviewed Worker before distributing the replacement iOS
build. Use the following notes in App Review Information, with the username and
password requirement disabled:

> Très Fort uses Sign in with Apple exclusively. There is no separate
> email/password login. Reviewers can create an account using Sign in with Apple
> on their review device. No invitation or subscription is required to create and
> log workouts. During onboarding, choose the option without an invite and build
> your first workout. Create a workout, add exercises, start it from Today, log
> sets, finish, and inspect Calendar/history. Profile > Account provides export,
> sign-out, and deletion. Claude, Apple Health, Intervals.icu and private groups
> are optional. Claude requires a separate account supporting custom connectors.

The owner authorized the replacement build and Apple review submission on
2026-09-12. Preserve manual public release. Verify Apple's actual submission
receipt separately from saving metadata or adding a draft item.
