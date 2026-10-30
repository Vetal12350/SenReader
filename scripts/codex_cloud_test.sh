#!/usr/bin/env bash
# Run from the repository root inside a Codex Cloud Linux environment.
# No Android SDK or local PC required for Dart/Flutter unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
else
  flutter_dir="${CODEX_FLUTTER_DIR:-$HOME/.local/share/senreader-flutter}"
  flutter_bin="$flutter_dir/bin/flutter"
  if [[ ! -x "$flutter_bin" ]]; then
    command -v git >/dev/null || { echo "git is required to bootstrap Flutter." >&2; exit 1; }
    mkdir -p "$(dirname "$flutter_dir")"
    echo "Installing Flutter stable for Cloud tests in $flutter_dir"
    git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$flutter_dir"
  fi
fi

"$flutter_bin" config --no-analytics
"$flutter_bin" --version
"$flutter_bin" pub get
"$flutter_bin" test
