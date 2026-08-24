// Lightweight DOM HUD: personal stats, leaderboard, event feed and sound state.
// Nodes are retained and updated in place so game ticks do not rebuild markup.

const MAX_LEADERS = 5;
const leaders = new Array(MAX_LEADERS);
const rowState = Array.from({ length: MAX_LEADERS }, () => ({
    id: null,
    name: '',
    score: 0,
    isMe: false,
    visible: false,
}));
const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

let els = null;
const lastMe = { id: null, name: '', score: 0, length: 0 };
let scoreVisible = false;
let boardVisible = false;

function setText(element, value) {
    const text = String(value);
    if (element.textContent !== text) element.textContent = text;
}

function feedContent(item) {
    switch (item.type) {
        case 'join':
            return { asset: '/img/snek.png', className: '', text: `${item.who} slithered in` };
        case 'death':
            return { asset: '/img/snek.png', className: 'is-death', text: `${item.who} crashed — score ${item.score}` };
        case 'drop-incoming':
            return { asset: '/img/crate.png', className: '', text: 'Supply drop incoming' };
        case 'drop-open':
            return { asset: '/img/crate.png', className: '', text: `${item.who} cracked a crate — +${item.apples} apples` };
        case 'golden':
            return { asset: '/img/golden.png', className: '', text: `${item.who} caught the golden apple — +${item.points}` };
        default:
            return { asset: '/img/snek.png', className: '', text: 'Game update' };
    }
}

function selectLeaders(players) {
    leaders.fill(null);
    for (let playerIndex = 0; playerIndex < players.length; playerIndex++) {
        const player = players[playerIndex];
        for (let position = 0; position < MAX_LEADERS; position++) {
            const current = leaders[position];
            if (current === null || player.score > current.score) {
                for (let shift = MAX_LEADERS - 1; shift > position; shift--) {
                    leaders[shift] = leaders[shift - 1];
                }
                leaders[position] = player;
                break;
            }
        }
    }
}

function findMe(players, id) {
    for (let index = 0; index < players.length; index++) {
        if (players[index].id === id) return players[index];
    }
    return null;
}

export const Hud = {
    init() {
        const root = document.getElementById('hud');
        if (root === null) return;

        root.innerHTML = `
            <section class="hud-panel hud-score" id="hud_score" aria-label="Your game stats" hidden>
                <span class="hud-you" id="hud_you"></span>
                <span class="hud-stat hud-stat-score" title="Score">
                    <svg aria-hidden="true" viewBox="0 0 20 20"><path d="m10 2.5 2.2 4.45 4.92.72-3.56 3.47.84 4.9L10 13.72l-4.4 2.32.84-4.9-3.56-3.47 4.92-.72L10 2.5Z"/></svg>
                    <span id="hud_points">0</span><span class="sr-only"> points</span>
                </span>
                <span class="hud-stat" title="Snake length">
                    <svg aria-hidden="true" viewBox="0 0 20 20"><path d="M3 5h7a3 3 0 0 1 0 6H8a3 3 0 0 0 0 6h9"/><path d="m14 13 3 3-3 3"/></svg>
                    <span id="hud_length">0</span><span class="sr-only"> segments</span>
                </span>
            </section>

            <section class="hud-panel hud-board" id="hud_board" aria-labelledby="hud_board_title" hidden>
                <header class="hud-board-header">
                    <h2 id="hud_board_title">Leaderboard</h2>
                    <span>Score</span>
                </header>
                <ol class="hud-rows" id="hud_rows"></ol>
            </section>

            <div id="hud_feed" role="log" aria-live="polite" aria-relevant="additions"></div>

            <button id="hud_mute" type="button" aria-pressed="false" aria-label="Turn sound off" title="Turn sound off">
                <svg class="sound-on" aria-hidden="true" viewBox="0 0 24 24"><path d="M5 9v6h4l5 4V5L9 9H5Z"/><path d="M17 9a4 4 0 0 1 0 6M19.5 6.5a8 8 0 0 1 0 11"/></svg>
                <svg class="sound-off" aria-hidden="true" viewBox="0 0 24 24"><path d="M5 9v6h4l5 4V5L9 9H5Z"/><path d="m18 9 5 5m0-5-5 5"/></svg>
            </button>
        `;

        const rows = document.getElementById('hud_rows');
        const rowElements = new Array(MAX_LEADERS);
        for (let index = 0; index < MAX_LEADERS; index++) {
            const row = document.createElement('li');
            const name = document.createElement('span');
            const score = document.createElement('span');
            name.className = 'hud-name';
            score.className = 'hud-pts';
            row.append(name, score);
            row.hidden = true;
            rows.append(row);
            rowElements[index] = { row, name, score };
        }

        els = {
            root,
            score: document.getElementById('hud_score'),
            board: document.getElementById('hud_board'),
            you: document.getElementById('hud_you'),
            points: document.getElementById('hud_points'),
            length: document.getElementById('hud_length'),
            rows: rowElements,
            feed: document.getElementById('hud_feed'),
            mute: document.getElementById('hud_mute'),
        };
    },

    setMuted(muted) {
        if (els === null) return;
        const label = muted ? 'Turn sound on' : 'Turn sound off';
        els.mute.dataset.muted = muted ? 'true' : 'false';
        els.mute.setAttribute('aria-pressed', muted ? 'true' : 'false');
        els.mute.setAttribute('aria-label', label);
        els.mute.title = label;
    },

    update(players, meId) {
        if (els === null) return;

        const me = findMe(players, meId);
        const nextScoreVisible = me !== null;
        const nextBoardVisible = players.length !== 0;
        if (scoreVisible !== nextScoreVisible) {
            els.score.hidden = !nextScoreVisible;
            scoreVisible = nextScoreVisible;
        }
        if (boardVisible !== nextBoardVisible) {
            els.board.hidden = !nextBoardVisible;
            boardVisible = nextBoardVisible;
        }

        if (me !== null) {
            const length = me.snake.length;
            if (lastMe.id !== me.id || lastMe.name !== me.displayName) setText(els.you, me.displayName);
            if (lastMe.id !== me.id || lastMe.score !== me.score) setText(els.points, me.score);
            if (lastMe.id !== me.id || lastMe.length !== length) setText(els.length, length);
            lastMe.id = me.id;
            lastMe.name = me.displayName;
            lastMe.score = me.score;
            lastMe.length = length;
        }

        selectLeaders(players);
        for (let index = 0; index < MAX_LEADERS; index++) {
            const player = leaders[index];
            const elements = els.rows[index];
            if (player === null) {
                if (rowState[index].visible) elements.row.hidden = true;
                rowState[index].id = null;
                rowState[index].visible = false;
                continue;
            }

            if (!rowState[index].visible) elements.row.hidden = false;
            const isMe = player.id === meId;
            if (rowState[index].isMe !== isMe) elements.row.classList.toggle('hud-me', isMe);
            if (rowState[index].id !== player.id || rowState[index].name !== player.displayName) {
                setText(elements.name, player.displayName);
            }
            if (rowState[index].id !== player.id || rowState[index].score !== player.score) {
                setText(elements.score, player.score);
            }
            rowState[index].id = player.id;
            rowState[index].name = player.displayName;
            rowState[index].score = player.score;
            rowState[index].isMe = isMe;
            rowState[index].visible = true;
        }
    },

    feed(item) {
        if (els === null) return;
        const content = feedContent(item);
        const entry = document.createElement('div');
        const icon = document.createElement('img');
        const text = document.createElement('span');

        entry.className = `hud-feed-item${content.className ? ` ${content.className}` : ''}`;
        icon.className = 'hud-feed-icon';
        icon.src = content.asset;
        icon.alt = '';
        icon.width = 72;
        icon.height = 72;
        text.textContent = content.text;
        entry.append(icon, text);
        els.feed.prepend(entry);

        if (!reduceMotion && window.gsap) {
            window.gsap.from(entry, { x: 24, opacity: 0.65, duration: 0.28, ease: 'power3.out' });
        }

        while (els.feed.children.length > 5) {
            const oldest = els.feed.lastElementChild;
            clearTimeout(oldest._hudTimer);
            oldest.remove();
        }

        entry._hudTimer = setTimeout(() => entry.remove(), 4500);
    },

    popScore() {
        if (els === null || reduceMotion || !window.gsap) return;
        window.gsap.fromTo(els.score, { scale: 1.06 }, { scale: 1, duration: 0.22, ease: 'power3.out' });
    },
};
