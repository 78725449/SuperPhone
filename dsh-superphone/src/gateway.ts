import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Config } from './config.js'
import type { ActivityLog } from './activity.js'

/**
 * 网关访问层（host 侧）。
 *
 * 两件事：
 * 1. `request()` — 工具直接调用网关 REST（Node 侧，无跨域问题）。
 * 2. `registerProxy()` — 把网关数据以 **DSH 同源路径** `/superphone/*` 暴露给浏览器面板，
 *    避免浏览器跨域（网关不带 CORS 头）与自签证书问题：面板只 fetch 同源地址。
 */

/** 拼接网关 URL（去掉尾部斜杠）。 */
export function gatewayUrl(config: Config, path: string): string {
  return `${config.gateway.replace(/\/+$/, '')}${path}`
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
    const res = await fetch(gatewayUrl(config, path), {
      headers: { ...authHeaders(config) },
      signal: AbortSignal.timeout(timeoutMs),
    })
    return {
      status: res.status,
      body: await res.text(),
      contentType: res.headers.get('content-type') ?? 'application/json; charset=utf-8',
    }
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
  const startedAt = Date.now()
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (config.token) headers.Authorization = `Bearer ${config.token}`
  try {
    const res = await fetch(gatewayUrl(config, path), {
      method: 'POST',
      headers,
      body: JSON.stringify(body ?? {}),
      signal: AbortSignal.timeout(timeoutMs),
    })
    const text = await res.text()
    let parsed: any
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = { ok: res.ok, raw: text.slice(0, 500) }
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
