# Node reference server

The canonical SnakeMP behavior uses Express and Socket.IO v2. `app.js` owns
HTTP and lifecycle wiring; `src/` contains the game model, validation, world
geometry, IDs, and constants. Static assets are served from the repository's
shared `client/` tree.

```bash
PORT=3000 SNEK_DEBUG=1 node servers/node/app.js
```
