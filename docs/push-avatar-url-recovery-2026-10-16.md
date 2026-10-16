# Push sender avatar recovery from saved metadata URLs

Date: 2026-10-16. The Notification Service Extension now resolves sender images as shared snapshot → saved preferred HTTPS URL → saved original HTTPS URL → deterministic initials. Full and summary notifications use the same rich renderer. Server code and push/XMPP wire payloads are unchanged.

## Behavior

`PushNotificationAvatarResolver` keeps account/contact and group-participant cache precedence. Network lookup uses only the exact account/contact shared metadata. It tries at most two distinct URLs accepted by the existing media URL policy. Each transfer has a three-second deadline, streaming two-MiB limit, sixteen-million source pixel limit and 256-pixel normalized output. HTTP status, MIME and image decoding are checked; redirects are revalidated. Cancellation, network/status/decode failures retain the initials fallback. Both metadata URLs are checked again after each awaited transfer; a changed/removed source rejects old bytes. NSE keeps existing pre/post-await credential, request generation and wipe checks.

Downloaded bytes are used only for the current `INPerson`/communication notification. The extension does not write the shared snapshot, clear deletion markers or change Contacts. Owner deletion blocks URL lookup. Temporary avatar files are deleted before returning, on success and failure.

`CommonContactsMetadataManager` has an additive optional `avatarOriginalUrl` field. Existing records without it continue with their preferred URL. Main app PEP avatar metadata saves the original `<info url>` including an unchanged metadata reply so upgrades can populate this field. Name updates with the same preferred URL preserve it; changing/removing the preferred URL without a replacement original clears it. Paths are never reconstructed. This is necessary for the observed server case where advertised WebP thumbnails return301→404 but the advertised original PNG returns200.

Debug traces include cache identity/hit/bytes, both URLs, complete explicit request metadata, redirects/response status and headers, transferred/normalized size, discard/failure/fallback and selected image source, then INPerson/donation/content completion. Existing raw stream and push payload logging remains unmodified. Runtime evidence stays outside Git.

## Verification

- Cache-only baseline:13 resolver tests ran with10 expected assertion failures.
- Implementation:89 affected tests passed (resolver19, shared snapshot25, rich extension26, local rich content19), building app/NSE.
- After immediate avatar staging cleanup:38 resolver/transport/local-renderer tests passed; app/NSE rebuilt by test action.
- Signed physical app/NSE build/install passed. Actual iPad NSE full-push request E083B50C-01D8-4ECC-BE36-2670DC897913 passed cache-miss → thumbnail301/404 → originalPNG200/112288bytes → normalized32982bytes → INPerson/donation/content completion in719ms. Additional opt-in hosted physical test passed1/1:32982-byte256×256remote image, INImage/content conversion succeeded, sharedsnapshot unchanged. User visual banner confirmation was requested but has not been received; the actual NSE download/intent/content path is verified.

The gated `PushNotificationAvatarDeviceTests` uses runtime owner/sender parameters and the actual App Group metadata with a missing snapshot. It performs real HTTP, validates non-initials image data and INImage/content conversion, and asserts the shared snapshot remains untouched. It does not send a message, donate an interaction or schedule a notification. This smoke test does not substitute for an actual NSE/APNs banner check.

Final iPad hostPID1415 remains in the background with both XMPP streams disconnected; full Debug raw capture continues. The failed first optional hosted smoke run selected an old test bundle in the wrong app host; rerunning with the physical host bundle explicitly set to xabber.ios and runtime storage isolation passed. No source workaround or cache reset was needed.
