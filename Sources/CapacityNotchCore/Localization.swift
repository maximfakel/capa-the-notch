import Foundation

/// The language Settings and the menu speak. The notch and notifications stay
/// in English for now; Settings are where a person reads whole sentences.
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
        case .russian: russian[english] ?? english
        case .english, .system: english
        }
    }

    public static func format(_ english: String, _ arguments: CVarArg..., in language: AppLanguage = current) -> String {
        String(format: text(english, in: language), locale: language.locale, arguments: arguments)
    }

    public static let russian: [String: String] = [
        // Sections
        "General": "Основные",
        "Providers": "Провайдеры",
        "Alerts": "Оповещения",
        "Modules": "Модули",
        "Diagnostics": "Диагностика",
        "Where Capacity Notch appears, and how it starts and updates.": "Где появляется Capacity Notch, как запускается и обновляется.",
        "Where Capacity comes from, and whether it is being read.": "Откуда берутся лимиты и читаются ли они сейчас.",
        "A notification when a window is about to run out.": "Уведомление, когда лимит вот-вот закончится.",
        "What the notch shows besides Capacity. Each one is off until you turn it on.": "Что ещё показывает шторка, кроме лимитов.",
        "What to send when something is wrong.": "Что отправить, если что-то пошло не так.",
        "Settings sections": "Разделы настроек",
        "Capacity Notch Settings": "Настройки Capacity Notch",

        // General
        "Language": "Язык",

        // Menu
        "Refresh Now": "Обновить сейчас",
        "Settings…": "Настройки…",
        "Quit Capacity Notch": "Завершить Capacity Notch",
        "System": "Как в системе",
        "Appearance": "Оформление",
        "Light": "Светлое",
        "Dark": "Тёмное",
        "Launch at login": "Открывать при входе",
        "Show on": "Показывать на",
        "Built-in display": "Встроенный дисплей",
        "Appear in screen sharing and recordings": "Показывать при демонстрации и записи экрана",
        "macOS keeps Capacity Notch out of the capture it controls. It cannot promise anything about a camera pointed at the screen.": "macOS убирает Capacity Notch из записи экрана, которой управляет сама. За камеру, направленную на экран, она ручаться не может.",
        "Version %@": "Версия %@",
        "Check for Updates…": "Проверить обновления…",
        "Opens the latest release on GitHub. Capacity Notch does not check on its own.": "Открывает последний выпуск на GitHub. Сама Capacity Notch обновления не проверяет.",

        // Providers
        "While the surface is closed": "Обновлять данные",
        "Every %d minutes": "Каждые %d мин",
        "Every hour": "Каждый час",
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
        "Codex answered in a form Capacity Notch cannot read. Update Capacity Notch.": "Codex ответил в формате, который Capacity Notch не понимает. Обновите Capacity Notch.",
        "Codex could not read its Capacity — %@ Retrying.": "Codex не смог прочитать свои лимиты — %@ Пробуем снова.",
        "Turn on Codex in Settings to read its Capacity.": "Включите Codex в настройках, чтобы читать его лимиты.",
        "Turn on Claude Code in Settings to read its Capacity.": "Включите Claude Code в настройках, чтобы читать его лимиты.",
        "Run Claude Code in a terminal to update its last published Capacity.": "Запустите Claude Code в терминале, чтобы обновить последние опубликованные лимиты.",
        "Claude Code has not published Capacity yet. Configure the Capacity Notch status-line bridge, then run Claude Code in a terminal.": "Claude Code ещё не публиковал лимиты. Настройте мост строки состояния Capacity Notch и запустите Claude Code в терминале.",
        "Install Claude Code, then try again.": "Установите Claude Code и попробуйте снова.",
        "Claude Code did not answer. Check that it is signed in, then refresh.": "Claude Code не ответил. Проверьте, что вход выполнен, и обновите.",
        "Claude Code's usage report has changed and Capacity Notch cannot read it. Update Capacity Notch.": "Отчёт Claude Code об использовании изменился, и Capacity Notch не может его прочитать. Обновите Capacity Notch.",
        "Last seen before Capacity Notch restarted. Refreshing.": "Получено до перезапуска Capacity Notch. Обновляем.",

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
        "%@ settings": "Настройки: %@",
        "Expanded": "Развёрнуто",
        "Collapsed": "Свёрнуто",
        "Open, the surface has a page for it. It is read through a part of macOS that Apple does not publish, which a macOS update could close.": "В раскрытом состоянии у неё своя страница.",
        "macOS no longer lets Capacity Notch read what's playing.": "macOS больше не даёт Capacity Notch узнать, что играет.",
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
        "Download failed. Check your connection and free disk space, then try again.": "Загрузка не удалась. Проверьте подключение и свободное место на диске и попробуйте снова.",
        "Download the speech model in Dictation settings before recording.": "Перед записью загрузите языковую модель в настройках диктовки.",
        "Microphone access is required. Allow Capacity Notch in System Settings → Privacy & Security → Microphone.": "Нужен доступ к микрофону. Разрешите Capacity Notch в Системных настройках → Конфиденциальность и безопасность → Микрофон.",
        "The microphone could not start. Check microphone access and your input device in System Settings.": "Микрофон не запустился. Проверьте доступ к микрофону и устройство ввода в Системных настройках.",
        "No speech was recognised. Check your microphone and try again.": "Речь не распознана. Проверьте микрофон и попробуйте снова.",
        "The microphone changed. Select your input device and try again.": "Микрофон сменился. Выберите устройство ввода и попробуйте снова.",
        "No microphone is available. Connect one and try again.": "Микрофон не найден. Подключите его и попробуйте снова.",
        "The speech model could not load. Download it again in Dictation settings.": "Языковая модель не загрузилась. Загрузите её заново в настройках диктовки.",
        "The speech model is missing or damaged. Download it again in Dictation settings.": "Языковая модель отсутствует или повреждена. Загрузите её заново в настройках диктовки.",
        "The download could not be unpacked. Check free disk space and try again.": "Загрузку не удалось распаковать. Проверьте свободное место и попробуйте снова.",

        // Diagnostics
        "Keep a log for bug reports": "Вести журнал для отчётов об ошибках",
        "Copy Diagnostics": "Копировать отчёт",
        "Reveal Log": "Показать журнал",
        "Run Onboarding Again": "Онбординг",
        "Copied text carries versions, the states of Providers and Dictation, and timings. It carries no credential, address, identifier, Provider message or dictated text — those cannot reach it.": "В скопированном тексте — версии, состояние провайдеров и диктовки, время. Учётных данных, адресов, идентификаторов, сообщений провайдеров и надиктованного текста в нём нет.",
    ]
}
