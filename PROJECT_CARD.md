# PROJECT_CARD — SenReader

**Дата составления:** 2026-11-15. **Назначение:** передача контекста другому ассистенту; только чтение исходных материалов.

**Область проверки и достоверность.** Прямо изучен приватный GitHub-репозиторий [`Vetal12350/SenReader`](https://github.com/Vetal12350/SenReader), ветка `main`, **HEAD `60c6573756ac5af652e2391cda3e807694308dfe` от 2026-11-03**. Проверены дерево Git, `README.md`, `AGENTS.md`, `pubspec.yaml`, CI, основные исходники, документация, коммиты и ветки. **Локальный Windows-репозиторий `C:\Projects\SenReader` и его незакоммиченные изменения здесь недоступны:** описания поздних версий 367–372 взяты *только из переданных владельцем отчётов Codex в переписке*. Не путать старый `main` и актуальную локальную сборку. Новая карточка создана вне репозитория; исходники/Git/телефон не изменялись.

**Маркировка:** **[Код/Git]** — непосредственно подтверждено доступной веткой GitHub; **[Док]** — прямо описано в документации (может отставать от кода); **[Отчёт владельца]** — сообщено в переписке, без доступа к локальным артефактам; **[Вывод]** — обоснованная интерпретация, требующая проверки.

## 1. Обзор

**Название:** SenReader. **Назначение [Код/Git, Док]:** личное Android-приложение для чтения манги и манхвы, преимущественно на русском языке. Объединяет каталог и поиск по публичным источникам **Senkuro** и **ReadManga**, карточки произведений, чтение длинных вертикальных глав, локальную библиотеку/закладки и сохранение прогресса. Исторические записи ReManga сохраняются для совместимости, но действующий адаптер ReManga из `main` удалён. Приложение не включает произведения или картинки в APK.

**Для кого:** для личного использования владельцем и, при добровольном подключении учётных записей, небольшой приватной группы. Основной сценарий — чтение с Android-телефона, продолжение с сохранённой страницы, отслеживание новых глав и опциональная синхронизация библиотеки. Это **не социальная сеть**, не сервер манги и не инструмент обхода ограничений источников.

**Стадия:** **активная разработка / личное тестирование на реальном устройстве**, не публичный production. README прямо называет приложение личной тестовой читалкой, а не production-релизом. **[Отчёт владельца]** На Pixel 8 Pro по состоянию на последний отчёт (11 ноября) установлена и проверялась **372**, локальные версии 367–372 обновлялись без сброса данных. Android подтвердил публикацию девяти уведомлений и успешное завершение одного worker за 120,65 с. При этом наблюдаются нерегулярность фоновых проверок, микрофризы чтения и жалобы на отзывчивость интерфейса; окончательное устранение не подтверждено.

## 2. Стек и окружение

**Язык и платформы [Код/Git]:** Dart, Flutter (SDK в `pubspec.yaml`: Dart `>=3.4.0 <4.0.0`), Android APK; Android-обвязка генерируется во время сборки командой `flutter create`. Python 3 используется для подготовки Android-обвязки и тестов скриптов, Bash — для Cloud/CI, PowerShell — для безопасной настройки подписи. CI: GitHub Actions на Ubuntu, Java Temurin 17, Flutter `stable`.

**Основные зависимости `pubspec.yaml` [Код/Git]:**

| Зависимость | Ограничение | Назначение |
|---|---|---|
| `sqflite` | `^2.4.2` | локальные SQLite-очереди и история уведомлений |
| `http` | `^1.3.0` | HTTP-клиент источников |
| `html` | `^0.15.5` | парсинг HTML ReadManga |
| `shared_preferences` | `^2.3.3` | локальная библиотека, настройки и часть состояния |
| `scrollable_positioned_list` | `^0.3.8` | список страниц и позиционирование в ридере |
| `workmanager` | `^0.10.10` | фоновые периодические и догоняющие проверки |
| `flutter_local_notifications` | `^22.3.3` | системные Android-уведомления |
| `firebase_core` | `^5.1.0` | инициализация Firebase |
| `firebase_auth` | `^7.0.1` | Google/e-mail авторизация |
| `cloud_firestore` | `^7.1.0` | приватная облачная синхронизация библиотеки |
| `google_sign_in` | `^7.1.1` | вход через Google |
| `crypto` | `^3.0.6` | хеширование стабильных идентификаторов |

Dev-зависимости: `flutter_test`, `sqflite_common_ffi`, `flutter_lints`. **Важно:** это версии зависимостей в GitHub `main` от 3 ноября, не гарантированно актуальные для локальной 372. `pubspec.lock` в проверенном дереве не обнаружен; точные разрешённые версии пакетов не установлены.

**Локальные хранилища [Код/Git]:** JSON библиотеки/настроек в `SharedPreferences`; несколько SQLite-таблиц/баз для inbox, очереди проверок, provider leases, диагностики и доставленных системных уведомлений. В GitHub `main` документация описывает inbox **v4** и scan queue **v2**; **[Отчёт владельца]** в локальной версии 370 выполнена миграция inbox **SQLite v4 → v5**. Не переносить это предположение на удалённый `main`.

**Внешние API/сервисы [Код/Git]:** Senkuro GraphQL (`https://api.senkuro.com/graphql`), сайт Senkuro, публичные HTML-страницы ReadManga (`https://a.zazaza.me` в коде), опциональные Firebase Authentication и Cloud Firestore, Android WorkManager/JobScheduler и уведомления, GitHub Actions/Releases. Отдельный backend, обязательная облачная учётная запись или FCM-сервер для проверок новых глав в основной архитектуре отсутствуют.

**Конфигурация — только ИМЕНА, без значений [Код/Git, Док]:**

- Firebase `--dart-define`/GitHub Variables: `SENREADER_FIREBASE_API_KEY`, `SENREADER_FIREBASE_APP_ID`, `SENREADER_FIREBASE_PROJECT_ID`, `SENREADER_FIREBASE_SENDER_ID`, `SENREADER_GOOGLE_WEB_CLIENT_ID`.
- Secrets GitHub Actions для release-подписи: `SENREADER_SIGNING_KEY_BASE64`, `SENREADER_SIGNING_STORE_PASSWORD`, `SENREADER_SIGNING_ALIAS`, `SENREADER_SIGNING_KEY_PASSWORD`.
- Cloud-тестовый скрипт: опциональная `CODEX_FLUTTER_DIR`; CI использует служебные `GITHUB_TOKEN`/`GH_TOKEN` и `GH_REPO` при публикации, а также локальные переменные сборочного задания.
- `firestore.rules` ограничивают документы `users/{uid}/library/{bookId}` проверенным владельцем аккаунта; удаление — через tombstone, не прямым `delete`.

**Документированные команды локального запуска/тестов (ЗДЕСЬ НЕ ВЫПОЛНЯЛИСЬ):**

```bash
flutter create --project-name senreader --org app.senreader --platforms android .
python scripts/prepare_android.py
flutter pub get
flutter test
flutter analyze
flutter build apk --debug
```

Выход обычной debug-сборки: `build/app/outputs/flutter-apk/app-debug.apk`. Для облачных Flutter-тестов: `bash scripts/codex_cloud_test.sh` (при необходимости скачивает Flutter и устанавливает зависимости; **не выполнять в режиме read-only**). CI описан в `.github/workflows/android-apk.yml`: проверки Python/PowerShell, генерация Android, analyzer, `flutter test`, debug APK, отдельный подписанный release и приватный `qa-latest`. Подписанный release должен иметь тот же сертификат, что установленное приложение.

## 3. Структура

**Дерево верхнего уровня `main` [Код/Git]:**

```text
SenReader/
├── .github/workflows/       # CI: сборка APK, bootstrap
├── AGENTS.md                # правила для Codex и других ИИ-агентов
├── README.md                # назначение, функции, сборка, ограничения
├── analysis_options.yaml   # Flutter/Dart lints
├── pubspec.yaml            # метаданные и зависимости Flutter
├── firebase.json           # путь к Firestore rules
├── firestore.rules         # правила доступа Firestore
├── branding/               # исходные векторные иконки Android
├── docs/                   # архитектурные решения, QA, Firebase, signing, Cloud
├── lib/
│   ├── main.dart           # старт Flutter, инициализация и главный экран
│   ├── core/               # модели, идентичности глав, интерфейс источника
│   ├── data/               # адаптеры API, хранилища, sync, очередь, уведомления
│   └── ui/                 # ридер, карточка манги, inbox, настройки, темы
├── scripts/                # генерация Android, Cloud-тесты, signing, backup
├── test/                   # Flutter/unit/widget/regression-тесты
└── _payload/               # пять фрагментов part00–part04; назначение не установлено
```

**Примечание:** постоянной папки `android/` в проверенном `main` нет: она создаётся на этапе сборки и дорабатывается `scripts/prepare_android.py`. Поэтому локальный Windows checkout может иметь дополнительные генерированные файлы.

**Точки входа и ключевые модули [Код/Git]:**

- `lib/main.dart`: `main()`, `SenReaderApp`, `MainShell`; инициализация `LibraryStore`, темы, аккаунтов, экранов и фоновых механизмов.
- `lib/data/chapter_background_scheduler.dart`: `@pragma('vm:entry-point') chapterWorkDispatcher()` — фоновый Dart entrypoint WorkManager; периодическая и разовая задачи.
- `lib/core/source.dart`, `models.dart`, `chapter_identity.dart`: контракт `MangaSource` (`popular`, `search`, `detail`, `pages`), модели и канонизация номера/тома главы.
- `lib/data/senkuro_source.dart`, `readmanga_source.dart`, `catalog_repository.dart`: два адаптера, общий поиск/каталог, консервативная связка тайтлов.
- `lib/data/library_store.dart`, `library_transfer.dart`, `cloud_library_sync.dart`, `firebase_account_service.dart`: локальное состояние, перенос библиотеки, профили, облачное слияние.
- `lib/data/chapter_checker.dart`, `chapter_scan_runner.dart`, `chapter_scan_queue.dart`, `chapter_scan_schedule.dart`, `local_source_gate.dart`: обнаружение новых глав, очередь SQLite, дедлайны, rate limits и leases.
- `lib/data/chapter_inbox_store.dart`, `chapter_notification_service.dart`, `chapter_alert_preferences.dart`: лента глав, статусы и Android-публикация.
- `lib/ui/reader_page.dart`, `reader_prefetch_policy.dart`, `reader_frame_metrics.dart`: ридер, загрузка/размеры изображений, предзагрузка, необязательные измерения.
- `lib/ui/detail_page.dart`, `chapter_inbox_panel.dart`, `settings_page.dart`: экран произведения, уведомления, настройки.
- `test/*_test.dart`: изолированные проверки источников, миграций, конфликтов, уведомлений, прокрутки и сохранения прогресса.

## 4. Архитектура и решения

**Явно задокументированные решения [Док + подтверждения в коде]:**

1. **Local-first.** Библиотека и прогресс доступны без входа и без сервера. Облако — опциональное. Гостевой профиль и профили Firebase разделены; данные гостя не выгружаются автоматически.
2. **Один активный источник у сохранённой книги.** Переключать перевод и переносить отметки чтения между источниками без явного решения нельзя. Ненадёжные совпадения названий не объединяются.
3. **Источник — отдельный адаптер** по `MangaSource`; данные глав, популярности, дат и авторов берутся из источника, не генерируются.
4. **Идентичность главы отделена от позиции в списке**: числовые главы/тома нормализуются, учитываются варианты названия; недоступная страница не эквивалентна новой опубликованной главе.
5. **Два уровня уведомлений:** долговечная локальная SQLite-inbox и необязательная публикация Android. Inbox записывается прежде уведомления; публикация не является общей транзакцией с SQLite, поэтому внешняя exactly-once доставка принципиально не гарантируется.
6. **Фоновые проверки на устройстве:** WorkManager, 15-минутная заявленная периодичность, SQLite-очередь, 120-секундный soft budget сканирования, ограниченный lease и cooldown источников. Успешная пара проверяется снова не ранее 30 минут, ошибка может повторяться через 5 минут; Android вправе откладывать задачи.
7. **Защита от гонок:** профильный namespace, lease/fencing token, checkpoint на уровне источника/главы, защита от устаревших результатов/облачных ревизий. Для части отказов допускаются задержки/недоставленные системные уведомления, но не потеря локальных обнаруженных глав.
8. **Ридер:** ленивый список длинных изображений, известная проблема меняющейся высоты изображений/геометрии, контроль декодирования, прогресс главы и страницы отдельно от отметки «прочитано».
9. **Сборка и подпись:** минимальный исходный Flutter-проект, Android wrapper генерируется в CI; публичный APK не является общедоступным артефактом, подписанная QA-сборка доступна владельцу приватного GitHub.

**Соглашения [частично явно в AGENTS.md, частично выведены из кода]:**

- **[Док]** Пользовательский интерфейс и обсуждение разработки — на русском. Не добавлять социальные функции, Shikimori/MyAnimeList, обязательный сервер/аккаунт без прямого запроса.
- **[Док]** Сохранность данных приоритетнее скорости релиза: не удалять закладки/прогресс, не менять package ID и подпись, не сбрасывать уведомления. Изменения небольшие, с регрессионными тестами.
- **[Код/Вывод]** Файлы/пакеты названы в `snake_case`, классы в `UpperCamelCase`, private members начинаются с `_`; слои `core` → `data` → `ui` в основном разделены. Сервисные хранилища выделены в отдельные классы.
- **[Код/Вывод]** Часто используются `Future`, `async/await`, `ChangeNotifier`/`ValueNotifier`; ошибки сетевых источников представлены `SourceException`/проверками HTTP/парсинга, для фоновых операций предпочтительны bounded retries и частичный успех вместо разрушительной перезаписи данных.
- **[Док]** В GitHub-работе — отдельная ветка и PR; не коммитить прямо в `main`, секреты, APK, скачанные страницы или пользовательские резервные копии. Для локальной разработки требование владельца в текущем диалоге ещё строже: никаких коммитов, пушей и установок без разрешения.

**Не подтверждено текущим локальным кодом:** детали `lastReading`, покомпонентные уведомления SQLite v5, файловый экспорт через SAF и ресурсы `notifications_init` в собранной 372. Это описывалось в отчётах Codex позднее ноябрьского GitHub `main` и требует прямой проверки в `C:\Projects\SenReader`.

## 5. Состояние работ

### Последние 20 коммитов `main` [Git, на 2026-11-15]

Это **GitHub `main`, не локальный `git log`**. Формат `SHA — тема` (сверху новые):

```text
60c65737  Fix automatic chapter scan reliability and diagnostics (#132)
3fc6204d  Fix reader image seams and offscreen decoding (#131)
22c5541f  Stabilize continuous reader geometry and image prefetch (#130)
f1f532b8  Group in-app chapter updates by manga (#129)
a304d8b0  Fix automatic chapter catch-up and add scan diagnostics (#128)
92ad355a  Fix bounded chapter alerts and inbox races (#125)
6fd74f2a  Protect reader session and profile writes after account switches (#123)
aa191750  Fix background scan progress races and stale chapter delivery (#119)
a4125dc7  Android-only chapter notifications: durable inbox and fair background scanning
86d6bcef  Release SenReader scroll, Continue and fair chapter alerts (#112)
069fee9b  Scan new chapters only for Reading titles (#107)
ced4461b  Add local-first automatic staggered chapter alerts and catch-up (#104)
698c508b  Fix saved ReadManga scans and add chapter-check diagnostics (#102)
eda1a03d  Fix first-scan and previously missed recent chapter notifications (#101)
70862968  Auto-select verified Senkuro/ReadManga chapters and deduplicate alerts (#100)
a9b56293  Optional Firebase accounts: Google + email/password with private library sync (#94)
2d3fb2c8  Handle Senkuro HTTP 429 quietly and preserve manga chapters (#98/#99)
ada84c44  Show ReadManga upload dates and retire ReManga safely (#95)
cc552a82  Speed up cold start, parallel source discovery, webtoon rendering (#93)
cea01a08  Focus current chapter, smooth autoscroll, recover missing images (#92)
```

### Незакрытые задачи и ветки

- **[Git]** В GitHub API обнаружено **111 веток** (100 на первой странице и 11 на второй). Помимо `main`, есть `fix/automatic-scan-reliability`, `fix/reader-seams-pipeline`, `fix/reader-scroll-geometry`, `fix/chapter-inbox-phase-a`, `fix/inbox-delivery-recovery`, `fix/reader-profile-session-guard`, `qa/scroll-continue-20261102`, `release/scroll-continue-20261102`, `ui/group-chapter-inbox-by-title` и другие. Наличие удалённой ветки **не означает**, что она активна или не слита; актуальные локальные ветки не проверялись. Полный список: GitHub **Branches**.
- **[Git]** Примеры открытых GitHub issues: [#127 — пропуски автоматического обнаружения](https://github.com/Vetal12350/SenReader/issues/127), [#126 — микрофризы webtoon](https://github.com/Vetal12350/SenReader/issues/126), [#122 — восстановление доставки после crash](https://github.com/Vetal12350/SenReader/issues/122), [#121 — race между чтением и inbox](https://github.com/Vetal12350/SenReader/issues/121), [#103 — концепция VPS/push](https://github.com/Vetal12350/SenReader/issues/103), [#37 — local-first backlog](https://github.com/Vetal12350/SenReader/issues/37), [#36 — Android UI backlog](https://github.com/Vetal12350/SenReader/issues/36). Часть пунктов уже могла быть решена локально, а старые issue — не закрыты.
- **TODO/FIXME:** поиск `TODO`, `FIXME`, `HACK`, `XXX`, `NotImplemented`, `UnimplementedError` через подключённый GitHub Code Search **не вернул результатов**. Это **не эквивалент локальному `rg` по всей рабочей копии**; полноценный grep не выполнялся. Открытые задачи документированы преимущественно в issue/README/`docs/`.

### Последняя известная локальная работа — только отчёты владельца

| Версия/период | Сообщённое состояние (не сверено с локальным Git) |
|---|---|
| 367 | устранены светлые швы между страницами и оптимизировано сохранение прогресса; микрофризы ещё наблюдались |
| 368 | оптимизация `LibraryStore` и стартовой позиции при поздней загрузке изображений; успешно обновлена поверх 367 |
| 369 | отдельные исправления обнаружения новых глав и inbox; стабильная подпись и миграция; был установлен service-build для экспорта |
| 370 | карточка на каждую главу, навигация карточка/синяя кнопка, SQLite v4→v5, `lastReading`, файловый экспорт через Android SAF; наблюдались лаги интерфейса |
| 371 | диагностика worker (runId, длительность, категории source.pages), сокращение повторных INSERT в `provider_gate`; найдена ошибка `notifications_init` |
| 372 | исправление `invalid_icon` (ссылка на несуществующий `@mipmap/ic_launcher` в release); Android подтвердил **9** публикаций уведомлений, worker `SUCCESS` за **120,65 с**, сохранены **70 закладок** и авторизация |

**Оставшиеся проблемы [Отчёт владельца]:** микрофризы и иногда общие лаги интерфейса; нерегулярность уведомлений/источников и отсутствие доказательства стабильной доставки на протяжении многих циклов; не все ошибки `source.pages` классифицированы по старым логам; ранее наблюдались долгие/незавершённые workers. Один успешный запуск 372 не исключает повторных задержек. Локальное состояние изменений и точные версии `pubspec.yaml` по состоянию на 15 ноября неизвестны.

## 6. Документация

**Основные файлы [прочитаны]:**

- [`README.md`](https://github.com/Vetal12350/SenReader/blob/main/README.md): пользовательские функции, источники, сборка/CI, ограничения, ссылки на источники архитектуры. **Возможна устаревшая информация:** документ написан для 0.1 и заявляет, что Android-публикацию ещё предстоит проверить; это противоречит позднему отчёту о 372.
- [`AGENTS.md`](https://github.com/Vetal12350/SenReader/blob/main/AGENTS.md): обязательные инструкции для ИИ-агентов — приватность, local-first, сохранность данных, стабильность идентичности и подписи, отдельные PR/тесты, запрет несанкционированных социальных функций и сервера.
- `docs/CODEX_CLOUD.md`: Cloud-окружение, привязка приватного GitHub, запуск тестов, отказ от постоянно работающего локального worker.
- `docs/ANDROID_SIGNING.md`: постоянная подпись и секреты CI, невозможность обновить несовместимо подписанный APK, резервное копирование перед удалением, ограничения `run-as`.
- `docs/FIREBASE_SETUP.md`: опциональные профили и Firestore, имена конфигурации, конфликтные ревизии и правила доступа.
- `docs/library_transfer.md`: формат JSON версии 1, additions-only import, preview/validation, сохранение полей. Описание «data layer only» может отставать от позднего файлового SAF-экспорта.
- `docs/reading_and_alerts.md`, `docs/chapter_delivery_phase_a.md`, `docs/chapter_queue_phase_b.md`, `docs/inbox_p2_findings.md`, `docs/automatic_scan_reliability.md`, `docs/automatic_discovery_127.md`: контракты источников, durable inbox, provider leases, дедлайны, обработка ошибок и гонок. Некоторые описывают **SQLite v4**, тогда как локальная 370+ сообщалась как **v5**.
- `docs/reader_scroll_followup.md`, `docs/reader_seams_pipeline.md`: расследование геометрии изображений, микрофризов, швов и регрессионные тесты; результаты CI/виджет-тестов не равнозначны ощущениям на Pixel.
- `docs/final_qa_a4125dc.md`, `docs/WORKER_INTEGRATION_SMOKE.md`, `docs/senkuro_rankings.md`: QA, smoke-тест через GitHub worker, ограничения публичных рейтингов.
- `branding/README.md`: векторные иконки Android, способ копирования в генерируемую сборку.

**Инструкции для агентов:** `AGENTS.md` — найден и прочитан; `docs/CODEX_CLOUD.md` — дополняет его. `.cursorrules` и `CLAUDE.md` в дереве GitHub `main` не обнаружены. Могут существовать в локальной Windows-копии; не проверено.

## 7. Риски и вопросы

**Подтверждённые риски/ограничения [Код, Док, отчёты]:**

1. **Расхождение версий.** GitHub `main` от 03.11 и локальная установленная 372 по отчёту от 11.11 — не одно состояние. Перед любой разработкой обязательно прочитать `git status`, локальный `git log`, `git diff`, файлы миграции, исходники и фактический APK; **не брать устаревший GitHub `main` за источник текущей архитектуры**.
2. **Данные и миграции.** Локальная JSON-копия библиотеки не включает SQLite inbox, tombstone, delivered state, авторизацию или настройки. Должна существовать проверенная стратегия обновления/восстановления. Запрещены uninstall, `pm clear`, принудительный downgrade, автоматические миграции на реальном Pixel без разрешения.
3. **Подпись Android.** Несовпадающий сертификат блокирует `adb install -r`; debug-ключи CI могут быть временными. Прежний release-ключ нельзя заменять, секреты нельзя копировать в Git/чат.
4. **Надёжность фоновых проверок.** WorkManager — best-effort, не мгновенный push. Несколько параллельных run, ошибки источников, provider gate, дедлайны и отсутствие отмены транспортного HTTP после `Future.timeout` могут приводить к задержкам. Связь с UI-лагами не доказана.
5. **Плавность webtoon.** Подстройка высоты, подготовка изображений, Flutter frame scheduling и декодирование остаются чувствительными; прежние масштабные эксперименты с bitmap/decode ограничениями ухудшали отдельные сценарии. Нельзя объявлять проблему решённой по одному синтетическому benchmark.
6. **Сторонние источники и права.** HTML, GraphQL, CDN, HTTP 403/429 и политика источников могут меняться. Не обходить авторизацию, DRM, CAPTCHA, paywall. Проверять условия использования и правомерность автоматизации.
7. **Firestore.** По документации конфликт записей одной книги решается по timestamp устройства; рассинхрон часов и одновременные устройства могут привести к потерям более свежего локального чтения. Реальное поведение позднего `lastReading` требует сверки.
8. **Документы/issue могут устареть.** Например, README и `pubspec` на старой ветке противоречат локальным релизным отчётам, а открытые issue включают ранее уже исследованные проблемы.
9. **`_payload/`** — нет подтверждённого описания назначения пяти фрагментов в дереве. Не считать их приложением, fixture или артефактом без просмотра содержимого.

**Вопросы владельцу/следующему ассистенту:**

- Какая текущая ветка и `git status` у `C:\Projects\SenReader`? Какие правки 367–372 в незакоммиченном рабочем дереве и какие в удалённом GitHub?
- Остаётся ли 372 актуальной установленной версией на Pixel? Есть ли новые наблюдения микрофризов и фоновых уведомлений после 11 ноября?
- Какой механизм резервного копирования **SQLite inbox v5 и settings/auth** допускается на release без root, если понадобится восстановление?
- Охватывает ли текущий файловый экспорт все нужные поля `lastReading`, истории, прогресса; где хранится подтверждённый restore path?
- Выполнены ли реальные тесты холодного запуска из Android notification, открытия точного chapterId и пометки одной главы?
- Есть ли подтверждённая причина UI-лагов после 370; можно ли сравнить ручное чтение при активном/неактивном worker без нового масштабного профилирования?
- Какой контракт новой архитектуры уведомлений установлен в локальной v372 (не объединять главы, статусы просмотренных/скрытых/удалённых) и где его регрессионные тесты?
- Требуется ли синхронизировать локальную разработку с GitHub и документацией? **Не делать это автоматически**: владелец прежде запрещал push/commit без одобрения.

**Итог для принимающего ассистента:** прежде чем менять код, получить прямой read-only доступ к **актуальному локальному** `C:\Projects\SenReader`, сверить diff с GitHub HEAD и посмотреть документы `AGENTS.md`/`docs/`. Основной пользовательский приоритет — **плавное чтение и надёжные уведомления** при абсолютной сохранности библиотеки, профилей и истории.
