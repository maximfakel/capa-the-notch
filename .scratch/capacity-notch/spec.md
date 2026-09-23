# Capacity Notch — spec

The shared understanding the author confirmed at the end of the
`grill-with-docs` interview, before ticket 01, kept here word for word. It
was not saved at the time — only the tickets, `CONTEXT.md` and the two ADRs
were — so its boundaries and its deferred list lived only in a chat until
2026-09-24.

Where it and a later decision disagree, the later decision stands; see
**Changed since** below.

---

Продукт
Capacity Notch — MIT‑приложение для Apple Silicon/macOS 14+, показывающее AI‑лимиты в области notch. Первая аудитория — вы и небольшая группа разработчиков.
Распространение: GitHub Releases → Developer ID signing и notarization. Sparkle обеспечивает подписанные обновления.
MVP

* Провайдеры: Codex и Claude Code.
* В закрытом состоянии: два индикатора по сторонам notch, основное значение — `% left`.
* Headline Window выбирается с учётом оставшегося времени, а не только процента.
* В раскрытии: две карточки со всеми окнами, reset countdown, свежестью и состоянием подключения.
* Hover открывает preview; click фиксирует; `Esc` и click снаружи закрывают.
* Обновление: 60 секунд при раскрытии, 5 минут в фоне, backoff после ошибок.
* Последний snapshot сохраняется и показывается как Stale Capacity.
* Menu Bar используется для Settings, Refresh, Diagnostics и Quit.
* Один выбранный экран, по умолчанию встроенный.
* Fullscreen поддерживается; содержимое исключается из screen recording.
* Launch at Login предлагается после первого успешного подключения.
* Обязательны keyboard navigation, VoiceOver, Reduce Motion, contrast и независимость от одного цвета.

Уведомления
Capacity Alert отправляется один раз при переходе окна в критическое состояние:

* `Capacity Pace < 0.5`;
* либо `10% left`, если длительность окна неизвестна.

Клик открывает нужную карточку. Stale‑данные уведомлений не вызывают.
Архитектура и безопасность

* Swift 6, SwiftUI + AppKit, `NSPanel`.
* Новый clean-room проект, а не форк.
* Codex — только через официальный App Server.
* Claude Code — экспериментальный read-only Adapter к непубличному first-party endpoint.
* Приложение не копирует, не сохраняет и не обновляет Provider credentials.
* Без App Sandbox; Hardened Runtime и минимальные entitlements.
* Без аналитики; локальные redacted diagnostics.
* Только один активный аккаунт на Provider.

Границы
Не делать вообще:

* Intel;
* Mac App Store;
* одновременную шторку на нескольких дисплеях.

Отложить до завершения MVP:

* музыка;
* Shelf и clipboard;
* календарь;
* стоимость и активные AI‑сессии;
* история и графики;
* новые AI‑провайдеры.

Speech Dictation
Это deferred hypothesis, а не обещание roadmap. После MVP возможен отдельный прототип:

* push‑to‑talk;
* фразы до 25 секунд;
* полностью локальное распознавание;
* русский с английскими dev‑терминами;
* вставка в активное поле с clipboard fallback;
* отдельная загрузка модели;
* permissions только при включении;
* проверка задержки, качества, памяти, батареи и совместимости на M1 Pro.

Глоссарий уже зафиксирован в `CONTEXT.md`, а ключевые решения — в двух ADR.

---

## Changed since

Read against the code on 2026-09-24.

Changed on purpose, and recorded:

| The spec said | Now | Where |
| --- | --- | --- |
| Developer ID signing, notarization, Sparkle | ad-hoc signing, updates by hand | ticket 11 |
| Headline Window weighed against time left | the scarcest window, an earlier reset breaking a tie | ticket 05, `CONTEXT.md` |
| Alert at `Capacity Pace < 0.5`, or 10% left | Capacity Pace is bands of what is left; an Alert when a window goes below 10% | ticket 05, ticket 08, `CONTEXT.md` |
| Claude Code through a non-public first-party endpoint | Claude Code's own `/usage`, and the status-line bridge | ticket 03, ticket 13, ADR 0001 |
| A notch that shows AI limits; music, Shelf, clipboard, calendar and dictation deferred | a Notch Surface hosting built-in Modules, Capacity the first; the deferred list ordered and decided | ticket 15, ADR 0003, `CONTEXT.md` |

Not what the spec said, and not recorded until now:

- **Hardened Runtime was off** — fixed on 2026-09-24. Both executables are
  now signed with `--options runtime` and no entitlements
  (`flags=0x10002(adhoc,runtime)`), in the install loop and the release;
  Codex, `/usage` and the bridge were checked working under it on the
  running application.
- **Diagnostics is not in the menu bar menu.** Copy Diagnostics is in
  Settings only.
- **Launch at Login is not always offered after the first connection.** Since
  the onboarding fix of ticket 07 (2026-09-23), someone who connected a
  Provider from the menu or a card and closed the welcome window is not asked;
  it stays off and in Settings.

The deferred list was decided by ticket 15 on 2026-09-24: the non-Capacity
features become Modules, in order; cost, sessions, history and new Providers
are declined for now.
