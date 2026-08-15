#!/usr/bin/env node
/*
 * gen-cert.mjs — 为 superphone-farm 网关自动生成自签 TLS 证书
 *
 * 功能：
 *   1. 探测 openssl（Windows: where.exe + Git/OpenSSL 常见安装路径；其他平台: PATH）
 *   2. 收集本机全部 IPv4，构造 SAN（DNS:localhost + IP:各网卡地址）
 *   3. 生成 RSA2048 自签证书（3650 天），输出到 data/cert/cert.pem + key.pem
 *
 * 参数：
 *   FARM_DATA_DIR  数据目录（默认 trollvnc-farm/data），证书写入其下 cert/
 *   FARM_CERT_DIR  覆盖证书输出目录
 *
 * 返回值：
 *   0 成功（含证书已存在）；1 失败（openssl 不可用或生成出错）
 */
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const CERT_DIR = process.env.FARM_CERT_DIR
  || path.join(process.env.FARM_DATA_DIR || path.join(ROOT, 'data'), 'cert');

/**
 * 探测可用的 openssl 可执行文件路径。
 * @returns {string|null} openssl 路径；找不到返回 null
 */
function findOpenSSL() {
  const candidates = [];
  if (process.platform === 'win32') {
    for (const probe of ['where.exe openssl', 'where openssl']) {
      const [cmd, ...args] = probe.split(' ');
      const r = spawnSync(cmd, args, { encoding: 'utf8', shell: true });
      if (r.status === 0 && r.stdout.trim()) {
        candidates.push(...r.stdout.trim().split(/\r?\n/).filter(Boolean));
      }
    }
    // Git for Windows / OpenSSL 常见安装路径
    candidates.push(
      'C:\\Program Files\\Git\\usr\\bin\\openssl.exe',
      'C:\\Program Files (x86)\\Git\\usr\\bin\\openssl.exe',
      'C:\\Program Files\\OpenSSL-Win64\\bin\\openssl.exe',
      'C:\\Program Files\\OpenSSL\\bin\\openssl.exe'
    );
  }
  candidates.push('openssl');
  for (const c of candidates) {
    if (!c) continue;
    const r = spawnSync(c, ['version'], { encoding: 'utf8' });
    if (r.status === 0 && r.stdout) return c;
  }
  return null;
}

/**
 * 收集本机全部非内部 IPv4 地址（用于证书 SAN，保证任意内网 IP 访问不报域名不匹配）。
 * @returns {string[]} IPv4 地址数组（含回环 127.0.0.1）
 */
function collectIPv4() {
  const ips = ['127.0.0.1'];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const iface of list || []) {
      if (iface.family === 'IPv4' && !iface.internal && !ips.includes(iface.address)) {
        ips.push(iface.address);
      }
    }
  }
  return ips;
}

/**
 * 主流程：证书缺失则自动生成；已存在则跳过。
 * @returns {number} 进程退出码（0 成功 / 1 失败）
 */
function main() {
  fs.mkdirSync(CERT_DIR, { recursive: true });
  const keyFile = path.join(CERT_DIR, 'key.pem');
  const certFile = path.join(CERT_DIR, 'cert.pem');
  if (fs.existsSync(keyFile) && fs.existsSync(certFile)) {
    console.log(`[tls] cert already exists: ${CERT_DIR}`);
    return 0;
  }
  const openssl = findOpenSSL();
  if (!openssl) {
    console.error('[tls] openssl not found — cannot auto-generate cert.');
    console.error('[tls] install OpenSSL (Git for Windows includes it) or generate manually:');
    console.error(`[tls]   openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "${keyFile}" -out "${certFile}" -subj "/CN=SuperPhone-Farm" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`);
    return 1;
  }
  const ips = collectIPv4();
  const san = ['DNS:localhost', ...ips.map((ip) => `IP:${ip}`)].join(',');
  const args = [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650',
    '-keyout', keyFile, '-out', certFile,
    '-subj', '/CN=SuperPhone-Farm',
    '-addext', `subjectAltName=${san}`,
  ];
  console.log(`[tls] generating self-signed cert via ${openssl} …`);
  console.log(`[tls] SAN: ${san}`);
  const r = spawnSync(openssl, args, { encoding: 'utf8' });
  if (r.status !== 0) {
    console.error(`[tls] openssl failed (code ${r.status}): ${r.stderr || r.stdout || 'no output'}`);
    // 清理半成品，避免下次启动误用损坏证书
    try { fs.unlinkSync(keyFile); } catch (_) { /* noop */ }
    try { fs.unlinkSync(certFile); } catch (_) { /* noop */ }
    return 1;
  }
  console.log(`[tls] cert written: ${certFile}`);
  return 0;
}

process.exit(main());
