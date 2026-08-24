import Menu from "./menu.js?v=__SNEK_ASSET_REV__";

const OVERLAY_SELECTOR = "[data-game-over-overlay]";

function roundedRect(ctx, x, y, width, height, radius) {
    const r = Math.min(radius, width / 2, height / 2);
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + width - r, y);
    ctx.quadraticCurveTo(x + width, y, x + width, y + r);
    ctx.lineTo(x + width, y + height - r);
    ctx.quadraticCurveTo(x + width, y + height, x + width - r, y + height);
    ctx.lineTo(x + r, y + height);
    ctx.quadraticCurveTo(x, y + height, x, y + height - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
}

export default class GameOverMenu extends Menu {
    constructor(ctx, options = {}) {
        super(ctx);
        this.score = 0;
        this.overlay = null;
        this.scoreOutput = null;
        this.context = null;
        this.retry = null;
        this.compact = options.compact === true;
        this.previousFocus = typeof document === "undefined" ? null : document.activeElement;

        const scale = Math.min(ctx.canvas.width / 1920, ctx.canvas.height / 1080);
        const buttonWidth = 236 * scale;
        const buttonHeight = 58 * scale;
        const centerX = ctx.canvas.width / 2;
        const centerY = ctx.canvas.height / 2;
        // Retained as a canvas-space hit target for the non-DOM fallback.
        super.addButton("Retry", centerX - buttonWidth / 2, centerY + 92 * scale,
            buttonWidth, buttonHeight);

        if (typeof document !== "undefined") this.mountOverlay();
    }

    mountOverlay() {
        document.querySelector(OVERLAY_SELECTOR)?.remove();

        const overlay = document.createElement("section");
        overlay.className = `game-over-overlay${this.compact ? " is-spectating is-replay" : ""}`;
        overlay.dataset.gameOverOverlay = "";
        // Chat remains a live peer control after death, so this cannot be an
        // aria-modal dialog: a modal would tell assistive technology that the
        // still-visible Chat button is unreachable. The strong visual overlay
        // remains, while Retry and Chat stay in the normal keyboard order.
        overlay.setAttribute("role", "region");
        overlay.setAttribute("aria-labelledby", "game_over_title");
        overlay.setAttribute("aria-describedby", "game_over_context");

        const panel = document.createElement("div");
        panel.className = "game-over-panel";

        const heading = document.createElement("h1");
        heading.id = "game_over_title";
        heading.textContent = this.compact ? "Run over" : "Game over";

        const context = document.createElement("p");
        context.id = "game_over_context";
        context.className = "game-over-context";
        context.setAttribute("aria-live", "polite");
        context.textContent = this.compact
            ? "Wreckage replay · 4s"
            : "The run is finished. Your place in this lobby is still here.";

        const scoreRow = document.createElement("div");
        scoreRow.className = "game-over-score";
        const scoreLabel = document.createElement("span");
        scoreLabel.textContent = "Final score";
        const scoreOutput = document.createElement("output");
        scoreOutput.setAttribute("aria-live", "polite");
        scoreOutput.setAttribute("aria-label", "Final score");
        scoreOutput.textContent = "0";
        scoreRow.append(scoreLabel, scoreOutput);

        const retry = document.createElement("button");
        retry.type = "button";
        retry.className = "game-over-action";
        retry.textContent = "Retry";
        retry.hidden = this.compact;
        retry.addEventListener("click", () => window.location.reload());

        const hint = document.createElement("p");
        hint.className = "game-over-hint";
        hint.textContent = this.compact
            ? "The full arena stays live while you watch."
            : "Retry reloads the arena and returns you to this lobby.";

        panel.append(heading, context, scoreRow, retry, hint);
        overlay.append(panel);
        document.body.append(overlay);

        this.overlay = overlay;
        this.scoreOutput = scoreOutput;
        this.context = context;
        this.retry = retry;
        if (this.compact) return;
        const focusRetry = () => retry.focus({ preventScroll: true });
        if (typeof requestAnimationFrame === "function") requestAnimationFrame(focusRetry);
        else focusRetry();
    }

    setScore(score) {
        this.score = Number.isFinite(score) ? score : 0;
        if (this.scoreOutput !== null) this.scoreOutput.textContent = String(this.score);
    }

    setReplay(remainingMs) {
        if (!this.compact || this.context === null || remainingMs <= 0) return;
        const text = `Wreckage replay · ${Math.max(1, Math.ceil(remainingMs / 1000))}s`;
        if (this.context.textContent !== text) this.context.textContent = text;
    }

    finishReplay() {
        if (!this.compact || this.overlay === null || !this.overlay.classList.contains("is-replay")) return;
        this.overlay.classList.remove("is-replay");
        if (this.context !== null) this.context.textContent = "Watching the arena. Retry when ready.";
        if (this.retry !== null) this.retry.hidden = false;
    }

    drawCanvasFallback() {
        const { ctx } = this;
        const { width, height } = ctx.canvas;
        const scale = Math.min(width / 1920, height / 1080);
        const panelWidth = 620 * scale;
        const panelHeight = 390 * scale;
        const panelX = (width - panelWidth) / 2;
        const panelY = (height - panelHeight) / 2;
        const button = this.buttonArray[0];

        ctx.save();
        ctx.fillStyle = "rgba(8, 11, 16, 0.74)";
        ctx.fillRect(0, 0, width, height);

        roundedRect(ctx, panelX, panelY, panelWidth, panelHeight, 18 * scale);
        ctx.fillStyle = "#11151d";
        ctx.fill();
        ctx.fillStyle = "#eb5147";
        ctx.fillRect(panelX, panelY, panelWidth, 4 * scale);

        ctx.textAlign = "left";
        ctx.textBaseline = "alphabetic";
        ctx.fillStyle = "#f5efe6";
        ctx.font = `800 ${54 * scale}px "Segoe UI", Arial, sans-serif`;
        ctx.fillText("Game over", panelX + 52 * scale, panelY + 92 * scale);

        ctx.fillStyle = "#b9b3aa";
        ctx.font = `600 ${18 * scale}px "Segoe UI", Arial, sans-serif`;
        ctx.fillText("FINAL SCORE", panelX + 52 * scale, panelY + 166 * scale);
        ctx.fillStyle = "#54d88c";
        ctx.font = `800 ${40 * scale}px "Segoe UI", Arial, sans-serif`;
        ctx.fillText(String(this.score), panelX + panelWidth - 120 * scale, panelY + 170 * scale);

        roundedRect(ctx, button.x, button.y, button.width, button.height, 9 * scale);
        ctx.fillStyle = "#d84238";
        ctx.fill();
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillStyle = "#ffffff";
        ctx.font = `800 ${18 * scale}px "Segoe UI", Arial, sans-serif`;
        ctx.fillText(button.text, button.x + button.width / 2, button.y + button.height / 2);
        ctx.restore();
    }

    draw() {
        if (this.overlay === null) this.drawCanvasFallback();
    }

    destroy() {
        this.overlay?.remove();
        this.overlay = null;
        this.scoreOutput = null;
        this.context = null;
        this.retry = null;
        if (typeof HTMLElement !== "undefined" && this.previousFocus instanceof HTMLElement) {
            this.previousFocus.focus({ preventScroll: true });
        }
    }
}
