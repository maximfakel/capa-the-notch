// Scenes for the Shelf page, to look at it in a browser:
// `index.html?mock=shelf-files&open&page=shelf` (shelf-moved, shelf-screens,
// shelf-clips, shelf-empty, shelf-empty-screens, shelf-empty-clips, shelf-drop,
// shelf-near, shelf-many).

const now = () => Date.now();

const item = (id, name, kind, extra = {}) => ({
    id, name, kind, badge: kind === 'image' ? null : (name.split('.').pop() ?? '').toUpperCase().slice(0, 4),
    path: `/home/me/${name}`, inMemory: false, missing: false, hasThumbnail: false, ...extra,
});

const tabInfo = (tab, held, extra = {}) => ({
    tab, held, limit: 20,
    emptyTitle: {files: 'dragFiles', screenshots: 'screenshotsWait', clipboard: 'textWaits'}[tab],
    emptyDetail: {hint: {files: 'filesLimit', screenshots: 'screenshotsLimit', clipboard: 'turnOnText'}[tab]},
    ...extra,
});

function view(overrides = {}) {
    const v = {
        enabled: true, tab: 'files', tabs: [], files: [], screenshots: [], clippings: [], justCopied: null,
        isDropTargeted: false, isDropNear: false, showsDropArea: false, swallowedAt: null,
        takesClipboardImages: true, keepsText: true, clippingLimit: 20, clippingsExpire: true,
        excludedApplications: [], clipboardRefused: false, screenshotFolderRefused: false, ...overrides,
    };
    v.tabs = [
        tabInfo('files', v.files.length),
        tabInfo('screenshots', v.screenshots.length, {emptyDetail: {hint: v.takesClipboardImages ? 'screenshotsLimit' : 'turnOnImages'}}),
        tabInfo('clipboard', v.clippings.length, {
            emptyDetail: v.keepsText ? {hint: v.clippingsExpire ? 'clippingsExpire' : 'clippingsStay', limit: 20} : {hint: 'turnOnText'},
        }),
    ];
    return v;
}

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

function module(v, language = 'en') {
    const thumbnails = {};
    for (const i of [...v.files, ...v.screenshots])
        if (i.hasThumbnail)
            thumbnails[i.id] = `/tmp/shelf/${i.id}.png`;
    return {
        view: v,
        thumbnails,
        counts: {
            files: plural(v.files.length, 'file', 'files'),
            screenshots: plural(v.screenshots.length, 'screenshot', 'screenshots'),
            clipboard: plural(v.clippings.length, 'clipping', 'clippings'),
        },
        pushClipboard: true, wantsClipboard: true, wantsText: v.keepsText, wantsImages: v.takesClipboardImages,
        holdsClippings: v.clippings.length > 0,
    };
}

const files = () => [
    item(1, 'Quarterly report.pdf', 'pdf'),
    item(2, 'Budget 2026.xlsx', 'spreadsheet'),
    item(3, 'Screenshot 2026-10-05 at 12.41.03.png', 'image', {hasThumbnail: true}),
    item(4, 'Pitch.key', 'presentation'),
    item(5, 'Contract draft.docx', 'document'),
    item(6, 'archive.zip', 'archive'),
    item(7, 'notes', 'other', {badge: null}),
];

const clippings = () => [
    {id: 1, text: 'The quick brown fox jumps over the lazy dog and keeps running through the long grass until it reaches the river bank', copiedAt: new Date(now() - 60e3).toISOString()},
    {id: 2, text: 'npm install --save-dev eslint', copiedAt: new Date(now() - 3600e3).toISOString()},
    {id: 3, text: 'https://example.com/a/very/long/link/that/does/not/break/anywhere/at/all?x=1', copiedAt: new Date(now() - 7200e3).toISOString()},
    {id: 4, text: 'Короткая заметка на русском языке', copiedAt: new Date(now() - 9000e3).toISOString()},
];

function scene(base, v, selected = 'shelf') {
    const state = base();
    return {...state, pages: ['capacity', 'shelf'], modules: {shelf: module(v)}, mockPage: selected};
}

export function shelfScenes(base) {
    return {
        'shelf-files': () => scene(base, view({files: files().slice(0, 5)})),
        'shelf-many': () => scene(base, view({files: files()})),
        'shelf-moved': () => scene(base, view({files: [item(1, 'Quarterly report.pdf', 'pdf', {missing: true}), ...files().slice(1, 4)]})),
        'shelf-screens': () => scene(base, view({tab: 'screenshots', screenshots: [
            item(10, 'Screenshot 2026-10-05 at 12.41.03.png', 'image', {hasThumbnail: true}),
            item(11, 'Image 2026-10-05 at 12.50.10.png', 'image', {hasThumbnail: true, inMemory: true, path: null}),
        ]})),
        'shelf-clips': () => scene(base, view({tab: 'clipboard', clippings: clippings(), justCopied: 2})),
        'shelf-empty': () => scene(base, view()),
        'shelf-empty-screens': () => scene(base, view({tab: 'screenshots', takesClipboardImages: false})),
        'shelf-empty-clips': () => scene(base, view({tab: 'clipboard', keepsText: true})),
        'shelf-drop': () => scene(base, view({files: files().slice(0, 2), isDropTargeted: true, showsDropArea: true})),
        'shelf-near': () => scene(base, view({files: files().slice(0, 2), isDropTargeted: true, isDropNear: true, showsDropArea: true})),
    };
}

/** What the hub would answer a `call` for the Shelf in a browser. */
export function shelfCall({method, args}) {
    if (method !== 'thumbnail')
        return null;
    const canvas = document.createElement('canvas');
    canvas.width = 112;
    canvas.height = 76;
    const ctx = canvas.getContext('2d');
    const gradient = ctx.createLinearGradient(0, 0, 112, 76);
    gradient.addColorStop(0, `hsl(${(args.id * 70) % 360} 70% 55%)`);
    gradient.addColorStop(1, `hsl(${(args.id * 70 + 60) % 360} 70% 35%)`);
    ctx.fillStyle = gradient;
    ctx.fillRect(0, 0, 112, 76);
    ctx.fillStyle = 'rgba(255,255,255,.5)';
    ctx.fillRect(10, 40, 60, 8);
    return {png: canvas.toDataURL('image/png').split(',')[1]};
}
