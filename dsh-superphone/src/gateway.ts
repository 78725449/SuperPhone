import type { IncomingMessage, ServerResponse } from 'node:http'
import http from 'node:http'
import https from 'node:https'
import type { Config } from './config.js'
import type { ActivityLog } from './activity.js'

/**
 * 网关访问层（host 侧）。
 *
 * 两件事：
 * 1. `request()` — 工具直接调用网关 REST（Node 侧，无跨域问题）。
 * 2. `registerProxy()` — 把网关数据以 **DSH 同源路径** `/superphone/*` 暴露给浏览器面板，
 *    避免浏览器跨域（网关不带 CORS 头）与自签证书问题：面板只 fetch 同源地址。
 *
 * ★ 协议自适应（2026-09-18）：网关【设计上默认启用 TLS】（trollvnc-farm 的 FARM_TLS !== '0'
 *   → https + 自签证书），但也允许 FARM_TLS=0 以纯 HTTP 运行。两种模式下插件都应可用。
 *   原先这里用全局 fetch 直连 config.gateway，有两个问题：
 *     ① 默认值写死 http://，网关以 https 启动时请求被 301 到 https，而全局 fetch 不信任自签证书 → 502；
 *     ② 即使配置改成 https://，全局 fetch 依然不信任自签证书 → 仍 502。
 *   改为用 node:http / node:https 直连（无第三方依赖）：https 时 rejectUnauthorized=false
 *   （内网自签边界，与 App 侧 TVNCGatewayClient 的 serverTrust 信任一致），
 *   并在协议错配时自动切换另一种协议重试一次。
 */

/** 网关响应（统一形态）。 */
interface RawResponse {
  status: number
  body: string
  contentType: string
}

/** 拼接网关 URL（去掉尾部斜杠）。 */
export function gatewayUrl(config: Config, path: string): string {
  return `${config.gateway.replace(/\/+$/, '')}${path}`
}

/** 同一网关地址换用另一种协议（http ↔ https）。 */
function otherScheme(urlStr: string): string | null {
  try {
    const u = new URL(urlStr)
    u.protocol = u.protocol === 'https:' ? 'http:' : 'https:'
    return u.toString()
  } catch {
    return null
  }
}

/**
 * 裸请求：支持 http/https，https 时信任网关自签证书。
 * 用 node:http(s) 而非全局 fetch —— 后者无法按请求关闭证书校验（内置 undici 不可直接 import）。
 */
function rawRequest(
  urlStr: string,
  method: string,
  headers: Record<string, string>,
  body: string | undefined,
  timeoutMs: number,
): Promise<RawResponse> {
  return new Promise((resolve, reject) => {
    let u: URL
    try {
      u = new URL(urlStr)
    } catch {
      reject(new Error(`网关地址非法: ${urlStr}`))
      return
    }
    const isTLS = u.protocol === 'https:'
    const mod = isTLS ? https : http
    const req = mod.request(
      u,
      {
        method,
        headers,
        timeout: timeoutMs,
        ...(isTLS ? { rejectUnauthorized: false } : {}), // 内网自签证书：与 App 侧信任语义一致
      },
      (res) => {
        const chunks: Buffer[] = []
        res.on('data', (c: Buffer) => chunks.push(c))
        res.on('end', () =>
          resolve({
            status: res.statusCode ?? 0,
            body: Buffer.concat(chunks).toString('utf8'),
            contentType: String(res.headers['content-type'] ?? 'application/json; charset=utf-8'),
          }),
        )
      },
    )
    req.on('timeout', () => req.destroy(new Error(`网关请求超时（${timeoutMs}ms）`)))
    req.on('error', reject)
    if (body !== undefined) req.write(body)
    req.end()
  })
}

/**
 * 协议错配判定：对端不是当前协议的服务时，应换另一种协议重试，而不是当成"网关不可达"。
 * 覆盖两种方向：① 对明文端口发 TLS（EPROTO / socket hang up / ECONNRESET）；
 * ② 对 TLS 端口发明文（网关会 301 到 https）。
 */
function isProtocolMismatchError(err: unknown): boolean {
  const code = (err as NodeJS.ErrnoException)?.code ?? ''
  const msg = err instanceof Error ? err.message : String(err)
  return (
    code === 'EPROTO' ||
    code === 'ECONNRESET' ||
    code === 'ERR_SSL_WRONG_VERSION_NUMBER' ||
    /EPROTO|wrong version number|socket hang up|SSL routines/i.test(msg)
  )
}

/**
 * 带协议自适应的请求：先用配置的协议；协议错配（含 301 重定向）则换另一种重试一次。
 * 只重试一次（http↔https 各一次），不会反复。
 */
async function requestAdaptive(
  config: Config,
  path: string,
  method: string,
  headers: Record<string, string>,
  body: string | undefined,
  timeoutMs: number,
): Promise<RawResponse> {
  const primary = gatewayUrl(config, path)
  try {
    const res = await rawRequest(primary, method, headers, body, timeoutMs)
    // http 打到 https 网关 → 网关 301；此时用 https 重试
    if (res.status === 301 || res.status === 308) {
      const alt = otherScheme(primary)
      if (alt) return await rawRequest(alt, method, headers, body, timeoutMs)
    }
    return res
  } catch (err) {
    if (!isProtocolMismatchError(err)) throw err
    const alt = otherScheme(primary)
    if (!alt) throw err
    return await rawRequest(alt, method, headers, body, timeoutMs)
  }
}

function authHeaders(config: Config): Record<string, string> {
  return config.token ? { Authorization: `Bearer ${config.token}` } : {}
}

export interface GatewayResponse {
  status: number
  body: string
  /** 后端声明的 JSON 内容类型（默认 application/json）。 */
  contentType: string
}

/** 请求网关（GET）；网络/超时错误以 502 返回，而不是抛给调用方。 */
export async function request(config: Config, path: string, timeoutMs = 15000): Promise<GatewayResponse> {
  try {
    return await requestAdaptive(config, path, 'GET', { ...authHeaders(config) }, undefined, timeoutMs)
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    return {
      status: 502,
      body: JSON.stringify({ error: 'gateway unreachable', detail: message, gateway: config.gateway }),
      contentType: 'application/json; charset=utf-8',
    }
  }
}

/** POST JSON 到网关（动作类调用），返回解析后的响应体。
 *  注：执行日志记在**工具层**（tools.ts 的 withActivity），不在这里——按工具记才能覆盖取帧类
 *  调用，同时不会把面板自己的缩略图/设备轮询（同源代理）混进 AI 步骤流水。 */
export async function post(config: Config, path: string, body?: unknown, timeoutMs = 20000): Promise<any> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (config.token) headers.Authorization = `Bearer ${config.token}`
  try {
    const payload = JSON.stringify(body ?? {})
    headers['Content-Length'] = String(Buffer.byteLength(payload))
    const res = await requestAdaptive(config, path, 'POST', headers, payload, timeoutMs)
    let parsed: any
    try {
      parsed = JSON.parse(res.body)
    } catch {
      parsed = { ok: res.status < 400, raw: res.body.slice(0, 500) }
    }
    return parsed
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

/** 面板可用的子路径 → 网关 REST 路径映射。 */
function mapToGatewayPath(sub: string): string | null {
  if (sub === '/devices') return '/api/devices'
  const thumb = /^\/thumb\/([^/]+)$/.exec(sub)
  if (thumb) return `/api/devices/${encodeURIComponent(decodeURIComponent(thumb[1]))}/thumb`
  return null
}

/**
 * 注册面板的同源数据代理（`ctx.webServer.register` 的 handler）。
 * 路由：GET /superphone/devices · /superphone/thumb/:id · /superphone/config · /superphone/log
 */
export function createProxyHandler(config: Config, log: ActivityLog) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const url = new URL(req.url ?? '/', 'http://localhost')
    const sub = url.pathname.replace(/^\/superphone/, '') || '/'

    const send = (status: number, body: string, contentType = 'application/json; charset=utf-8'): void => {
      res.writeHead(status, { 'Content-Type': contentType, 'Cache-Control': 'no-store' })
      res.end(body)
    }

    // POST：面板动作（目前只有「断开」= 踢掉外部控制端），与网关同一套语义。
    if (req.method === 'POST') {
      const disconnect = /^\/disconnect\/([^/]+)$/.exec(sub)
      if (!disconnect) {
        send(404, JSON.stringify({ error: `unknown superphone action: ${sub}` }))
        return
      }
      const result = await post(config, `/api/devices/${encodeURIComponent(decodeURIComponent(disconnect[1]))}/disconnect`, {})
      send(result?.ok === false ? 502 : 200, JSON.stringify(result))
      return
    }

    if (sub === '/config') {
      // 面板需要网关地址来拼「大屏」iframe URL（iframe 直连网关，不经同源代理）。
      send(200, JSON.stringify({ gateway: config.gateway, hasToken: config.token !== '', thumbPollMs: config.thumbPollMs }))
      return
    }

    if (sub === '/log') {
      // 执行日志 + AI 活跃标记（面板据此显示「AI 控制中」与步骤流水）。
      send(200, JSON.stringify(log.snapshot()))
      return
    }

    const gatewayPath = mapToGatewayPath(sub)
    if (!gatewayPath) {
      send(404, JSON.stringify({ error: `unknown superphone path: ${sub}` }))
      return
    }

    const result = await request(config, gatewayPath)
    send(result.status, result.body, result.contentType)
  }
}
