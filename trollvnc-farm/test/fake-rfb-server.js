// 最小 RFB(VNC) 假服务端：用于本地联调网关桥接
// 支持两种模式：echo（原样回显，测试字节管道） / rfb（完成 RFB 3.8 无认证握手）
import net from 'node:net';

export class FakeVncServer {
  constructor({ port = 15901, mode = 'echo' } = {}) {
    this.port = port;
    this.mode = mode;
    this.connections = new Set(); // { sock, received: Buffer[] }
    this.server = null;
  }
  start() {
    return new Promise((resolve, reject) => {
      this.server = net.createServer((sock) => {
        const conn = { sock, received: [], closed: false, state: null };
        this.connections.add(conn);
        if (this.mode === 'rfb') {
          // RFB 协议：服务端先发版本串
          conn.state = 'wait-client-version';
          sock.write(Buffer.from('RFB 003.008\n'));
        } else {
          conn.state = 'echo';
        }
        sock.on('data', (buf) => {
          conn.received.push(Buffer.from(buf));
          if (this.mode === 'echo') {
            sock.write(buf); // 原样回显，方便测试
          } else {
            this._handleRfb(conn, buf);
          }
        });
        sock.on('close', () => { conn.closed = true; this.connections.delete(conn); });
        sock.on('error', () => {});
        this.onConnection?.(conn);
      });
      this.server.listen(this.port, '127.0.0.1', () => resolve());
      this.server.on('error', reject);
    });
  }
  _handleRfb(conn, buf) {
    // 维护跨数据段缓冲：一个 TCP 段可能合并多个 RFB 消息
    conn.rx = conn.rx ? Buffer.concat([conn.rx, buf]) : Buffer.from(buf);
    let progressed = true;
    while (progressed && conn.rx.length > 0) {
      progressed = false;
      const st = conn.state;
      if (st === 'wait-client-version') {
        if (conn.rx.length >= 12) {
          conn.state = 'wait-sec-choice';
          conn.sock.write(Buffer.from([1, 1])); // 1 种安全类型：None
          conn.rx = conn.rx.subarray(12);
          progressed = true;
        }
      } else if (st === 'wait-sec-choice') {
        if (conn.rx.length >= 1) {
          conn.state = 'wait-shared';
          conn.sock.write(Buffer.from([0, 0, 0, 0])); // security result OK
          conn.rx = conn.rx.subarray(1);
          progressed = true;
        }
      } else if (st === 'wait-shared') {
        if (conn.rx.length >= 1) {
          conn.state = 'ready';
          // 标准 ServerInit：width(2) height(2) PIXEL_FORMAT(16) nameLen(4) name
          const name = Buffer.from('FakeVNC');
          const init = Buffer.alloc(2 + 2 + 16 + 4 + name.length);
          init.writeUInt16BE(1170, 0);   // 真实手机分辨率（测试约定）
          init.writeUInt16BE(2532, 2);
          init[4] = 32;   // bpp
          init[5] = 24;   // depth
          init[6] = 0;    // bigEndian
          init[7] = 1;    // trueColor
          init.writeUInt16BE(255, 8);   // redMax
          init.writeUInt16BE(255, 10);  // greenMax
          init.writeUInt16BE(255, 12);  // blueMax
          init[14] = 16;  // redShift
          init[15] = 8;   // greenShift
          init[16] = 0;   // blueShift
          // 17..19 padding
          init.writeUInt32BE(name.length, 20);
          name.copy(init, 24);
          conn.sock.write(init);
          conn.rx = conn.rx.subarray(1);
          progressed = true;
        }
      } else if (st === 'ready') {
        // 简单解析客户端消息并记录
        const type = conn.rx[0];
        let msgLen = 1;
        if (type === 0) { msgLen = 20; }            // SetPixelFormat
        else if (type === 2) {                      // SetEncodings
          msgLen = 4 + conn.rx.readUInt16BE(2) * 4;
        } else if (type === 3) { msgLen = 10; }     // FramebufferUpdateRequest
        if (conn.rx.length < msgLen) break;
        conn.received.push(Buffer.from(conn.rx.subarray(0, msgLen)));
        if (type === 3) {
          // 回一帧黑色 raw（bpp=32 -> 每像素 4 字节）
          const rectDataLen = 1170 * 2532 * 4;
          const rect = Buffer.alloc(4 + 4 + 4 + rectDataLen);
          rect.writeUInt16BE(0, 0);   // x
          rect.writeUInt16BE(0, 2);   // y
          rect.writeUInt16BE(1170, 4); // w
          rect.writeUInt16BE(2532, 6); // h
          rect.writeUInt32BE(0, 8);   // encoding=Raw
          const upd = Buffer.alloc(4 + rect.length);
          upd.writeUInt8(0, 0);       // type=0 (FramebufferUpdate)
          upd.writeUInt8(0, 1);       // padding
          upd.writeUInt16BE(1, 2);    // numRects
          rect.copy(upd, 4);
          conn.sock.write(upd);
        }
        conn.rx = conn.rx.subarray(msgLen);
        progressed = true;
      }
    }
  }
  sendToAll(buf) {
    for (const c of this.connections) {
      if (!c.closed) c.sock.write(buf);
    }
  }
  allReceived(conn) {
    return conn ? Buffer.concat(conn.received) : null;
  }
  stop() {
    return new Promise((resolve) => {
      for (const c of this.connections) c.sock.destroy();
      if (this.server) this.server.close(() => resolve());
      else resolve();
    });
  }
}
