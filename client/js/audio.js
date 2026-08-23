// Tiny WebAudio synth: zero asset SFX with a persistent mute toggle.
let ctx = null;
let muted = false;
try {
    muted = localStorage.getItem('snake_muted') === '1';
} catch (e) { /* storage unavailable */ }

function audio() {
    if (ctx === null) ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (ctx.state === 'suspended') ctx.resume();
    return ctx;
}

function tone(freq, dur, type = 'sine', vol = 0.12, delay = 0, slideTo = 0) {
    if (muted) return;
    try {
        const a = audio();
        const osc = a.createOscillator();
        const gain = a.createGain();
        const t0 = a.currentTime + delay;
        osc.type = type;
        osc.frequency.setValueAtTime(freq, t0);
        if (slideTo > 0) osc.frequency.exponentialRampToValueAtTime(slideTo, t0 + dur);
        gain.gain.setValueAtTime(vol, t0);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
        osc.connect(gain).connect(a.destination);
        osc.start(t0);
        osc.stop(t0 + dur + 0.02);
    } catch (e) { /* audio unavailable */ }
}

export const Sfx = {
    get muted() { return muted; },
    toggle() {
        muted = !muted;
        try { localStorage.setItem('snake_muted', muted ? '1' : '0'); } catch (e) {}
        return muted;
    },
    unlock() {
        try { audio(); } catch (e) {}
    },
    eat() { tone(520, 0.09, 'square', 0.10, 0, 780); },
    golden() { [660, 880, 1320].forEach((f, i) => tone(f, 0.12, 'triangle', 0.12, i * 0.07)); },
    drop() { tone(170, 0.16, 'sawtooth', 0.12, 0, 90); tone(880, 0.1, 'triangle', 0.09, 0.14); },
    death() { tone(420, 0.45, 'sawtooth', 0.14, 0, 60); },
    join() { tone(440, 0.08, 'triangle', 0.07); tone(660, 0.08, 'triangle', 0.07, 0.09); },
    countIn() { tone(330, 0.07, 'square', 0.08); tone(330, 0.07, 'square', 0.08, 0.12); tone(660, 0.16, 'square', 0.1, 0.24); },
};

// Browsers require a user gesture before audio can start.
document.addEventListener('keydown', () => Sfx.unlock(), { once: true });
document.addEventListener('pointerdown', () => Sfx.unlock(), { once: true });
