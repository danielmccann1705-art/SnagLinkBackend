# Snaglist domain and email configuration — 11 September 2026

Checkpoint: 15:17 UTC. Domain routing verified at 14:15 UTC; Google domain, Gmail and alias configuration completed in this continuation, with the verification limits below. This is an applied-configuration handover, not production platform acceptance. Owner: Daniel McCann. The registered customer domain is **usesnaglist.com**; the brand remains Snaglist. Keep the existing snaglist.dev domain and issued links.

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

## Google mailbox — setup and delivery checks complete

Dan explicitly approved **one Business Starter user on the £7/month Flexible plan, before tax, with no annual commitment**: `dan@usesnaglist.com`, with `hello@usesnaglist.com`, `support@usesnaglist.com` and `billing@usesnaglist.com` aliases. Aliases route into Dan's mailbox and do not add paid users. Do not ask for this plan approval again; do not select a higher tier, extra users or an annual commitment.

Dan completed password creation and checkout directly in Google. The preceding checkout showed **Business Starter, one user, Monthly plan, £0 due today and £7/month before tax starting 25 September 2026, cancel anytime**. The Admin console confirms one Active user, `dan@usesnaglist.com`, with one Business Starter licence. The new inbox contains Google's billing-information-received message stating that billing begins when the free trial ends. No extra users or paid aliases were created. The live **Billing → Subscriptions** page was subsequently read back: **Active, Google Workspace Business Starter, 1 assigned licence, Flexible Plan, £7.00 GBP per user/month**. The next billing date is **1 October 2026**; this is distinct from the paid-service start of 25 September shown at checkout. The subscription page also says paid service starts in 13 days. No early-start, upgrade or payment-plan change was made.

Google explicitly reports **usesnaglist.com verified** and **Gmail activated**. The user profile confirms these three saved alternate emails: `hello@usesnaglist.com`, `support@usesnaglist.com`, `billing@usesnaglist.com`. They route to Dan's single mailbox and are not independent logins. Google owns mailbox/alias routing; Cloudflare continues to host DNS and website redirects.

Applied DNS, all unproxied with automatic TTL:

| Record | Value / status | Cloudflare record ID |
| --- | --- | --- |
| Root ownership TXT | Actual Google verification challenge copied from setup; Google ownership verified | `e122272043b805f54593e73111030a4a` |
| Root MX | `smtp.google.com`, priority **1**; Google Gmail activation passed | `ce9882bee0c19288e7a1b183bc3cddbc` |
| Root SPF TXT | `v=spf1 include:_spf.google.com ~all`; public readback matches | `53e8050bc29177a06016be4f03d29955` |
| `google._domainkey` TXT | Actual **2048-bit** Google public DKIM key; public readback matches and setup confirmation accepted | `49307d5a76d5b641518f563b35fb82b9` |

No previous root MX/SPF/DKIM records were replaced. Existing Resend return-path records remain on their separate subdomain. Root DMARC stays `p=none`; Workspace headers now pass, while new-domain Resend delivery/header checks remain open. Only public DKIM material was read; Google retains the private key.

**Inbound delivery evidence:** three distinct labelled setup messages were sent from Dan's already connected personal Gmail at approximately 14:40 UTC, one each to hello/support/billing, using only synthetic setup text. After Dan restored sign-in, the active business address was verified as **dan@usesnaglist.com**. All three messages were found. Billing initially arrived in Inbox; hello and support initially arrived in Spam with Gmail's generic similarity-to-spam explanation. Both legitimate tests were reported as not spam, and the subsequent any-folder search visibly showed **all three in Inbox**. No blanket allowlist or filter was created. This confirms alias receipt, not guaranteed future inbox placement.

**Sending configuration saved and read back:**

| Identity | Gmail state |
| --- | --- |
| Daniel McCann `<dan@usesnaglist.com>` | Default sender, preserved |
| Snaglist `<hello@usesnaglist.com>` | Saved Send mail as identity |
| Snaglist Support `<support@usesnaglist.com>` | Saved Send mail as identity |
| Snaglist Billing `<billing@usesnaglist.com>` | Saved Send mail as identity |

All three use **Treat as an alias**. The selected reply option is **Reply from the same address to which the message was sent**. After re-authentication, real replies to the three existing synthetic tests each automatically selected their corresponding alias. The expanded From and recipient controls were inspected before sending.

**Outgoing acceptance — all three passed:**

| Reply identity | Received in Dan's personal Gmail | SPF | DKIM | DMARC |
| --- | --- | --- | --- | --- |
| `hello@usesnaglist.com` | Inbox, 16:12 UK time | PASS | PASS, `usesnaglist.com`, selector `google` | PASS |
| `support@usesnaglist.com` | Inbox, 16:13 UK time | PASS | PASS, `usesnaglist.com`, selector `google` | PASS |
| `billing@usesnaglist.com` | Inbox, 16:14 UK time | PASS | PASS, `usesnaglist.com`, selector `google` | PASS |

The receiving account's actual message metadata was read with the Gmail connector; From/To and `Authentication-Results` were checked. The SPF envelope sender is `dan@usesnaglist.com`, while the visible From is the chosen alias. Both share the same aligned domain. DMARC remains **p=none**, so passing authentication does not imply an enforcing anti-spoofing policy. These tests use only Dan's own accounts, with synthetic setup text. Inbox arrival here is not a guarantee for all providers or future messages. A separate new-message test from the primary `dan@` identity was not necessary for the alias reply acceptance and was not performed.

**Resolved session interruption:** the business session worked for alias setup, then disappeared around 15:07 UTC. Fresh Gmail navigation returned the personal account even while the older Admin page still displayed the business identity. A new sign-in explicitly requested the business password. Dan restored the session and the outgoing checks above then completed. Cause unknown; no password was read, reset or changed. This is historical context, **not an outstanding user action**. Do not repeat account creation, checkout or alias setup.

**Remaining platform work:** the staff mailbox is ready for correspondence and the support address has passed a real reply test. Public website/contact-copy replacement can now proceed with its normal review. Resend new-domain sender configuration, customer sign-in, invitations, Contractor links and production API/portal cutover remain separate, unverified work as described below. No such cutover was made by this mailbox task.

Local evidence: `outputs/domain-setup/GOOGLE-MAIL-DNS-CHECKS.json` is the historical public-DNS checkpoint at **14:46:24 UTC**. [GOOGLE-MAIL-VERIFICATION.json](https://drive.google.com/file/d/1_YSpnU0Dn7TxxYZdWpnGBoQ7Q_ynxYla/view) (local `outputs/domain-setup/GOOGLE-MAIL-VERIFICATION.json`) records the completed inbound, sender/reply and outgoing authentication checks plus the confirmed subscription. DNSSEC was rechecked at **15:09 UTC** and remains **pending**.

Sources: [Google Flexible versus annual plans](https://knowledge.workspace.google.com/admin/billing/compare-flexible-and-annual-fixed-term-payment-plans), [Google aliases](https://support.google.com/a/answer/33327), [Cloudflare DNSSEC](https://developers.cloudflare.com/registrar/get-started/enable-dnssec/).

## Transactional sender and origin migration still required

Resend domain ID: `4cb0f2cc-4587-4b5a-9738-7355cd6fc3c3`. Its DKIM public key was copied from the verified dashboard into TXT `resend._domainkey.mail.usesnaglist.com`. Return-path records are MX `send.mail.usesnaglist.com` → `feedback-smtp.eu-west-1.amazonses.com`, priority 10, and TXT `v=spf1 include:amazonses.com ~all`. Records are unproxied with automatic TTL. No tracking subdomain was configured. The existing `mail.snaglist.dev` domain and sending credentials remain intact.

Current deployed staging still uses `EMAIL_FROM=Snaglist <notifications@mail.snaglist.dev>` and a key scoped to that old sender. Provision a sending-only key restricted to the verified new domain, install it through the existing secret mechanism, then test new-domain login and Contractor-link delivery to Dan only before retiring any old sender. A verified Resend domain alone is not an email-delivery pass. SPF/DKIM header alignment, link destination, expiry/replay and spam placement need actual inspection.

Current staging `BASE_URL` and `MAGIC_LINK_BASE_URL` are still `https://snaglist-api-staging.danielmccann1705.workers.dev`. The adapter's exact-origin guard also expects that origin. The native staging configuration uses it. Change these together with provider/cookie/CORS/native-association checks; preserve old issued-link paths. The hostname's health response does not prove an origin migration or actual Google/Apple/Microsoft login.

Recommended remaining layout: marketing at the apex, manager portal at `app.usesnaglist.com`, production API at `api.usesnaglist.com`, staging API at the already configured staging hostname, and a separate staging portal origin. The production API and portal hostnames have **not** been attached to staging or placeholder deployments. The current unified branch still needs its matching Linux/private-R2 staging and release evidence; see NEXT-SESSION.md.

Configuration references: backend `Infrastructure/cloudflare/wrangler.jsonc`, its adapter source/tests, `Sources/App/Services/BrowserSessionService.swift` (`PORTAL_ORIGIN`, `PLATFORM_ENVIRONMENT`) and `Sources/App/Services/GoogleIdentityProof.swift` (`GOOGLE_AUTH_ENVIRONMENT`, `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_IOS_CLIENT_ID`); native `Snaglist/Utilities/Configuration.swift` and the existing entitlements. Confirm actual symbols/paths before the later migration. Google Workspace staff email is independent of customer sign-in.

## Website follow-up

The currently served website is the existing 6 March Worker version. It still has waitlist/launching-soon copy, old “Magic Links” wording, legacy typography, placeholder help and contact `Snaglistapp@gmail.com`. Its source is `/Users/danielmccann/Desktop/Projects/snaglist_website`; `constants.ts` still contains the old `https://snaglist.app` URL. This turn changed routing only. Review the actual approved brand/product state before publishing a website update; the new support mailbox has now passed receipt and reply checks. Do not describe this legacy site as the completed brand/portal implementation.

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

Local redacted evidence: `/Users/danielmccann/Documents/Codex/2026-09-06/her/outputs/domain-setup/BASELINE.json`, `INITIAL-HTTP-CHECKS.json` and `FINAL-HTTP-CHECKS.json`. Final network check: 14:12:58 UTC. Resend's refreshed dashboard explicitly showed Verified. Staging adapter suite: **10 passed, zero failures/skips**. No new native, full backend or portal build is claimed for a DNS-only change. Google alias/SPF setup references: [aliases](https://knowledge.workspace.google.com/admin/users/add-or-delete-an-alternate-email-address-email-alias), [SPF](https://knowledge.workspace.google.com/admin/security/set-up-spf).

Backend branch `feature/unified-platform`, baseline HEAD `10dfc87`, now records the additive custom domain in `Infrastructure/cloudflare/wrangler.jsonc`. Portal baseline HEAD `e02fbef`, native baseline HEAD `b58b773`; their application source is unchanged by this checkpoint. Preserve unrelated backend untracked configuration directories. Repository documentation copies are maintained alongside this report; check Git for the resulting documentation/configuration commits.

Rollback is additive and scoped: remove the three new Worker bindings and this new-zone redirect rule if needed; restore `always_use_https` from `on` to its prior `off` only if specifically necessary. Leave existing old-domain bindings and images intact. Remove only the listed new email DNS records (including the Google SPF record above) if abandoning the new sender, after checking whether Workspace has subsequently started using the root policy. Handle DNSSEC through Cloudflare Registrar to keep DS publication consistent, not manual deletion of DNS records. No database rollback is involved.

Do not run a blanket `wrangler deploy --env staging` solely to reproduce this routing edit: the checked-in configuration builds a Container image from the current, substantially newer unified-platform branch. The domain was attached through the Cloudflare API specifically without changing that deployed image. The matching platform deployment remains a separate tested operation.
