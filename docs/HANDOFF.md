# HANDOFF — выпуск Rocket Landing 1.1.0 (для агента на Windows)

Код готов; твоя задача — собрать **3 цели**, проверить, **выпустить GitHub
Release v1.1.0**, загрузить артефакты релиза и скопировать APK в `~/intemp`
(на Windows это `%USERPROFILE%\intemp`, либо папка, указанная пользователем).

Всё в Windows, нативно. WSL не нужен, кроме опциональной сборки `.deb`
(см. «Linux (Debian)»).

## Что уже сделано (репо rival-afk/rocket-landing, ветка main)

- **Меню** (`game/menu.gd`): при обычном запуске — «Играть / TAS». TAS-экран:
  запуск/остановка расчёта, сохранение в `user://tas.json`, загрузка ленты из
  файла, проверка реальным воспроизведением в игре, экран результата.
  Меню не показывается при `--api`/headless/`--shot`; **любой запрос к API
  автоматически закрывает меню** (так тренажёр не блокируется).
- **Сенсорное управление** (`game/touch.gd`): кнопки ◀ ▶ и «ТЯГА», только
  Android (`OS.get_name() == "Android"`), прячется в меню/проверке TAS.
- **TAS-поиск** (`game/tas_search.gd`, `tas_gpu_search.gd`, `tas_coop.gd`,
  `tas_kernel.glsl(.spv)`): на каждом из 60 тиков/с перебирает все
  6 комбинаций (−, ←, →, ▲, ▲+←, ▲+→) с отсечением пересечений со стеной;
  цель — лучший рекорд (глубина) и время. GPU-compute шейдер (локальный
  RenderingDevice) + независимый CPU-поток параллельно; без GPU/Vulkan —
  честный fallback «CPU ×2». Лента в `user://tas.json` совместима с
  `/tas/verify` игры.
- **Игра**: меню/touch интегрированы в `game.gd`; solo-смерть при активном
  TAS не перезагружает сцену (иначе проверка не увидит результат); версия
  поднята до **1.1.0**.
- **README.md** (корень) и **docs/RELEASE_NOTES_1.1.0.md** — готовы.

Headless-проверки пройдены: все скрипты парсятся, TAS-поиск считает и пишет
ленту, `/tas/verify` воспроизводит её в реальной физике (см. «Известные
проблемы»).

## 0. Окружение

| Что | Откуда |
|---|---|
| Godot 4.7.2 stable (Windows, **не** .NET) | https://godotengine.org/download/ — `Godot_v4.7.2-stable_win64.exe` + `_console.exe` |
| Export templates 4.7.2.stable | тот же сайт (`.tpz`) — распаковать `templates/` в `%APPDATA%\Godot\export_templates\4.7.2.stable\` |
| Android SDK cmdline-tools + `platform-tools`, `platforms;android-34`, `build-tools;34.0.0` | https://developer.android.com/studio#command-line-tools-only |
| OpenJDK 17 или 21 | любой, `java` в PATH |
| git, gh (авторизован как rival-afk) | уже стоят |

`ANDROID_SDK_ROOT`/`ANDROID_HOME` должны указывать на SDK. В редакторе Godot
укажи путь к SDK при первом запуске (или он сам найдёт).

## 1. Однократная подготовка проекта

```powershell
# из корня репо (папка с README.md)
& "путь\к\Godot_v4.7.2-stable_win64_console.exe" --headless --path .\game --import
```

Это создаст `.godot/` (в `.gitignore`): без него игра не стартует — все
ассеты (включая `rocket.svg`) не резолвятся и игра падает в цикл
«crash → reload → crash». На машинах разработчиков это норма: импорт
делается один раз.

## 2. Быстрые проверки

```powershell
# игра грузится и печатает версию + API
& "путь\к\Godot_v4.7.2-stable_win64_console.exe" --headless --path .\game --quit
# ждём "Rocket Landing 1.1.0 (<commit>)" и "Rocket Landing API: http://127.0.0.1:8080"
```

## 3. Сборка трёх целей

```powershell
.\build_all.ps1
```

Скрипт сам: проставляет `VERSION/COMMIT/BUILD_DATE` в `game.gd` (и откатывает
правки), собирает:

- `build\windows\RocketLanding.exe` + `RocketLanding.pck`
- `build\linux\RocketLanding` (бинарь) + `RocketLanding.pck`, затем
  `RocketLanding-linux-x86_64.tar.gz`
- `build\android\RocketLanding.apk`

и печатает SHA256 артефактов. Годится и выборочно:
`.\build_all.ps1 -Target windows|linux|android`.

### Linux (Debian)

Артефакт — tarball с бинарём и `.pck` (`tar` встроен в Windows 10+). Если
нужен именно `.deb`, собери его на Debian/Ubuntu (например, в WSL или на
машине пользователя):

```bash
# пример скелета .deb — скрипт build_all.ps1 этого не делает
mkdir -p pkg/DEBIAN pkg/usr/games pkg/usr/share/rocket-landing
cat > pkg/DEBIAN/control <<EOF2
Package: rocket-landing
Version: 1.1.0
Section: games
Priority: optional
Architecture: amd64
Maintainer: Rocket Landing
Description: Deterministic cave-flyer with HTTP API and TAS
EOF2
cp build/linux/RocketLanding build/linux/RocketLanding.pck pkg/usr/share/rocket-landing/
ln -s /usr/share/rocket-landing/RocketLanding pkg/usr/games/rocket-landing
dpkg-deb --build pkg rocket-landing_1.1.0_amd64.deb
```

и добавь `rocket-landing_1.1.0_amd64.deb` в релиз (если пользователь подтвердил,
что `.deb` нужен).

### Android

- Пресет `Android` в `game/export_presets.cfg`: `arm64-v8a`, `min_sdk 24`,
  package `com.rocketlanding.game`, подпись — **default debug keystore**
  (поля `keystore/*` пустые; Godot сгенерирует/возьмёт стандартный
  `debug.keystore`). Для публичного продакшена позже нужен настоящий release
  keystore: `keytool -genkeypair -v -keystore release.keystore -alias rocket
  -keyalg RSA -keysize 2048 -validity 10000` и прописать его в пресете.
- Если `godot` жалуется на отсутствие SDK/templates — проверь шаги 0–1.
- Проверка подписи: `apksigner verify --print-certs build\android\RocketLanding.apk`
  (или пропусти — скрипт собирает debug-подписанный APK, устанавливается на
  любое устройство с включённой установкой из источников).

## 4. GitHub Release v1.1.0

```powershell
gh release create v1.1.0 --repo rival-afk/rocket-landing `
  --title "Rocket Landing 1.1.0" `
  --notes-file docs\RELEASE_NOTES_1.1.0.md `
  build\windows\RocketLanding.exe build\windows\RocketLanding.pck `
  build\linux\RocketLanding-linux-x86_64.tar.gz `
  build\android\RocketLanding.apk
```

(Если релиз уже создан, используй `gh release upload v1.1.0 <files>`.)

## 5. Копирование APK

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\intemp" | Out-Null
Copy-Item build\android\RocketLanding.apk "$env:USERPROFILE\intemp\" -Force
```

Если пользователь имел в виду иное `~/intemp` (например, путь внутри
Android-устройства через `adb push`), уточни у него.

## 6. Известные проблемы (не блокируют релиз)

1. **TAS verify может вернуть FAIL** с тиком касания стены, хотя лента
   получена поиском: модель поиска (float64, semi-implicit Euler, 9 контрольных
   точек + 2 px запаса) расходится с реальной физикой ~1 px на тик после
   нескольких сотен тиков. Verify честно сообщает результат (`PASS ... ticks`
   или `FAIL ... tick N`). Улучшения: калибровка модели по эталонной записи,
   либо сравнение только по выживанию (так и сделано — FAIL только если
   коснулся стены или нарушены инварианты логики).
2. **Проверять TAS только на `time_scale = 1.0`**; `/speed 3+` нестабилен для
   повтора физики.
3. **GPU-шейдер** `tas_kernel.glsl` уже скомпилирован в `.spv` и лежит в
   репо. При изменении `.glsl` пересобрать:
   `glslangValidator -V -S comp --target-env vulkan1.1 game\tas_kernel.glsl -o game\tas_kernel.glsl.spv`
   (или любой другой Vulkan-компилятор).
4. **Без GPU/Vulkan** TAS автоматически считает двумя CPU-потоками («CPU ×2»
   в меню) — норма, так задумано.
5. **Упоминания `.uid`** в `.tscn`/репо на свежих клонах дают предупреждения —
   лечатся первым `--import`.

## 7. Контрольный список релиза

- [ ] `--import` прошёл, `--quit` печатает `Rocket Landing 1.1.0` + API-баннер
- [ ] Собраны `RocketLanding.exe` + `.pck` (Windows), `.tar.gz` (Linux), `.apk` (Android)
- [ ] APK установился/поставлен на устройство или эмулятор (опционально, но желательно)
- [ ] `gh release create v1.1.0` (или `upload`), все 4 артефакта приложены
- [ ] APK скопирован в `%USERPROFILE%\intemp` (или путь пользователя)
- [ ] Отчёт пользователю: ссылка на релиз
