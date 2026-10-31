# SenReader launcher branding

The Android wrapper is generated in GitHub Actions by `flutter create`, so
launcher assets live here and are copied into the wrapper by
`scripts/prepare_android.py`.

* Display name: **SenReader** (capital S and R).
* Legacy icon: vector open-book mark on a dark rounded background, usable on API 24–25.
* Adaptive icon (API 26+): independent dark background, purple/orange book
  foreground, plus a dedicated monochrome version for themed icons.
* Resource name: `@mipmap/senreader_launcher`. The application ID and signing
  configuration remain unchanged.

No icon generator, external asset download, or build-time image conversion is needed.
