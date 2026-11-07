# OreateMusic

Flutter-приложение: Supabase Auth (регистрация, вход, подтверждение почты, профиль),
каталог из `public.tracks`, скачивание MP3 (Dio), SQLite-кэш, офлайн-плеер (just_audio).

## Быстрый старт

Нужен установленный Flutter SDK (3.10+).

```bash
bash tool/setup.sh
```

Скрипт создаёт `android/` и `ios/`, добавляет `INTERNET` в AndroidManifest,
выполняет `flutter pub get`, `flutter analyze` и `flutter build apk --release`.
APK: `build/app/outputs/flutter-apk/app-release.apk`.

Вручную:

```bash
flutter create --org com.oreate --project-name oreate_music --platforms=android,ios .
# добавьте <uses-permission android:name="android.permission.INTERNET"/>
# в android/app/src/main/AndroidManifest.xml (перед <application>)
flutter pub get
flutter analyze
flutter run
```

## Настройка Supabase (в панели проекта)

1. **Authentication → Providers → Email** — включён вход по email/паролю.
   Если включено *Confirm email*, после регистрации приложение покажет экран
   подтверждения с повторной отправкой письма.
2. **Authentication → URL Configuration** — задайте Site URL. Ссылка из письма
   откроет эту страницу; после неё вернитесь в приложение и нажмите
   «Я подтвердил — войти».
3. **RLS для `public.tracks`** — чтение должно быть разрешено для роли
   `authenticated`. Если каталог в приложении пуст, а в таблице есть строки,
   проверьте политику, например:
   ```sql
   create policy "tracks readable by signed-in users"
   on public.tracks for select to authenticated using (true);
   ```
   (Таблицу заново создавать не нужно — это только политика доступа.)

## Что внутри

- `lib/main.dart` — всё приложение (как в исходном проекте).
- Колонка `audio_url` из Supabase хранится в SQLite как `url`; схема SQLite
  не менялась, существующие установки продолжат работать.
- Имя пользователя хранится в `user_metadata.name`.
- Режим «Слушать скачанное без входа» нужен, чтобы офлайн-плеер работал,
  даже если сессию не удалось восстановить без сети.

## Что изменено относительно исходного кода

- `MockApi` и фейковый `AuthService` заменены на Supabase.
- Каталог при ошибке сети берётся из SQLite, а не заменяется экраном ошибки.
- Из кэша удаляются нескачанные треки, исчезнувшие из Supabase.
- Если скачанный файл пропал с диска, отметка «скачано» сбрасывается.
- Загрузка идёт во временный `.part`-файл и переименовывается после успеха.
- Добавлены кнопки «предыдущий/следующий» и автопереход к следующему треку.
- `permission_handler` удалён из `pubspec.yaml`: не использовался, а для
  записи в папку приложения разрешений не нужно.

## Сборка APK через GitHub Actions

Файл `.github/workflows/build-apk.yml` собирает release APK на серверах GitHub:
вкладка **Actions → Build APK → Run workflow**, затем скачать артефакт
`app-release-apk` со страницы запуска.
