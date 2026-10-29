# Native library transfer (data layer only)

`lib/data/library_transfer.dart` provides offline export, validation and an
additions-only import preview. It has no network, file-picker, preferences writes,
UI integration or automatic merge. Storage, screens and reading-state models are
unchanged; this module does not depend on the status/page-resume work in PR #29.

## Format and lossless handling

The supported format is SenReader-native JSON, UTF-8, version **1**:

```json
{
  "format": "senreader-library",
  "version": 1,
  "books": [{
    "title": "Example",
    "entries": {
      "senkuro": {
        "source": "senkuro", "id": "example", "title": "Example", "coverUrl": ""
      }
    },
    "lastChapter": "Chapter 12",
    "lastSource": "senkuro",
    "seenChapterKeys": ["v0:c12"],
    "initializedSources": ["senkuro"]
  }]
}
```

`LibraryTransfer.exportBooks(savedBooks)` calls each `SavedBook.toJson()`, so
fields added by future models are included. Early v1 book records may omit the
four optional progress/baseline fields. The envelope is still required; raw
SharedPreferences arrays are not accepted as files.

`parseBytes` / `parse` return a `LibraryBackup`. `toJsonString()` re-exports all
envelope, book and entry fields, including unknown fields. Formatting is not
preserved. `TransferBook.toJson()` returns a detached copy; lists of records and
preview items are unmodifiable. **Do not round-trip through
`SavedBook.fromJson()` in an older application**: that model may drop unfamiliar
completion, status or chapter/page fields. Opaque future fields are retained as
JSON, not interpreted or executed. Future persistence must preserve them or
refuse to apply a record it cannot store losslessly.

## Validation and limits

- Maximum 5 MiB of UTF-8, 5,000 books, 32 nested containers/values and 250,000
  JSON values. Future file-picker code must also cap the read before allocating
  the entire input. Invalid UTF-8, malformed JSON and repeated object keys
  (including escaped spellings) throw `FormatException`.
- Known fields are type checked. Titles must normalize to nonempty text, entry
  maps must be nonempty, and entry source fields must match their map keys.
  Only `senkuro`, `readmanga` and `remanga` are accepted. Source slugs/IDs use
  ASCII letters, digits, `_` and `-`. ReadManga accepts a single title path or
  an HTTPS title URL on `a.zazaza.me` / `3.readmanga.ru`.
- State source references must belong to the book. Known baseline lists reject
  duplicate/non-string values, more than 20,000 items, or overlong keys (128
  characters for chapter keys, 32 for initialized sources). General known strings
  have a 4,096-character cap and reject control characters.
- Nonempty covers must use HTTPS on an explicitly trusted host. The default
  hosts are `senkuro.com`, `remanga.org`, `a.zazaza.me`, `3.readmanga.ru`.
  Credentials, explicit ports, queries, fragments, whitespace, backslashes and
  percent escapes are rejected. These conservative rules can reject existing
  covers served by other CDNs. A caller may supply `trustedCoverHosts` from
  reviewed application policy; the backup cannot extend that policy. No URL is
  fetched during parsing or preview, including retained opaque fields.

## Preview rules and counts

Call `preview(backup, existing: localSnapshots)`. Use `snapshot(savedBooks)` for
current in-memory models, or lossless backup records for newer fields. Compare
against a fresh local snapshot again immediately before any future user-approved
write; a preview is not a transaction or permission to overwrite storage.

Each incoming row gets exactly one disposition, in file order:

1. **Conflict:** another local or incoming row shares the exact `normalizedTitle`
   key or a known `(source, ID)` identity but has different JSON data. All rows in
   a colliding group are withheld. Candidate normalized keys are exposed, sorted,
   for later confirmation. ReadManga paths/current/legacy origins share identity.
2. **Duplicate:** an identical incoming row has already been classified, with no
   conflicting candidate. Repeated records are counted, never added twice.
3. **Existing:** the first identical incoming row matches local data. Keep local.
4. **New:** no colliding candidate exists. Only these rows appear in `additions`.

Object-key order does not affect equality; array order does. Counts are exclusive
and sum to the input row count. Duplicate JSON object keys are invalid input;
repeated whole records are preview duplicates, while semantic title/source
collisions are preview conflicts. Conflicts take precedence over duplicates.

Matching a title alone never authorizes replacing or extending an existing book.
Even an incoming record with later chapter progress or additional sources is a
conflict if local data differs. Existing entries, completed markers, chapter/page
position, notification baselines and unknown fields remain untouched. No progress
comparison or baseline union is attempted. Different translated titles are never
fuzzy-merged; a shared source ID surfaces ambiguity, otherwise they stay separate.

## Privacy and future integration

Backups contain personal reading history and source URLs. They are plain JSON,
not encrypted. Keep them private; the engine sends nothing and logs nothing.
Future UI work should use a user-selected local file, bounded reads, safe error
messages without echoing file contents, preview counts and explicit conflict
resolution. It must not load cover URLs or interpret opaque fields during preview.
Any apply step must preserve lossless records, recheck the local snapshot, and
be reviewed separately after PR #29. Notification scheduling/global preferences
are not exported by this per-book format.

Senkuro direct account/cloud import and third-party bookmark formats are **not
supported**. A trustworthy official Senkuro export sample/API has not been
validated. No authentication, paywall, CAPTCHA or access-control bypass is involved.

Offline checks for CI: `flutter test test/library_transfer_test.dart`, then the
existing full test suite and `flutter analyze`. APK validation remains in CI.
