# RoutePic generation proxy

The app never holds a provider API key: a decompiled binary hands one over
immediately (`DESIGN.md` §8.3). Everything that costs money goes through here.

## What this service guarantees

- **No coordinates arrive.** The request body carries normalised control images
  and a numeric fingerprint. The shape was projected onto its own centroid and
  scaled to a fixed canvas before it left the device, so there is no location to
  strip (`DESIGN.md` §11).
- **Uploads expire.** Objects are written with a 7-day TTL and a lifecycle rule
  deletes them; a nightly job verifies the deletion actually happened.
- **Logs carry no input.** Request bodies and signed URLs are never logged. The
  access log records a device attestation hash and nothing else.
- **One picture is charged once.** `Idempotency-Key` is required. A retry after a
  dropped response returns the original job rather than starting a second one.
- **A failure is refunded.** `failed`, `cancelled` and `expired` all return the
  reservation.

## Before this runs in production

`DESIGN.md` §11 makes these blocking, not advisory:

- [ ] Written confirmation of each provider's retention period, whether inputs
      are used for training, which region they are processed in, and the
      deletion SLA.
- [ ] `PROVIDER_*` secrets set via `wrangler secret put`, never in `wrangler.toml`.
- [ ] App Attest verification wired to the real Apple endpoint (the stub here
      accepts any well-formed assertion).
- [ ] StoreKit 2 receipt verification against Apple's servers.

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/jobs` | Submit. Requires `Idempotency-Key` and an attestation header. |
| `GET` | `/jobs/:id` | Poll. |
| `POST` | `/jobs/:id/cancel` | Cancel and refund. |
| `GET` | `/quota` | Current allowance and usage. |
