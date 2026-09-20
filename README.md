# Winnie

Персональный десктоп-питомец для macOS: Винни-Пух поверх всех окон с карманным чатом на Claude API.
Личный проект, не публикуется.

## Что умеет

- Чат с Claude (веб-поиск, скриншоты, голос), вкладки Chat · Events · Notes
- Напоминания с системными уведомлениями, заметки в Markdown-файлах, память
- Чтение Gmail, свои HTTP-API и MCP-серверы, Telegram-бот
- Управление собственными настройками из чата, перекур в 16:20 и сны

Все решения и их причины — в [docs/design.md](docs/design.md).

## Сборка

Нужны только Command Line Tools (`xcode-select --install`), Xcode не обязателен.

```bash
./scripts/install.sh     # собрать, подписать и поставить в /Applications, перезапустив Винни
./scripts/build-app.sh   # только собрать build/Winnie.app
swift test               # тесты ядра
```

Подпись: скрипт использует самоподписанный сертификат «Winnie Dev» из Связки ключей, если он есть
(тогда разрешения macOS переживают пересборки), иначе подписывает ad-hoc.

## Инструменты разработчика

```bash
swift run WinnieSnapshot out.png [chat|empty|events|notes|note|mention|confirm|mail|settings-<раздел>]
swift run WinnieSnapshot /dev/null editor-test    # поведение и скорость редактора заметок
swift scripts/add-sprite.swift картинка.png состояние [--colour-only] [--bounds-from другая.png]
swift scripts/import-sprites.swift                # разложить спрайты в папку приложения
```

`WinnieSnapshot` рисует настоящие окна приложения в PNG с тестовыми данными — так вёрстка проверяется
без доступа к экрану. Его окна не могут получить фокус клавиатуры.

## Устройство

| Каталог | Что в нём |
|---|---|
| `Sources/WinnieCore` | Логика без AppKit: API-клиент, хранилища, инструменты модели, разбор Markdown. Покрыта тестами |
| `Sources/WinnieApp` | Окна, меню, чат, редактор заметок, голос, интеграции |
| `Sources/Winnie` | Исполняемая оболочка в одну строку |
| `Sources/WinnieSnapshot` | Утилита снимков и проверок редактора (только debug) |
| `Assets` | Оригиналы спрайтов и иконок |

Данные пользователя лежат в `~/Library/Application Support/Winnie/` (чаты, события, заметки, память,
статистика, спрайты); секреты — в Связке ключей, сервис `local.winnie.pet`.
