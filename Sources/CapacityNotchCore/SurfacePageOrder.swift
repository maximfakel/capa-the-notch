/// A page of the expanded surface: one per Module that has something to show.
public enum SurfacePage: Hashable, Sendable {
    case capacity
    case music
    case teleprompter
}

/// Which pages the expanded surface has, in which order, and how a turn moves
/// between them. Capacity first — it is the question the product answers —
/// then each Module in the order it arrived (ADR 0003).
public enum SurfacePageOrder {
    public static func pages(musicLoaded: Bool, teleprompter: Bool) -> [SurfacePage] {
        [.capacity]
            + (musicLoaded ? [.music] : [])
            + (teleprompter ? [.teleprompter] : [])
    }

    /// One page on or back; the ends hold.
    public static func step(from page: SurfacePage, by steps: Int, in pages: [SurfacePage]) -> SurfacePage {
        let current = pages.firstIndex(of: page) ?? 0
        return pages[min(max(current + steps, 0), pages.count - 1)]
    }

    /// The page to show when the one chosen may have gone — a track ended, a
    /// Module switched off.
    public static func shown(_ page: SurfacePage, in pages: [SurfacePage]) -> SurfacePage {
        pages.contains(page) ? page : .capacity
    }
}
