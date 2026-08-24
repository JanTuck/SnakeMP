// Minimal native WebSocket transport. Hot inputs are fixed binary packets;
// infrequent server control messages are compact JSON arrays.
(function () {
    const encoder = new TextEncoder();
    const directionCode = { ArrowUp: 0, ArrowDown: 1, ArrowLeft: 2, ArrowRight: 3 };
    // These packets are immutable after construction. Reusing them avoids a
    // short-lived allocation for every key press; WebSocket.send snapshots the
    // supplied bytes before returning.
    const directionPacket = [
        Uint8Array.of(2, 0),
        Uint8Array.of(2, 1),
        Uint8Array.of(2, 2),
        Uint8Array.of(2, 3)
    ];
    const visibilityPacket = [Uint8Array.of(3, 0), Uint8Array.of(3, 1)];

    class SnekSocket {
        constructor() {
            this.id = '';
            this.listeners = new Map();
            this.pendingJoin = null;
            this.retryMs = 250;
            this.connect();
        }
        on(name, handler) {
            let handlers = this.listeners.get(name);
            if (handlers === undefined) this.listeners.set(name, handlers = []);
            handlers.push(handler);
            return this;
        }
        dispatch(name, value) {
            const handlers = this.listeners.get(name);
            if (handlers !== undefined) {
                // Listener registration is append-only, so a defensive slice
                // only allocated garbage on every 15 Hz binary snapshot.
                const length = handlers.length;
                for (let index = 0; index < length; index++) handlers[index](value);
            }
        }
        connect() {
            const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
            const ws = this.ws = new WebSocket(scheme + '//' + location.host + '/ws');
            ws.binaryType = 'arraybuffer';
            ws.onopen = () => {
                if (this.ws !== ws) return;
                this.retryMs = 250;
                // Reassert visibility after every reconnect. A hidden tab gets
                // 1 Hz keyframes while simulation remains authoritative; a
                // newly visible tab is independently resynchronized.
                ws.send(visibilityPacket[document.hidden ? 0 : 1]);
                // Notify first. The page's reconnect handler may send the join
                // immediately, in which case emit() clears the queued copy and
                // prevents a duplicate join on a fast initial connection.
                this.dispatch('connect');
                if (this.pendingJoin !== null) {
                    ws.send(this.pendingJoin);
                    this.pendingJoin = null;
                }
            };
            ws.onmessage = (message) => {
                if (this.ws !== ws) return;
                if (typeof message.data !== 'string') {
                    this.dispatch('b', message.data);
                    return;
                }
                let event;
                try { event = JSON.parse(message.data); } catch (_) { return; }
                if (!Array.isArray(event) || typeof event[0] !== 'string') return;
                if (event[0] === 'id' && typeof event[1] === 'string') this.id = event[1];
                this.dispatch(event[0], event[1]);
            };
            ws.onclose = () => {
                if (this.ws !== ws) return;
                this.id = '';
                this.dispatch('disconnect', 'transport close');
                const delay = this.retryMs;
                this.retryMs = Math.min(5000, this.retryMs * 2);
                setTimeout(() => this.connect(), delay);
            };
        }
        emit(name, first, second) {
            if (name === 'keyPress') {
                const code = directionCode[first];
                // Stale direction input is worse than dropped input: after a
                // reconnect it could be applied before the player rejoins.
                if (code !== undefined && this.ws.readyState === WebSocket.OPEN) {
                    this.ws.send(directionPacket[code]);
                }
                return;
            }
            if (name !== 'clientReady') return;
            const username = encoder.encode(String(first));
            const lobby = encoder.encode(String(second));
            if (username.length === 0 || username.length > 255 || lobby.length === 0 || lobby.length > 255) return;
            const packet = new Uint8Array(3 + lobby.length + username.length);
            packet[0] = 1;
            packet[1] = lobby.length;
            packet[2] = username.length;
            packet.set(lobby, 3);
            packet.set(username, 3 + lobby.length);
            if (this.ws.readyState === WebSocket.OPEN) {
                this.pendingJoin = null;
                this.ws.send(packet);
            } else {
                // Only the most recent identity is relevant while connecting.
                this.pendingJoin = packet;
            }
        }
    }

    const socket = window.socket = new SnekSocket();
    document.addEventListener('visibilitychange', () => {
        const ws = socket.ws;
        if (ws.readyState === WebSocket.OPEN) ws.send(visibilityPacket[document.hidden ? 0 : 1]);
    });
})();
