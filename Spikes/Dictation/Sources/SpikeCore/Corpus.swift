/// What the author reads aloud once: Russian as a developer speaks it, with
/// the English words that come with the work, in short, medium and long
/// phrases up to the 25 seconds ticket 12 allows.
public enum Corpus {
    public enum Length: String, CaseIterable, Sendable {
        case short   // a few seconds
        case medium  // about ten
        case long    // twenty or so
    }

    public struct Phrase: Sendable {
        public let id: String
        public let length: Length
        public let text: String
    }

    public static let phrases: [Phrase] = [
        Phrase(id: "s01", length: .short, text: "Открой pull request в main."),
        Phrase(id: "s02", length: .short, text: "Запусти тесты ещё раз."),
        Phrase(id: "s03", length: .short, text: "Сделай commit и push."),
        Phrase(id: "s04", length: .short, text: "Упал build на CI."),
        Phrase(id: "s05", length: .short, text: "Добавь это в README."),
        Phrase(id: "s06", length: .short, text: "Верни JSON вместо строки."),
        Phrase(id: "s07", length: .short, text: "Проверь логи в Xcode."),
        Phrase(id: "s08", length: .short, text: "Переименуй функцию в fetchUser."),
        Phrase(id: "s09", length: .short, text: "Созвон перенесли на завтра."),
        Phrase(id: "s10", length: .short, text: "Deploy на staging прошёл."),
        Phrase(id: "s11", length: .short, text: "Поставь breakpoint в этом месте."),
        Phrase(id: "m01", length: .medium, text: "Посмотри, пожалуйста, почему SwiftUI перерисовывает весь список, когда меняется одна строка."),
        Phrase(id: "m02", length: .medium, text: "В Settings добавь переключатель, который включает Dark Mode только для окна настроек."),
        Phrase(id: "m03", length: .medium, text: "Claude Code отвечает медленно, проверь, не упирается ли он в rate limit."),
        Phrase(id: "m04", length: .medium, text: "Сделай rebase на свежий main и реши конфликты в Package.swift."),
        Phrase(id: "m05", length: .medium, text: "Напиши unit test на парсер, который читает ответ usage из терминала."),
        Phrase(id: "m06", length: .medium, text: "Давай вынесем эту логику в отдельный модуль и покроем её тестами."),
        Phrase(id: "m07", length: .medium, text: "В Docker контейнере не хватает памяти, подними limit до четырёх гигабайт."),
        Phrase(id: "m08", length: .medium, text: "Открой Figma, найди экран Settings и скопируй оттуда отступы."),
        Phrase(id: "m09", length: .medium, text: "Через GitHub Actions собери release и приложи zip к тегу."),
        Phrase(id: "m10", length: .medium, text: "Задача в Jira висит уже неделю, давай разобьём её на три тикета."),
        Phrase(id: "m11", length: .medium, text: "Надо обновить macOS до двадцать седьмой версии и пересобрать проект."),
        Phrase(id: "l01", length: .long, text: "Сегодня я хочу показать, как работает Capacity Notch: он показывает лимиты Codex и Claude Code прямо в вырезе экрана, и если лимит заканчивается, приходит уведомление."),
        Phrase(id: "l02", length: .long, text: "Сначала проверь, что backend отвечает на health check, потом посмотри в Grafana, не вырос ли latency, и только после этого откатывай deploy на предыдущую версию."),
        Phrase(id: "l03", length: .long, text: "В этом pull request я переписал загрузку конфигурации: теперь она читает YAML, проверяет схему и падает с понятной ошибкой, если какого-то поля не хватает."),
        Phrase(id: "l04", length: .long, text: "Давай договоримся, что каждый feature branch живёт не больше двух дней, а code review делаем в тот же день, когда открыли merge request."),
        Phrase(id: "l05", length: .long, text: "Модель распознавания работает локально через ONNX Runtime, ничего не отправляет в облако, и текст вставляется прямо туда, где стоит курсор."),
        Phrase(id: "l06", length: .long, text: "Если в терминале команда claude висит дольше тридцати секунд, значит, она ждёт доступа к Keychain, и её надо перезапустить после разблокировки."),
        Phrase(id: "l07", length: .long, text: "Встреча в Zoom начнётся в три часа, пришли ссылку в Slack и не забудь поделиться экраном, чтобы показать новый дизайн."),
        Phrase(id: "l08", length: .long, text: "Я бы начал с простого прототипа на SwiftUI, проверил идею на двух-трёх пользователях, а уже потом думал о том, как это масштабировать."),
        Phrase(id: "l09", length: .long, text: "Обычный разговор без терминов тоже важен: завтра утром я поеду на дачу, вернусь к обеду и сразу сяду разбирать почту."),
        Phrase(id: "l10", length: .long, text: "Когда пользователь нажимает на уведомление, открывается карточка нужного провайдера, и окно, о котором было предупреждение, подсвечивается на несколько секунд."),
        Phrase(id: "l11", length: .long, text: "Для диктовки нужен push to talk: держишь клавишу, говоришь, отпускаешь, и через секунду текст появляется в поле, а буфер обмена остаётся прежним."),
    ]
}
