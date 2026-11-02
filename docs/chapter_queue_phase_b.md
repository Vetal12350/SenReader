# Phase B: Android-local resumable chapter checks

Based on phase A branch (PR #117). No servers, FCM or paid infrastructure.

A SQLite job is keyed by profile, saved book, provider and manga ID. Reconcile
retains existing state and removes subscriptions no longer eligible. Only reading
and trusted linked sources qualify. A claim persists a finite five-minute lease,
incrementing fencing token and turn before network I/O. Finishing checkpoints each
pair. A killed worker leaves a lease which expires: no task is permanently lost.
There is no library-position or reading-activity priority. Providers alternate.

Scheduled work uses a 120-second soft budget instead of a 12-source cap. The active
pair is bounded by 45 seconds or the remaining duration, whichever is smaller. No new production HTTP work or inbox
commit starts after the deadline. A timeout retains the finite lease; subsequent
runs continue other eligible jobs. A delayed HTTP response may still finish in the
transport; the deadline prevents further chained requests or inbox writes.

**Only automatic chapter scans** use the persistent device-wide per-provider
request gate: one request at a time, a two-second minimum interval, and an
expiring request lease. The scan zone is explicit, scoped to the WorkManager
scanner's per-pair run, and is propagated through its asynchronous HTTP calls.
Injected fixture clients keep their deterministic transport.

HTTP 429 persists Retry-After for **background scans** (at least one minute;
default 30 minutes); HTTP 403 defers automatic background checks for 24 hours.
One provider's background cooldown does not block the other queue. Explicit
foreground browsing, chapter opening and image loading use their established
request paths, so a background 403 does not disable reading for 24 hours.
Foreground responses still surface 403/429 normally; existing Senkuro
request throttling/retry-after handling remains active. Neither path bypasses
CAPTCHA, access restrictions, or provider rate limits. These defaults are not
a declaration of permission or a guarantee that 429 cannot occur.

WorkManager's existing connected/battery constraints and 15-minute opportunistic
schedule remain. Catch-up is unawaited by UI startup and shares the same SQLite
claims with background work. Home renders cached/inbox results instead of privately
checking 12 recently read books. Previously committed inbox updates render without
waiting for network; unobserved updates require catch-up. Doze, OEM restrictions
and force-stop can delay checks; force-stop recovery requires user interaction.

The SQLite queue is separate from reading history and Firebase library data.
Legacy manual timestamps seed newly queued jobs; completed pair checkpoints do not
rely on the full scan finishing. Changes preserve phase A's inbox-before-seen
ordering. Unit tests use actual SQLite for 70/200 jobs, abandoned leases, stale
owners, cooldowns, profiles, offline retry and budget-based continuation. Device
reboot/Doze/OEM behavior still requires Android-device validation.
