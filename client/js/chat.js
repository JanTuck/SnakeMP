// Lobby chat stays out of the arena until it is needed: recent messages float
// over play, while focusing the input reveals bounded session scrollback.
(function () {
    'use strict';

    const MAX_HISTORY = 100;
    const MAX_PLAYERS = 100;
    const MAX_SCALARS = 96;
    const MAX_BYTES = 160;
    const FADE_AFTER_MS = 8500;
    const HIDE_AFTER_MS = 10000;
    const encoder = new TextEncoder();
    const palette = [
        '#78dce8', '#ffd866', '#a9dc76', '#ff9b8f',
        '#ab9df2', '#ffb86c', '#7bdff2', '#f7a8d8',
        '#9ee493', '#f5c26b', '#8cb4ff', '#e59bff',
        '#75e6b5', '#ff9fbc', '#c4b5fd', '#fde68a'
    ];

    const root = document.getElementById('game_chat');
    const history = document.getElementById('chat_history');
    const form = document.getElementById('chat_form');
    const input = document.getElementById('chat_input');
    const status = document.getElementById('chat_status');
    const openButton = document.getElementById('chat_open');
    if (root === null || history === null || form === null || input === null ||
        status === null || openButton === null || typeof socket === 'undefined') return;

    let enabled = false;
    let open = false;
    let scrollPending = false;
    const messages = [];
    let roster = new Map();

    function hashIdentity(id) {
        let hash = 2166136261;
        for (let index = 0; index < id.length; index++) {
            hash ^= id.charCodeAt(index);
            hash = Math.imul(hash, 16777619);
        }
        return hash >>> 0;
    }

    function validColor(value) {
        if (typeof value !== 'string' || !/^#[0-9a-f]{6}$/i.test(value)) return false;
        const channels = [1, 3, 5].map((offset) => {
            const unit = Number.parseInt(value.slice(offset, offset + 2), 16) / 255;
            return unit <= 0.04045 ? unit / 12.92 : ((unit + 0.055) / 1.055) ** 2.4;
        });
        const foreground = channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722;
        const background = 0.0037; // #090c12, the focused and transient chat surface
        return (foreground + 0.05) / (background + 0.05) >= 4.5;
    }

    function paletteColor(id, used) {
        const start = hashIdentity(id) % palette.length;
        for (let attempt = 0; attempt < palette.length; attempt++) {
            const color = palette[(start + attempt * 7) % palette.length];
            if (used === undefined || !used.has(color)) return color;
        }
        return palette[start];
    }

    function reconcileRoster(nextRoster) {
        if (!Array.isArray(nextRoster) || nextRoster.length > MAX_PLAYERS) return;
        const candidates = [];
        const ids = new Set();
        for (const meta of nextRoster) {
            if (!Array.isArray(meta) || meta.length < 2 ||
                typeof meta[0] !== 'string' || meta[0].length === 0 ||
                typeof meta[1] !== 'string' || ids.has(meta[0])) return;
            ids.add(meta[0]);
            candidates.push({ id: meta[0], name: meta[1], color: meta[2] });
        }

        // Stable ordering plus collision resolution gives every active player a
        // distinct fallback without coupling chat color to roster arrival order.
        candidates.sort((left, right) => left.id.localeCompare(right.id));
        const used = new Set();
        const next = new Map();
        for (const candidate of candidates) {
            let color = validColor(candidate.color) ? candidate.color.toLowerCase() : null;
            if (color === null || used.has(color)) color = paletteColor(candidate.id, used);
            used.add(color);
            next.set(candidate.id, { name: candidate.name, color });
        }
        roster = next;
    }

    function validMessageText(value) {
        if (typeof value !== 'string') return null;
        const text = value.trim();
        if (text.length === 0 || Array.from(text).length > MAX_SCALARS) return null;
        return encoder.encode(text).length <= MAX_BYTES ? text : null;
    }

    function scrollToLatest() {
        history.scrollTop = history.scrollHeight;
    }

    function scheduleScrollToLatest() {
        if (scrollPending) return;
        scrollPending = true;
        requestAnimationFrame(() => {
            scrollPending = false;
            scrollToLatest();
        });
    }

    function setOpen(nextOpen) {
        if (nextOpen && !enabled) return;
        open = nextOpen;
        root.classList.toggle('is-open', open);
        openButton.setAttribute('aria-expanded', open ? 'true' : 'false');
        if (open) {
            input.focus({ preventScroll: true });
            scheduleScrollToLatest();
        } else if (document.activeElement === input) {
            input.blur();
        }
    }

    function expireMessage(record) {
        record.fadeTimer = setTimeout(() => record.element.classList.add('is-fading'), FADE_AFTER_MS);
        record.hideTimer = setTimeout(() => record.element.classList.add('is-expired'), HIDE_AFTER_MS);
    }

    function appendMessage(item) {
        if (item === null || typeof item !== 'object' || Array.isArray(item) ||
            typeof item.id !== 'string' || item.id.length === 0) return;
        const text = validMessageText(item.text);
        const identity = roster.get(item.id);
        const suppliedName = typeof item.who === 'string' ? item.who : item.name;
        const name = identity?.name ?? suppliedName;
        if (text === null || typeof name !== 'string' || name.length === 0 ||
            Array.from(name).length > 24) return;

        const entry = document.createElement('div');
        const nameElement = document.createElement('span');
        const messageElement = document.createElement('span');
        entry.className = 'chat-message';
        entry.dir = 'auto';
        nameElement.className = 'chat-name';
        messageElement.className = 'chat-text';
        nameElement.textContent = name;
        messageElement.textContent = text;
        const fallbackColor = validColor(item.color) ? item.color.toLowerCase() : paletteColor(item.id);
        nameElement.style.color = identity?.color ?? fallbackColor;
        entry.append(nameElement, document.createTextNode(': '), messageElement);
        history.append(entry);

        const record = { element: entry, fadeTimer: 0, hideTimer: 0 };
        messages.push(record);
        expireMessage(record);
        while (messages.length > MAX_HISTORY) {
            const removed = messages.shift();
            clearTimeout(removed.fadeTimer);
            clearTimeout(removed.hideTimer);
            removed.element.remove();
        }
        if (open) scheduleScrollToLatest();
    }

    socket.on('init', () => {
        enabled = true;
        root.hidden = false;
        root.classList.remove('is-game-over');
        status.textContent = '';
    });
    socket.on('death', () => {
        root.classList.add('is-game-over');
        status.textContent = 'Press T to chat while you wait.';
    });
    socket.on('r', reconcileRoster);
    socket.on('chat', appendMessage);

    form.addEventListener('submit', (event) => {
        event.preventDefault();
        const message = validMessageText(input.value);
        if (message === null) {
            input.setCustomValidity('Use 1 to 96 characters and no more than 160 UTF-8 bytes.');
            input.reportValidity();
            return;
        }
        input.setCustomValidity('');
        if (socket.emit('chat', message)) {
            input.value = '';
            status.textContent = 'Message sent.';
            // Match the familiar in-game chat loop: Enter sends, closes chat,
            // and immediately returns the keyboard to steering. Recent
            // messages remain visible in the lightweight feed above the
            // persistent Chat button.
            setOpen(false);
        } else {
            status.textContent = 'Chat is offline. Reconnect and try again.';
        }
    });

    input.addEventListener('input', () => {
        input.setCustomValidity('');
        status.textContent = '';
    });
    input.addEventListener('keydown', (event) => {
        if (event.key !== 'Escape') return;
        event.preventDefault();
        setOpen(false);
    });
    input.addEventListener('blur', () => {
        setTimeout(() => {
            if (open && !root.contains(document.activeElement)) setOpen(false);
        }, 0);
    });
    openButton.addEventListener('click', () => setOpen(true));

    document.addEventListener('pointerdown', (event) => {
        if (open && !root.contains(event.target)) setOpen(false);
    });
    document.addEventListener('keydown', (event) => {
        if (!enabled || event.defaultPrevented || open) return;
        const enter = event.key === 'Enter';
        const shortcut = event.code === 'KeyT' && !event.altKey && !event.ctrlKey && !event.metaKey;
        if (!enter && !shortcut) return;
        const target = event.target;
        const tag = target && typeof target.tagName === 'string' ? target.tagName.toUpperCase() : '';
        if ((target && target.isContentEditable) ||
            tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;
        if (enter && (tag === 'BUTTON' || tag === 'A')) return;
        event.preventDefault();
        setOpen(true);
    });
})();
