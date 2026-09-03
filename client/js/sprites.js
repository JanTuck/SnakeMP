// Asset loader: prefers the ready-made sprites in /img (Twemoji, CC-BY 4.0)
// and falls back to procedural canvas drawings if a file is missing, so the
// game works fully offline too. Drop your own PNG into /img using the same
// name to override any sprite.
const FILES = {
    apple: 'apple.png',
    golden: 'golden.png',
    crate: 'crate.png',
    ioHead: 'io-360-head.png',
    ioBody: 'io-360-body.png',
    ioTail: 'io-360-tail.png',
    ioBoost: 'io-360-boost-ring.png',
    ioApple: 'io/apple.png',
    ioStrawberry: 'io/strawberry.png',
    ioCheese: 'io/cheese.png',
    ioDonut: 'io/donut.png',
    ioGoldenApple: 'io/golden-apple.png',
    ioLightning: 'io/lightning-berry.png',
    ioRainbow: 'io/rainbow-candy.png',
    ioFeast: 'io/feast-platter.png',
    ioCrate: 'io/crate.png',
    ioMine: 'io/spike-mine.png',
};

function loadImage(file) {
    return new Promise((resolve) => {
        const img = new Image();
        img.onload = () => resolve([file, img]);
        img.onerror = () => resolve([file, null]);
        img.src = '/img/' + file;
    });
}

const IO_STYLE_COLORS = ['#51cf66', '#ff6b6b', '#fcc419', '#339af0', '#845ef7', '#f6e6c7'];

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
    } else {
        g.fillStyle = '#a8ec18';
        g.beginPath();
        g.arc(32, 32, name === 'ioBody' ? 25 : 29, 0, Math.PI * 2);
        g.fill();
    }
    return c;
}

export const Sprites = {
    images: new Map(),
    ioVariants: new Map(),

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

    getIo(name, styleIndex) {
        const source = this.images.get(name);
        if (source === undefined) return undefined;
        const palette = Math.max(0, Math.min(IO_STYLE_COLORS.length - 1, styleIndex | 0));
        let variants = this.ioVariants.get(name);
        if (variants === undefined) {
            variants = new Array(IO_STYLE_COLORS.length);
            this.ioVariants.set(name, variants);
        }
        const cached = variants[palette];
        if (cached !== undefined) return cached;
        const canvas = document.createElement('canvas');
        canvas.width = 64;
        canvas.height = 64;
        const context = canvas.getContext('2d');
        context.imageSmoothingEnabled = true;
        context.drawImage(source, 0, 0, 64, 64);
        context.globalCompositeOperation = 'source-atop';
        context.globalAlpha = 0.72;
        context.fillStyle = IO_STYLE_COLORS[palette];
        context.fillRect(0, 0, 64, 64);
        context.globalAlpha = palette === 5 ? 0.7 : 0.3;
        context.fillStyle = '#151914';
        if (palette === 1) {
            for (let x = 6; x < 64; x += 15) context.fillRect(x, 0, 5, 64);
        } else if (palette === 2 || palette === 4 || palette === 5) {
            for (const [x, y, radius] of [[17, 18, 5], [42, 35, 7], [24, 53, 4]]) {
                context.beginPath();
                context.arc(x, y, palette === 5 ? radius : radius * 0.62, 0, Math.PI * 2);
                context.fill();
            }
        } else if (palette === 3) {
            for (let y = 10; y < 64; y += 16) context.fillRect(0, y, 64, 4);
        }
        context.globalCompositeOperation = 'source-over';
        context.globalAlpha = 1;
        variants[palette] = canvas;
        return canvas;
    },
};
