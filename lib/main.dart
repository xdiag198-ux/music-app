import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Конфигурация
// ---------------------------------------------------------------------------

/// Project URL без /rest/v1/ — SDK сам добавляет нужные пути.
const String supabaseUrl = 'https://ivubrpaaauzbdwzhwwtu.supabase.co';

/// Publishable (anon) key. Он предназначен для клиентских приложений.
const String supabaseKey = 'sb_publishable_1DIWwkBWMSzsbnex6VU5fw_QcfEaFVZ';

const Color backgroundColor = Color(0xFF101010);
const Color surfaceColor = Color(0xFF1C1C1C);
const Color accentColor = Color(0xFF1ED760);
const Color accentGlow = Color(0x2E1ED760);
const Color errorColor = Color(0xFFFF6B6B);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseKey);
  runApp(const MusicApp());
}

// ---------------------------------------------------------------------------
// Модель
// ---------------------------------------------------------------------------

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.url,
    this.localPath,
    this.isDownloaded = false,
  });

  final int id;
  final String title;
  final String artist;
  final String url;
  final String? localPath;
  final bool isDownloaded;

  /// Строка из SQLite.
  factory Track.fromMap(Map<String, Object?> map) => Track(
        id: map['id'] as int,
        title: map['title'] as String,
        artist: map['artist'] as String,
        url: map['url'] as String,
        localPath: map['localPath'] as String?,
        isDownloaded: (map['isDownloaded'] as int? ?? 0) == 1,
      );

  /// Строка из таблицы public.tracks в Supabase (audio_url -> url).
  factory Track.fromRemote(Map<String, dynamic> row) => Track(
        id: (row['id'] as num).toInt(),
        title: (row['title'] as String?)?.trim().isNotEmpty == true
            ? (row['title'] as String).trim()
            : 'Без названия',
        artist: (row['artist'] as String?)?.trim().isNotEmpty == true
            ? (row['artist'] as String).trim()
            : 'Неизвестный исполнитель',
        url: row['audio_url'] as String,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'artist': artist,
        'url': url,
        'localPath': localPath,
        'isDownloaded': isDownloaded ? 1 : 0,
      };
}

// ---------------------------------------------------------------------------
// Валидация
// ---------------------------------------------------------------------------

final RegExp _emailRegExp = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
final RegExp _letterRegExp = RegExp(r'\p{L}', unicode: true);
final RegExp _digitRegExp = RegExp(r'\d');

String? validateName(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Введите имя';
  if (text.length < 2) return 'Минимум 2 символа';
  if (text.length > 32) return 'Максимум 32 символа';
  return null;
}

String? validateEmail(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Введите email';
  if (!_emailRegExp.hasMatch(text)) return 'Некорректный email';
  return null;
}

String? validateNewPassword(String? value) {
  final text = value ?? '';
  if (text.isEmpty) return 'Придумайте пароль';
  if (text.length < 8) return 'Минимум 8 символов';
  if (!_letterRegExp.hasMatch(text) || !_digitRegExp.hasMatch(text)) {
    return 'Добавьте буквы и цифры';
  }
  return null;
}

String? validateLoginPassword(String? value) {
  if ((value ?? '').isEmpty) return 'Введите пароль';
  return null;
}

// ---------------------------------------------------------------------------
// Auth (Supabase)
// ---------------------------------------------------------------------------

class AuthService {
  static GoTrueClient get _auth => Supabase.instance.client.auth;

  static Session? get currentSession => _auth.currentSession;
  static User? get currentUser => _auth.currentUser;
  static Stream<AuthState> get authChanges => _auth.onAuthStateChange;

  static Future<AuthResponse> signUp({
    required String name,
    required String email,
    required String password,
  }) {
    return _auth.signUp(
      email: email.trim(),
      password: password,
      data: {'name': name.trim()},
    );
  }

  static Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) {
    return _auth.signInWithPassword(email: email.trim(), password: password);
  }

  static Future<void> resendConfirmation(String email) {
    return _auth.resend(type: OtpType.signup, email: email.trim());
  }

  static Future<User?> updateName(String name) async {
    final response = await _auth.updateUser(
      UserAttributes(data: {'name': name.trim()}),
    );
    return response.user;
  }

  static Future<void> signOut() => _auth.signOut();

  static String displayName(User? user) {
    final name = user?.userMetadata?['name'];
    if (name is String && name.trim().isNotEmpty) return name.trim();
    final email = user?.email;
    if (email != null && email.contains('@')) return email.split('@').first;
    return 'Пользователь';
  }

  static bool isEmailNotConfirmed(Object error) {
    return error is AuthException &&
        error.message.toLowerCase().contains('email not confirmed');
  }

  static bool _looksLikeNetworkError(Object error) {
    if (error is SocketException || error is TimeoutException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('socketexception') ||
        text.contains('failed host lookup') ||
        text.contains('clientexception') ||
        text.contains('connection refused') ||
        text.contains('network is unreachable') ||
        text.contains('connection closed') ||
        text.contains('connection reset');
  }

  /// Преобразует любую ошибку в понятное сообщение для пользователя.
  static String humanError(Object error) {
    if (_looksLikeNetworkError(error)) {
      return 'Нет соединения с интернетом. Проверьте сеть и повторите попытку.';
    }
    if (error is AuthException) {
      final message = error.message.toLowerCase();
      final status = '${error.statusCode}';

      if (message.contains('invalid login credentials') ||
          message.contains('invalid_credentials')) {
        return 'Неверный email или пароль.';
      }
      if (message.contains('email not confirmed')) {
        return 'Почта ещё не подтверждена. Откройте письмо и перейдите по ссылке.';
      }
      if (message.contains('already registered') ||
          message.contains('already been registered') ||
          message.contains('user_already_exists')) {
        return 'Этот email уже зарегистрирован. Попробуйте войти.';
      }
      if (message.contains('same password')) {
        return 'Новый пароль должен отличаться от старого.';
      }
      if (message.contains('password') &&
          (message.contains('weak') ||
              message.contains('at least') ||
              message.contains('should contain') ||
              message.contains('too short'))) {
        return 'Слишком слабый пароль. Используйте минимум 8 символов, буквы и цифры.';
      }
      if (status == '429' ||
          message.contains('rate limit') ||
          message.contains('security purposes') ||
          message.contains('too many')) {
        return 'Слишком много попыток. Подождите минуту и повторите.';
      }
      if (message.contains('signups not allowed') ||
          message.contains('signup is disabled') ||
          message.contains('signup_disabled')) {
        return 'Регистрация сейчас отключена.';
      }
      if (message.contains('invalid email') ||
          message.contains('unable to validate email') ||
          (message.contains('email address') && message.contains('invalid'))) {
        return 'Сервер не принял этот email. Проверьте адрес.';
      }
      if (message.contains('jwt') || message.contains('refresh token')) {
        return 'Сессия истекла. Войдите снова.';
      }
      if (status.startsWith('5')) {
        return 'Сервер временно недоступен. Попробуйте позже.';
      }
      return 'Ошибка авторизации: ${error.message}';
    }
    return 'Что-то пошло не так: $error';
  }
}

// ---------------------------------------------------------------------------
// Каталог (Supabase, таблица public.tracks)
// ---------------------------------------------------------------------------

class CatalogService {
  static Future<List<Track>> fetchTracks() async {
    final rows = await Supabase.instance.client
        .from('tracks')
        .select('id, title, artist, audio_url')
        .order('id', ascending: true)
        .timeout(const Duration(seconds: 20));
    final tracks = <Track>[];
    for (final row in rows) {
      final map = Map<String, dynamic>.from(row);
      final url = map['audio_url'];
      if (map['id'] == null || url is! String || url.trim().isEmpty) continue;
      tracks.add(Track.fromRemote(map));
    }
    return tracks;
  }

  static String humanError(Object error) {
    if (error is PostgrestException) {
      final message = error.message.toLowerCase();
      if (message.contains('jwt')) return 'Сессия истекла. Войдите снова.';
      if (message.contains('permission denied') ||
          message.contains('row-level security')) {
        return 'Нет доступа к таблице tracks (проверьте политики RLS).';
      }
      return error.message;
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error.toString().toLowerCase().contains('clientexception')) {
      return 'нет подключения к интернету.';
    }
    return '$error';
  }
}

// ---------------------------------------------------------------------------
// SQLite
// ---------------------------------------------------------------------------

class DatabaseService {
  static Database? _database;

  static Future<Database> get database async {
    if (_database != null) return _database!;

    final dbPath = await getDatabasesPath();
    _database = await openDatabase(
      p.join(dbPath, 'music_app.db'),
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE tracks (
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            artist TEXT NOT NULL,
            url TEXT NOT NULL,
            localPath TEXT,
            isDownloaded INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
    return _database!;
  }

  /// Обновляет кэш каталога, не затирая информацию о скачанных файлах.
  /// Нескачанные треки, исчезнувшие из Supabase, удаляются из кэша.
  static Future<void> saveTracks(List<Track> tracks) async {
    final db = await database;
    final batch = db.batch();
    for (final track in tracks) {
      batch.rawInsert(
        '''
        INSERT INTO tracks (id, title, artist, url, localPath, isDownloaded)
        VALUES (?, ?, ?, ?, NULL, 0)
        ON CONFLICT(id) DO UPDATE SET
          title = excluded.title,
          artist = excluded.artist,
          url = excluded.url
        ''',
        [track.id, track.title, track.artist, track.url],
      );
    }
    if (tracks.isEmpty) {
      batch.delete('tracks', where: 'isDownloaded = 0');
    } else {
      final marks = List.filled(tracks.length, '?').join(',');
      batch.delete(
        'tracks',
        where: 'isDownloaded = 0 AND id NOT IN ($marks)',
        whereArgs: tracks.map((t) => t.id).toList(),
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Track>> getAllTracks() async {
    final rows = await (await database).query('tracks', orderBy: 'id ASC');
    return rows.map(Track.fromMap).toList();
  }

  static Future<List<Track>> getDownloadedTracks() async {
    final rows = await (await database).query(
      'tracks',
      where: 'isDownloaded = ?',
      whereArgs: [1],
      orderBy: 'id ASC',
    );
    return rows.map(Track.fromMap).toList();
  }

  static Future<void> markDownloaded(int id, String localPath) async {
    await (await database).update(
      'tracks',
      {'localPath': localPath, 'isDownloaded': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Файл пропал с диска — сбрасываем отметку «скачано».
  static Future<void> resetDownload(int id) async {
    await (await database).update(
      'tracks',
      {'localPath': null, 'isDownloaded': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}

// ---------------------------------------------------------------------------
// Скачивание (Dio)
// ---------------------------------------------------------------------------

class DownloadService {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      followRedirects: true,
    ),
  );

  static Future<String> download(
    Track track, {
    required ProgressCallback onProgress,
  }) async {
    final documents = await getApplicationDocumentsDirectory();
    final musicDirectory = Directory(p.join(documents.path, 'music'));
    if (!await musicDirectory.exists()) {
      await musicDirectory.create(recursive: true);
    }

    final filePath = p.join(musicDirectory.path, 'track_${track.id}.mp3');
    final partPath = '$filePath.part';

    // Качаем во временный файл, чтобы оборванная загрузка не выглядела
    // как готовый трек.
    await _dio.download(
      track.url,
      partPath,
      onReceiveProgress: onProgress,
      deleteOnError: true,
    );

    final part = File(partPath);
    if (!await part.exists() || await part.length() == 0) {
      if (await part.exists()) await part.delete();
      throw Exception('Скачанный файл пуст или отсутствует.');
    }

    final target = File(filePath);
    if (await target.exists()) await target.delete();
    await part.rename(filePath);
    return filePath;
  }

  static String humanError(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
          return 'истекло время ожидания, проверьте соединение.';
        case DioExceptionType.connectionError:
          return 'нет подключения к интернету.';
        case DioExceptionType.badResponse:
          return 'сервер ответил кодом ${error.response?.statusCode}.';
        case DioExceptionType.cancel:
          return 'загрузка отменена.';
        default:
          return '${error.message ?? error}';
      }
    }
    if (error is FileSystemException) {
      return 'не удалось сохранить файл (${error.message}).';
    }
    return '$error';
  }
}

// ---------------------------------------------------------------------------
// Приложение и маршрутизация по состоянию авторизации
// ---------------------------------------------------------------------------

class MusicApp extends StatelessWidget {
  const MusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MUSIC',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: const ColorScheme.dark(
          primary: accentColor,
          surface: surfaceColor,
        ),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _subscription;
  Session? _session;
  bool _offlineMode = false;

  @override
  void initState() {
    super.initState();
    // Supabase сам восстанавливает сессию из локального хранилища.
    _session = AuthService.currentSession;
    _subscription = AuthService.authChanges.listen((state) {
      if (!mounted) return;
      setState(() {
        _session = state.session;
        if (state.session != null) _offlineMode = false;
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (_session != null) {
      child = const HomeScreen(key: ValueKey('home-online'));
    } else if (_offlineMode) {
      child = HomeScreen(
        key: const ValueKey('home-offline'),
        offlineOnly: true,
        onLeaveOfflineMode: () => setState(() => _offlineMode = false),
      );
    } else {
      child = AuthScreen(
        key: const ValueKey('auth'),
        onContinueOffline: () => setState(() => _offlineMode = true),
      );
    }

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Экран регистрации / входа
// ---------------------------------------------------------------------------

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.onContinueOffline});

  final VoidCallback onContinueOffline;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _registerMode = false;
  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  // Состояние «ждём подтверждения почты».
  bool _awaitingConfirmation = false;
  String _pendingEmail = '';
  String? _notice;
  Timer? _cooldownTimer;
  int _cooldown = 0;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _setMode(bool register) {
    if (_registerMode == register) return;
    setState(() {
      _registerMode = register;
      _error = null;
    });
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  void _showConfirmationPanel(String email, {String? notice}) {
    setState(() {
      _awaitingConfirmation = true;
      _pendingEmail = email;
      _notice = notice;
      _error = null;
    });
    _startCooldown();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final email = _emailController.text.trim();
    try {
      if (_registerMode) {
        final response = await AuthService.signUp(
          name: _nameController.text,
          email: email,
          password: _passwordController.text,
        );
        if (response.session != null) {
          return; // Подтверждение почты отключено — AuthGate сам откроет приложение.
        }
        final identities = response.user?.identities;
        if (response.user != null && identities != null && identities.isEmpty) {
          if (!mounted) return;
          setState(() {
            _error = 'Этот email уже зарегистрирован. Попробуйте войти.';
          });
          return;
        }
        if (!mounted) return;
        _showConfirmationPanel(
          email,
          notice: 'Мы отправили письмо со ссылкой подтверждения.',
        );
      } else {
        await AuthService.signIn(
          email: email,
          password: _passwordController.text,
        );
      }
    } catch (error) {
      if (!mounted) return;
      if (AuthService.isEmailNotConfirmed(error)) {
        _showConfirmationPanel(
          email,
          notice: 'Почта ещё не подтверждена. Откройте письмо и перейдите '
              'по ссылке — либо отправьте его заново.',
        );
      } else {
        setState(() => _error = AuthService.humanError(error));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    if (_cooldown > 0 || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthService.resendConfirmation(_pendingEmail);
      if (!mounted) return;
      setState(() => _notice = 'Письмо отправлено повторно. Проверьте и папку «Спам».');
      _startCooldown();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = AuthService.humanError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmedSignIn() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthService.signIn(
        email: _pendingEmail,
        password: _passwordController.text,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = AuthService.isEmailNotConfirmed(error)
            ? 'Почта пока не подтверждена. Перейдите по ссылке из письма '
                'и нажмите кнопку ещё раз.'
            : AuthService.humanError(error);
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _backToForm() {
    _cooldownTimer?.cancel();
    setState(() {
      _awaitingConfirmation = false;
      _error = null;
      _notice = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned(
            top: -130,
            right: -90,
            child: _Glow(size: 340, color: accentGlow),
          ),
          const Positioned(
            bottom: -160,
            left: -110,
            child: _Glow(size: 380, color: Color(0x1F2D7BFF)),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: _FadeSlideIn(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildLogo(),
                        const SizedBox(height: 28),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          switchInCurve: Curves.easeOutCubic,
                          transitionBuilder: (child, animation) => FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, 0.04),
                                end: Offset.zero,
                              ).animate(animation),
                              child: child,
                            ),
                          ),
                          child: _awaitingConfirmation
                              ? _buildConfirmationPanel()
                              : _buildForm(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2BE36F), Color(0xFF0E8A41)],
            ),
            boxShadow: const [
              BoxShadow(color: accentGlow, blurRadius: 30, spreadRadius: 4),
            ],
          ),
          child: const Icon(Icons.graphic_eq, size: 40, color: Colors.black87),
        ),
        const SizedBox(height: 16),
        const Text(
          'MUSIC',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 4,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Твоя музыка — онлайн и офлайн',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Container(
      key: const ValueKey('auth-form'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xCC1C1C1C),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white10),
      ),
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModeToggle(register: _registerMode, onChanged: _setMode),
            const SizedBox(height: 20),
            AnimatedSize(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_registerMode) ...[
                    _AuthField(
                      controller: _nameController,
                      label: 'Имя',
                      icon: Icons.person_outline_rounded,
                      textInputAction: TextInputAction.next,
                      autofillHints: const [AutofillHints.name],
                      validator: validateName,
                    ),
                    const SizedBox(height: 14),
                  ],
                  _AuthField(
                    controller: _emailController,
                    label: 'Email',
                    icon: Icons.mail_outline_rounded,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    validator: validateEmail,
                  ),
                  const SizedBox(height: 14),
                  _AuthField(
                    controller: _passwordController,
                    label: 'Пароль',
                    icon: Icons.lock_outline_rounded,
                    obscure: _obscurePassword,
                    textInputAction:
                        _registerMode ? TextInputAction.next : TextInputAction.done,
                    autofillHints: [
                      _registerMode
                          ? AutofillHints.newPassword
                          : AutofillHints.password,
                    ],
                    validator:
                        _registerMode ? validateNewPassword : validateLoginPassword,
                    onSubmitted: _registerMode ? null : (_) => _submit(),
                    suffix: IconButton(
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                  if (_registerMode) ...[
                    const SizedBox(height: 14),
                    _AuthField(
                      controller: _confirmController,
                      label: 'Повторите пароль',
                      icon: Icons.lock_reset_rounded,
                      obscure: _obscureConfirm,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _submit(),
                      validator: (value) {
                        if ((value ?? '').isEmpty) return 'Повторите пароль';
                        if (value != _passwordController.text) {
                          return 'Пароли не совпадают';
                        }
                        return null;
                      },
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _obscureConfirm = !_obscureConfirm),
                        icon: Icon(
                          _obscureConfirm
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          color: Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _ErrorBanner(message: _error),
            const SizedBox(height: 20),
            _PrimaryButton(
              label: _registerMode ? 'Создать аккаунт' : 'Войти',
              loading: _loading,
              onPressed: _submit,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loading ? null : widget.onContinueOffline,
              icon: const Icon(Icons.download_for_offline_outlined, size: 18),
              label: const Text('Слушать скачанное без входа'),
              style: TextButton.styleFrom(foregroundColor: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmationPanel() {
    return Container(
      key: const ValueKey('auth-confirm'),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xCC1C1C1C),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.6, end: 1),
            duration: const Duration(milliseconds: 600),
            curve: Curves.elasticOut,
            builder: (context, value, child) =>
                Transform.scale(scale: value, child: child),
            child: Container(
              alignment: Alignment.center,
              child: Container(
                width: 68,
                height: 68,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentGlow,
                ),
                child: const Icon(
                  Icons.mark_email_read_outlined,
                  color: accentColor,
                  size: 34,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'Подтвердите почту',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            _pendingEmail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: accentColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_notice != null) ...[
            const SizedBox(height: 10),
            Text(
              _notice!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white60, height: 1.35),
            ),
          ],
          _ErrorBanner(message: _error),
          const SizedBox(height: 22),
          _PrimaryButton(
            label: 'Я подтвердил — войти',
            loading: _loading,
            onPressed: _confirmedSignIn,
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: (_cooldown > 0 || _loading) ? null : _resend,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              _cooldown > 0
                  ? 'Отправить повторно через $_cooldown с'
                  : 'Отправить письмо ещё раз',
            ),
          ),
          TextButton(
            onPressed: _loading ? null : _backToForm,
            style: TextButton.styleFrom(foregroundColor: Colors.white60),
            child: const Text('Назад'),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, Colors.transparent]),
        ),
      ),
    );
  }
}

class _FadeSlideIn extends StatelessWidget {
  const _FadeSlideIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 24),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.register, required this.onChanged});

  final bool register;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: register ? Alignment.centerRight : Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.5,
              heightFactor: 1,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          Row(
            children: [
              _toggleItem('Вход', !register, () => onChanged(false)),
              _toggleItem('Регистрация', register, () => onChanged(true)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toggleItem(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: selected ? Colors.white : Colors.white54,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

class _AuthField extends StatelessWidget {
  const _AuthField({
    required this.controller,
    required this.label,
    required this.icon,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
    this.textInputAction,
    this.validator,
    this.autofillHints,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final FormFieldValidator<String>? validator;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;

  OutlineInputBorder _border(Color color, [double width = 1]) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      validator: validator,
      onFieldSubmitted: onSubmitted,
      cursorColor: accentColor,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        floatingLabelStyle: const TextStyle(color: accentColor),
        prefixIcon: Icon(icon, color: Colors.white54),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF141414),
        border: _border(Colors.transparent),
        enabledBorder: _border(Colors.white10),
        focusedBorder: _border(accentColor, 1.6),
        errorBorder: _border(errorColor),
        focusedErrorBorder: _border(errorColor, 1.6),
        errorStyle: const TextStyle(color: errorColor),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: message == null
            ? const SizedBox(width: double.infinity)
            : Container(
                key: ValueKey(message),
                width: double.infinity,
                margin: const EdgeInsets.only(top: 14),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x26FF6B6B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x66FF6B6B)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline, color: errorColor, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        message!,
                        style: const TextStyle(
                          color: Color(0xFFFFB4B4),
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({
    required this.label,
    required this.onPressed,
    this.loading = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool loading;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = !widget.loading;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: () => setState(() => _pressed = false),
      onTap: enabled ? widget.onPressed : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: enabled
                  ? const [Color(0xFF2BE36F), Color(0xFF14A84E)]
                  : const [Color(0xFF1F6B3D), Color(0xFF17512E)],
            ),
            boxShadow: enabled
                ? const [
                    BoxShadow(
                      color: accentGlow,
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ]
                : const [],
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: widget.loading
                ? const SizedBox(
                    key: ValueKey('spinner'),
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.black87,
                    ),
                  )
                : Text(
                    widget.label,
                    key: const ValueKey('label'),
                    style: const TextStyle(
                      color: Colors.black87,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Главный экран: каталог, офлайн, профиль + мини-плеер
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    this.offlineOnly = false,
    this.onLeaveOfflineMode,
  });

  /// Режим без аккаунта: только скачанные треки и кэш каталога.
  final bool offlineOnly;
  final VoidCallback? onLeaveOfflineMode;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<ProcessingState>? _completionSubscription;

  List<Track> tracks = [];
  List<Track> downloadedTracks = [];
  Track? currentTrack;
  List<int> _queueIds = [];
  int _playRequest = 0;

  bool isLoading = true;
  bool isDownloading = false;
  int? downloadingTrackId;
  double downloadProgress = 0;
  String? errorMessage;
  String? catalogWarning;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _completionSubscription = _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _skip(1, auto: true);
    });
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    if (mounted) {
      setState(() {
        isLoading = tracks.isEmpty;
        errorMessage = null;
      });
    }

    String? remoteFailure;
    if (!widget.offlineOnly) {
      try {
        final remote = await CatalogService.fetchTracks();
        await DatabaseService.saveTracks(remote);
      } catch (error) {
        remoteFailure = CatalogService.humanError(error);
      }
    }

    try {
      await _refreshTracks();
      if (!mounted) return;
      final failure = remoteFailure;
      setState(() {
        if (failure != null) {
          if (tracks.isEmpty) {
            errorMessage = 'Не удалось загрузить каталог: $failure';
          } else {
            catalogWarning = 'Нет связи с каталогом — показаны сохранённые треки.';
          }
        } else {
          catalogWarning = null;
        }
        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        errorMessage = 'Ошибка локальной базы данных: $error';
        isLoading = false;
      });
    }
  }

  Future<void> _refreshTracks() async {
    var all = await DatabaseService.getAllTracks();

    // Если файл удалили с диска — сбрасываем отметку «скачано».
    var repaired = false;
    for (final track in all) {
      final path = track.localPath;
      if (track.isDownloaded && (path == null || !await File(path).exists())) {
        await DatabaseService.resetDownload(track.id);
        repaired = true;
      }
    }
    if (repaired) all = await DatabaseService.getAllTracks();

    final offline = all.where((track) => track.isDownloaded).toList();
    if (!mounted) return;
    setState(() {
      tracks = all;
      downloadedTracks = offline;
      isLoading = false;
      errorMessage = null;
    });
  }

  Track? _byId(int id) {
    for (final track in tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  Future<void> _playTrack(Track requested, {required List<Track> queue}) async {
    final track = _byId(requested.id) ?? requested;
    final request = ++_playRequest;

    setState(() {
      currentTrack = track;
      _queueIds = queue.map((item) => item.id).toList();
    });

    try {
      final localPath = track.localPath;
      final localFileExists = track.isDownloaded &&
          localPath != null &&
          await File(localPath).exists();

      if (localFileExists) {
        await _player.setAudioSource(AudioSource.file(localPath));
      } else {
        if (track.isDownloaded) {
          await DatabaseService.resetDownload(track.id);
          await _refreshTracks();
        }
        await _player.setAudioSource(AudioSource.uri(Uri.parse(track.url)));
      }

      if (!mounted || request != _playRequest) return;
      // play() завершается только после паузы/конца трека, поэтому не ждём его.
      unawaited(
        _player.play().catchError((Object error) {
          if (mounted) _showMessage('Ошибка воспроизведения: $error');
        }),
      );
    } catch (error) {
      if (!mounted || request != _playRequest) return;
      _showMessage(
        'Не удалось воспроизвести трек. Если он не скачан, нужен интернет. '
        '($error)',
      );
    }
  }

  /// Переключение треков: [delta] = 1 — следующий, -1 — предыдущий.
  Future<void> _skip(int delta, {bool auto = false}) async {
    final current = currentTrack;
    if (current == null || _queueIds.isEmpty) return;

    if (delta < 0 &&
        !auto &&
        _player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }

    final index = _queueIds.indexOf(current.id);
    if (index < 0) return;
    final nextIndex = index + delta;

    if (nextIndex < 0 || nextIndex >= _queueIds.length) {
      if (auto) {
        await _player.pause();
        await _player.seek(Duration.zero);
      }
      return;
    }

    final next = _byId(_queueIds[nextIndex]);
    if (next == null) return;
    await _playTrack(
      next,
      queue: _queueIds.map(_byId).whereType<Track>().toList(),
    );
  }

  Future<void> _togglePlayback() async {
    try {
      if (_player.playing) {
        await _player.pause();
      } else if (currentTrack != null) {
        unawaited(_player.play());
      }
    } catch (error) {
      if (mounted) _showMessage('Ошибка плеера: $error');
    }
  }

  Future<void> _downloadTrack(Track track) async {
    if (track.isDownloaded || isDownloading) return;

    setState(() {
      isDownloading = true;
      downloadingTrackId = track.id;
      downloadProgress = 0;
    });

    try {
      final localPath = await DownloadService.download(
        track,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => downloadProgress = received / total);
        },
      );
      await DatabaseService.markDownloaded(track.id, localPath);
      await _refreshTracks();
      if (mounted) _showMessage('${track.title} сохранён офлайн.');
    } catch (error) {
      if (mounted) {
        _showMessage('Ошибка скачивания: ${DownloadService.humanError(error)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          isDownloading = false;
          downloadingTrackId = null;
          downloadProgress = 0;
        });
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFF303030),
        ),
      );
  }

  Widget _buildDownloadButton(Track track) {
    if (track.isDownloaded) {
      return const Icon(Icons.check_circle, color: accentColor);
    }

    if (downloadingTrackId == track.id) {
      return SizedBox(
        width: 27,
        height: 27,
        child: CircularProgressIndicator(
          value: downloadProgress > 0 ? downloadProgress : null,
          strokeWidth: 2.5,
          color: accentColor,
        ),
      );
    }

    return IconButton(
      tooltip: 'Скачать',
      onPressed: isDownloading ? null : () => _downloadTrack(track),
      icon: const Icon(Icons.download_rounded, color: Colors.white70),
    );
  }

  Widget _buildTrackCard(
    Track track, {
    required bool offline,
    required List<Track> queue,
  }) {
    final selected = currentTrack?.id == track.id;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF252D27) : surfaceColor,
        borderRadius: BorderRadius.circular(13),
      ),
      child: ListTile(
        onTap: () => _playTrack(track, queue: queue),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF315B43), Color(0xFF152C20)],
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            selected ? Icons.graphic_eq : Icons.music_note_rounded,
            color: accentColor,
            size: 27,
          ),
        ),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: selected ? accentColor : Colors.white,
          ),
        ),
        subtitle: Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: offline
            ? const Icon(Icons.offline_pin, color: accentColor)
            : _buildDownloadButton(track),
      ),
    );
  }

  Widget _buildEmptyState(
    IconData icon,
    String title, {
    String subtitle = '',
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 62, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCatalogError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 50, color: Colors.redAccent),
            const SizedBox(height: 15),
            Text(errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 15),
            ElevatedButton(
              onPressed: _loadCatalog,
              child: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCatalog() {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator(color: accentColor));
    }
    if (errorMessage != null) return _buildCatalogError();
    if (tracks.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: _buildEmptyState(
              Icons.music_off,
              'Каталог пуст',
              subtitle: 'В таблице tracks пока нет композиций '
                  'или к ним нет доступа.',
            ),
          ),
          TextButton(onPressed: _loadCatalog, child: const Text('Обновить')),
          const SizedBox(height: 16),
        ],
      );
    }
    return RefreshIndicator(
      color: accentColor,
      onRefresh: _loadCatalog,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 12, bottom: 20),
        children: [
          if (catalogWarning != null)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x26FFB74D),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.cloud_off, size: 18, color: Colors.orangeAccent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      catalogWarning!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
                ],
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Text(
              'Рекомендуемое',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
            ),
          ),
          ...tracks.map(
            (track) => _buildTrackCard(track, offline: false, queue: tracks),
          ),
        ],
      ),
    );
  }

  Widget _buildOffline() {
    if (downloadedTracks.isEmpty) {
      return _buildEmptyState(
        Icons.download_for_offline_outlined,
        'Здесь пока ничего нет',
        subtitle: 'Скачанные композиции появятся здесь',
      );
    }
    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Text(
            'Скачано: ${downloadedTracks.length}',
            style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
        ),
        ...downloadedTracks.map(
          (track) => _buildTrackCard(
            track,
            offline: true,
            queue: downloadedTracks,
          ),
        ),
      ],
    );
  }

  Widget _buildMiniPlayer() {
    final track = currentTrack;
    if (track == null) return const SizedBox.shrink();

    final canSkip = _queueIds.length > 1;

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF282828),
        borderRadius: BorderRadius.circular(12),
      ),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        builder: (context, snapshot) {
          final playerState = snapshot.data;
          final playing = playerState?.playing ?? false;
          final processing = playerState?.processingState;
          final loading = processing == ProcessingState.loading ||
              processing == ProcessingState.buffering;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, positionSnapshot) {
                  final position = positionSnapshot.data ?? Duration.zero;
                  final duration = _player.duration ?? Duration.zero;
                  final progress = duration.inMilliseconds > 0
                      ? (position.inMilliseconds / duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : 0.0;
                  return LinearProgressIndicator(
                    value: progress,
                    minHeight: 2,
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(accentColor),
                  );
                },
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Предыдущий',
                    onPressed: canSkip ? () => _skip(-1) : null,
                    icon: const Icon(Icons.skip_previous_rounded, size: 28),
                    color: Colors.white,
                    disabledColor: Colors.white24,
                  ),
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: accentColor,
                        ),
                      ),
                    )
                  else
                    IconButton(
                      onPressed: _togglePlayback,
                      icon: Icon(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 32,
                        color: accentColor,
                      ),
                    ),
                  IconButton(
                    tooltip: 'Следующий',
                    onPressed: canSkip ? () => _skip(1) : null,
                    icon: const Icon(Icons.skip_next_rounded, size: 28),
                    color: Colors.white,
                    disabledColor: Colors.white24,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: backgroundColor,
        title: const Row(
          children: [
            Icon(Icons.graphic_eq, color: accentColor, size: 29),
            SizedBox(width: 9),
            Text(
              'MUSIC',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                fontSize: 21,
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: accentColor,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: 'Обзор (API)'),
            Tab(text: 'Скачанные (Офлайн)'),
            Tab(text: 'Профиль'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildCatalog(),
          _buildOffline(),
          ProfileTab(
            offlineOnly: widget.offlineOnly,
            onLeaveOfflineMode: widget.onLeaveOfflineMode,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: _buildMiniPlayer(),
      ),
    );
  }

  @override
  void dispose() {
    _completionSubscription?.cancel();
    _tabController.dispose();
    _player.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Профиль
// ---------------------------------------------------------------------------

const List<String> _monthsRu = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String _formatDate(String? iso) {
  final date = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (date == null) return '—';
  return '${date.day} ${_monthsRu[date.month - 1]} ${date.year}';
}

class ProfileTab extends StatefulWidget {
  const ProfileTab({
    super.key,
    required this.offlineOnly,
    this.onLeaveOfflineMode,
  });

  final bool offlineOnly;
  final VoidCallback? onLeaveOfflineMode;

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  User? _user = AuthService.currentUser;
  bool _saving = false;
  bool _signingOut = false;

  Future<void> _editName() async {
    final current = AuthService.displayName(_user);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => _EditNameDialog(initial: current),
    );
    if (newName == null || newName == current || !mounted) return;

    setState(() => _saving = true);
    try {
      final updated = await AuthService.updateName(newName);
      if (!mounted) return;
      setState(() => _user = updated ?? AuthService.currentUser);
      _toast('Имя обновлено.');
    } catch (error) {
      if (mounted) _toast(AuthService.humanError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceColor,
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Скачанные треки останутся на устройстве и будут доступны офлайн.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: errorColor,
              foregroundColor: Colors.black87,
            ),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _signingOut = true);
    try {
      await AuthService.signOut();
    } catch (error) {
      if (mounted) {
        setState(() => _signingOut = false);
        _toast(AuthService.humanError(error));
      }
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: const Color(0xFF303030),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.offlineOnly) return _buildOfflineProfile();

    final user = _user;
    final name = AuthService.displayName(user);
    final email = user?.email ?? '—';
    final confirmed = user?.emailConfirmedAt != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
      children: [
        Center(child: _Avatar(seed: email, name: name, size: 104)),
        const SizedBox(height: 18),
        Text(
          name,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          email,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 26),
        _InfoTile(
          icon: Icons.person_outline_rounded,
          label: 'Имя пользователя',
          value: name,
          trailing: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: accentColor,
                  ),
                )
              : IconButton(
                  tooltip: 'Изменить имя',
                  onPressed: _editName,
                  icon: const Icon(Icons.edit_outlined, color: accentColor),
                ),
        ),
        _InfoTile(
          icon: Icons.mail_outline_rounded,
          label: 'Email',
          value: email,
          trailing: Icon(
            confirmed ? Icons.verified_rounded : Icons.error_outline,
            color: confirmed ? accentColor : Colors.orangeAccent,
          ),
        ),
        _InfoTile(
          icon: Icons.event_available_outlined,
          label: 'Дата регистрации',
          value: _formatDate(user?.createdAt),
        ),
        const SizedBox(height: 22),
        OutlinedButton.icon(
          onPressed: _signingOut ? null : _signOut,
          icon: _signingOut
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_rounded),
          label: const Text('Выйти из аккаунта'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            foregroundColor: errorColor,
            side: const BorderSide(color: Color(0x66FF6B6B)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOfflineProfile() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 62, color: Colors.white24),
            const SizedBox(height: 16),
            const Text(
              'Вы не вошли в аккаунт',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Сейчас доступны только скачанные треки. '
              'Войдите, чтобы открыть весь каталог.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: widget.onLeaveOfflineMode,
              style: FilledButton.styleFrom(
                backgroundColor: accentColor,
                foregroundColor: Colors.black87,
                minimumSize: const Size(200, 50),
              ),
              child: const Text('Войти или зарегистрироваться'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.seed, required this.name, required this.size});

  final String seed;
  final String name;
  final double size;

  static const List<List<Color>> _palettes = [
    [Color(0xFF2BE36F), Color(0xFF0E8A41)],
    [Color(0xFF4FC3F7), Color(0xFF1565C0)],
    [Color(0xFFFFB74D), Color(0xFFE65100)],
    [Color(0xFFBA68C8), Color(0xFF6A1B9A)],
    [Color(0xFFFF8A80), Color(0xFFC62828)],
    [Color(0xFF4DB6AC), Color(0xFF00695C)],
  ];

  @override
  Widget build(BuildContext context) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final colors = _palettes[hash % _palettes.length];
    final trimmed = name.trim();
    final initial = trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: const [
          BoxShadow(color: accentGlow, blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _EditNameDialog extends StatefulWidget {
  const _EditNameDialog({required this.initial});

  final String initial;

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.pop(context, _controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceColor,
      title: const Text('Изменить имя'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          cursorColor: accentColor,
          textInputAction: TextInputAction.done,
          validator: validateName,
          onFieldSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: 'Имя',
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: accentColor),
            ),
            floatingLabelStyle: TextStyle(color: accentColor),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: Colors.black87,
          ),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}
