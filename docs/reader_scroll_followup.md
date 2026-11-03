# Непрерывная прокрутка: уточнение после main f1f532b

Работа выполнена от актуального main; PR #105/#110 целиком не переносились.
Их уже присутствующие width decode limit, сохранение высот, ленивый список,
автопрокрутка и профильные guards были изучены в текущей реализации.
Нет физического Pixel 8 Pro/ADB. Ни идеальные 120 Гц, ни улучшение времени
GPU/декодирования на телефоне по widget-тестам не утверждаются.

## Что воспроизведено

Первый корректно изолированный прогон до исправления:
[6df3bc5, CI 41616962655](https://github.com/Vetal12350/SenReader/actions/runs/41616962655):
322 passed, 3 failed. Управляемый ImageProvider задерживает готовность реальных
ui.Image 400×3000/6000/12000, отдельно от движения списка, без HTTP и чужой манги.

| Причина | До | Исправление / проверяемый критерий после |
| --- | --- | --- |
| `_preloadUpcomingGeometry` делает root setState при каждом успешном probe | Один лишний rebuild ReaderPage на завершение | Локальный ValueNotifier страницы: ноль root rebuild на то же завершение |
| Неизвестная высота `width*1.5` меняется после появления соседней страницы | Уже видимая декодированная следующая страница выходит из построенной области после готовности длинной картинки выше | Сохранить экранную координату известной страницы с погрешностью ≤1 logical px |
| `_refreshChapterImages` удаляет весь geometry cache и меняет ключи tiles | Высота известного изображения падает 6000→600, пока новый URL загружается | Сохранить 6000 при pending/error/retry; сменить размер только по новым данным |

Это **layout shift** и подтверждённая лишняя UI-работа. Их наличие не доказывает
число пропущенных vsync или причину каждого микрофриза на Pixel. Время UI/raster
до/после на физическом устройстве пока не измерено.

## Дополнительные выводы аудита

- ScrollablePositionedList сохраняет indexed navigation и continuous append,
  но не сохраняет автоматически выбранный пользователем видимый контент, если
  размер предыдущего элемента меняется вокруг старой опоры списка. Его jumpTo
  останавливает текущий scroll activity. Использовать его на каждом image frame
  во время drag/fling нельзя. Масштабная миграция на SliverList не требуется для
  воспроизведённых случаев и не выполнена.
- Старый cache хранит logical height, очищается при изменении ширины и удаляет
  старые записи после 600 страниц. `_RetryableReaderImage._measured` может уже
  запретить повторное измерение. Теперь хранятся отношения height/width для всей
  активной reader route, независимо от bitmap residency и ширины. Это небольшие
  метаданные; они не записываются в библиотеку/SQLite/Firebase.
- Раньше probe держал полученный ImageInfo без явного dispose. Каждый слушатель
  владеет clone; теперь geometry listener освобождает его в finally. Это исправление
  владения ресурсом, **не измеренное уменьшение peak RAM**.
- 1600×12000 RGBA — около 73 MiB только пикселей, без GPU/codec overhead.
  Это расчёт, не измерение на Pixel. Width cap 1600 и качество видимого изображения
  сохранены. Для известных больших страниц пропускается дорогой speculative decode;
  cache occupancy/OS memory pressure сокращают окно/конкурентность. Глобальный
  ImageCache не увеличивается и не очищается нашим coordinator.
- Ошибка prefetch больше не запрещает страницу до выхода из reader. Есть cooldown
  и повтор при новом окне. После 12 секунд слот остаётся занят до фактического
  завершения запроса: removeListener не является HTTP abort. Нет бесконечного
  timeout→новые запросы. On-screen retry остаётся отдельным прежним механизмом.
- Refresh/rotation/dispose инвалидируют поколение probes. Старый результат не
  меняет новую геометрию; URL refresh оставляет прежний ratio как временный до
  подтверждения новой картинкой. При изменении содержания страницы ratio уточняется.

## Архитектура точечного изменения

1. Image сообщает intrinsic размер готового кадра, а не измеренный RenderBox с
   уже заданной высотой. До безопасного commit tile сохраняет прежнюю геометрию.
2. Размеры меняются в общей post-frame пачке через per-page ValueNotifier,
   без rebuild всего reader. Изменения менее одного logical pixel игнорируются.
3. Опора — уже известная видимая страница. Если изменение выше неё сдвинет контент,
   оно откладывается на время drag/fling/autoscroll. На idle опора восстанавливается
   по index + leading edge в той же пачке, без анимации и остановки свайпа.
   Впереди опоры размеры можно готовить во время движения.
4. Prefetch ориентируется на первый/последний видимый item и направление, берёт
   две ближайшие страницы, до четырёх при быстром движении и одну обратную.
  Лимит новых probes — 2, при давлении памяти — 1; уже начатые запросы завершаются.
  Даже устаревшие после URL refresh задачи удерживают слот до terminal completion.
  Bitmap уже известной страницы
   разрешено прогреть повторно после eviction. Очередь ограничена окном.
  Первый decoded frame выровнен по верхнему краю: временный ClipRect не должен
  показывать середину длинного strip на один кадр. Это проверяет pixel-тест с
  контрастной полосой, а не только координаты RenderBox.
5. Записи позиции, read/unread, terminal completion, source selection, account guards,
   переходы, полноэкранный режим и настройки остаются прежними. Позиция сохраняется
   с существующей точностью до страницы; новый формат pixel-offset не вводится.

## Что изучено у Android-читалок

Ссылки закреплены на изученных commits, а не на плавающей ветке. Код не копировался.

- [Mihon WebtoonLayoutManager](https://github.com/mihonapp/mihon/blob/e588e04359fe1058206a2cbac1b01018ad787359/app/src/main/java/eu/kanade/tachiyomi/ui/reader/viewer/webtoon/WebtoonLayoutManager.kt):
  extra layout space вместо стандартного item prefetch, подготовка view до видимости.
- [Mihon WebtoonAdapter](https://github.com/mihonapp/mihon/blob/e588e04359fe1058206a2cbac1b01018ad787359/app/src/main/java/eu/kanade/tachiyomi/ui/reader/viewer/webtoon/WebtoonAdapter.kt)
  и WebtoonPageHolder: DiffUtil, переиспользование holder, отмена старой coroutine,
  отдельные состояния download/decode/error. HttpPageLoader ограничивает chunks,
  отменяет старые jobs и восстанавливает Queue после отмены.
- [Mihon WebtoonStripImageView](https://github.com/mihonapp/mihon/blob/e588e04359fe1058206a2cbac1b01018ad787359/app/src/main/java/eu/kanade/tachiyomi/ui/reader/viewer/webtoon/WebtoonStripImageView.kt):
  bitmap strips, отсечение невидимых strips, освобождение больших bitmap при detach
  с сохранением размеров до reload. ReaderPageImageView также использует subsampling.
- [Kotatsu WebtoonLayoutManager](https://github.com/KotatsuApp/Kotatsu/blob/34f6e5232bf7f0bcdf8f3fbddb986697518e82a4/app/src/main/kotlin/org/koitharu/kotatsu/reader/ui/pager/webtoon/WebtoonLayoutManager.kt):
  дополнительный экран layout space только в направлении движения.
- [Kotatsu WebtoonImageView](https://github.com/KotatsuApp/Kotatsu/blob/34f6e5232bf7f0bcdf8f3fbddb986697518e82a4/app/src/main/kotlin/org/koitharu/kotatsu/reader/ui/pager/webtoon/WebtoonImageView.kt)
  и WebtoonHolder/FrameLayout/RecyclerView: SubsamplingScaleImageView, intrinsic
  размеры, высота view не больше viewport, внутреннее смещение длинной картинки,
  восстановление scroll после ready, распределение scroll между view и RecyclerView.
  BaseReaderAdapter использует AsyncListDiffer и освобождение recycled holder.

Адаптированы разделение геометрии/пикселей, локальные обновления, ограниченное
направленное окно и поколение загрузки. Native subsampling/внутренний scroll/strips
не перенесены. Tile-based decoder остаётся отдельным решением лишь если profiling
покажет корреляцию длинных bitmap с RAM/GPU/codec stalls; иначе это лишняя сложность.

## Проверка на Pixel 8 Pro

Debug APK/эмулятор/widget-tests не дают достоверных 120-Гц измерений. Использовать
одинаковый profile build и ту же главу, масштаб, сеть, яркость и настройки экрана.
Проверить реальную частоту через Android display/Developer options; система может
менять её. Не удалять установленное приложение/данные ради несовместимой подписи.
Не менять applicationId/signing для измерения.

Для opt-in измерения после обычной подготовки Flutter Android wrapper:

```sh
flutter run --profile --dart-define=SENREADER_READER_TRACE=true --dart-define=SENREADER_FRAME_BUDGET_US=8333
adb logcat -s flutter
```

Открыть reader, выполнить одинаковые 60-секундные проходы вниз/вверх, затем выйти
из reader. В логе будет `SenReader.ReaderFrames` JSON: UI/raster p95, число кадров
выше 8.333 ms, **оценка** missed vsync, root rebuilds, geometry commits и idle anchor
corrections, максимум учтённых cache bytes. Счётчики ограничены 12000 frames и
сообщают truncation. Флаг выключен по умолчанию; никакие данные не отправляются.
Geometry commits/corrections не означают увиденные скачки; проверять координату
конкретного рисунка/границы отдельно, при необходимости записью экрана.

Для одинакового Android-level сравнения main/PR дополнительно использовать
Perfetto (FrameTimeline, UI/raster/GC/texture upload) и `adb shell dumpsys gfxinfo
app.senreader.senreader framestats`. FrameTiming не является доказательством числа
реально пропущенных SurfaceFlinger presentation frames.

Повторить cold/warm cache, сеть с задержкой/обрывом, CDN error+retry, возврат после
давления памяти, 3000/6000/12000px, быстрый разворот направления, переход главы,
resume/ручной выбор, автопрокрутку и два профиля/гостя. Проверить, что позиция и
read markers не изменились посторонним образом. Device RAM/native heap/cache
не одно и то же: без этих измерений не делать вывод о необходимости tiles.

Остаточные ограничения: неизвестный первый bitmap всё ещё требует временного
loading box, синхронные UI/parsing и raster decode/upload могут давать frame jank,
ImageCache не учитывает всю память, listener cancellation не отменяет HTTP.
Уведомления, background scan, источники, SQLite, signing и CI не изменены.
В актуальном main ReManga уже удалён; сохранены его исторические данные и прежняя
обработка legacy-записей, адаптер в рамках оптимизации не возвращался.
