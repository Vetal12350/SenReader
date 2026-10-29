# Senkuro ranking contract

`SenkuroSource.popular()` requests the existing public catalog operation
`mangas(first: 30, orderBy: {field: POPULARITY_SCORE, direction: DESC})`.
This is **generic source popularity**, not a verified read count, aggregate
rating, or day/week/month chart. The adapter preserves the returned order;
the first valid occurrence wins when either slug or source ID repeats.
It never sorts by score or manufactures a ranking from another source.

## Public evidence checked on 2026-10-29

- [Senkuro homepage](https://senkuro.com/) publicly displays “Самое читаемое”
  with day, week and month controls. This verifies the website feature exists,
  but does not establish its API operation, period values or counting semantics.
- The [upstream adapter referenced by README](https://raw.githubusercontent.com/redcatpet/mangayomi-ru-sources/main/sources/ru/manga/senkuro/senkuro.js)
  defines `Q_MANGAS` and `getPopular()` using `POPULARITY_SCORE DESC`.
  It also lists `VIEWS` as a catalog sort, without a period argument. These are
  concrete query examples, not an authoritative complete Senkuro schema.
- The [Keiyoushi query definitions](https://raw.githubusercontent.com/keiyoushi/extensions-source/master/lib-multisrc/senkuro/src/eu/kanade/tachiyomi/multisrc/senkuro/SenkuroQueries.kt)
  expose another catalog operation, `mangaTachiyomiSearch`, with `orderBy` but
  no period parameter in the inspected query. This does not prove no such API exists.
- The research web tool could not access `https://api.senkuro.com/graphql`,
  including an anonymous GET schema-introspection request. A direct anonymous
  homepage fetch from the local environment also failed at the connection layer.
  No usable live schema or period-specific response was obtained. Neither failure
  establishes an authentication requirement or the absence of period charts.

**True period charts are not implemented.** No public period-specific GraphQL
contract could be verified in this investigation. Do not label `popular()` as
“Самое читаемое за день/неделю/месяц”, reuse its results for three period tabs,
or reinterpret `VIEWS` as a time-window count. Further implementation requires
an accessible anonymous schema or public first-party query plus evidence of
the period variables, response shape and server-side ranking semantics.

## Transport and failure policy

The optional `http.Client` is caller-owned and is not closed by the adapter.
With the default constructor, a client is created and closed per request.
Requests use the fixed HTTPS endpoint, no credentials/cookies, no redirects,
and no automatic retries after access restrictions or rate limits.
The 18-second deadline covers headers and streamed body consumption; the body
is limited to 4 MiB, checked against both declared length and received bytes.
HTTP failures, malformed JSON/connection shapes, and GraphQL errors (including
partial data) raise `SourceException` rather than producing a misleading list.
Malformed individual catalog nodes are skipped; an explicit empty edge list
is valid. Chapter pagination retains the existing ten-batch bound.

Covers and page images must be absolute HTTPS URLs with DNS hostnames, no
credentials, whitespace, backslashes, fragments, IP literals, local hostnames,
or nonstandard ports. External CDN DNS names are allowed because no complete
first-party CDN allowlist was verified; this is syntactic validation, not DNS
resolution or a guarantee about a CDN's redirects. Invalid covers become empty
without removing the manga from its source position. Pages prefer a valid
compressed URL and fall back to a valid original URL.

## Offline validation

`test/senkuro_ranking_test.dart` uses synthetic `MockClient` and streamed
fixtures only. It covers order, both deduplication keys, malformed payloads,
GraphQL partial/errors, HTTP 403/429, client/timeout failures, body limits and
cancellation, cover validation, search variables, detail/chapter pagination,
and page ordering/fallback. Fixtures do not certify live API compatibility.

Run in Flutter CI: `flutter test test/senkuro_ranking_test.dart`, followed by
the normal analysis, full tests and APK build. Flutter/Dart SDKs were not
available in this checkout environment, so those checks were not run locally.
