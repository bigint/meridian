import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const WINDOW = 120            // frames kept for the averages and sparklines
const PAUSED_AFTER = 5_000    // ms without a frame
const HINT_AFTER = 15_000     // ms without ever getting one
const WIDTH = 120, HEIGHT = 32 // the sparkline's viewBox

const UNITS = [ "B", "KB", "MB", "GB", "TB" ]

// Bytes in binary units: 512 B, 3.4 MB.
function formatBytes(bytes) {
  let value = bytes, unit = 0
  while (value >= 1024 && unit < UNITS.length - 1) { value /= 1024; unit++ }
  return unit === 0 ? `${Math.round(value)} B` : `${value.toFixed(1)} ${UNITS[unit]}`
}

// Bytes per second: 14.7 B/s, 1.2 KB/s, 3.0 MB/s.
function formatRate(bytes) {
  if (bytes === 0) return "0 B/s"
  if (bytes < 1024) return `${bytes.toFixed(1)} B/s`
  const units = [ "KB/s", "MB/s", "GB/s" ]
  let value = bytes / 1024, unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++ }
  return `${value.toFixed(1)} ${units[unit]}`
}

const percent = value => `${value.toFixed(1)}%`
const share = (part, whole) => whole > 0 ? (part / whole) * 100 : null
const plural = (count, word) => `${count} ${word}${count === 1 ? "" : "s"}`

// How each host tile reads a frame. value is a number or null; capacity is
// the most the value can be, used to keep the sparkline from exaggerating noise;
// share is how full that makes it, in percent.
const METRICS = {
  cpu: {
    value: host => share(host.cpu_cores, host.cores),
    share: null, // the value already is one
    capacity: () => 100,
    format: percent,
    caption: host => host.cores ? `of ${plural(host.cores, "core")}` : "",
  },
  memory: {
    value: host => host.memory_used ?? null,
    capacity: host => host.memory_total,
    format: formatBytes,
    caption: host => host.memory_total ? `of ${formatBytes(host.memory_total)}` : "",
    share: host => share(host.memory_used, host.memory_total),
  },
  load: {
    value: host => host.load1 ?? null,
    capacity: host => host.cores,
    format: value => value.toFixed(2),
    caption: host => host.cores ? `of ${plural(host.cores, "core")}` : "",
    share: host => share(host.load1, host.cores),
  },
  disk: {
    value: host => host.disk_used ?? null,
    capacity: host => host.disk_total,
    format: formatBytes,
    caption: host => host.disk_total ? `of ${formatBytes(host.disk_total)}` : "",
    share: host => share(host.disk_used, host.disk_total),
  },
}

function level(percentage) {
  if (percentage == null) return null
  return percentage >= 90 ? "bad" : percentage >= 75 ? "warn" : null
}

function setLevel(element, value) {
  if (value) element.dataset.level = value
  else delete element.dataset.level
}

// A server's live numbers. Subscribes to ServerStatsChannel through Turbo's
// own cable consumer, keeps the last WINDOW host frames, and draws the host
// tiles and each running container's CPU, memory and network cells. The
// tiles are data-turbo-permanent; the container cells are redrawn after a
// morph, so a board refresh never blanks them.
export default class extends Controller {
  static targets = [ "strip", "status", "noHost", "noFrames" ]
  static values = { serverId: Number }

  connect() {
    this.closed = false
    this.window = []
    this.latest = null
    this.lastFrameAt = null
    this.startedAt = performance.now()
    this.tiles = this.#readTiles()

    this.#subscribe()
    this.ticker = setInterval(() => this.#drawStatus(), 1000)
    this.#drawStatus()
  }

  disconnect() {
    clearInterval(this.ticker)
    this.closed = true
    this.subscription?.unsubscribe()
    this.subscription = null
  }

  // After a morph the cells hold the server's "—" again. Put the numbers back.
  apply() {
    if (this.latest) this.#drawContainers()
  }

  async #subscribe() {
    const subscription = await cable.subscribeTo(
      { channel: "ServerStatsChannel", server_id: this.serverIdValue },
      {
        received: frame => this.#receive(frame),
        connected: () => this.stripTarget.toggleAttribute("data-subscribed", true),
        disconnected: () => this.stripTarget.toggleAttribute("data-subscribed", false)
      }
    )
    if (this.closed) subscription.unsubscribe()
    else this.subscription = subscription
  }

  #receive(frame) {
    this.latest = frame
    this.lastFrameAt = performance.now()
    if (frame.host) {
      this.window.push(frame.host)
      if (this.window.length > WINDOW) this.window.shift()
    }

    this.#drawHost()
    this.#drawContainers()
    this.#drawStatus()
  }

  #drawStatus() {
    const now = performance.now()
    const state = this.lastFrameAt == null ? "connecting" : now - this.lastFrameAt > PAUSED_AFTER ? "paused" : "live"
    const labels = { connecting: "Connecting…", live: "Live", paused: "Paused, the agent stopped sending" }

    this.stripTarget.dataset.state = state
    if (this.statusTarget.textContent !== labels[state]) this.statusTarget.textContent = labels[state]
    this.noFramesTarget.hidden = !(this.lastFrameAt == null && now - this.startedAt > HINT_AFTER)
    this.noHostTarget.hidden = !(this.latest && !this.latest.host)
  }

  #readTiles() {
    return Object.fromEntries([ ...this.stripTarget.querySelectorAll("[data-metric]") ].map(tile => [
      tile.dataset.metric,
      {
        element: tile,
        value: tile.querySelector("[data-part=value]"),
        capacity: tile.querySelector("[data-part=capacity]"),
        share: tile.querySelector("[data-part=share]"),
        range: tile.querySelector("[data-part=range]"),
        area: tile.querySelector("[data-part=area]"),
        trace: tile.querySelector("[data-part=trace]")
      }
    ]))
  }

  #drawHost() {
    const host = this.latest.host
    for (const [ name, metric ] of Object.entries(METRICS)) {
      const tile = this.tiles[name]
      const current = host && metric.value(host)

      if (current == null) {
        tile.value.textContent = "—"
        tile.capacity.textContent = ""
        tile.share.textContent = ""
        tile.range.textContent = "avg — · peak —"
        tile.area.setAttribute("d", "")
        tile.trace.setAttribute("d", "")
        setLevel(tile.element, null)
        continue
      }

      const series = this.window.map(metric.value).filter(value => value != null)
      const average = series.reduce((sum, value) => sum + value, 0) / series.length
      const peak = Math.max(...series)

      tile.value.textContent = metric.format(current)
      tile.capacity.textContent = metric.caption(host)
      tile.range.textContent = `avg ${metric.format(average)} · peak ${metric.format(peak)}`
      const used = metric.share ? metric.share(host) : current
      tile.share.textContent = metric.share && used != null ? percent(used) : ""
      setLevel(tile.element, level(used))
      this.#drawSparkline(tile, series, metric.capacity(host))
    }
  }

  // Newest on the right, so the line grows in from the edge. The scale tops
  // out at 20% above the window's peak, but never below a tenth of capacity:
  // an idle machine reads as idle, not as a mountain range.
  #drawSparkline(tile, series, capacity) {
    if (series.length < 2) return

    const top = Math.max(Math.max(...series) * 1.2, (capacity || 0) * 0.1, Number.EPSILON)
    const x = index => ((WINDOW - series.length + index) / (WINDOW - 1)) * WIDTH
    const y = value => HEIGHT - 1 - (Math.min(value, top) / top) * (HEIGHT - 3)
    const points = series.map((value, index) => `${x(index).toFixed(2)} ${y(value).toFixed(2)}`)
    const line = `M${points.join(" L")}`

    tile.trace.setAttribute("d", line)
    tile.area.setAttribute("d", `${line} L${x(series.length - 1).toFixed(2)} ${HEIGHT} L${x(0).toFixed(2)} ${HEIGHT} Z`)
  }

  #drawContainers() {
    const byId = new Map((this.latest.containers ?? []).map(container => [ container.id, container ]))
    const cores = this.latest.host?.cores || 1

    for (const row of this.element.querySelectorAll("tr[data-live-container]")) {
      const stats = byId.get(row.dataset.liveContainer)
      const cell = part => row.querySelector(`[data-part=${part}]`)

      if (!stats) {
        for (const part of [ "cpu", "memory", "rx", "tx" ]) cell(part).textContent = "—"
        for (const part of [ "cpu-meter", "memory-meter" ]) this.#meter(cell(part), null)
        continue
      }

      const { cpu_cores = 0, memory_used = 0, memory_limit = 0, net_rx = 0, net_tx = 0 } = stats
      const cpu = share(cpu_cores, cores)
      cell("cpu").textContent = percent(cpu)
      cell("cpu").title = `${cpu_cores.toFixed(3)} cores${this.latest.host ? "" : " (host cores unknown, shown against one)"}`
      this.#meter(cell("cpu-meter"), cpu)

      cell("memory").textContent = formatBytes(memory_used)
      cell("memory").title = memory_limit ? `of ${formatBytes(memory_limit)}` : ""
      this.#meter(cell("memory-meter"), share(memory_used, memory_limit))

      cell("rx").textContent = formatRate(net_rx)
      cell("tx").textContent = formatRate(net_tx)
    }
  }

  #meter(element, percentage) {
    element.style.setProperty("--share", percentage == null ? 0 : Math.min(percentage, 100).toFixed(1))
    setLevel(element, level(percentage))
  }
}
