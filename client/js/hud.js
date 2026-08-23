// DOM HUD: score panel, live leaderboard, event feed and the mute toggle.
// Rendered as DOM (not canvas) so it stays crisp and CSS-animatable.
import { Sfx } from "./audio.js";

const G = () => window.gsap; // GSAP is optional juice; everything degrades fine.

let els = null;
let myId = null;
const feedTimers = [];

function feedText(item) {
    switch (item.type) {
        case 'join': return { icon: '🐍', text: `${item.who} slithered in` };
        case 'death': return { icon: '💀', text: `${item.who} crashed (score ${item.score})` };
        case 'drop-incoming': return { icon: '📦', text: 'Supply drop incoming!' };
        case 'drop-open': return { icon: '🎉', text: `${item.who} cracked a crate: +${item.apples} apples` };
        case 'golden': return { icon: '⭐', text: `${item.who} grabbed the golden apple +${item.points}` };
        default: return { icon: '•', text: JSON.stringify(item) };
    }
}

export const Hud = {
    init() {
        const root = document.getElementById('hud');
        if (root === null) return;
        root.innerHTML = `
            <div class="hud-panel" id="hud_score"></div>
            <div class="hud-panel" id="hud_board"></div>
            <div id="hud_feed"></div>
            <button id="hud_mute" title="Toggle sound"></button>
        `;
        els = {
            root,
            score: document.getElementById('hud_score'),
            board: document.getElementById('hud_board'),
            feed: document.getElementById('hud_feed'),
            mute: document.getElementById('hud_mute'),
        };
        // Panels stay hidden until there is something to show (i.e. joined).
        els.score.style.display = 'none';
        els.board.style.display = 'none';
        this.setMuted(this.muted);
        els.mute.addEventListener('click', () => {
            const m = this.toggleMute();
            if (!m) Sfx && Sfx.eat && Sfx.eat();
        });
    },

    // Wired by rendering.js so the button can unmute with a confirmation blip.
    setMuted(muted) {
        if (els === null) return;
        els.mute.textContent = muted ? '🔇' : '🔊';
    },

    update(players, meId) {
        if (els === null) return;
        myId = meId;
        if (players.length > 0) {
            els.score.style.display = 'flex';
            els.board.style.display = 'block';
        }
        const me = players.find((p) => p.id === meId);
        const sorted = [...players].sort((a, b) => b.score - a.score).slice(0, 5);
        els.score.innerHTML = me
            ? `<span class="hud-you">${me.displayName}</span>
               <span class="hud-stat">⭐ ${me.score}</span>
               <span class="hud-stat">📏 ${me.snake.length}</span>`
            : '';
        els.board.innerHTML = sorted.map((p, i) =>
            `<div class="hud-row${p.id === meId ? ' hud-me' : ''}">
                <span class="hud-rank">${i + 1}.</span>
                <span class="hud-name">${p.displayName}</span>
                <span class="hud-pts">${p.score}</span>
            </div>`).join('');
    },

    feed(item) {
        if (els === null) return;
        const { icon, text } = feedText(item);
        const el = document.createElement('div');
        el.className = 'hud-feed-item';
        el.innerHTML = `<span class="hud-icon">${icon}</span> ${text}`;
        els.feed.prepend(el);
        if (G()) G().from(el, { x: 40, opacity: 0, duration: 0.3, ease: 'power2.out' });
        while (els.feed.children.length > 5) els.feed.lastChild.remove();
        const timer = setTimeout(() => {
            el.remove();
        }, 4500);
        feedTimers.push(timer);
    },

    popScore() {
        if (els === null || !G()) return;
        G().fromTo(els.score, { scale: 1.12 }, { scale: 1, duration: 0.25, ease: 'power2.out' });
    },
};
