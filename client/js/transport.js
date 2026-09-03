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
    const boostPacket = [Uint8Array.of(4, 0), Uint8Array.of(4, 1)];
    const steerPacket = new Uint8Array(3);
    steerPacket[0] = 6;

    class SnekSocket {
        constructor() {
            this.id = '';
            this.listeners = new Map();
            // `init` is the join acknowledgement that unlocks the whole game
            // UI. Module scripts can finish loading after a fast server reply,
            // so keep the current acknowledgement available for each listener
            // that attaches late instead of silently dropping it.
            this.hasInit = false;
            this.lastInit = undefined;
            this.hasRoster = false;
            this.lastRoster = undefined;
            this.pendingJoin = null;
            this.retryMs = 250;
            this.connect();
        }
        on(name, handler) {
            let handlers = this.listeners.get(name);
            if (handlers === undefined) this.listeners.set(name, handlers = []);
            handlers.push(handler);
            if (name === 'init' && this.hasInit) handler(this.lastInit);
            else if (name === 'r' && this.hasRoster) handler(this.lastRoster);
            return this;
        }
        reconnect() {
            const ws = this.ws;
            if (ws === undefined || ws.readyState === WebSocket.CLOSED) {
                this.connect();
                return;
            }
            if (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
                try { ws.close(); } catch (_) { this.connect(); }
            }
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
                if (event[0] === 'init') {
                    this.hasInit = true;
                    this.lastInit = event[1];
                } else if (event[0] === 'r') {
                    this.hasRoster = true;
                    this.lastRoster = event[1];
                } else if (event[0] === 'game_error') {
                    this.hasInit = false;
                    this.lastInit = undefined;
                    this.hasRoster = false;
                    this.lastRoster = undefined;
                }
                this.dispatch(event[0], event[1]);
            };
            ws.onclose = () => {
                if (this.ws !== ws) return;
                this.id = '';
                this.hasInit = false;
                this.lastInit = undefined;
                this.hasRoster = false;
                this.lastRoster = undefined;
                this.dispatch('disconnect', 'transport close');
                const delay = this.retryMs;
                this.retryMs = Math.min(5000, this.retryMs * 2);
                setTimeout(() => this.connect(), delay);
            };
        }
        emit(name, first, second, third, fourth) {
            if (name === 'keyPress') {
                const code = directionCode[first];
                // Stale direction input is worse than dropped input: after a
                // reconnect it could be applied before the player rejoins.
                if (code !== undefined && this.ws.readyState === WebSocket.OPEN) {
                    this.ws.send(directionPacket[code]);
                    return true;
                }
                return false;
            }
            if (name === 'boost') {
                if (this.ws.readyState !== WebSocket.OPEN) return false;
                this.ws.send(boostPacket[first === true ? 1 : 0]);
                return true;
            }
            if (name === 'steer') {
                if (this.ws.readyState !== WebSocket.OPEN || !Number.isFinite(first)) return false;
                const angle = Math.max(0, Math.min(65535, Math.round(first)));
                steerPacket[1] = angle & 0xff;
                steerPacket[2] = angle >>> 8;
                this.ws.send(steerPacket);
                return true;
            }
            if (name === 'chat') {
                const message = String(first == null ? '' : first).trim();
                if (message.length === 0 || Array.from(message).length > 96) return false;
                const bytes = encoder.encode(message);
                if (bytes.length === 0 || bytes.length > 160 || this.ws.readyState !== WebSocket.OPEN) return false;
                const packet = new Uint8Array(1 + bytes.length);
                packet[0] = 5;
                packet.set(bytes, 1);
                this.ws.send(packet);
                return true;
            }
            if (name !== 'clientReady') return false;
            // A new join/retry needs its own authoritative acknowledgement;
            // never replay the preceding life/session to a listener that loads
            // while the request is in flight.
            this.hasInit = false;
            this.lastInit = undefined;
            this.hasRoster = false;
            this.lastRoster = undefined;
            const username = encoder.encode(String(first));
            const lobby = encoder.encode(String(second));
            // Passwords are opaque user input. Preserve whitespace and other
            // characters exactly; only the protocol's UTF-8 byte bound applies.
            const password = encoder.encode(third == null ? '' : String(third));
            // The optional appearance byte extends the original packet without
            // changing it for older markup or benchmark clients.
            const hasStyle = Number.isInteger(fourth) && fourth >= 0 && fourth < 6;
            if (username.length === 0 || username.length > 255 ||
                lobby.length === 0 || lobby.length > 255 || password.length > 64) return false;
            const packet = new Uint8Array(4 + lobby.length + username.length + password.length + (hasStyle ? 1 : 0));
            packet[0] = 1;
            packet[1] = lobby.length;
            packet[2] = username.length;
            packet[3] = password.length;
            packet.set(lobby, 4);
            packet.set(username, 4 + lobby.length);
            packet.set(password, 4 + lobby.length + username.length);
            if (hasStyle) packet[packet.length - 1] = fourth;
            if (this.ws.readyState === WebSocket.OPEN) {
                this.pendingJoin = null;
                this.ws.send(packet);
            } else {
                // Only the most recent identity is relevant while connecting.
                this.pendingJoin = packet;
            }
            return true;
        }
    }

    const socket = window.socket = new SnekSocket();
    document.addEventListener('visibilitychange', () => {
        const ws = socket.ws;
        if (ws.readyState === WebSocket.OPEN) ws.send(visibilityPacket[document.hidden ? 0 : 1]);
    });
})();
