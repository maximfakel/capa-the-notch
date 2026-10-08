// The Modules' parts of the surface, one file each: the page a Module has on
// the open surface, and the row it may add under the closed strip. A Module
// is listed here once it has them.
//
// A file exports `default` an object:
//   id            the Module's id in the hub's state (`state.modules[id]`)
//   page          'music' | 'teleprompter' | 'shelf': the page it draws, if any
//   drawPage(g, scene, box, ctx)      draws the page into box {x, y, width}; `ctx` is the page model
//   compactRow(ctx) -> null | {priority, height, width?, wide?, draw(g, scene, box, ctx)}
//                     the row under the closed strip; the highest priority shows
//   hoverOpens(ctx) -> bool            false keeps a passing pointer from opening the surface
//   running(ctx) -> bool               a dot on its page button while it runs
//   onEvent(scene, name, data)         something the Module said that is not state
//   excludesFromCapture(ctx) -> bool   true keeps the surface out of screen recordings (the Shelf's Clippings)
// `ctx` is what `SurfaceScene.pageModel()` returns, with the Module's own
// state as `ctx.module`.

import shelf from './shelf.js';
import music from './music.js';
import teleprompter from './teleprompter.js';
import dictation from './dictation.js';

export const MODULES = [music, shelf, teleprompter, dictation];
