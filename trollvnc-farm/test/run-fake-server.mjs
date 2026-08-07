// 独立运行的假 RFB 服务端（供联调/测试），端口默认 15901
import { FakeVncServer } from './fake-rfb-server.js';
const port = parseInt(process.env.FAKE_VNC_PORT || '15901', 10);
const srv = new FakeVncServer({ port, mode: 'rfb' });
srv.onConnection = (conn) => {
  conn.sock.on('data', (buf) => {
    if (conn.state === 'ready') {
      // 打印 ready 后收到的客户端消息（操作注入验证）
      console.log('[fake-vnc] ready-data ' + buf.toString('hex'));
    }
  });
};
await srv.start();
console.log('[fake-vnc] listening on ' + port);
setInterval(() => {}, 1000);
