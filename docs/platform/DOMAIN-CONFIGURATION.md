# Snaglist domain and email configuration — 11 September 2026

Checkpoint: 14:15 UTC. This is an applied-configuration handover, not production platform acceptance. Owner: Daniel McCann. The registered customer domain is **usesnaglist.com**; the brand remains Snaglist. Keep the existing snaglist.dev domain and issued links.

## Applied and verified

| Address or setting | Actual destination/state | Evidence and limits |
| --- | --- | --- |
| `https://usesnaglist.com` | Existing `snaglist-website-next` Worker | HTTP 200; actual Chrome homepage and Support navigation inspected. Existing JS/CSS assets return 200. This is the legacy marketing website, not the approved portal or a website reskin. |
| `https://www.usesnaglist.com` | Same Worker binding, with a Cloudflare 308 redirect to the apex | Actual root and asset-path requests preserve the path and query string. |
| HTTP requests on the new zone | Always Use HTTPS enabled | Actual apex request returns 301 to HTTPS. No old-zone setting changed. |
| `https://staging-api.usesnaglist.com` | Existing `snaglist-api-staging` Worker/Container | `/health` returns 200 JSON and `Cache-Control: no-store`. Additive hostname only; emitted links and native staging configuration still use workers.dev. |
| `mail.usesnaglist.com` | Resend, Ireland `eu-west-1` | Dashboard reports **Verified**, with Domain verified event and verified DNS. No new-domain message has been sent and no new-domain API key has been created. |
| `_dmarc.usesnaglist.com` | TXT `v=DMARC1; p=none;` | Initial non-enforcing policy, while Google and Resend delivery are tested. No reporting address configured. This does not claim spoofing enforcement. |
| DNSSEC | Enablement requested in Cloudflare Registrar; status **pending** | Rechecked at this checkpoint. Cloudflare publishes the DS automatically, normally within 1–2 days. Recheck before claiming active. |

The new Worker Custom Domains added DNS and managed certificates. No application Worker code or Container image was deployed. The old `snaglist.dev` website and workers.dev staging health both still return 200. Production `api.snaglist.dev/health` remains **530** on the disconnected old tunnel; this domain work does not restore production.

## Approved Google mailbox — setup pending password handoff

Dan explicitly approved **one Business Starter user on the £7/month Flexible plan, before tax, with no annual commitment**: `dan@usesnaglist.com`, with `hello@usesnaglist.com`, `support@usesnaglist.com` and `billing@usesnaglist.com` aliases. Aliases route into Dan's mailbox and do not add paid users. Do not ask for this plan approval again; do not select a higher tier, extra users or an annual commitment.

Google signup is prepared in Chrome for Snaglist, United Kingdom, one person, the owned domain and username `dan`. Dan was asked to enter/confirm a new password directly on Google's page and click **Agree and continue**. No account creation, trial activation or paid subscription is confirmed. Do not read password fields or put credentials in chat, source, screenshots or Drive. Await the user's completion signal before continuing that form.

After the password step: select the approved Starter/Flexible plan, complete Google's actual domain verification challenge, configure the exact MX records shown for this account, add one root Google SPF record, enable Google DKIM and add the three aliases. Verify Gmail send/receive and alias delivery using Dan's already authorised personal test recipient. Keep Resend's return-path SPF on its separate subdomain; do not create two SPF records at the same hostname. Public support/contact addresses should change only after receiving mail is verified. No Google MX, SPF, DKIM or verification TXT has been published yet.

Sources: [Google Flexible versus annual plans](https://knowledge.workspace.google.com/admin/billing/compare-flexible-and-annual-fixed-term-payment-plans), [Google aliases](https://support.google.com/a/answer/33327), [Cloudflare DNSSEC](https://developers.cloudflare.com/registrar/get-started/enable-dnssec/).

## Transactional sender and origin migration still required

Resend domain ID: `4cb0f2cc-4587-4b5a-9738-7355cd6fc3c3`. Its DKIM public key was copied from the verified dashboard into TXT `resend._domainkey.mail.usesnaglist.com`. Return-path records are MX `send.mail.usesnaglist.com` → `feedback-smtp.eu-west-1.amazonses.com`, priority 10, and TXT `v=spf1 include:amazonses.com ~all`. Records are unproxied with automatic TTL. No tracking subdomain was configured. The existing `mail.snaglist.dev` domain and sending credentials remain intact.

Current deployed staging still uses `EMAIL_FROM=Snaglist <notifications@mail.snaglist.dev>` and a key scoped to that old sender. Provision a sending-only key restricted to the verified new domain, install it through the existing secret mechanism, then test new-domain login and Contractor-link delivery to Dan only before retiring any old sender. A verified Resend domain alone is not an email-delivery pass. SPF/DKIM header alignment, link destination, expiry/replay and spam placement need actual inspection.

Current staging `BASE_URL` and `MAGIC_LINK_BASE_URL` are still `https://snaglist-api-staging.danielmccann1705.workers.dev`. The adapter's exact-origin guard also expects that origin. The native staging configuration uses it. Change these together with provider/cookie/CORS/native-association checks; preserve old issued-link paths. The hostname's health response does not prove an origin migration or actual Google/Apple/Microsoft login.

Recommended remaining layout: marketing at the apex, manager portal at `app.usesnaglist.com`, production API at `api.usesnaglist.com`, staging API at the already configured staging hostname, and a separate staging portal origin. The production API and portal hostnames have **not** been attached to staging or placeholder deployments. The current unified branch still needs its matching Linux/private-R2 staging and release evidence; see NEXT-SESSION.md.

Configuration references: backend `Infrastructure/cloudflare/wrangler.jsonc`, its adapter source/tests, `Sources/App/Services/BrowserSessionService.swift` (`PORTAL_ORIGIN`, `PLATFORM_ENVIRONMENT`) and `Sources/App/Services/GoogleIdentityProof.swift` (`GOOGLE_AUTH_ENVIRONMENT`, `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`); native `Snaglist/Utilities/Configuration.swift` and the existing entitlements. Confirm actual symbols/paths before the later migration. Google Workspace staff email is independent of customer sign-in.

## Website follow-up

The currently served website is the existing 6 March Worker version. It still has waitlist/launching-soon copy, old “Magic Links” wording, legacy typography, placeholder help and contact `Snaglistapp@gmail.com`. Its source is `/Users/danielmccann/Desktop/Projects/snaglist_website`; `constants.ts` still contains the old `https://snaglist.app` URL. This turn changed routing only. Review the actual approved brand/product state before publishing a website update, and verify the new mailbox before replacing its contact link. Do not describe this legacy site as the completed brand/portal implementation.

## Reproducibility, evidence and rollback

Cloudflare account: `387d49014cd0d45f9e6434196ab513c0`. New zone: `524101d7172595a591bfcdec0c407c27`. Old zone: `4d84f938866cbe79b5f26299f02f7119`.

| Applied resource | ID / preserved state |
| --- | --- |
| Apex Worker binding | `994847e1e1f1fc8cb3f4fc102f5390639eccee50` |
| www Worker binding | `b5396553d79fe247efccad175c41dd014e9117a9` |
| Staging Worker binding | `ad924b4e85377f03945af7cd2f4fdf61b93080b1` |
| Redirect entrypoint ruleset / rule | `e778f83c93d248008268c2e1a64fa8d5` / `7f4dde1e43ed4cd39689660e591c35af` |
| Resend DKIM / return MX / return SPF / root DMARC DNS record IDs | `c377888c3dadebc5f532435cc15a2c38` / `e4a019e5a9494a645722469528e1978f` / `f71e164ec9cf2210ef17f629504533f9` / `278f8115ea82f72c7e129a753f739a7e` |
| Website Worker version, unchanged | `95b27eb4-c4c3-447f-993e-96cef18a83c0` |
| Staging Worker version, unchanged | `dd2bcc61-10a0-4e57-a433-0ca546c1591d` |

Local redacted evidence: `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/domain-setup/BASELINE.json`, `INITIAL-HTTP-CHECKS.json` and `FINAL-HTTP-CHECKS.json`. Final network check: 14:12:58 UTC. Resend's refreshed dashboard explicitly showed Verified. Staging adapter suite: **10 passed, zero failures/skips**. No new native, full backend or portal build is claimed for a DNS-only change.

Backend branch `feature/unified-platform`, baseline HEAD `10dfc87`, now records the additive custom domain in `Infrastructure/cloudflare/wrangler.jsonc`. Portal baseline HEAD `e02fbef`, native baseline HEAD `b58b773`; their application source is unchanged by this checkpoint. Preserve unrelated backend untracked configuration directories. Repository documentation copies are maintained alongside this report; check Git for the resulting documentation/configuration commits.

Rollback is additive and scoped: remove the three new Worker bindings and this new-zone redirect rule if needed; restore `always_use_https` from `on` to its prior `off` only if specifically necessary. Leave existing old-domain bindings and images intact. Remove only the listed new email DNS records if abandoning the new sender, after checking whether Workspace has subsequently started using the root policy. Handle DNSSEC through Cloudflare Registrar to keep DS publication consistent, not manual deletion of DNS records. No database rollback is involved.

Do not run a blanket `wrangler deploy --env staging` solely to reproduce this routing edit: the checked-in configuration builds a Container image from the current, substantially newer unified-platform branch. The domain was attached through the Cloudflare API specifically without changing that deployed image. The matching platform deployment remains a separate tested operation.
