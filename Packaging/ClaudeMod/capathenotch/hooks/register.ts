// CapaTheNotch's Claude Code mod (ADR 0001, amended 2026-10-08).
//
// After a reply, Claude Code measures the session; when the plan's limits
// moved, their two windows are handed to CapaTheNotch's bridge in the shape
// Claude Code's status line gives it. Nothing else crosses: no prompt, no
// transcript, no cost, no folder, no session id of Claude Code's.
//
// What this mod may hook and call is fixed, and checked by CapaTheNotch's
// tests through `claude plugin validate`: the `session.measure` hook and
// `$.process.run`, nothing more.
import type { Register, SessionRateLimit } from 'claude-code'
import { bridge } from './bridge.ts'

/**
 * The bridge runs under `/usr/bin/env -i`: with an empty environment, so
 * nothing Claude Code was started with — the desktop app's sign-in token,
 * account ids, API keys — reaches it.
 */
export const argv: readonly string[] = ['/usr/bin/env', '-i', bridge]

/**
 * Tells this session's readings apart from another's, as the status line's
 * session id does, without carrying Claude Code's own: the bridge keeps only
 * a digest of it anyway.
 */
const session = crypto.randomUUID()

type Window = { used_percentage: number; resets_at: number }

/**
 * The windows as the status line spells them — `used_percentage`, and
 * `resets_at` in seconds since 1970 — or nothing when there is no window the
 * bridge reads.
 */
export function statusLine(session: string, limits: readonly SessionRateLimit[]): string | undefined {
  const windows: Record<string, Window> = {}
  for (const limit of limits) {
    if (limit.kind !== 'five_hour' && limit.kind !== 'seven_day') continue
    if (limit.resetsAt === undefined) continue
    const resetsAt = Date.parse(limit.resetsAt)
    if (!Number.isFinite(resetsAt) || !Number.isFinite(limit.percentUsed)) continue
    windows[limit.kind] = { used_percentage: limit.percentUsed, resets_at: Math.floor(resetsAt / 1000) }
  }
  if (Object.keys(windows).length === 0) return undefined
  return JSON.stringify({ session_id: session, rate_limits: windows })
}

export const register: Register = on => {
  on('session.measure', async ($, e, next) => {
    const measured = await next(e)
    // The first measurement names every unit it has a figure for, so it
    // counts as a change too.
    if (!e.changed.includes('rateLimits')) return measured
    const stdin = statusLine(session, e.rateLimits)
    if (stdin === undefined) return measured
    try {
      // Started in `/`, not the session's folder, which is the person's.
      await $.process.run(argv, { cwd: '/', stdin, timeoutMs: 10_000 })
    } catch {
      // CapaTheNotch moved or was removed: the card goes Stale, as it would
      // with no reading at all. Claude Code is never interrupted for it.
    }
    return measured
  })
}
