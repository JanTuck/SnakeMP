// Asset loader: prefers the ready-made sprites in /img (Twemoji, CC-BY 4.0)
// and falls back to procedural canvas drawings if a file is missing, so the
// game works fully offline too. Drop your own PNG into /img using the same
// name to override any sprite.
const FILES = {
    apple: 'apple.png',
    golden: 'golden.png',
    crate: 'crate.png',
};

function loadImage(file) {
    return new Promise((resolve) => {
        const img = new Image();
        img.onload = () => resolve([file, img]);
        img.onerror = () => resolve([file, null]);
        img.src = '/img/' + file;
    });
}

// Procedural fallbacks, drawn once into offscreen canvases.
function procedural(name) {
    const c = document.createElement('canvas');
    c.width = 64;
    c.height = 64;
    const g = c.getContext('2d');
    if (name === 'apple' || name === 'golden') {
        const gold = name === 'golden';
        const grad = g.createRadialGradient(26, 24, 4, 32, 34, 26);
        grad.addColorStop(0, gold ? '#ffe066' : '#ff6b6b');
        grad.addColorStop(1, gold ? '#e8a400' : '#c0392b');
        g.fillStyle = grad;
        g.beginPath();
        g.arc(32, 36, 24, 0, Math.PI * 2);
        g.fill();
        g.strokeStyle = '#6b4423';
        g.lineWidth = 4;
        g.beginPath();
        g.moveTo(32, 14);
        g.quadraticCurveTo(34, 6, 42, 4);
        g.stroke();
        g.fillStyle = '#2ecc71';
        g.beginPath();
        g.ellipse(42, 10, 9, 5, -0.5, 0, Math.PI * 2);
        g.fill();
        g.fillStyle = 'rgba(255,255,255,0.55)';
        g.beginPath();
        g.ellipse(22, 26, 6, 4, -0.6, 0, Math.PI * 2);
        g.fill();
    } else if (name === 'crate') {
        g.fillStyle = '#a3702e';
        g.fillRect(6, 10, 52, 48);
        g.fillStyle = '#8a5a20';
        g.fillRect(6, 10, 52, 8);
        g.fillRect(6, 50, 52, 8);
        g.fillRect(6, 10, 8, 48);
        g.fillRect(50, 10, 8, 48);
        g.strokeStyle = '#5f3d12';
        g.lineWidth = 3;
        g.strokeRect(6, 10, 52, 48);
        g.beginPath();
        g.moveTo(6, 10); g.lineTo(58, 58);
        g.moveTo(58, 10); g.lineTo(6, 58);
        g.stroke();
    }
    return c;
}

export const Sprites = {
    images: new Map(),

    async load() {
        const pairs = await Promise.all(Object.values(FILES).map(loadImage));
        for (const [file, img] of pairs) {
            const name = Object.keys(FILES).find((k) => FILES[k] === file);
            this.images.set(name, img !== null ? img : procedural(name));
        }
        return this;
    },

    get(name) {
        return this.images.get(name);
    },
};
