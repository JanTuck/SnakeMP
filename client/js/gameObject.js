export default class GameObject {
    constructor(ctx, scale = 16) {
        this.ctx = ctx;
        this.scale = scale;
    }
    draw(x, y, color){
        this.ctx.fillStyle = color;
        this.ctx.fillRect( x, y, this.scale, this.scale);
    }
}
