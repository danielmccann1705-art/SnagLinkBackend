# GitHub and current source state

Updated 12 September 2026. This file documents source storage, not production readiness.

| Component | GitHub repository | Visibility | Current development/release branch |
| --- | --- | --- | --- |
| ios | [danielmccann1705-art/Snaglist-iOS](https://github.com/danielmccann1705-art/Snaglist-iOS) | private | `feature/unified-platform` |
| backend | [danielmccann1705-art/SnagLinkBackend](https://github.com/danielmccann1705-art/SnagLinkBackend) | public | `feature/unified-platform` |
| portal | [danielmccann1705-art/Snaglist-Portal](https://github.com/danielmccann1705-art/Snaglist-Portal) | private | `feature/unified-portal` |
| website | [danielmccann1705-art/snaglist-website-next](https://github.com/danielmccann1705-art/snaglist-website-next) | public | `release/website-usesnaglist` |

## This checkout

- Repository: https://github.com/danielmccann1705-art/SnagLinkBackend
- Push remote: `origin`.
- Current work: `feature/unified-platform`. The branch contains the implementation history and the instruction/readiness documentation; a local commit is backed up only after its GitHub branch SHA matches.
- This GitHub update does not merge into `main`, submit an App Store release or activate online services. Existing repository visibility is preserved; the new portal repository is private.
- Push the intended branch explicitly after reviewing its diff and secret scan. Do not use blanket `git add -A`, `git push --all`, `--mirror` or force-push as a backup shortcut.

## Current release boundary

Dan confirmed on 12 September 2026 that the currently released iOS app has **no online services**. The online services and manager portal are planned together for **v2.0**. A backend deployment, synthetic test or network-capable branch does not establish released functionality. Preserve existing offline use and on-device data.

The unified app/portal is not release-ready until ownership-backed import, account isolation, the complete canonical sync journey, permissions/private media, provider/billing checks and D1/D2 acceptance are complete. Prove ordinary iOS capture → distinct authorised portal manager → scoped Contractor link → completion evidence → accepted closure → app/fresh-device/report parity. Local test success does not replace this acceptance.

`docs/platform/NEXT-SESSION.md` and related dated reports describe earlier implementation checkpoints. Their older online-service/outage assumptions are superseded by the release boundary above.

## What belongs in GitHub

Commit application source, source assets, relevant tests, safe example configuration and maintained project documentation. Keep credentials, customer records, bearer links/PINs, local databases, build caches and machine-specific agent settings out of source control. The developer's personal skill overrides live outside these repositories; `AGENTS.md` records the portable project agreement.

GitHub stores source. Cloudflare is the deployment platform; a push is not proof of deployment. The backend still contains historical workflows for `main` and `staging`; these current feature-branch pushes do not run those deployment workflows. Reconcile retired Hetzner automation before any future main/staging release change.

The Snaglist Google Drive knowledge bank remains the location for the controlling brief/register and approved brand/design assets. For current project instructions, start with [AGENTS.md](AGENTS.md), then the references relevant to the task.
