# Snaglist — domain and business email recommendation

## Domain wiring and approved monthly mailbox — 11 September 2026

The existing website is now live at **https://usesnaglist.com**, with HTTPS and a tested www → apex redirect. **https://staging-api.usesnaglist.com/health** returns 200 as an additive alias to the existing 9 September staging deployment. Resend **mail.usesnaglist.com** is Verified; the deployed sender is still on the old domain and new-domain message delivery has not been tested. DNSSEC activation is pending. Existing .dev routes are preserved; production API health remains 530 and the manager portal is not deployed.

Dan approved **one Google Workspace Business Starter user, £7/month Flexible before tax, no annual commitment**, `dan@usesnaglist.com` with `hello@`, `support@` and `billing@` aliases. Dan completed checkout. Google reports **usesnaglist.com verified and Gmail activated**; the Admin console confirms one active Business Starter user and the three saved aliases. Google MX, SPF and 2048-bit DKIM are published and publicly checked; the setup wizard accepted DKIM confirmation. One synthetic test to billing@ visibly arrived in Dan’s new inbox. Tests to hello@ and support@ were sent, but receipt and outgoing authentication headers remain unverified. Google then signed the new mailbox out; its actual alert requested a new sign-in. A Chrome sign-in page is prepared for dan@usesnaglist.com and Dan was asked to sign in again. After that, finish alias From/reply settings and delivery/header checks. This is not a new account, password-creation or plan-approval request. Never inspect or record credentials or payment details. See [DOMAIN-CONFIGURATION.md](https://drive.google.com/file/d/15Itk0Yvjib5FagJ22Gx4oRQiOIVwqq_y/view) for applied resources, tests, remaining origin/sender work and scoped rollback. Website routing is complete; this does not establish platform production readiness.

Research checked 11 September 2026 at approximately 13:20 UTC; registration verified at 13:52 UTC. Domain wiring checkpoint: approximately 14:15 UTC. The latest applied status below supersedes the historical registration-only checkpoint.

## Recommendation

Dan selected **usesnaglist.com** as the customer-facing domain. The Snaglist brand stays unchanged. **Google Workspace Business Starter Flexible** for one staff mailbox is now approved at £7/month before tax; checkout is complete and Gmail is activated; final delivery checks await a restored sign-in. Website and staging domain wiring are applied, as detailed above; production API/portal cutover remains separate work.

`snaglist.dev` is a legitimate software domain. A familiar .com is my preference for the site's UK construction audience and verbal/email use. That is a design/marketing judgement, not measured customer research. Keep the owned .dev domain and preserve existing API/Contractor-link compatibility during any migration; replacing production origins is separate work.

## Historical registration checkpoint — 11 September 2026, 13:52 UTC

**usesnaglist.com is registered and Active in the existing Cloudflare account.** Dan confirmed personal ownership, supplied the required phone number, and the registrant organisation field was removed. The saved contact table confirms **Daniel McCann** as registrant, administrator, technical and billing contact. Contact/address/payment details are retained in Cloudflare, not this knowledge bank or source control.

- Purchase: **US$10.46 for one year**, using the existing saved payment method. Final checkout showed US$10.46 due today; the purchase completed and Cloudflare displayed “Your domain is ready”.
- Invoice: the billing page says a consolidated invoice appears within 24 hours. No invoice for this order was listed yet at the verification checkpoint; the checkout success and Active domain establish completed registration.
- Expiration: **11 September 2027**.
- Automatic renewal: **enabled**, currently **US$10.46/year**, scheduled for **12 August 2027**. Future registrar prices/taxes may change; this is the current account display.
- Verification: domain management explicitly reports **Active**. No outstanding registrant-email-verification prompt was shown on the overview or contact pages at this checkpoint. This is an observed dashboard result, not a claim about unread email.
- Secure registrar defaults: the checkout includes WHOIS privacy. DNSSEC was advertised as included, but enablement has not been independently verified or changed; do not claim it is active from the inclusion label alone.

The personal registration replaces the earlier pending-owner/phone checkpoint. No second domain, registrar upsell or email subscription was bought. Google Workspace Business Starter remains the recommended mailbox host; its paid plan still needs selection before activation.

**Next implementation work:** prepare the website and manager-portal origins, transactional sender verification and production Google/Apple/Microsoft configuration against this owned domain. Preserve existing `snaglist.dev` API and Contractor-link URLs, including issued links. No production routes, email DNS or sender identities were changed as part of registration. Re-test sign-in, invitations and Contractor links after any later origin/sender changes.

Registrar workflow: [Cloudflare domain registration](https://developers.cloudflare.com/registrar/get-started/register-domain/).

## Live availability and price observations

| Candidate | Observed result | Assessment |
| --- | --- | --- |
| [usesnaglist.com](https://porkbun.com/checkout/search?q=usesnaglist.com) | Porkbun live search offers registration at **US$11.08/year**, renewing at **US$11.08/year**. Verisign RDAP returns no registered object (404). | First choice: readable .com, keeps the exact brand inside a short action phrase, suitable for app and web. |
| [snaglisthq.com](https://porkbun.com/checkout/search?q=snaglisthq.com) | Porkbun live search offers registration at **US$11.08/year**, renewing at **US$11.08/year**. Verisign RDAP returns 404. | Strong alternative for a central company workspace; HQ needs spelling out when spoken. |
| [snaglist.io](https://porkbun.com/checkout/search?q=snaglist.io) | Shown as available in Porkbun's actual snaglist search: **US$28.12 first year**, **US$51.80 renewal**. | Exact brand, but a more expensive technology-oriented ending; less compelling improvement over the owned .dev. |

Prices are the registrar's displayed USD figures, not a converted GBP quote or a locked checkout. Availability can change before registration. No item was added to the Porkbun cart. The later Cloudflare registration checkpoint above supersedes the earlier recommendation price.

Exact `snaglist.com`, `snaglist.co.uk`, `snaglist.uk` and `snaglist.app` are registered according to their registry RDAP services. Porkbun lists `snaglist.co` unavailable. `getsnaglist.com`, `snaglistapp.com` and `snaglistpro.com` are also registered. A registered domain might be resold, but no current acquisition quote or owner approach was made. An old secondary listing for snaglist.com was not treated as a reliable current price.

Registry sources: [Verisign .com](https://rdap.verisign.com/com/v1/domain/snaglist.com), [Nominet .co.uk](https://rdap.nominet.uk/uk/domain/snaglist.co.uk), [Nominet .uk](https://rdap.nominet.uk/uk/domain/snaglist.uk), [Google .app](https://pubapi.registry.google/rdap/domain/snaglist.app). Registration checks included metadata only; no registrant personal data was copied.

## Google Workspace setup and cost

Business Starter's official GBP standard rate is **£5.90 per user/month with a one-year commitment** or **£7 per user/month on Flexible**, before applicable tax. One annual seat is £70.80/year before tax. The plan includes business Gmail and 30 GB pooled storage per user. Existing personal use of Google Drive does not itself prove an existing Workspace subscription. If Dan already pays for an eligible Workspace account, check whether the chosen domain can be added there before buying another subscription.

Dan approved one actual mailbox, `dan@usesnaglist.com`, and `hello@`, `support@` and `billing@` aliases routed to that mailbox. Google supports up to 30 aliases per user without another licence; aliases are not independent logins/mailboxes or a substitute for additional staff accounts. The domain is registered; these addresses are now configured in Google; final delivery and reply-address checks are recorded above.

Sources: [Google GBP annual/flexible rates](https://knowledge.workspace.google.com/admin/billing/compare-flexible-and-annual-fixed-term-payment-plans), [UK Starter features](https://workspace.google.com/intl/en-GB_uk/index.html?hl=en-GB_uk), [alias rules](https://support.google.com/a/answer/33327), [adding a domain to an existing account](https://support.google.com/a/answer/7502379).

Lower-cost comparator: [Zoho Mail Lite](https://www.zoho.com/mail/zohomail-pricing.html?src=ft) advertises 5 GB custom-domain email from **US$1/user/month, billed annually**. Its pages returned inconsistent region/currency localisation during research, so this is the published USD comparison, not a verified UK checkout price. Google's familiar Gmail/Drive environment makes Starter my recommendation for this one-mailbox business.

Business mailbox hosting is independent of Snaglist customer authentication. Dan approved **Google, Apple, Microsoft and email link on iOS and web**; no customer needs a paid Snaglist staff Workspace mailbox to sign in. Keep Resend as the app's transactional email service, with the selected domain/subdomain verified and delivery tested; use Workspace for staff correspondence/support. Configure SPF, DKIM and DMARC consistently before switching senders. Recheck privacy/support URLs and Google/Apple/Microsoft production origins after the domain decision. Do not change old links or active provider registrations merely to update branding.
