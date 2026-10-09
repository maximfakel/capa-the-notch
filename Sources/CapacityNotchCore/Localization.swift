import Foundation

/// The language CapaTheNotch speaks: onboarding, Settings, the menu, the
/// notch and its notifications.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case english
    case russian

    /// Each language names itself, so it can be found by someone who cannot
    /// read the other; System is the one word that is translated.
    public var title: String {
        switch self {
        case .system: Localization.text("System")
        case .english: "English"
        case .russian: "Русский"
        }
    }

    /// System becomes Russian when Russian is the Mac's first language, and
    /// English otherwise.
    public func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        return preferred.first?.hasPrefix("ru") == true ? .russian : .english
    }

    public var locale: Locale {
        Locale(identifier: resolved() == .russian ? "ru_RU" : "en_US")
    }
}

/// English is the key: a sentence missing from a table is shown as written.
///
/// Explicit tables rather than `.lproj` bundles, so the language can change
/// while Settings are open, and the build needs no Xcode to compile them.
public enum Localization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: AppLanguage = .english

    /// The resolved language, set at launch and whenever the choice changes.
    public static var current: AppLanguage {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue.resolved() } }
    }

    public static func text(_ english: String, in language: AppLanguage = current) -> String {
        switch language.resolved() {
        case .russian: russian[english] ?? translatorRussian[english] ?? english
        case .english, .system: english
        }
    }

    public static func format(_ english: String, _ arguments: CVarArg..., in language: AppLanguage = current) -> String {
        String(format: text(english, in: language), locale: language.locale, arguments: arguments)
    }

    /// "5 files", "5 файлов": Russian takes one of three endings by the last
    /// digits, which a single format string cannot hold.
    public static func fileCount(_ count: Int, in language: AppLanguage = current) -> String {
        switch language.resolved() {
        case .russian:
            let tens = count % 100, ones = count % 10
            let word = (11...14).contains(tens) ? "файлов" : ones == 1 ? "файл" : (2...4).contains(ones) ? "файла" : "файлов"
            return "\(count) \(word)"
        case .english, .system:
            return count == 1 ? "1 file" : "\(count) files"
        }
    }

    /// How many Clippings the Clipboard tab holds.
    public static func clippingCount(_ count: Int, in language: AppLanguage = current) -> String {
        switch language.resolved() {
        case .russian:
            let tens = count % 100, ones = count % 10
            let word = (11...14).contains(tens) ? "текстов" : ones == 1 ? "текст" : (2...4).contains(ones) ? "текста" : "текстов"
            return "\(count) \(word)"
        case .english, .system:
            return count == 1 ? "1 clipping" : "\(count) clippings"
        }
    }

    /// How many screenshots and images the Screenshots tab holds.
    public static func screenshotCount(_ count: Int, in language: AppLanguage = current) -> String {
        switch language.resolved() {
        case .russian:
            let tens = count % 100, ones = count % 10
            let word = (11...14).contains(tens) ? "скринов" : ones == 1 ? "скрин" : (2...4).contains(ones) ? "скрина" : "скринов"
            return "\(count) \(word)"
        case .english, .system:
            return count == 1 ? "1 screenshot" : "\(count) screenshots"
        }
    }

    /// A Provider's window names arrive as English data ("5 hour", "Weekly");
    /// Russian says them itself, shortly, as the notch has little room.
    public static func windowLabel(_ label: String, in language: AppLanguage = current) -> String {
        guard language.resolved() == .russian else { return label }
        switch label {
        case "Weekly": return "Неделя"
        case "Daily": return "День"
        case "Quota": return "Лимит"
        default: break
        }
        let parts = label.split(separator: " ")
        guard parts.count == 2, let count = Int(parts[0]) else { return label }
        switch parts[1] {
        case "hour": return "\(count) ч"
        case "minute": return "\(count) мин"
        case "day": return "\(count) дн."
        default: return label
        }
    }

    public static let russian: [String: String] = [
        // Sections
        "General": "Основные",
        "Providers": "Провайдеры",
        "Alerts": "Оповещения",
        "Modules": "Модули",
        "Diagnostics": "Диагностика",
        "Where CapaTheNotch appears, and how it starts and updates.": "Где появляется CapaTheNotch, как запускается и обновляется.",
        "Where Capacity comes from, and whether it is being read.": "Откуда берутся лимиты и читаются ли они сейчас.",
        "A notification when a window is about to run out.": "Уведомление, когда лимит вот-вот закончится.",
        "What the notch shows besides Capacity. Each one is off until you turn it on.": "Что ещё показывает шторка, кроме лимитов.",
        "What to send when something is wrong.": "Что отправить, если что-то пошло не так.",
        "Settings sections": "Разделы настроек",
        "CapaTheNotch Settings": "Настройки CapaTheNotch",

        // General
        "Language": "Язык",

        // Menu
        "Refresh Now": "Обновить сейчас",
        "Settings…": "Настройки…",
        "Quit CapaTheNotch": "Завершить CapaTheNotch",
        "System": "Как в системе",
        "Appearance": "Оформление",
        "Light": "Светлое",
        "Dark": "Тёмное",
        "Launch at login": "Открывать при входе",
        "Show on": "Показывать на",
        "Built-in display": "Встроенный дисплей",
        "Appear in screen sharing and recordings": "Показывать при демонстрации и записи экрана",
        "macOS keeps CapaTheNotch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.": "macOS убирает CapaTheNotch из записи экрана, которой управляет сама. За камеру, направленную на экран, она ручаться не может.",
        "Version %@": "Версия %@",
        "Check for Updates…": "Проверить обновления…",
        "Opens the latest release on GitHub. CapaTheNotch does not check on its own.": "Открывает последний выпуск на GitHub. Сама CapaTheNotch обновления не проверяет.",

        // Providers
        "Refresh data": "Обновлять данные",
        "Shown in the closed strip": "Лимиты в компактной шторке",
        "5 hours": "5 часов",
        // "Week": "Неделя" is the Calendar's, and says the same here.
        "Every minute": "Каждую минуту",
        "Every 5 min": "Каждые 5 мин",
        "Every 15 min": "Каждые 15 мин",
        "Codex is refreshed on this schedule. Claude refreshes itself, after each reply.": "Codex обновляется по этому расписанию. Claude — сам, после каждого ответа.",
        // Claude Code's card (Paper "Settings — Providers — Claude mod …")
        "Mod in Claude": "Мод в Claude",
        "Working": "Работает",
        "Not added": "Не добавлен",
        "Add": "Добавить",
        "Remove": "Удалить",
        "Only from CapaTheNotch in Applications": "Только из CapaTheNotch в «Программах»",
        "Needs Claude Code %@ or later": "Нужен Claude Code %@ или новее",
        "Refresh from a terminal": "Обновить из терминала",
        "Open Terminal": "Открыть Терминал",
        "Without the mod, Claude's limits update only from a terminal.": "Без мода лимиты Claude обновляются только из терминала.",
        "Claude Code %@ is installed, and mods arrived in %@. Until then, limits update only from a terminal.": "Установлен Claude Code %@, а моды появились в %@. Пока лимиты обновляются только из терминала.",
        "No Claude Code %@ or later was found where it is usually installed. Until then, limits update only from a terminal.": "Claude Code %@ или новее не нашёлся там, где его обычно ставят. Пока лимиты обновляются только из терминала.",
        "What the mod is": "Что такое мод",
        "A small add-on for Claude Code. After each of Claude's replies — in the Claude app, VS Code or a terminal — it hands over only the percentages and reset times of your limits. No conversations, no tokens.": "Небольшое дополнение для Claude Code. После каждого ответа Claude — в приложении Claude, VS Code или терминале — он передаёт сюда только проценты и время сброса лимитов. Ни переписки, ни токенов.",
        "It lives in ~/.claude/skills/capathenotch. Remove takes it away whole.": "Лежит в ~/.claude/skills/capathenotch. «Удалить» убирает его целиком.",
        "Refreshing from a terminal": "Обновление из терминала",
        "Claude Code in a terminal draws a status line, and CapaTheNotch's bridge reads the limits from it after each of Claude's replies. Open Terminal starts claude there; send any message and Capacity updates.": "В терминале Claude Code рисует строку состояния, и мост CapaTheNotch берёт из неё лимиты после каждого ответа Claude. «Открыть Терминал» запускает там claude — отправьте любое сообщение, и лимиты обновятся.",
        "Nothing is sent for you. Close the window when you are done.": "За вас ничего не отправляется. Когда закончите, окно можно закрыть.",
        "About %@": "Что такое «%@»",
        "Claude Code was not found. Install it, or start claude yourself.": "Claude Code не найден. Установите его или запустите claude сами.",
        "Terminal could not be opened.": "Не удалось открыть Терминал.",
        "The mod was not added": "Мод не добавлен",
        "~/.claude/skills/capathenotch is already there, and CapaTheNotch did not put it there, so it is left alone.": "Папка ~/.claude/skills/capathenotch уже есть, и положил её туда не CapaTheNotch, поэтому её никто не трогает.",
        "Refresh %@": "Обновить %@",
        "Off": "Выключено",
        "On": "Включено",
        "Fresh · read %@": "Свежие · обновлено %@",
        "Stale · last read at %@": "Устарели · обновлено в %@",
        "Disconnected": "Данных нет",
        "Connecting": "Подключение",
        "Mock": "Демо",
        "just now": "только что",
        "Install the Codex CLI, then try again.": "Установите Codex CLI и попробуйте снова.",
        "Update the Codex CLI — %@": "Обновите Codex CLI — %@",
        "Sign in with `codex login`, then try again.": "Войдите командой `codex login` и попробуйте снова.",
        "Codex is not answering — %@": "Codex не отвечает — %@",
        "Codex answered in a form CapaTheNotch cannot read. Update CapaTheNotch.": "Codex ответил в формате, который CapaTheNotch не понимает. Обновите CapaTheNotch.",
        "Codex could not read its Capacity — %@ Retrying.": "Codex не смог прочитать свои лимиты — %@ Пробуем снова.",
        "Turn on Codex in Settings to read its Capacity.": "Включите Codex в настройках, чтобы читать его лимиты.",
        "Turn on Claude Code in Settings to read its Capacity.": "Включите Claude Code в настройках, чтобы читать его лимиты.",
        "Run Claude Code in a terminal to update its last published Capacity.": "Запустите Claude Code в терминале, чтобы обновить последние опубликованные лимиты.",
        "Claude Code's Capacity appears after your next message in Claude Code in a terminal.": "Лимиты Claude Code появятся после следующего сообщения в Claude Code в терминале.",
        "Turn on Claude Code?": "Включить Claude Code?",
        "CapaTheNotch adds its bridge to Claude Code's status line in ~/.claude/settings.json. Your own status line keeps working, and turning Claude Code off puts everything back.": "CapaTheNotch добавит свой мост в строку состояния Claude Code (~/.claude/settings.json). Ваша строка состояния продолжит работать, а при выключении всё вернётся как было.",
        "Set up Claude Code's status line?": "Настроить строку состояния Claude Code?",
        "CapaTheNotch now reads Claude Code's Capacity from its status line. It can add its bridge there, in ~/.claude/settings.json. Your own status line keeps working, and turning Claude Code off puts everything back.": "Теперь CapaTheNotch читает лимиты Claude Code из его строки состояния. Он может добавить туда свой мост — в ~/.claude/settings.json. Ваша строка состояния продолжит работать, а при выключении всё вернётся как было.",
        "Set Up": "Настроить",
        "Not Now": "Не сейчас",
        "CapaTheNotch adds its bridge to Claude Code's status line in ~/.claude/settings.json, and a small Claude Code mod in ~/.claude/skills/capathenotch that hands it only the plan's limits after each reply — in the desktop app and VS Code too. Your own status line keeps working, and turning Claude Code off removes both.": "CapaTheNotch добавит свой мост в строку состояния Claude Code (~/.claude/settings.json) и небольшой мод Claude Code в ~/.claude/skills/capathenotch: после каждого ответа он передаёт только лимиты тарифа — в том числе в приложении Claude и VS Code. Ваша строка состояния продолжит работать, а при выключении Claude Code уберётся и то и другое.",
        "Keep Claude Code's Capacity fresh in the desktop app?": "Обновлять лимиты Claude Code и в приложении Claude?",
        "CapaTheNotch can add a small Claude Code mod in ~/.claude/skills/capathenotch. After each reply — in the desktop app, VS Code or a terminal — it hands CapaTheNotch only the plan's limits: no prompts, no code, no sign-in. settings.json is not changed, and turning Claude Code off removes it.": "CapaTheNotch может добавить небольшой мод Claude Code в ~/.claude/skills/capathenotch. После каждого ответа — в приложении Claude, VS Code или терминале — он передаёт CapaTheNotch только лимиты тарифа: ни запросов, ни кода, ни данных входа. settings.json не меняется, а при выключении Claude Code мод уберётся.",
        "Set up Claude Code for CapaTheNotch?": "Настроить Claude Code для CapaTheNotch?",
        "CapaTheNotch can add its bridge to Claude Code's status line in ~/.claude/settings.json, and a small Claude Code mod in ~/.claude/skills/capathenotch that hands it only the plan's limits after each reply — in the desktop app and VS Code too. Your own status line keeps working, and turning Claude Code off removes both.": "CapaTheNotch может добавить свой мост в строку состояния Claude Code (~/.claude/settings.json) и небольшой мод Claude Code в ~/.claude/skills/capathenotch: после каждого ответа он передаёт только лимиты тарифа — в том числе в приложении Claude и VS Code. Ваша строка состояния продолжит работать, а при выключении Claude Code уберётся и то и другое.",
        "Updates after Claude's next reply · read %@": "Обновится после следующего ответа Claude · данные %@",
        "Updates after your next message in Claude Code in a terminal · read %@": "Обновится после следующего сообщения в Claude Code в терминале · данные %@",
        "Claude Code's Capacity appears after Claude's next reply.": "Лимиты Claude Code появятся после следующего ответа Claude.",
        "Updates after Claude's next reply — in the desktop app, VS Code or a terminal.": "Обновится после следующего ответа Claude — в приложении Claude, VS Code или терминале.",
        "~/.claude/settings.json is not JSON CapaTheNotch can safely change. Add the status line by hand, as the README shows.": "~/.claude/settings.json — не тот JSON, который CapaTheNotch может безопасно изменить. Добавьте строку состояния вручную, как показано в README.",
        "Last seen before CapaTheNotch restarted. Refreshing.": "Получено до перезапуска CapaTheNotch. Обновляем.",

        // Alerts
        "Warn me when a window is about to run out": "Предупреждать, когда лимит вот-вот закончится",
        "One warning per window, when it first drops below a tenth left, and nothing more until it recovers or resets.": "Одно предупреждение на лимит — когда в нём впервые остаётся меньше 10%. Следующее — только после того, как лимит восстановится или сбросится.",

        // Modules
        "Built-in features. Each one is off until you turn it on.": "Встроенные функции. Каждая выключена, пока вы её не включите.",
        "Music": "Музыка",
        "Teleprompter": "Телесуфлёр",
        "Dictation": "Диктовка",
        "What's playing, with its controls, under Capacity.": "Что сейчас играет и управление — под лимитами.",
        "Your Script, scrolling beside the camera.": "Ваш текст бежит под камерой.",
        "Speak, then keep typing.": "Голосовая клавиатура на русском.",
        "Shelf": "Полка",
        "Files at hand, dropped on the notch.": "Файлы под рукой — просто бросьте их на шторку.",
        "Files dropped on the notch stay at hand until you drag them away or CapaTheNotch quits. Only a reference is kept; nothing is copied.": "Брошенные на шторку файлы остаются под рукой, пока вы их не утащите или не выйдете из CapaTheNotch. Хранится только ссылка — сами файлы никуда не копируются.",
        "Empty": "Пусто",
        "Image %@": "Изображение %@",
        "Images and files from the clipboard": "Картинки и файлы из буфера обмена",
        "What you copy lands on the Shelf: a screenshot, a picture from a page, media or a document from a messenger. Copying in Finder, text and passwords are left alone. New screenshots saved to a folder land under Screenshots too.": "Скопированное само ложится на полку: скриншот, картинка со страницы, медиа или документ из мессенджера. Копирование в Finder, текст и пароли не трогаются. Новые скриншоты, сохранённые в папку, тоже попадают во «Скрины».",
        "macOS does not let CapaTheNotch read the folder screenshots are saved to. Allow it in System Settings → Privacy & Security → Files & Folders. Screenshots you copy still arrive.": "macOS не даёт CapaTheNotch читать папку, куда сохраняются скриншоты. Разрешите это в Системных настройках → Конфиденциальность и безопасность → Файлы и папки. Скопированные скриншоты по-прежнему приходят.",
        "macOS does not let CapaTheNotch read the clipboard. Allow it in System Settings → Privacy & Security.": "macOS не даёт CapaTheNotch читать буфер обмена. Разрешите это в Системных настройках → Конфиденциальность и безопасность.",
        "Clear": "Очистить",
        "Clear %@": "Очистить: %@",
        "Up to %d. Each goes after 24 hours, and all when CapaTheNotch quits.": "До %d. Каждый уходит через 24 часа, все — при выходе из CapaTheNotch.",
        "Up to %d. All go when CapaTheNotch quits.": "До %d. Все уходят при выходе из CapaTheNotch.",
        "Copied": "Скопировано",
        "reset %@": "сброшен в %@",
        "Remove from the Shelf": "Убрать с полки",
        "Puts it on the clipboard": "Кладёт в буфер обмена",
        "Text from the clipboard": "Текст из буфера обмена",
        "Text you copy is kept under Clipboard, newest first, to put on the clipboard again. Passwords and anything marked secret are left alone.": "Скопированный текст хранится во вкладке «Буфер», новые сверху, — чтобы снова положить его в буфер. Пароли и всё, помеченное как секретное, не трогаются.",
        "Keep": "Хранить",
        "Forget each after 24 hours": "Забывать каждый через 24 часа",
        "Never from these applications": "Никогда из этих приложений",
        "Passwords and Keychain Access are always left alone.": "Пароли и Связка ключей не трогаются никогда.",
        "Add Application…": "Добавить приложение…",
        "Remove %@": "Убрать %@",
        "Files": "Файлы",
        "Screenshots": "Скрины",
        "Clipboard": "Буфер",
        "Screenshots and images you copy wait here": "Здесь ждут скопированные скриншоты и картинки",
        "Text you copy can wait here": "Здесь может ждать скопированный текст",
        "Up to 20. The Shelf empties when CapaTheNotch quits.": "До 20. Полка очищается при выходе из CapaTheNotch.",
        "Turn on “Images and files from the clipboard” in Settings → Modules → Shelf.": "Включите «Картинки и файлы из буфера обмена» в Настройках → Модули → Полка.",
        "Turn on text from the clipboard in Settings → Modules → Shelf.": "Включите текст из буфера в Настройках → Модули → Полка.",
        "File\nmoved": "Файл\nперемещён",
        "%@, moved": "%@, перемещён",
        "Remove %@ from the Shelf": "Убрать %@ с полки",
        "Drag files here to keep them at hand": "Перетащите сюда файлы, чтобы держать их под рукой",
        "Up to 20 files. The Shelf empties when CapaTheNotch quits.": "До 20 файлов. Полка очищается при выходе из CapaTheNotch.",
        "Show Kapa": "Показывать Капу",
        "%@ settings": "Настройки: %@",
        "Expanded": "Развёрнуто",
        "Collapsed": "Свёрнуто",
        "Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.": "В раскрытом состоянии у неё своя страница.",
        "macOS no longer lets CapaTheNotch read what's playing.": "macOS больше не даёт CapaTheNotch узнать, что играет.",
        "Nothing playing": "Ничего не играет",
        "Play a track in any player and it shows up here": "Включите трек в любом плеере — он появится здесь",
        "Played at %@": "Играло в %@",
        "Played in %@ · %@": "Играло: %@ · %@",
        "Audio is never saved. Esc cancels without changing your clipboard.": "Аудиозаписи не сохраняются. Esc отменяет запись, не трогая буфер обмена.",

        // Teleprompter
        "Script": "Сценарий",
        "Paste from Clipboard": "Вставить из буфера",
        "Restore Previous Script": "Восстановить прошлый",
        "%d words · %d min": "Слов: %d · %d мин",
        "Speed": "Скорость",
        "Faster": "Быстрее",
        "Slower": "Медленнее",
        "Text size": "Размер текста",
        // Teleprompter: following the voice (ticket 20)
        "Follow my voice": "Следовать за голосом",
        "The Script moves as you read it aloud and waits when you stop. It listens only while the Script runs, on this Mac; nothing is kept.": "Текст движется, пока вы читаете его вслух, и ждёт, когда вы замолкаете. Микрофон слушает только во время показа, распознавание идёт на этом Mac, ничего не сохраняется.",
        "CapaTheNotch may not use the microphone. Allow it in System Settings → Privacy & Security → Microphone, then turn this on again.": "CapaTheNotch не может пользоваться микрофоном. Разрешите это в Системных настройках → Конфиденциальность и безопасность → Микрофон и включите снова.",
        "Following the voice uses Dictation's speech model. Turn Dictation on and download the model, then turn this on again.": "Следование за голосом использует модель речи из диктовки. Включите диктовку, скачайте модель и включите снова.",
        "The microphone or the speech model did not start, so the Script went back to its set speed. Turn this on again to try once more.": "Микрофон или модель речи не запустились, поэтому текст снова идёт с заданной скоростью. Включите ещё раз, чтобы попробовать снова.",
        "Open Microphone Settings": "Открыть настройки микрофона",
        "Following your voice": "Следует за голосом",
        "Teleprompter, following your voice": "Телесуфлёр, следует за голосом",
        "Small": "Мелкий",
        "Medium": "Средний",
        "Large": "Крупный",
        "Shortcuts": "Сочетания клавиш",
        "Start or pause": "Старт или пауза",
        "Stop": "Стоп",
        "Another app already uses this shortcut.": "Это сочетание уже занято другим приложением.",
        "Type a shortcut": "Нажмите сочетание",
        "%@ shortcut": "Сочетание: %@",
        "None": "Нет",

        // Dictation
        "Hold a shortcut to turn speech into text, entirely on this Mac.": "Удерживайте сочетание, чтобы превращать речь в текст — целиком на этом Mac.",
        "Hold to dictate": "Удерживать для диктовки",
        "This shortcut is in use. Choose another.": "Это сочетание занято. Выберите другое.",
        "Model ready": "Модель готова",
        "Speech model": "Языковая модель",
        "Downloaded": "Загружена",
        "Manage speech model": "Управление языковой моделью",
        "Set up": "Настроить",
        "Automatic insertion": "Автоматическая вставка",
        "Allowed": "Разрешена",
        "Enable": "Включить",
        "Word replacements": "Замены слов",
        "Edit": "Изменить",
        "Press keys…": "Нажмите клавиши…",
        "Keep history": "Хранить историю",
        "No saved results": "Нет сохранённых результатов",
        "%d saved results": "Сохранённых результатов: %d",
        "View history": "Открыть историю",
        "Allow microphone access": "Разрешить доступ к микрофону",
        "‹ Modules / Dictation": "‹ Модули / Диктовка",
        "Set up Dictation": "Настройка диктовки",
        "Dictation history": "История диктовки",
        "Speak in Russian, with the IT terms you use every day.": "Говорите по-русски, с IT-терминами, которыми пользуетесь каждый день.",
        "Your last 50 results, kept only on this Mac.": "Последние 50 результатов хранятся локально.",
        "Choose how recognised words are written.": "Выберите, как записывать распознанные слова.",
        "Turn on Dictation": "Включить диктовку",
        "Download the speech model": "Загрузить языковую модель",
        "One download, then recognition works offline.\nGigaAM v3 · 170 MB download · 232 MB on disk": "Распознавание будет работать локально и без сети.\nGigaAM v3 · загрузка 170 МБ · 232 МБ на диске",
        "Checking the model…": "Проверяем модель…",
        "Downloading · %d%%": "Загрузка · %d%%",
        "Cancel": "Отменить",
        "Source & licences ↗": "Источник и лицензии ↗",
        "Show in Finder": "Показать в Finder",
        "Download again": "Загрузить заново",
        "Download • 170 MB": "Загрузить • 170 МБ",
        "Microphone access is needed only while recording.": "Микрофон нужен только во время записи.",
        "Requested after the model is ready.": "Запросим, когда модель будет готова.",
        "Enable automatic insertion": "Включить автоматическую вставку",
        "Optional. You can always paste from the clipboard.": "Необязательно. Всегда можно вставить из буфера обмена.",
        "Your audio stays on this Mac and is never saved.\nText history is off unless you choose to enable it.": "Аудиозаписи не сохраняются. Историю расшифровок можно включить в настройках.",
        "Turning this off keeps your saved results.": "При отключении сохранённые результаты останутся.",
        "%d results": "Результатов: %d",
        "Clear History": "Очистить историю",
        "Your next dictation will appear here.": "Здесь появится ваша следующая диктовка.",
        "No saved results. Turn on Keep history to save future dictations.": "Нет сохранённых результатов. Включите «Хранить историю», чтобы сохранять следующие диктовки.",
        "Copy": "Скопировать",
        "Delete": "Удалить",
        "%d active rules": "Активных правил: %d",
        "+ Add replacement": "+ Добавить замену",
        "Matches whole words and phrases, ignoring letter case.\nChanges apply to your next dictation.": "Распознаются целые слова и фразы, без учёта регистра.\nИзменения применятся к следующей диктовке.",
        "Recognised": "Распознано",
        "Replace with": "Заменить на",
        "Enable %@": "Включить «%@»",
        "Recognised phrase": "Распознанная фраза",
        "Replacement": "Замена",
        "Delete replacement": "Удалить замену",
        "Delete %@ replacement": "Удалить замену «%@»",
        "The text could not be pasted. It is still in the clipboard.": "Не удалось вставить текст. Он остался в буфере обмена.",
        "Download failed. Check your connection and free disk space, then try again.": "Загрузка не удалась. Проверьте подключение и свободное место на диске и попробуйте снова.",
        "Download the speech model in Dictation settings before recording.": "Перед записью загрузите языковую модель в настройках диктовки.",
        "Microphone access is required. Allow CapaTheNotch in System Settings → Privacy & Security → Microphone.": "Нужен доступ к микрофону. Разрешите CapaTheNotch в Системных настройках → Конфиденциальность и безопасность → Микрофон.",
        "The microphone could not start. Check microphone access and your input device in System Settings.": "Микрофон не запустился. Проверьте доступ к микрофону и устройство ввода в Системных настройках.",
        "No speech was recorded. Hold the shortcut while speaking.": "Речь не записана. Удерживайте сочетание, пока говорите.",
        "No speech was recognised. Check your microphone and try again.": "Речь не распознана. Проверьте микрофон и попробуйте снова.",
        "The microphone changed. Select your input device and try again.": "Микрофон сменился. Выберите устройство ввода и попробуйте снова.",
        "No microphone is available. Connect one and try again.": "Микрофон не найден. Подключите его и попробуйте снова.",
        "The speech model could not load. Download it again in Dictation settings.": "Языковая модель не загрузилась. Загрузите её заново в настройках диктовки.",
        "The speech model is missing or damaged. Download it again in Dictation settings.": "Языковая модель отсутствует или повреждена. Загрузите её заново в настройках диктовки.",
        "The download could not be unpacked. Check free disk space and try again.": "Загрузку не удалось распаковать. Проверьте свободное место и попробуйте снова.",

        // The notch
        "Next page": "Следующая страница",
        "Previous page": "Предыдущая страница",
        "Show or hide Capacity details": "Показать или скрыть лимиты",
        "Connect": "Подключить",
        "Connect this Provider": "Подключить провайдера",
        "Refresh %@ Capacity": "Обновить лимиты %@",
        "%d%% used": "Исп %d%%",
        "Fresh": "Свежие",
        "Stale": "Устарели",
        "reset time not reported": "время сброса неизвестно",
        "resets in %@": "сброс через %@",
        "No data": "Данных нет",
        "Turn one off to turn this on.": "Отключите одного, чтобы включить этот.",
        "Turn on OpenCode?": "Включить OpenCode?",
        "CapaTheNotch reads your OpenCode Go key from OpenCode's own file and asks opencode.ai only for your plan's percentages and reset times — every five minutes, and when you refresh. The key is kept nowhere and sent nowhere else.": "CapaTheNotch читает ключ OpenCode Go из файла самого OpenCode и спрашивает у opencode.ai только проценты и время сброса вашего плана — раз в пять минут и когда вы обновляете. Ключ нигде не хранится и больше никуда не отправляется.",
        "Turn On": "Включить",
        "Month used up": "Месяц исчерпан",
        "Monthly limit reached · until %@": "Месячный лимит исчерпан · до %@",
        "Monthly limit reached": "Месячный лимит исчерпан",
        "Turn on OpenCode in Settings to read its Capacity.": "Включите OpenCode в настройках, чтобы читать его лимиты.",
        "Sign in to OpenCode with `opencode auth login`, then try again.": "Войдите в OpenCode командой `opencode auth login` и попробуйте снова.",
        "OpenCode refused its key. Sign in again with `opencode auth login`.": "OpenCode не принял ключ. Войдите заново командой `opencode auth login`.",
        "opencode.ai is not answering. Retrying.": "opencode.ai не отвечает. Пробуем снова.",
        "OpenCode's answer was not understood. Update CapaTheNotch.": "Ответ OpenCode не распознан. Обновите CapaTheNotch.",
        "moments": "мгновение",
        "under a minute": "меньше минуты",
        "%dd %dh": "%d д %d ч",
        "%dd": "%d д",
        "%dh %dm": "%d ч %d мин",
        "%dh": "%d ч",
        "%dm": "%d мин",
        "Previous track": "Предыдущий трек",
        "Next track": "Следующий трек",
        "Play": "Воспроизвести",
        "Pause": "Пауза",
        "Start": "Старт",
        "Now playing": "Сейчас играет",
        "Paused": "На паузе",
        "Position": "Позиция",
        "Volume": "Громкость",
        "Mute": "Выключить звук",
        "Unmute": "Включить звук",
        "%@ of %@": "%@ из %@",
        "Teleprompter, running": "Телесуфлёр, идёт",
        "Teleprompter, paused": "Телесуфлёр, на паузе",
        "Teleprompter, finished": "Телесуфлёр, закончен",
        "Teleprompter, stopped": "Телесуфлёр, остановлен",
        "Paste a Script, or write one in Settings.": "Вставьте текст или напишите его в настройках.",
        "%.2f times": "%.2f×",
        "Paste": "Вставить",
        "Edit Script": "Изменить текст",
        "Progress through the Script": "Прогресс текста",
        "%d percent": "%d%%",
        "Text copied, not inserted": "Текст скопирован, но не вставлен",
        "Dictation stopped": "Диктовка остановлена",
        "Insertion was unavailable.": "Вставка недоступна.",
        "Try again.": "Попробуйте снова.",
        "Open Dictation Settings": "Открыть настройки диктовки",
        "Dismiss": "Закрыть",
        "Recording. Release the shortcut to recognise. Escape cancels.": "Запись. Отпустите сочетание, чтобы распознать. Esc отменяет.",
        "Recognising speech. Escape cancels.": "Распознаём речь. Esc отменяет.",
        "Text inserted and copied": "Текст вставлен и скопирован",
        "Text copied to clipboard. Tap for insertion details.": "Текст скопирован в буфер. Нажмите, чтобы узнать подробности.",
        "Dictation error. Show details.": "Ошибка диктовки. Показать подробности.",
        "No external application was captured when recording began.": "Когда началась запись, не было приложения, куда вставить текст.",
        "The target application stopped being active before insertion.": "Приложение перестало быть активным до вставки.",
        "The field changed during Accessibility insertion; paste was skipped to avoid duplicating text.": "Поле изменилось во время вставки; вставка пропущена, чтобы не задвоить текст.",
        "The captured field lost focus before insertion.": "Поле потеряло фокус до вставки.",
        "The target application or text field changed before insertion.": "Приложение или поле изменилось до вставки.",
        "Recognition could not start. Try again.": "Распознавание не запустилось. Попробуйте снова.",
        "Recognition failed. Try again.": "Распознавание не удалось. Попробуйте снова.",

        // Calendar (ticket 23)
        "Calendar": "Календарь",
        "What's next in your calendar, under Capacity.": "Что дальше в календаре — под лимитами.",
        "Events from every calendar on this Mac. Ten minutes before one starts it shows under Capacity, with Join when it carries a call link; open, the surface has a page for the day. Nothing is read while this is off.": "События из всех календарей на этом Mac. За десять минут до начала событие появляется под лимитами — с кнопкой «Войти», если в нём есть ссылка на звонок; в открытой шторке есть страница дня. Пока модуль выключен, ничего не читается.",
        "macOS does not let CapaTheNotch read your calendars. Allow it in System Settings → Privacy & Security → Calendars.": "macOS не даёт CapaTheNotch читать календари. Разрешите это в Системных настройках → Конфиденциальность и безопасность → Календари.",
        "Calendar access has not been asked for yet.": "Доступ к календарям ещё не запрошен.",
        "Allow Calendar Access": "Разрешить доступ к календарям",
        "Open Privacy Settings": "Открыть настройки конфиденциальности",
        "Join": "Войти",
        "Hide this event": "Скрыть встречу",
        "Join call": "Войти в звонок",
        "Today": "Сегодня",
        "Now": "Сейчас",
        "All day": "весь день",
        "No title": "Без названия",
        "Nothing else today": "Сегодня больше ничего",
        "Events from every calendar on this Mac show up here.": "Здесь появляются события из всех календарей на этом Mac.",
        "In %d min": "Через %d мин",
        "In %d h": "Через %d ч",
        "In %d h %d min": "Через %d ч %d мин",
        "Now · %d min left": "Сейчас · осталось %d мин",
        "+%d more": "и ещё %d",
        // Calendar: Week and Month (2026-10-07)
        "Day": "День",
        "Week": "Неделя",
        "Month": "Месяц",
        "Calendar view": "Вид календаря",
        "%d more": "ещё %d",
        "Free": "свободно",
        "No events": "Нет встреч",
        "That's all for today": "На сегодня всё",
        "Holiday": "Праздник",
        // Calendar: the author's edits (2026-10-08)
        "no events": "нет встреч",
        "all day": "весь день",
        "A free week": "Неделя свободна",
        "A free day": "Свободный день",
        "Next — %@ · %@": "Ближайшее — %@ · %@",
        "tomorrow, %@": "завтра, %@",
        "Nothing ahead": "Впереди пусто",
        "Telemost": "Телемост",
        "VK Calls": "VK Звонки",

        // Notifications
        "%@ is running out": "У %@ заканчиваются лимиты",
        "%@: %d%% left": "%@: осталось %d%%",
        "%@, resets in %@": "%@, сброс через %@",

        // VoiceOver
        "on pace": "в норме",
        "tightening": "сокращаются",
        "running out": "заканчиваются",
        "%@ window": "окно %@",
        "%d percent left": "осталось %d%%",
        "%d percent used": "использовано %d%%",
        "resets in %@, at %@": "сброс через %@, в %@",
        "no Capacity read": "лимиты не прочитаны",
        "mock Capacity": "демо-лимиты",
        "connecting": "подключение",
        "Fresh Capacity": "свежие лимиты",
        "Stale Capacity": "устаревшие лимиты",
        "disconnected": "нет данных",

        // Diagnostics
        "Keep a log for bug reports": "Вести журнал для отчётов об ошибках",
        "Copy Diagnostics": "Копировать отчёт",
        "Reveal Log": "Показать журнал",
        "Run Onboarding Again": "Онбординг",

        // Onboarding
        "Welcome": "Приветствие",
        "Welcome to CapaTheNotch": "Добро пожаловать в CapaTheNotch",
        "Connect a Provider": "Подключите провайдера",
        "How much of Codex, Claude Code and OpenCode is left, right under the notch — and a few tools beside it.": "Сколько осталось лимитов Codex, Claude Code и OpenCode — прямо под вырезом экрана. И ещё несколько инструментов рядом.",
        "CapaTheNotch reads nothing until a Provider is on.": "Пока провайдер выключен, CapaTheNotch ничего не читает.",
        "Control what's playing without leaving what you're doing.": "Управляйте музыкой, не отрываясь от работы.",
        "Read your Script beside the camera, without looking away.": "Читайте текст рядом с камерой, не отводя взгляд.",
        "Speech becomes text on this Mac. The speech model is downloaded once.": "Речь превращается в текст прямо на этом Mac. Языковая модель загружается один раз.",
        "Everything chosen here can be changed later in Settings.": "Всё, что вы выберете здесь, можно поменять потом в настройках.",
        "Onboarding steps": "Шаги онбординга",
        "Done": "Готово",
        "Step %d": "Шаг %d",
        "Back": "Назад",
        "Continue": "Продолжить",
        "Skip": "Пропустить",
        "Skipped": "Пропущено",
        "Permissions": "Разрешения",
        "Everything macOS will ask about, at once, so nothing interrupts you later.": "Всё, о чём спросит macOS, — сразу, чтобы потом ничего не отвлекало.",
        "Notifications": "Уведомления",
        "Microphone": "Микрофон",
        "Accessibility": "Универсальный доступ",
        "System Events": "System Events",
        "A Capacity Alert when a window is about to run out.": "Оповещение, когда лимит вот-вот закончится.",
        "Dictation hears you only while you hold its shortcut.": "Диктовка слышит вас, пока вы держите сочетание.",
        "Dictation types its text where the cursor is.": "Диктовка вставляет текст туда, где стоит курсор.",
        "Dictation's fallback for pasting its text.": "Запасной способ вставки текста для диктовки.",
        "macOS asks about each one in turn. Accessibility is switched on in System Settings; its state here follows when you come back.": "macOS спросит о каждом по очереди. Универсальный доступ включается в Системных настройках — когда вернётесь, здесь это отразится.",
        "Allow All": "Разрешить всё",
        "Allow": "Разрешить",
        "Granted": "Разрешено",
        "Open Settings": "Открыть настройки",
        "Calendars": "Календари",
        // The permissions asked again after the old grants were reset (ticket 33).
        "Permissions, Once More": "Разрешения — ещё раз",
        "From this version on, CapaTheNotch is signed with its author's certificate. The permissions given to earlier builds were reset — once, so that a build someone else signed cannot use them.": "С этой версии CapaTheNotch подписан сертификатом автора. Разрешения, выданные прежним сборкам, сброшены — один раз, чтобы ими не могла воспользоваться чужая сборка.",
        "macOS asks about each one in turn; Accessibility is switched on in System Settings. After this, updates keep the permissions again.": "macOS спросит о каждом по очереди; Универсальный доступ включается в Системных настройках. Дальше обновления снова сохраняют разрешения.",
        "The Earlier Permissions Were Not Reset": "Прежние разрешения не сброшены",
        "CapaTheNotch is now signed with its author's certificate, but macOS did not let it reset the permissions of earlier builds. While they are there, a build someone else signed can use them. Remove them by hand:": "CapaTheNotch теперь подписан сертификатом автора, но macOS не дала сбросить разрешения прежних сборок. Пока они на месте, ими может воспользоваться чужая сборка. Уберите их руками:",
        "In each list, choose CapaTheNotch and press −; under Automation, turn System Events off. CapaTheNotch asks again after that.": "В каждом списке выберите CapaTheNotch и нажмите «−»; в «Автоматизации» выключите System Events. Потом CapaTheNotch спросит снова.",
        "Try Again": "Попробовать снова",
        "Already Removed": "Уже убраны",
        "macOS refused again.": "macOS снова не дала.",
        "Automation": "Автоматизация",
        "Dictation and the Teleprompter hear you.": "Диктовка и суфлёр слышат вас.",
        "Text goes where the cursor is.": "Текст встаёт туда, где курсор.",
        "System Events, the fallback for pasting.": "System Events — запасной способ вставки.",
        "Connect up to two in Settings": "Подключите до двух — в настройках",
        "Open Provider Settings": "Открыть настройки провайдеров",
        "Unavailable": "Недоступно",
        "Finish": "Готово",
        "Capacity": "Лимиты",
        "What is left of each window, and whether it will last.": "Сколько осталось в каждом лимите и хватит ли его.",
        "Settings and the notch speak it; you can change it at any time.": "На нём говорят настройки и шторка. Поменять можно в любой момент.",
        "Claude Code and OpenCode are experimental. CapaTheNotch says what it reads before reading anything.": "Claude Code и OpenCode — экспериментальные. Прежде чем что-то читать, CapaTheNotch скажет, что именно.",
        "Write or paste the Script in Settings, under Modules. The shortcuts can be changed there too.": "Текст можно написать или вставить в настройках, в разделе «Модули». Там же меняются сочетания клавиш.",
        "Play sounds": "Воспроизводить звуки",
        // Ticket 14: two taps on the trackpad.
        "Open with two taps on the trackpad": "Открывать двумя касаниями трекпада",
        "Asks for no permission. Reads touches through MultitouchSupport, a private part of macOS that Apple can change in any update; if it stops answering, this says so. With Tap to click on, the two taps also double-click where the pointer is.": "Разрешений не просит. Касания читаются через MultitouchSupport — закрытую часть macOS, которую Apple может изменить в любом обновлении; если она перестанет отвечать, здесь будет об этом сказано. Если включена «Имитация нажатия касанием», два касания ещё и делают двойной щелчок там, где стоит указатель.",
        "macOS no longer lets CapaTheNotch read the trackpad, so two taps cannot open the notch.": "macOS больше не даёт CapaTheNotch читать трекпад, поэтому два касания не откроют шторку.",
        "No trackpad is connected. Two taps will work once one is.": "Трекпад не подключён. Два касания заработают, когда он появится.",
        "The trackpad stopped answering CapaTheNotch, so two taps cannot open the notch. Turning the switch off and on tries again.": "Трекпад перестал отвечать CapaTheNotch, поэтому два касания не откроют шторку. Если выключить и снова включить переключатель, будет ещё одна попытка.",
        "Move Claude Code's status line to CapaTheNotch?": "Перенести строку состояния Claude Code на CapaTheNotch?",
        "Capacity Notch is now CapaTheNotch.app. If ~/.claude/settings.json runs the status-line bridge from CapacityNotch.app, Claude Code's status line stops once that app is gone — yours too, if it runs through the bridge. CapaTheNotch can point that one path at this copy. It opens Claude Code's settings only for this, keeps nothing it reads and changes nothing else.": "Capacity Notch теперь называется CapaTheNotch.app. Если в ~/.claude/settings.json мост строки состояния запускается из CapacityNotch.app, строка состояния Claude Code пропадёт, когда этого приложения не станет, — и ваша тоже, если она идёт через мост. CapaTheNotch может указать этот путь на эту копию. Настройки Claude Code открываются только для этого: прочитанное не сохраняется, больше ничего не меняется.",
        "Update Path": "Обновить путь",
        "Leave It": "Оставить",
        "Nothing to change": "Менять нечего",
        "No path to CapacityNotch.app was found in Claude Code's settings.": "В настройках Claude Code нет пути к CapacityNotch.app.",
        "Claude Code's status line now runs the bridge from this copy.": "Строка состояния Claude Code теперь запускает мост из этой копии.",
        "Changed: %@. CapacityNotch.app can go to the Trash.": "Изменено: %@. CapacityNotch.app можно перенести в Корзину.",
        "Claude Code's settings were not changed": "Настройки Claude Code не изменены",
        "Copied text carries versions, the states of Providers and Dictation, and timings. It carries no credential, address, identifier, Provider message or dictated text — those cannot reach it.": "В скопированном тексте — версии, состояние провайдеров и диктовки, время. Учётных данных, адресов, идентификаторов, сообщений провайдеров и надиктованного текста в нём нет.",
    ]
}
