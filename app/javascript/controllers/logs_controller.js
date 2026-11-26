import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"

const MAX_LINES = 5_000        // rows kept in the page; the oldest go first
const WAITING_AFTER = 10_000   // ms without anything from the agents
const NEAR_BOTTOM = 4          // px from the end that still counts as the end
const MAX_MARKS = 200          // highlights drawn in one line

// Log text comes from containers, so it only ever reaches the page as text
// nodes and textContent, never as markup.

// ANSI, as the agent passes it through. SGR colours and styles become
// classes; every other escape sequence (cursor moves, OSC titles…) is cut.
const ESCAPE = /\x1b(?:\[([0-?]*)[ -/]*([@-~])|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_]|[\s\S]?)/g
const CONTROLS = /[\x00-\x08\x0b-\x1f\x7f]/g
const NO_CLASSES = Object.freeze([])

const isColor = code => (code >= 30 && code <= 37) || (code >= 90 && code <= 97)

function applySgr(style, params) {
  const codes = params === "" ? [ 0 ] : params.split(";").map(code => code === "" ? 0 : Number(code))
  const next = { ...style }

  for (let index = 0; index < codes.length; index++) {
    const code = codes[index]
    if (code === 0) Object.assign(next, { color: null, bold: false, dim: false, italic: false, underline: false })
    else if (code === 1) next.bold = true
    else if (code === 2) next.dim = true
    else if (code === 3) next.italic = true
    else if (code === 4) next.underline = true
    else if (code === 22) Object.assign(next, { bold: false, dim: false })
    else if (code === 23) next.italic = false
    else if (code === 24) next.underline = false
    else if (code === 39) next.color = null
    else if (isColor(code)) next.color = code
    else if (code === 38 || code === 48) index += codes[index + 1] === 5 ? 2 : codes[index + 1] === 2 ? 4 : 0 // 256 and truecolour: skip their arguments
  }
  return next
}

function classesFor(style) {
  const classes = []
  if (style.color) classes.push(`ansi-${style.color}`)
  if (style.bold) classes.push("ansi-bold")
  if (style.dim) classes.push("ansi-dim")
  if (style.italic) classes.push("ansi-italic")
  if (style.underline) classes.push("ansi-underline")
  return classes.length ? classes : NO_CLASSES
}

// A message as [{ text, classes }] runs, with no escape sequences left.
function parseAnsi(message) {
  if (!message.includes("\x1b")) return [ { text: message.replace(CONTROLS, ""), classes: NO_CLASSES } ]

  const segments = []
  let style = { color: null, bold: false, dim: false, italic: false, underline: false }
  let last = 0
  const push = text => {
    text = text.replace(CONTROLS, "")
    if (text) segments.push({ text, classes: classesFor(style) })
  }

  for (const match of message.matchAll(ESCAPE)) {
    push(message.slice(last, match.index))
    last = match.index + match[0].length
    if (match[2] === "m" && /^[0-9;]*$/.test(match[1])) style = applySgr(style, match[1])
  }
  push(message.slice(last))
  return segments
}

// Structured logs: a line that is one JSON object (kamal-proxy, slog, pino,
// zap, logfmt-free Rails JSON loggers…) reads as its level, its message and
// then key=value fields, most useful first. Empty fields and a timestamp
// that only repeats Docker's are left out; the whole object is one click away.
const LEVEL_KEYS = [ "level", "lvl", "severity", "log.level", "@level" ]
const MESSAGE_KEYS = [ "msg", "message", "@message" ]
const TIME_KEYS = [ "time", "ts", "timestamp", "@timestamp" ]
const FIRST_KEYS = [ "error", "err", "status", "method", "host", "path", "duration", "service" ]
const INLINE_FIELDS = 6  // key=value pairs drawn on the line; the rest are searchable and one click away
const NUMERIC_LEVELS = { 10: "trace", 20: "debug", 30: "info", 40: "warn", 50: "error", 60: "fatal" } // pino and bunyan

function levelTone(level) {
  const word = String(level).toLowerCase()
  if (/^(err|error|fatal|panic|crit|critical|alert|emerg|emergency)/.test(word)) return "bad"
  if (/^warn/.test(word)) return "warn"
  if (/^(info|notice)/.test(word)) return "info"
  return "quiet"
}

function shown(value) {
  if (typeof value === "string") return /[\s"=]/.test(value) ? JSON.stringify(value) : value
  return JSON.stringify(value)
}

// [{ text, classes }] runs for a JSON line, or null when it isn't one.
function parseStructured(message) {
  const text = message.trim()
  if (!text.startsWith("{") || !text.endsWith("}")) return null
  let object
  try { object = JSON.parse(text) } catch { return null }
  if (!object || typeof object !== "object" || Array.isArray(object)) return null

  const pick = keys => { const key = keys.find(key => typeof object[key] === "string" || typeof object[key] === "number"); return key && [ key, object[key] ] }
  const level = pick(LEVEL_KEYS), said = pick(MESSAGE_KEYS)
  const skip = new Set([ level?.[0], said?.[0], ...TIME_KEYS.filter(key => typeof object[key] === "string" || typeof object[key] === "number") ])

  const segments = []
  if (level) {
    const name = typeof level[1] === "number" ? (NUMERIC_LEVELS[level[1]] ?? String(level[1])) : level[1]
    segments.push({ text: name.toUpperCase(), classes: [ "json-level", `json-level--${levelTone(name)}` ] })
  }
  if (said) segments.push({ text: (segments.length ? " " : "") + String(said[1]), classes: [ "json-message" ] })

  const keys = Object.keys(object).filter(key => !skip.has(key) && object[key] !== "" && object[key] !== null)
  keys.sort((a, b) => (FIRST_KEYS.includes(a) ? FIRST_KEYS.indexOf(a) : FIRST_KEYS.length) - (FIRST_KEYS.includes(b) ? FIRST_KEYS.indexOf(b) : FIRST_KEYS.length))
  for (const key of keys.slice(0, INLINE_FIELDS)) {
    const tone = (key === "error" || key === "err") ? "json-value--bad" : key === "status" && Number(object[key]) >= 500 ? "json-value--bad" : key === "status" && Number(object[key]) >= 400 ? "json-value--warn" : null
    segments.push({ text: (segments.length ? "  " : "") + key, classes: [ "json-key" ] })
    segments.push({ text: "=", classes: [ "json-key" ] })
    segments.push({ text: shown(object[key]).replace(CONTROLS, ""), classes: tone ? [ "json-value", tone ] : [ "json-value" ] })
  }
  const rest = keys.slice(INLINE_FIELDS)
  if (rest.length) segments.push({ text: `  +${rest.length} more`, classes: [ "json-more" ] })
  if (!segments.length) return null

  // What isn't drawn still answers the filter.
  const hidden = rest.map(key => `${key}=${shown(object[key])}`).join(" ")
  return { segments, hidden, pretty: JSON.stringify(object, null, 2) }
}

// Docker's RFC3339Nano as a sortable number: milliseconds, plus the digits
// below a millisecond as a fraction of one. null when it isn't a timestamp.
const TIMESTAMP = /^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$/

function parseTime(text) {
  const match = TIMESTAMP.exec(text)
  if (!match) return null

  const fraction = (match[2] ?? "").padEnd(3, "0")
  const milliseconds = Date.parse(`${match[1]}.${fraction.slice(0, 3)}${match[3]}`)
  return Number.isNaN(milliseconds) ? null : milliseconds + Number(`0.${fraction.slice(3) || "0"}`)
}

const pad = (number, width = 2) => String(number).padStart(width, "0")

// HH:MM:SS.mmm in the reader's time zone.
function clock(milliseconds) {
  const time = new Date(milliseconds)
  return `${pad(time.getHours())}:${pad(time.getMinutes())}:${pad(time.getSeconds())}.${pad(time.getMilliseconds(), 3)}`
}

// Lower case that never changes a text's length, so match offsets from the
// lower-cased copy still point into the original.
function lowerOf(text) {
  const lower = text.toLowerCase()
  if (lower.length === text.length) return lower
  return Array.from(text, character => { const small = character.toLowerCase(); return small.length === character.length ? small : character }).join("")
}

function matchRanges(lower, query) {
  const ranges = []
  for (let from = lower.indexOf(query); from !== -1 && ranges.length < MAX_MARKS; from = lower.indexOf(query, from + query.length)) {
    ranges.push([ from, from + query.length ])
  }
  return ranges
}

function drawText(container, segments, ranges) {
  const fragment = document.createDocumentFragment()
  let offset = 0

  for (const { text, classes } of segments) {
    const wrapper = classes.length ? document.createElement("span") : null
    wrapper?.classList.add(...classes)
    const target = wrapper ?? fragment
    let cursor = 0

    for (const [ from, to ] of ranges) {
      const start = Math.max(from - offset, cursor), stop = Math.min(to - offset, text.length)
      if (stop <= start) continue
      if (start > cursor) target.append(text.slice(cursor, start))
      const mark = document.createElement("mark")
      mark.textContent = text.slice(start, stop)
      target.append(mark)
      cursor = stop
    }
    if (cursor < text.length) target.append(text.slice(cursor))
    if (wrapper) fragment.append(wrapper)
    offset += text.length
  }
  container.replaceChildren(fragment)
}

const plural = (count, word) => `${count.toLocaleString("en-US")} ${word}${count === 1 ? "" : "s"}`

// One or several containers' logs. Subscribes to LogsChannel through Turbo's
// own cable consumer, which asks each container's agent for its last 200 lines
// and then new ones. Lines from every source are kept in timestamp order (a
// new one almost always lands at the end), at most MAX_LINES of them, and
// the page is only touched once per animation frame.
export default class extends Controller {
  static targets = [ "filter", "stream", "wrap", "follow", "status", "scroller", "lines", "empty", "jump", "chip" ]
  static values = { placementIds: Array, sources: Array }

  connect() {
    this.closed = false
    this.connected = false
    this.lines = []
    this.structured = new WeakMap()
    this.queue = []
    this.queued = 0
    this.unseen = 0
    this.query = ""
    this.stream = "both"
    this.follow = true
    this.lastActivityAt = performance.now()
    this.sources = new Map(this.sourcesValue.map(source => [ source.id, {
      ...source, enabled: true, held: new Set(), off: false, refused: false, ended: false
    } ]))

    const longest = Math.max(...this.sourcesValue.map(source => source.label.length))
    this.element.style.setProperty("--source-width", `calc(${longest}ch + 1.25rem)`)

    this.#subscribe()
    this.ticker = setInterval(() => this.#drawStatus(), 1000)
    this.#drawStatus()
  }

  disconnect() {
    clearInterval(this.ticker)
    cancelAnimationFrame(this.drawFrame)
    cancelAnimationFrame(this.filterFrame)
    this.closed = true
    this.subscription?.unsubscribe()
    this.subscription = null
  }

  filter() {
    this.query = this.filterTarget.value.toLowerCase()
    this.#refilter()
  }

  pick({ currentTarget }) {
    this.stream = currentTarget.dataset.stream
    for (const button of this.streamTargets) button.setAttribute("aria-pressed", button === currentTarget)
    this.#refilter()
  }

  toggleSource({ currentTarget }) {
    const source = this.sources.get(Number(currentTarget.dataset.sourceId))
    source.enabled = !source.enabled
    currentTarget.setAttribute("aria-pressed", source.enabled)
    this.#refilter()
  }

  toggleWrap() {
    const wrapping = this.element.toggleAttribute("data-wrap")
    this.wrapTarget.setAttribute("aria-pressed", wrapping)
    if (this.follow) this.#toBottom()
  }

  toggleFollow() {
    this.#setFollow(!this.follow)
    if (this.follow) this.#toBottom()
  }

  jump() {
    this.#setFollow(true)
    this.#toBottom()
  }

  clear() {
    this.lines = []
    this.linesTarget.replaceChildren()
    for (const source of this.sources.values()) Object.assign(source, { off: false, refused: false, ended: false })
    this.unseen = 0
    this.#drawEmpty()
    this.#drawJump()
  }

  // Scrolling up lets go of the end; getting back to it picks it up again.
  scrolled() {
    const scroller = this.scrollerTarget
    const atEnd = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < NEAR_BOTTOM
    if (atEnd !== this.follow) this.#setFollow(atEnd)
  }

  async #subscribe() {
    const subscription = await cable.subscribeTo(
      { channel: "LogsChannel", placement_ids: this.placementIdsValue },
      {
        received: batch => this.#receive(batch),
        connected: () => { this.connected = true; this.lastActivityAt = performance.now(); this.#drawStatus() },
        disconnected: () => { this.connected = false; this.#drawStatus() }
      }
    )
    if (this.closed) subscription.unsubscribe()
    else this.subscription = subscription
  }

  // Batches wait for the next frame. A tab nobody looks at never gets one,
  // so once what waits is more than the page keeps, it is drawn at once.
  #receive(batch) {
    const source = this.sources.get(batch.source)
    if (!source) return

    this.queue.push({ source, batch })
    this.queued += batch.lines?.length ?? 0
    if (this.queued > MAX_LINES) {
      cancelAnimationFrame(this.drawFrame)
      this.drawFrame = null
      this.#draw()
    } else {
      this.drawFrame ??= requestAnimationFrame(() => { this.drawFrame = null; this.#draw() })
    }
  }

  #draw() {
    const batches = this.queue
    this.queue = []
    this.queued = 0

    let shown = 0
    for (const { source, batch } of batches) shown += this.#apply(source, batch)

    const excess = this.lines.length - MAX_LINES
    if (excess > 0) for (const record of this.lines.splice(0, excess)) record.element.remove()

    if (this.follow) this.#toBottom()
    else if (shown) { this.unseen += shown; this.#drawJump() }
    this.#drawEmpty()
    this.#drawStatus()
  }

  // Returns how many rows it added that are not filtered out.
  #apply(source, batch) {
    let shown = 0
    const add = record => { if (this.#insert(record)) shown++ }

    if (batch.off && !source.off) {
      source.off = true
      add(this.#notice(source, "off", `Logs are off on ${source.server}'s agent. Set MERIDIAN_LOGS=1 there to turn them on.`))
    }
    if (batch.refused && source.refused !== batch.refused) {
      source.refused = batch.refused
      add(this.#notice(source, "refused", `Logs refused: ${batch.refused}`))
    }

    const lines = this.#accept(source, batch)
    if (lines.length || batch.dropped || batch.ended) this.lastActivityAt = performance.now()
    if (lines.length) Object.assign(source, { off: false, refused: false, ended: false })

    if (batch.dropped) add(this.#notice(source, "dropped", `${plural(batch.dropped, "line")} skipped (over 512 KB/s)`, lines[0]?.key))
    for (const line of lines) add(line)
    if (batch.ended && !source.ended) {
      source.ended = true
      add(this.#notice(source, "ended", "Container stopped", lines.at(-1)?.key))
    }
    return shown
  }

  // The batch's lines as records. A backlog is history: it can arrive after
  // live lines (the container was already being followed) or twice (another
  // reader asked for it too), so its lines go in by timestamp and any line
  // already held, same time, stream and text, is skipped.
  #accept(source, batch) {
    const records = []
    for (const raw of batch.lines ?? []) {
      const identity = `${raw.t}\n${raw.s}\n${raw.m}`
      if (batch.backlog && source.held.has(identity)) continue
      this.#hold(source, identity)

      const key = parseTime(raw.t) ?? this.#now()
      const structured = parseStructured(raw.m)
      const segments = structured?.segments ?? parseAnsi(raw.m)
      records.push(this.#record({ kind: "line", source, key, stream: raw.s, title: raw.t, segments, pretty: structured?.pretty, hidden: structured?.hidden }))
    }
    return records
  }

  // Remembers a line for the backlog check, forgetting the oldest past what the page can hold.
  #hold(source, identity) {
    source.held.add(identity)
    if (source.held.size > MAX_LINES) source.held.delete(source.held.values().next().value)
  }

  #notice(source, notice, text, key = this.#now()) {
    return this.#record({ kind: "notice", notice, source, key, stream: null, segments: [ { text, classes: NO_CLASSES } ] })
  }

  // Arrival time, but never before the newest line: what the viewer says goes at the end.
  #now() {
    return Math.max(Date.now(), this.lines.at(-1)?.key ?? 0)
  }

  #record(fields) {
    const plain = fields.segments.map(segment => segment.text).join("")
    // Ranges past the drawn text (in hidden fields) match the filter but draw no mark.
    const lower = lowerOf(fields.hidden ? `${plain}\n${fields.hidden}` : plain)
    return { ...fields, plain, lower, painted: false, marked: false, element: null, text: null }
  }

  // Into its place by timestamp, searching from the end. Returns whether it is shown.
  #insert(record) {
    let index = this.lines.length
    while (index > 0 && this.lines[index - 1].key > record.key) index--

    this.#build(record)
    this.linesTarget.insertBefore(record.element, this.lines[index]?.element ?? null)
    this.lines.splice(index, 0, record)
    return this.#show(record)
  }

  #build(record) {
    const row = document.createElement("div")
    row.classList.add("logs__line")
    if (record.kind === "notice") { row.classList.add("logs__line--notice"); row.dataset.notice = record.notice }
    if (record.stream) row.dataset.stream = record.stream

    const time = document.createElement("time")
    time.classList.add("logs__time")
    time.textContent = clock(record.key)
    if (record.title) time.dataset.tooltip = record.title
    row.append(time)

    if (this.sources.size > 1) {
      const chip = document.createElement("span")
      chip.classList.add("logs__source")
      chip.dataset.tone = record.source.tone
      chip.textContent = record.source.label
      chip.dataset.tooltip = record.source.title
      row.append(chip)
    }

    record.text = document.createElement("span")
    record.text.classList.add("logs__text")
    record.element = row
    row.append(record.text)

    if (record.pretty) {
      row.classList.add("logs__line--json")
      this.structured.set(row, record)
    }
  }

  // A structured line opens to its whole object, and closes again. Selecting
  // text inside it doesn't count as a click.
  expand(event) {
    if (event.target.closest(".logs__json")) return
    const row = event.target.closest(".logs__line--json")
    const record = row && this.structured.get(row)
    if (!record || window.getSelection()?.toString()) return

    if (record.expanded) {
      record.expanded.remove()
      record.expanded = null
    } else {
      record.expanded = document.createElement("pre")
      record.expanded.classList.add("logs__json")
      record.expanded.textContent = record.pretty
      row.append(record.expanded)
      if (this.follow) this.#setFollow(false) // reading one line: don't scroll it away
    }
    row.setAttribute("aria-expanded", record.expanded ? "true" : "false")
  }

  #matches(record) {
    if (!record.source.enabled) return false
    if (this.stream !== "both" && record.stream && record.stream !== this.stream) return false
    return !this.query || record.lower.includes(this.query)
  }

  // Hides or shows a row and draws its message, highlighted while a filter is typed.
  #show(record) {
    const visible = this.#matches(record)
    record.element.hidden = !visible
    if (visible && (!record.painted || this.query || record.marked)) this.#paint(record)
    return visible
  }

  #paint(record) {
    const ranges = this.query ? matchRanges(record.lower, this.query) : []
    record.painted = true
    record.marked = ranges.length > 0
    if (!ranges.length && record.segments.length === 1 && !record.segments[0].classes.length) record.text.textContent = record.segments[0].text
    else drawText(record.text, record.segments, ranges)
  }

  #refilter() {
    this.filterFrame ??= requestAnimationFrame(() => {
      this.filterFrame = null
      for (const record of this.lines) this.#show(record)
      this.#drawEmpty()
      if (this.follow) this.#toBottom()
    })
  }

  #setFollow(following) {
    this.follow = following
    this.followTarget.setAttribute("aria-pressed", following)
    if (following) this.unseen = 0
    this.#drawJump()
  }

  #toBottom() {
    this.scrollerTarget.scrollTop = this.scrollerTarget.scrollHeight
  }

  #drawJump() {
    this.jumpTarget.hidden = this.follow || this.unseen === 0
    this.jumpTarget.textContent = `${plural(this.unseen, "new line")}, jump to latest`
  }

  #drawEmpty() {
    const anyShown = this.linesTarget.querySelector(".logs__line:not([hidden])")
    this.emptyTarget.hidden = !!anyShown
    this.emptyTarget.textContent = this.lines.length ? "No lines match." : "No lines yet. Whatever the container writes shows up here."
  }

  #drawStatus() {
    const sources = [ ...this.sources.values() ]
    const state = !this.connected ? "connecting"
      : sources.every(source => source.off || source.refused) ? "unavailable"
      : performance.now() - this.lastActivityAt > WAITING_AFTER ? "waiting"
      : "live"
    const labels = { connecting: "Connecting…", live: "Live", waiting: "Waiting for new lines", unavailable: "Not streaming" }

    this.element.dataset.state = state
    if (this.statusTarget.textContent !== labels[state]) this.statusTarget.textContent = labels[state]
  }
}
