import { defineTool, type ToolDefinition } from '@deepseek-ai/dsh-tools'
import type { ActivityLog } from './activity.js'
import type { Config } from './config.js'
import { post, request } from './gateway.js'

/**
 * dsh-superphone 模型可见工具（全部经网关 REST，Node 侧无跨域）。
 *
 * 两条纪律：
 * - 会改动设备的工具在执行前检查网关 `controlled`：人工正在控制时返回 blocked，让 AI 让路。
 * - 返回值必须**无损 JSON**：可选字段一律 `?? null`（`undefined` 会在 JSON 往返时丢字段，
 *   触发 harness 的 "value is not lossless JSON" 校验失败）。
 *
 * 每次工具调用都写入执行日志（面板的 AI 步骤流水 + 「AI 控制中」判定都基于它）——
 * 记在**工具层**而非 HTTP 层：取帧类工具（screenshot）也要算作 AI 的一步，
 * 而面板自身的缩略图/设备轮询（同源代理，不经工具）绝不入日志。
 */

export interface DeviceSummary {
  id: string
  name: string
  host: string
  port: number
  online: boolean
  controlled: boolean
  controlledSource?: string | null
  lastSeen?: number | null
}

/** 设备目录（网关是唯一来源：设备注册时携带 IP，DHCP 变更后这里总是最新的）。 */
export async function listDevices(config: Config): Promise<DeviceSummary[]> {
  const res = await request(config, '/api/devices')
  if (res.status !== 200) throw new Error(`gateway returned ${res.status}: ${res.body.slice(0, 200)}`)
  const parsed = JSON.parse(res.body) as { devices?: DeviceSummary[] }
  return parsed.devices ?? []
}

/** 人工控制检查：被控中时返回阻止原因。 */
async function humanControlled(config: Config, deviceId: string): Promise<string | undefined> {
  const devices = await listDevices(config)
  const device = devices.find((item) => item.id === deviceId)
  if (!device) return `device ${deviceId} is not registered on the gateway`
  if (device.controlled) {
    return `device ${deviceId} is under human control (${device.controlledSource ?? 'unknown'})`
  }
  return undefined
}

/** 把一次工具执行记进执行日志（成功/失败都记，带耗时）。 */
function withActivity<TArgs, TResult>(
  log: ActivityLog,
  name: string,
  describe: (args: TArgs) => string,
  execute: (args: TArgs) => Promise<TResult>,
): (args: TArgs) => Promise<TResult> {
  return async (args: TArgs) => {
    const startedAt = Date.now()
    try {
      const result = await execute(args)
      log.push({
        ts: startedAt,
        kind: 'call',
        name,
        detail: describe(args),
        ok: (result as { ok?: boolean } | null)?.ok !== false,
        ms: Date.now() - startedAt,
      })
      return result
    } catch (error) {
      log.push({ ts: startedAt, kind: 'call', name, detail: describe(args), ok: false, ms: Date.now() - startedAt })
      throw error
    }
  }
}

/** 设备 id 的短标签（日志里不必打印完整 UUID）。 */
function short(id: string): string {
  return id.slice(0, 8)
}

export function createSuperphoneTools(config: Config, log: ActivityLog): ToolDefinition[] {
  return [
    defineTool({
      name: 'superphone_devices',
      description: 'List SuperPhone devices known to the farm gateway (id, name, host, online, controlled).',
      parameters: {},
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          {
            type: 'text',
            text:
              (value.devices as DeviceSummary[] | undefined)
                ?.map((d) => `${d.online ? '●' : '○'} ${d.name} (${d.id}) ${d.host}:${d.port}${d.controlled ? ' [被控]' : ''}`)
                .join('\n') || 'no devices',
          },
        ],
      },
      execute: withActivity(log, 'superphone_devices', () => '列出设备', async () => {
        return { devices: await listDevices(config) }
      }),
    }),

    defineTool({
      name: 'superphone_screenshot',
      description:
        'Get the device screen as base64 JPEG. By default it takes a LIVE frame on demand (screen.snapshot, board ~320px, tens of ms) — pass cached:true only when a frame up to 2s old is acceptable (gateway poll cache).',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id from superphone_devices.' },
        cached: { type: 'boolean', description: 'Read the gateway thumbnail cache (up to 2s old) instead of a live frame.' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          {
            type: 'text',
            text: value.thumb
              ? `${value.live ? 'live' : 'cached'} frame ${value.thumb.length} chars (base64 JPEG)${value.seq != null ? ` seq=${value.seq}` : ''}`
              : `no frame: ${value.error ?? 'unknown'}`,
          },
        ],
      },
      execute: withActivity(
        log,
        'superphone_screenshot',
        (a: { deviceId: string; cached?: boolean }) => `${a.cached ? '取缓存帧' : '取帧'} ${short(a.deviceId)}`,
        async (args: { deviceId: string; cached?: boolean }) => {
          if (args.cached) {
            const res = await request(config, `/api/devices/${encodeURIComponent(args.deviceId)}/thumb`)
            if (res.status !== 200) {
              return { deviceId: args.deviceId, live: false, thumb: '', seq: null, ok: false, error: `gateway ${res.status}` }
            }
            const parsed = JSON.parse(res.body) as { thumb?: string; ts?: number }
            return { deviceId: args.deviceId, live: false, thumb: parsed.thumb ?? '', seq: null, ts: parsed.ts ?? Date.now(), ok: true, error: null }
          }
          // 实时取帧（感知要准）：设备端 captureSingleFrameBuffer，冷启动几十 ms；顺带返回 seq 供 wait 使用
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, {
            cap: 'screen.snapshot',
            params: {},
            timeout: 20000,
          })
          const jpeg = typeof ack?.ack?.jpeg === 'string' ? ack.ack.jpeg : ''
          return {
            deviceId: args.deviceId,
            live: true,
            thumb: jpeg,
            seq: typeof ack?.ack?.seq === 'number' ? ack.ack.seq : null,
            w: ack?.ack?.w ?? null,
            h: ack?.ack?.h ?? null,
            ok: ack?.ok !== false && jpeg !== '',
            error: ack?.error ?? null,
          }
        },
      ),
    }),

    defineTool({
      name: 'superphone_tap',
      description: 'Tap a device screen at normalized 0-1 coordinates (top-left origin).',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        x: { type: 'number', required: true, description: 'Normalized X (0-1).' },
        y: { type: 'number', required: true, description: 'Normalized Y (0-1).' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) =>
          value.blocked
            ? [{ type: 'text', text: `blocked: ${value.error}` }]
            : [{ type: 'text', text: value.ok ? `tapped (${value.x}, ${value.y})` : `tap failed: ${value.error}` }],
      },
      execute: withActivity(
        log,
        'superphone_tap',
        (a: { x: number; y: number }) => `tap(${a.x.toFixed(3)}, ${a.y.toFixed(3)})`,
        async (args: { deviceId: string; x: number; y: number }) => {
          const blocked = await humanControlled(config, args.deviceId)
          if (blocked) return { deviceId: args.deviceId, ok: false, blocked: true, error: blocked, x: args.x, y: args.y }
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, {
            cap: 'touch.tap',
            params: { x: args.x, y: args.y },
          })
          return { deviceId: args.deviceId, ok: ack?.ok !== false, x: args.x, y: args.y, ack: ack ?? null, error: ack?.error ?? null }
        },
      ),
    }),

    defineTool({
      name: 'superphone_ocr',
      description:
        'On-device OCR (Apple Vision) with normalized boxes. Pass text to only get matching lines with their tap coordinates.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        text: { type: 'string', description: 'Optional text to locate (vision.find_text); omit for full OCR.' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          {
            type: 'text',
            // ⚠️ 必须带坐标：模型要靠 cx/cy 把"锚点"解析成点击坐标。
            // 2026-09-17 真机验收发现：原实现只输出 l.text，把 cx/cy 丢在结构化返回值里 →
            // 模型在工具面上拿不到坐标 → 「锚点→坐标→点击」链路断裂。
            text: `${value.count ?? 0} line(s): ${(value.lines ?? [])
              .slice(0, 12)
              .map((l: any) => `${l.text}@(${Number(l.cx ?? 0).toFixed(3)},${Number(l.cy ?? 0).toFixed(3)})`)
              .join(' | ')}`,
          },
        ],
      },
      execute: withActivity(
        log,
        'superphone_ocr',
        (a: { text?: string }) => (a.text ? `find_text(${a.text})` : 'OCR 全屏'),
        async (args: { deviceId: string; text?: string }) => {
          const cap = args.text ? 'vision.find_text' : 'vision.ocr'
          const params = args.text ? { text: args.text } : {}
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, { cap, params, timeout: 30000 })
          const lines = (args.text ? ack?.ack?.matches : ack?.ack?.texts) ?? []
          return { deviceId: args.deviceId, ok: ack?.ok !== false, count: lines.length, lines, error: ack?.error ?? null }
        },
      ),
    }),

    defineTool({
      name: 'superphone_take_control',
      description:
        'Take the device back from a human operator: drops external (5801 / direct) controllers so AI input is accepted again.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [{ type: 'text', text: value.ok ? 'external controllers dropped' : `failed: ${value.error}` }],
      },
      execute: withActivity(log, 'superphone_take_control', (a: { deviceId: string }) => `接管 ${short(a.deviceId)}`, async (args: { deviceId: string }) => {
        const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/disconnect`, {})
        return { deviceId: args.deviceId, ok: ack?.ok !== false, ack: ack ?? null, error: ack?.error ?? null }
      }),
    }),

    defineTool({
      name: 'superphone_app_list',
      description: 'List apps installed on the device (name + bundleId). Use this to find the bundleId for superphone_app_open.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          { type: 'text', text: `${(value.apps ?? []).length} app(s): ${(value.apps ?? []).slice(0, 6).map((a: any) => a.name).join(' / ')}` },
        ],
      },
      execute: withActivity(log, 'superphone_app_list', () => '列出应用', async (args: { deviceId: string }) => {
        const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, { cap: 'app.list', params: {} })
        const apps = (ack?.ack?.apps ?? []) as Array<{ name: string; bundleId: string }>
        return { deviceId: args.deviceId, ok: ack?.ok !== false, count: apps.length, apps, error: ack?.error ?? null }
      }),
    }),

    defineTool({
      name: 'superphone_app_open',
      description: 'Launch an app on the device by bundleId (find it with superphone_app_list first).',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        bundleId: { type: 'string', required: true, description: 'App bundle id, e.g. com.ss.iphone.ugc.Aweme (Douyin).' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [{ type: 'text', text: value.ok ? `launched ${value.bundleId}` : `launch failed: ${value.error}` }],
      },
      execute: withActivity(
        log,
        'superphone_app_open',
        (a: { bundleId: string }) => `打开 ${a.bundleId}`,
        async (args: { deviceId: string; bundleId: string }) => {
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, {
            cap: 'app.open',
            params: { bundleId: args.bundleId },
          })
          return { deviceId: args.deviceId, bundleId: args.bundleId, ok: ack?.ok !== false, ack: ack ?? null, error: ack?.error ?? null }
        },
      ),
    }),

    defineTool({
      name: 'superphone_type',
      description:
        'Type text into the device (clipboard paste — the only correct path for Chinese / emoji). Focus the input field first with superphone_tap.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        text: { type: 'string', required: true, description: 'Text to type (Chinese / emoji supported).' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          { type: 'text', text: value.ok ? `typed ${value.length} char(s)` : `type failed: ${value.error}` },
        ],
      },
      execute: withActivity(
        log,
        'superphone_type',
        (a: { text: string }) => `输入「${a.text.slice(0, 12)}」`,
        async (args: { deviceId: string; text: string }) => {
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, {
            cap: 'type.paste',
            params: { text: args.text },
          })
          return {
            deviceId: args.deviceId,
            length: ack?.ack?.length ?? 0,
            ok: ack?.ok !== false,
            ack: ack ?? null,
            error: ack?.error ?? null,
          }
        },
      ),
    }),

    defineTool({
      name: 'superphone_end_control',
      description:
        'End the AI control session on a device (clears the gateway AI-active state so the card stops showing AI 控制中).',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [{ type: 'text', text: value.ended ? 'AI control session ended' : 'no active AI session' }],
      },
      execute: withActivity(
        log,
        'superphone_end_control',
        (a: { deviceId: string }) => `结束控制 ${short(a.deviceId)}`,
        async (args: { deviceId: string }) => {
          const ack = await post(config, `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`, { cap: 'control.end', params: {} })
          return { deviceId: args.deviceId, ended: ack?.ack?.ended === true, ok: ack?.ok !== false, ack: ack ?? null, error: ack?.error ?? null }
        },
      ),
    }),

    defineTool({
      name: 'superphone_wait_change',
      description:
        'Wait until the device screen CHANGES (event-driven, no polling). SCOPE: it only captures changes that happen WHILE this call is pending — the device detects changes via a pHash event source (Hamming distance > 2, so tiny changes such as a blinking caret are deliberately ignored) which runs only while someone is waiting; a change that already finished before you call this is not reported (you get a timeout). For "verify that my tap took effect" use superphone_wait_stable + superphone_screenshot instead. Pass since = the seq from a previous superphone_screenshot call to wait for changes after that point; omitting it sends since=0, which is already satisfied as soon as the device has seen any change since start (i.e. it returns almost immediately) — so always pass an explicit since when you mean "from now on". A timeout is a normal outcome (changed:false), not an error.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        since: { type: 'number', description: 'Baseline seq from a previous superphone_screenshot call. Omit = sends 0 (returns almost immediately on a device that has ever changed). Changes that already finished before this call are never reported.' },
        timeoutMs: { type: 'number', description: 'Application-level deadline in ms (default 15000, capped 120000).' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          { type: 'text', text: value.changed ? `changed (seq ${value.seq}) in ${value.ms}ms` : `no change within ${value.ms}ms` },
        ],
      },
      execute: withActivity(
        log,
        'superphone_wait_change',
        (a: { since?: number }) => (a.since != null ? `等变化(since=${a.since})` : '等变化'),
        async (args: { deviceId: string; since?: number; timeoutMs?: number }) => {
          const timeout = Math.min(Math.max(args.timeoutMs ?? 15000, 1000), 120000)
          const startedAt = Date.now()
          const ack = await post(
            config,
            `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`,
            { cap: 'screen.wait', params: { since: args.since ?? 0 }, timeout },
            timeout + 8000,
          )
          const ms = Date.now() - startedAt
          const seq = typeof ack?.ack?.seq === 'number' ? ack.ack.seq : null
          const changed = ack?.ok !== false && seq !== null
          return {
            deviceId: args.deviceId,
            changed,
            seq: seq ?? 0,
            ms,
            ok: true, // 等待本身成功（超时是编排可决策的正常结论，不算工具错误）
            error: changed ? null : (ack?.error ?? 'no change within timeout'),
          }
        },
      ),
    }),

    defineTool({
      name: 'superphone_wait_stable',
      description:
        'Wait until the device screen has been STABLE for a given window (event-driven). Use after a tap/swipe so the next recognition step does not read an animation mid-frame.',
      parameters: {
        deviceId: { type: 'string', required: true, description: 'Device id.' },
        minStableMs: { type: 'number', description: 'Stable window in ms (default 400).' },
      },
      output: {
        schema: { type: 'object', additionalProperties: true },
        render: (_args, value: any) => [
          { type: 'text', text: value.stable ? `stable after ${value.ms}ms` : `still changing after ${value.ms}ms` },
        ],
      },
      execute: withActivity(
        log,
        'superphone_wait_stable',
        (a: { minStableMs?: number }) => `等稳定(${a.minStableMs ?? 400}ms)`,
        async (args: { deviceId: string; minStableMs?: number }) => {
          const minStableMs = Math.min(Math.max(args.minStableMs ?? 400, 100), 10000)
          const startedAt = Date.now()
          const ack = await post(
            config,
            `/api/devices/${encodeURIComponent(args.deviceId)}/invoke`,
            { cap: 'screen.waitStable', params: { minStableMs }, timeout: 30000 },
            40000,
          )
          const ms = Date.now() - startedAt
          const stable = ack?.ok !== false && ack?.ack?.stable !== false
          return {
            deviceId: args.deviceId,
            stable,
            ms,
            ok: true,
            error: stable ? null : (ack?.error ?? 'screen kept changing'),
          }
        },
      ),
    }),
  ]
}
