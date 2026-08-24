'use strict';

// Node counterpart of client/js/transport.js for parity and load tests.
const WebSocket = require('ws');
const directionCode = { ArrowUp: 0, ArrowDown: 1, ArrowLeft: 2, ArrowRight: 3 };

class RawSocket {
  constructor(base, options) {
    this.base = base;
    this.options = options || {};
    this.id = '';
    this.handlers = new Map();
    this.pending = [];
    this.closed = false;
    this.retryMs = 250;
    this.connect();
  }
  on(name, handler) {
    let list = this.handlers.get(name);
    if (!list) this.handlers.set(name, list = []);
    list.push(handler);
    return this;
  }
  once(name, handler) {
    const wrapped = (...args) => { this.off(name, wrapped); handler(...args); };
    return this.on(name, wrapped);
  }
  off(name, handler) {
    const list = this.handlers.get(name);
    if (!list) return this;
    const index = list.indexOf(handler);
    if (index >= 0) list.splice(index, 1);
    return this;
  }
  dispatch(name, ...args) {
    const list = this.handlers.get(name);
    if (list) for (const handler of list.slice()) handler(...args);
  }
  connect() {
    const url = new URL(this.base);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    url.pathname = '/ws';
    url.search = '';
    const ws = this.ws = new WebSocket(url);
    ws.binaryType = 'arraybuffer';
    ws.on('open', () => {
      this.retryMs = 250;
      for (const packet of this.pending) ws.send(packet);
      this.pending.length = 0;
      this.dispatch('connect');
    });
    ws.on('message', (data, isBinary) => {
      const bytes = Buffer.isBuffer(data) ? data : null;
      if (isBinary === true || data instanceof ArrayBuffer || (bytes && bytes.length >= 2 && bytes[0] === 0x53 && bytes[1] === 0x4e)) {
        return this.dispatch('b', data);
      }
      let event;
      try { event = JSON.parse(data.toString()); } catch (_) { return; }
      if (!Array.isArray(event) || typeof event[0] !== 'string') return;
      if (event[0] === 'id' && typeof event[1] === 'string') this.id = event[1];
      this.dispatch(event[0], event[1]);
    });
    ws.on('error', (error) => this.dispatch('connect_error', error));
    ws.on('close', () => {
      this.dispatch('disconnect', 'transport close');
      if (this.closed || this.options.reconnection === false) return;
      const delay = this.retryMs;
      this.retryMs = Math.min(5000, delay * 2);
      setTimeout(() => this.connect(), delay);
    });
  }
  send(packet) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(packet);
    else if (this.pending.length < 8) this.pending.push(packet);
  }
  emit(name, first, second) {
    if (name === 'keyPress') {
      const code = directionCode[first];
      if (code !== undefined) this.send(Buffer.from([2, code]));
      return this;
    }
    if (name !== 'clientReady') return this;
    const username = Buffer.from(String(first));
    const lobby = Buffer.from(String(second));
    if (!username.length || username.length > 255 || !lobby.length || lobby.length > 255) return this;
    this.send(Buffer.concat([Buffer.from([1, lobby.length, username.length]), lobby, username]));
    return this;
  }
  close() {
    this.closed = true;
    if (this.ws) this.ws.close();
  }
}

module.exports = (base, options) => new RawSocket(base, options);
