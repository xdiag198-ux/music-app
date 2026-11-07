#!/usr/bin/env bash
# Создаёт платформенные папки (android/ios), добавляет разрешение INTERNET,
# ставит зависимости, запускает анализ и собирает release APK.
# Запуск из корня проекта:  bash tool/setup.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK не найден. Установите: https://docs.flutter.dev/get-started/install" >&2
  exit 1
fi

# Страховка: flutter create не должен затронуть наши файлы.
cp lib/main.dart /tmp/oreate_main.dart.bak
cp pubspec.yaml /tmp/oreate_pubspec.yaml.bak

flutter create --org com.oreate --project-name oreate_music --platforms=android,ios .

cp /tmp/oreate_main.dart.bak lib/main.dart
cp /tmp/oreate_pubspec.yaml.bak pubspec.yaml
rm -rf test  # шаблонный тест ссылается на MyApp и ломает analyze

# В release-манифесте по умолчанию нет INTERNET — без него Supabase,
# стриминг и загрузка не будут работать в собранном APK.
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed -i 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MANIFEST"
  echo "INTERNET permission добавлен в $MANIFEST"
fi

flutter pub get
flutter analyze
flutter build apk --release

echo
echo "Готово: build/app/outputs/flutter-apk/app-release.apk"
