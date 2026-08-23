import Menu from "./menu.js";

export default class GameOverMenu extends Menu{
    constructor(ctx){
        super(ctx);
        this.ctx = ctx;
        super.addText("Game Over", this.ctx.canvas.width/2, 300, 64);
        // A single actionable button: the previous pair overlapped exactly
        // and had no click handling at all.
        super.addButton("Retry", this.ctx.canvas.width/2-60, 430, 120, 32);
    }
    setScore(score){
        super.addText(`Score: ${score}`, this.ctx.canvas.width/2, 380, 32);
    }
}