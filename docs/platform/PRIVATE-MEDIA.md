# Private media candidate — 10 September 2026

## Implemented and tested locally

New v2 internal-user routes allocate a stable asset UUID against a real authorised snag, exact SHA-256/size/MIME and capture/completion purpose. Completion uploads also require an intention UUID; they cannot masquerade as capture evidence. Allocation, binary processing and revisioned capture attachment are distinct operations. Binary retries retain the same asset and bytes; capture attachment uses the normal immutable operation receipt and expected snag revision. Failed or interrupted work is not presented as attached.

Original JPEG/PNG bytes stay private; a separately encoded JPEG strips source metadata and is served through a same-origin, authenticated, no-store gateway. Reads recheck current project access before and after fetching bytes. Unattached uploads are visible only to their uploader and expire for access after 24 hours. Attached evidence appears in register previews, bounded manifests, consistent register snapshots and atomic change events. Original public media tables and URLs remain untouched.

The portal preserves photo bytes, allocation/attachment intentions and uncertain retries in account-owned memory while changing snags/projects. Conflicts require explicit use of the latest snag before retry. Sign-out disposes photo tasks and warns about pending work; the file is not yet a persistent offline queue.

## Evidence

- Full backend: platform-private-media-full-final, 218 passed / 0 failed / 0 skipped, 34.661s including build; source fingerprint in JSON.
- Subsequent register-preview addition: platform-private-media-preview, 7 passed / 0 failed / 0 skipped.
- Portal generated contract, TypeScript and production build pass; 25 tests including binary transport, uncertainty, conflict, disposal and stale photo reads.
- Actual Chrome: chose the existing synthetic door-before.png in the native file picker; real cookie/CSRF allocation, upload/process and attachment succeeded. The original-defect panel, register thumbnail and enlarged viewer survived reload. The snag stayed Open.
- Actual capture: connected-register-private-photo-local.png. Corrected a cropped preview to show the full image and replaced the stale missing-photo row icon with a private preview.

## Configuration and limits

R2_PRIVATE_BUCKET_NAME must be a separate bucket from R2_BUCKET_NAME; R2_ACCOUNT_ID, R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY use the existing S3 client. Keep both r2.dev and custom-domain public access disabled. No private bucket provisioning/deployment verification was performed in this continuation. See [Cloudflare public bucket controls](https://developers.cloudflare.com/r2/buckets/public-buckets/) and [S3 compatibility](https://developers.cloudflare.com/r2/api/s3/api/).

Local fallback is restricted to testing or development with PLATFORM_ENVIRONMENT=local, and writes to PrivateMedia outside Public. It is excluded from Git and Docker build context. Production without private storage fails closed. Do not expose this directory through a static server.

Uploads are at most 10 MB; JPEG/PNG still images only, at most 40 MP and 12,000 pixels per side. Renditions have a maximum 4096-pixel side. macOS ImageIO processing was exercised. The Linux branch uses the existing runtime image's ImageMagick with explicit JPEG/PNG decoding, resource limits and a subprocess deadline. Linux build/process and R2 integration still need real staging verification; a local Docker image-processing diagnostic stalled on this host and is not a pass.

## Still required

The subsequent canonical completion/decision/evidence-consumption candidate is implemented and compiled at backend `7b4c8cd`, but database verification is pending (see WORKFLOW.md). Remaining: contractor grant/PIN media routes; cancellation/retirement and durable orphan deletion; annotation/original relationships and drawings; separate thumbnails/performance measurements (current row previews use the bounded rendition); HEIC/PDF processing; resumable large-file upload/range support; native upload/import/outbox integration. There is no claim of full WP-04/05/06, G1 or D2 acceptance.
