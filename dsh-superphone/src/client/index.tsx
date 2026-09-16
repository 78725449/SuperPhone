import React, { useEffect, useRef, useState } from 'react'
import type { Context } from '@deepseek-ai/cordis'

/**
 * dsh-superphone — 客户端半边（浏览器）。
 *
 * 面板 = **选择器 + 网关单卡（iframe）+ 执行日志**，画面区的一切交互都交给网关：
 * - 悬停 → 网关的卡片提示（普通「点击进入控制」/ AI 控制中时「AI 控制中」）
 * - 点击 → 网关的卡片浮层（被控制中 / AI 控制中都是同一套「断开 / 接管」）
 * - 点击「接管」→ 网关自己进入聚焦控制（退出由网关 FAB 提供）
 *
 * 所以这里**不再自绘任何浮层**（渐变光、状态胶囊、接管按钮都曾重复实现过，与网关格式
 * 打架；纪律：窄容器嵌入方一律用 `?only=`/`?syscursor=` 复用网关实现）。
 * 面板只保留网关不知道的两件事：设备选择器与执行日志。
 */

export const inject = ['betterSidebar']

interface Device {
  id: string
  name: string
  host: string
  online: boolean
  controlled: boolean
  controlledSource?: string | null
  /** 网关合成的互斥控制状态：direct(5801) / gateway(隧道会话) / ai(程序化输入) / idle */
  controlState?: 'direct' | 'gateway' | 'ai' | 'idle'
}

interface PanelConfig {
  gateway: string
}

interface LogEntry {
  ts: number
  kind: 'call' | 'panel'
  name: string
  detail?: string
  ok: boolean
  ms: number
}

interface LogSnapshot {
  lastCallAt: number
  entries: LogEntry[]
}

async function getJson<T>(path: string): Promise<T | null> {
  try {
    const res = await fetch(path, { headers: { Accept: 'application/json' } })
    if (!res.ok) return null
    return (await res.json()) as T
  } catch {
    return null
  }
}

/**
 * 选择器里的设备标签：状态点 + 名称 + **连接状态**（在线/离线）。
 * 它只表达"设备是否连上"；被控状态属于当前关注设备的实时状态（由头部徽标呈现），
 * 不放选择器，保持"选设备"的单一语义。
 */
function deviceLabel(d: Device): string {
  return `${d.online ? '●' : '○'} ${d.name} · ${d.online ? '在线' : '离线'}`
}

export function SuperphoneTab({ visible = true }: { ctx?: Context; visible?: boolean }): React.ReactElement {
  const [devices, setDevices] = useState<Device[]>([])
  const [config, setConfig] = useState<PanelConfig | null>(null)
  const [deviceId, setDeviceId] = useState<string | null>(null)
  const [log, setLog] = useState<LogSnapshot | null>(null)
  const [error, setError] = useState<string | null>(null)
  const logRef = useRef<HTMLDivElement>(null)

  const selected = devices.find((d) => d.id === deviceId) ?? null

  // 设备列表 + 配置（1.5s：控制状态由设备端事件驱动上报，面板的可见延迟取决于此周期）
  useEffect(() => {
    if (!visible) return
    let alive = true
    const load = async (): Promise<void> => {
      const cfg = await getJson<PanelConfig>('/superphone/config')
      const devs = await getJson<{ devices: Device[] }>('/superphone/devices')
      if (!alive) return
      if (cfg) setConfig(cfg)
      if (devs?.devices) {
        setDevices(devs.devices)
        setDeviceId((current) => current ?? devs.devices![0]?.id ?? null)
        setError(null)
      } else {
        setError('无法读取设备列表（网关不可达？）')
      }
    }
    void load()
    const timer = setInterval(load, 1500)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [visible])

  // 执行日志（AI 步骤流水：每次经插件的工具调用一行）
  useEffect(() => {
    if (!visible) return
    let alive = true
    const tick = async (): Promise<void> => {
      const data = await getJson<LogSnapshot>('/superphone/log')
      if (alive && data) setLog(data)
    }
    void tick()
    const timer = setInterval(tick, 2000)
    return () => {
      alive = false
      clearInterval(timer)
    }
  }, [visible])

  useEffect(() => {
    const el = logRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [log])

  const gateway = config?.gateway?.replace(/\/+$/, '') ?? ''
  // 单卡模式 + 保持系统鼠标；聚焦切换由网关卡片自己的点击/浮层完成，面板不接管
  // pv = 面板侧的内嵌版本位：网关前端的样式/脚本更新后递增它，强制 iframe 重新加载
  //（否则 iframe 不会自动重载，面板会一直用缓存的旧样式——曾因此出现"网关有呼吸光、
  //  面板没有"的现象）。改网关 web/ 后请同步 +1。
  const frameUrl = gateway && deviceId ? `${gateway}/?syscursor=1&pv=2&only=${encodeURIComponent(deviceId)}` : null

  const status = (() => {
    if (!selected) return { text: '未选择设备', color: '#888' }
    if (!selected.online) return { text: '离线', color: '#d9534f' }
    // 互斥三态（与网关同一事实）：AI / 网关（隧道会话）/ 直连（5801），其余为在线
    switch (selected.controlState) {
      case 'ai':
        return { text: 'AI 控制中', color: '#4a9eff' }
      case 'gateway':
        return { text: '网关控制中', color: '#e0a020' }
      case 'direct':
        return { text: '直连控制中', color: '#e0a020' }
      default:
        return { text: '在线', color: '#3fb950' }
    }
  })()

  const s: Record<string, React.CSSProperties> = {
    wrap: { display: 'flex', flexDirection: 'column', gap: 8, padding: 10, height: '100%', boxSizing: 'border-box', fontSize: 13 },
    head: { display: 'flex', alignItems: 'center', gap: 8 },
    title: { fontWeight: 600, flex: 1 },
    badge: { display: 'inline-flex', alignItems: 'center', gap: 5, color: status.color, fontSize: 12 },
    dot: { width: 8, height: 8, borderRadius: 4, background: status.color, display: 'inline-block' },
    select: {
      width: '100%',
      padding: '4px 6px',
      borderRadius: 6,
      border: '1px solid var(--background-modifier-border, #3a3a3a)',
      background: 'var(--background-primary, #161616)',
      color: 'inherit',
      fontSize: 12,
    },
    frame: { position: 'relative', flex: '1 1 auto', minHeight: 220, borderRadius: 10, overflow: 'hidden', background: '#000' },
    frameEl: { width: '100%', height: '100%', border: '0', display: 'block', background: '#000' },
    logBox: {
      flex: '0 0 auto',
      height: 120,
      overflowY: 'auto',
      borderRadius: 8,
      border: '1px solid var(--background-modifier-border, #3a3a3a)',
      background: 'var(--background-primary, #161616)',
      padding: '6px 8px',
      fontSize: 11,
      lineHeight: '16px',
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    },
    empty: { opacity: 0.5 },
    err: { fontSize: 11, color: '#d9534f' },
  }

  const logLine = (entry: LogEntry, index: number): React.ReactElement =>
    React.createElement(
      'div',
      { key: `${entry.ts}-${index}` },
      React.createElement('span', { style: { opacity: 0.55 } }, `${new Date(entry.ts).toLocaleTimeString()} `),
      React.createElement('span', { style: { color: entry.ok ? '#3fb950' : '#d9534f' } }, entry.ok ? '✓ ' : '✗ '),
      React.createElement('span', null, entry.detail ?? entry.name),
      React.createElement('span', { style: { opacity: 0.45 } }, ` ${entry.ms}ms`),
    )

  return React.createElement(
    'div',
    { style: s.wrap },
    React.createElement(
      'div',
      { key: 'head', style: s.head },
      React.createElement('span', { key: 't', style: s.title }, 'SuperPhone'),
      React.createElement('span', { key: 'b', style: s.badge }, React.createElement('i', { style: s.dot }), status.text),
    ),
    React.createElement(
      'select',
      {
        key: 'sel',
        style: s.select,
        value: deviceId ?? '',
        onChange: (e: React.ChangeEvent<HTMLSelectElement>) => setDeviceId(e.target.value || null),
      },
      devices.length === 0
        ? React.createElement('option', { value: '' }, '（无设备）')
        : devices.map((d) => React.createElement('option', { key: d.id, value: d.id }, deviceLabel(d))),
    ),
    React.createElement(
      'div',
      { key: 'frame', style: s.frame },
      frameUrl
        ? React.createElement('iframe', { key: 'frame', src: frameUrl, style: s.frameEl, allow: 'clipboard-read; clipboard-write' })
        : React.createElement('div', { style: { ...s.empty, padding: 12 } }, '选择设备'),
    ),
    React.createElement(
      'div',
      { key: 'log', style: s.logBox, ref: logRef },
      log && log.entries.length > 0 ? log.entries.map(logLine) : React.createElement('div', { style: s.empty }, '暂无执行记录'),
    ),
    error ? React.createElement('div', { key: 'err', style: s.err }, error) : null,
  )
}

export function apply(ctx: Context): void {
  const betterSidebar = (ctx as any).betterSidebar
  if (!betterSidebar) return
  ctx.effect(
    () =>
      betterSidebar.registerTab({
        id: 'superphone',
        title: 'SuperPhone',
        icon: React.createElement('span', null, '📱'),
        order: 20,
        single: true,
        component: SuperphoneTab,
      }),
    'dsh-superphone: sidebar tab',
  )
}
