// Asset loader: prefers the ready-made sprites in /img (Twemoji, CC-BY 4.0)
// and falls back to procedural canvas drawings if a file is missing, so the
// game works fully offline too. Drop your own PNG into /img using the same
// name to override any sprite.
const FILES = {
    apple: 'apple.png',
    golden: 'golden.png',
    crate: 'crate.png',
    bolt: 'bolt.png',
    crown: 'crown.png',
    party: 'party.png',
    sparkles: 'sparkles.png',
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
    } else if (name === 'bolt') {
        g.fillStyle = '#f7d31e';
        g.beginPath();
        g.moveTo(36, 2); g.lineTo(14, 36); g.lineTo(28, 36);
        g.lineTo(24, 62); g.lineTo(50, 26); g.lineTo(34, 26);
        g.closePath();
        g.fill();
    } else if (name === 'crown') {
        g.fillStyle = '#f7d31e';
        g.beginPath();
        g.moveTo(8, 50); g.lineTo(8, 20); g.lineTo(20, 34); g.lineTo(32, 12);
        g.lineTo(44, 34); g.lineTo(56, 20); g.lineTo(56, 50);
        g.closePath();
        g.fill();
        g.fillStyle = '#e0362c';
        g.fillRect(8, 44, 48, 6);
    } else if (name === 'party' || name === 'sparkles') {
        const colors = ['#e74c3c', '#f1c40f', '#2ecc71', '#3498db', '#9b59b6'];
        for (let i = 0; i < 10; i++) {
            g.fillStyle = colors[i % colors.length];
            g.fillRect(8 + (i * 53) % 48, 8 + (i * 29) % 48, 6, 6);
        }
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
