# Snaglist — domain and business email recommendation

Research checked 11 September 2026, approximately 13:20 UTC. Registration completed and verified approximately 13:52 UTC. Domain purchase is complete; website/API migration and email setup are not performed.

## Recommendation

Dan selected **usesnaglist.com** as the customer-facing domain. The Snaglist brand stays unchanged. **Google Workspace Business Starter** for one staff mailbox remains the recommended email host; no subscription has been activated. Domain registration is complete, as detailed below; production routing changes remain separate work.

`snaglist.dev` is a legitimate software domain. A familiar .com is my preference for the site's UK construction audience and verbal/email use. That is a design/marketing judgement, not measured customer research. Keep the owned .dev domain and preserve existing API/Contractor-link compatibility during any migration; replacing production origins is separate work.

## Registered domain — 11 September 2026

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

Start with one actual mailbox, proposed `dan@usesnaglist.com`, and `hello@`, `support@` and `billing@` aliases routed to that mailbox. Google supports up to 30 aliases per user without another licence; aliases are not independent logins/mailboxes or a substitute for additional staff accounts. The domain is registered; these addresses remain proposed until the mailbox and aliases are configured.

Sources: [Google GBP annual/flexible rates](https://knowledge.workspace.google.com/admin/billing/compare-flexible-and-annual-fixed-term-payment-plans), [UK Starter features](https://workspace.google.com/intl/en-GB_uk/index.html?hl=en-GB_uk), [alias rules](https://support.google.com/a/answer/33327), [adding a domain to an existing account](https://support.google.com/a/answer/7502379).

Lower-cost comparator: [Zoho Mail Lite](https://www.zoho.com/mail/zohomail-pricing.html?src=ft) advertises 5 GB custom-domain email from **US$1/user/month, billed annually**. Its pages returned inconsistent region/currency localisation during research, so this is the published USD comparison, not a verified UK checkout price. Google's familiar Gmail/Drive environment makes Starter my recommendation for this one-mailbox business.

Business mailbox hosting is independent of Snaglist customer authentication. Dan approved **Google, Apple, Microsoft and email link on iOS and web**; no customer needs a paid Snaglist staff Workspace mailbox to sign in. Keep Resend as the app's transactional email service, with the selected domain/subdomain verified and delivery tested; use Workspace for staff correspondence/support. Configure SPF, DKIM and DMARC consistently before switching senders. Recheck privacy/support URLs and Google/Apple/Microsoft production origins after the domain decision. Do not change old links or active provider registrations merely to update branding.
