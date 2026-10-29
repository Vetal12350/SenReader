# Unified favorites and manual chapter checks

The configured sites remain exactly Senkuro, ReadManga and ReManga. There is no
Android scheduler or native notification integration in this stage.

## Manual use

Open a saved title and choose **Проверить новые главы** (Check new chapters), or
use that action in the library app bar to check the whole library. The result
screen also has a labeled button to repeat the check. It displays errors per
source/chapter and a saved inbox of new chapters. Tap a chapter to open the source
first detected as accessible. After another check, buttons offer any accessible
later copies, including another translation branch on the same site. The title's
source picker also remains available. Marking a chapter read removes it from the
inbox, retains its notified key, and records progress independently of source.

**Связать источник** (Link source) searches for a title on another site. Search
results are suggestions: the dialog names both titles and the candidate site/ID,
and only **Подтвердить связь** confirms the connection. Cancel does not save it.
If the candidate is already a favorite, confirmation combines the favorites,
both progress histories and their chapter state. Conflicting IDs from one site
are rejected rather than overwritten. One source entry per site is supported.

Automatic matching uses only an exact normalized title with one candidate per
site. Fuzzy/localized matches and same-label, different-ID collisions are never
automatically joined. Existing separate favorites require confirmation before
being combined. A title rename cannot change a saved favorite's stable ID.
Known ambiguous catalog groups retain a persisted approval requirement, including
after reopening the app, so searching in the reverse direction cannot silently
connect a previously ambiguous candidate.

## Persistence and migration

`senreader.library.v1` remains unchanged as a backup. On first load without v2,
the complete v1 list is parsed and copied into `senreader.library.v2`, containing
`{"version":2,"books":[...]}`. Migration assigns stable IDs to each old record,
preserves all source entries and the exact `lastChapter`/`lastSource` labels, and
copies legacy progress into the progress history. Update state starts without a
baseline, so migration cannot announce old chapters. Subsequent loads use v2 and
do not reimport the backup or duplicate history.

Malformed data or an unsupported schema version blocks writes and exposes a
library error; the original stored strings are not replaced by an empty library.
Edits and checks run in a serialized queue. They operate on a copy and publish it
only after SharedPreferences acknowledges the complete v2 write. A failed source
never clears progress, seen keys, notified keys or inbox entries. The inbox is
saved with the keys before returning results to the UI, so reopening the app can
display an interrupted check's result without announcing the chapter again.

## Chapter identity and detection

`canonicalChapterKey` uses volume plus precise decimal chapter number, for example
`v2:c7.125`. It normalizes leading/trailing zeros and decimal commas using strings,
without floating-point rounding. It excludes subtitle, translation ID and site
chapter ID. Adapters retain structured Senkuro `volume`/`number`, ReManga
`tome`/`volume` and `chapter`, and ReadManga's volume/chapter label coordinates.
Recognized old chapter labels can also provide coordinates for legacy progress.

Missing volume metadata uses volume `0`; it is not guessed to equal a known
volume. Unnumbered specials or invalid coordinates are skipped with a warning.
Inconsistent numbering or volumes between sites therefore need correction in an
adapter before they can safely be deduplicated; title similarity, chapter IDs and
subtitles are not used to guess chapter equivalence.

`reduceChapterCheck` is a pure state reduction over accessible detections ordered
by actual detection. `ChapterChecker` requests linked sites concurrently and
checks public page metadata, with at most four page-metadata requests at once per
site. It does not download image bytes during checks. ReManga's published/locked/
paid flags are filtered first, and purchased flags are never trusted without a
session. HTTP errors (including 403), empty page metadata and blocked releases do
not create seen/notified keys. A previously blocked chapter can be detected when
it becomes freely readable. Previously seen chapters outside the inbox do not
need another page-metadata request.

The first successful check initializes the title's
baseline and records accessible keys without adding anything to the inbox. An
empty/paid-only successful listing also establishes a baseline. If every listing
fails, or every numbered candidate's reader is inaccessible, the title stays
uninitialized until its first readable lookup. Later checks add each newly detected key
once, regardless of how many sites/translations expose it. Senkuro and ReManga
inspect all returned translation branches within their existing pagination caps.

The winning source is whichever public page-metadata request first succeeds for
that key; provider insertion order and catalog cover preference do not decide it.
Detection timestamps are local observation times, never publication timestamps.
An old release first discovered after a source outage or a newly approved link
can appear as newly detected: no claim about its actual publication time is made.
Source lists remain bounded (Senkuro: 10 pages of 100 per branch; ReManga: 5 pages
of 500 per branch). Later image downloads can still fail or access can change;
the reader displays those errors and another accessible copy can be selected.

## Offline verification

`test/chapter_updates_test.dart` covers pure baseline/idempotency, decimal and
volume keys, subtitle/ID changes, detection ordering, partial/all-source outages,
paid/locked/empty releases, v1 migration, malformed storage, app restart,
concurrent checks, progress, ambiguous matching and confirmation UI. Widget tests
exercise the manual action and opening the selected chapter.
`test/chapter_metadata_test.dart` uses synthetic HTTP fixtures for all three
adapters, multiple branches, precise volume/number preservation, paid-only titles
and 403 reader endpoints. Existing source tests remain offline.

Run `flutter test` and `flutter analyze` in the trusted Flutter CI environment,
then build the debug APK and review before merge. No live-site verification or
local Flutter/Android build was performed while implementing this stage.
