/**
 * 执行日志（host 侧环形缓冲）。
 *
 * 数据来源 = 本插件对网关的每一次调用（AI 工具调用全部经此出口）：工具名、关键参数、
 * 结果与耗时。面板用它显示「AI 正在做什么」，并据此判断 AI 是否处于活跃控制中
 * （最近 N 秒内有调用）——完全在插件内闭环，不需要网关新增协议或状态。
 */

export interface ActivityEntry {
  /** 发生时刻（毫秒时间戳）。 */
  ts: number
  /** 条目类型：网关调用 / 面板动作。 */
  kind: 'call' | 'panel'
  /** 操作名（网关路径的最后一段或 cap 名）。 */
  name: string
  /** 关键参数摘要（人类可读）。 */
  detail?: string
  ok: boolean
  /** 耗时（毫秒）。 */
  ms: number
}

export class ActivityLog {
  private entries: ActivityEntry[] = []
  private lastCallAt = 0

  constructor(private readonly limit = 200) {}

  push(entry: ActivityEntry): void {
    this.entries.push(entry)
    if (this.entries.length > this.limit) this.entries.splice(0, this.entries.length - this.limit)
    if (entry.kind === 'call') this.lastCallAt = entry.ts
  }

  /**
   * 面板读取的快照：最近条目（新的在后）+ 最后活动时刻。
   * 注：这里**不再**提供"AI 活跃"判定——控制状态以网关的 `controlState` 为唯一真相源
   *（网关能覆盖全部程序化输入：插件/MCP/脚本/curl；插件侧只看得到自己的调用，
   *  曾因此漏判），本类只负责"执行日志"这一件事。
   */
  snapshot(limit = 60): { lastCallAt: number; entries: ActivityEntry[] } {
    return { lastCallAt: this.lastCallAt, entries: this.entries.slice(-limit) }
  }
}
