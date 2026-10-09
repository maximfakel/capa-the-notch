// Run with `claude plugin test Packaging/ClaudeMod/capathenotch`. Not
// shipped: the application copies only the manifest and the hooks.
import { expect, test } from 'claude-code/testing'
import type { On, ProcessRunInit, SessionMeasureInput } from 'claude-code'
import { bridge } from '../hooks/bridge.ts'

type Run = { argv: readonly string[]; init?: ProcessRunInit }

const measured: SessionMeasureInput = {
  context: { window: 200000 } as SessionMeasureInput['context'],
  changed: ['context', 'rateLimits', 'cost'],
  rateLimits: [
    { kind: 'five_hour', percentUsed: 27, resetsAt: '2026-10-08T12:50:00.000Z' },
    { kind: 'seven_day', percentUsed: 34.5, resetsAt: '2026-10-11T15:00:00.000Z' },
  ],
  cost: { totalUsd: 1.25 } as SessionMeasureInput['cost'],
}

function recording(on: On) {
  const runs: Run[] = []
  on('process.run', ($, e) => {
    runs.push({ argv: e.argv, init: e.init })
    return { value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  return runs
}

test('the limits reach the bridge in the status line shape, and nothing else does', async ($, on) => {
  const runs = recording(on)
  await $.session.measure(measured)

  expect(runs.length).toBe(1)
  const run = runs[0]!
  // An empty environment: nothing Claude Code was started with crosses.
  expect(run.argv).toEqual(['/usr/bin/env', '-i', bridge])
  expect(run.init?.env).toBeUndefined()
  expect(run.init?.cwd).toBe('/')

  const sent = JSON.parse(run.init?.stdin ?? '{}')
  expect(Object.keys(sent).sort()).toEqual(['rate_limits', 'session_id'])
  expect(sent.rate_limits).toEqual({
    five_hour: { used_percentage: 27, resets_at: 1791463800 },
    seven_day: { used_percentage: 34.5, resets_at: 1791730800 },
  })
  expect(typeof sent.session_id).toBe('string')
})

test('nothing runs when the limits did not move', async ($, on) => {
  const runs = recording(on)
  await $.session.measure({ ...measured, changed: ['context', 'cost'] })
  expect(runs.length).toBe(0)
})

test('nothing runs off a subscription, or before the first reading', async ($, on) => {
  const runs = recording(on)
  await $.session.measure({ ...measured, rateLimits: [] })
  await $.session.measure({ ...measured, rateLimits: [{ kind: 'spend_limit', percentUsed: 12 }] })
  expect(runs.length).toBe(0)
})

test('one window is enough, and a window without a reset is left out', async ($, on) => {
  const runs = recording(on)
  await $.session.measure({
    ...measured,
    rateLimits: [
      { kind: 'five_hour', percentUsed: 3 },
      { kind: 'seven_day', percentUsed: 40, resetsAt: '2026-10-11T15:00:00.000Z' },
    ],
  })
  expect(runs.length).toBe(1)
  expect(JSON.parse(runs[0]!.init?.stdin ?? '{}').rate_limits).toEqual({
    seven_day: { used_percentage: 40, resets_at: 1791730800 },
  })
})

test('a bridge that cannot run never fails the measurement', async ($, on) => {
  on('process.run', () => {
    throw new Error('no such file')
  })
  on('session.measure', ($, e) => ({ changed: e.changed }))
  const result = await $.session.measure(measured)
  expect(result.changed).toEqual(measured.changed)
})
