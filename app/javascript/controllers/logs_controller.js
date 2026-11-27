import { Controller } from "@hotwired/stimulus"
import { cable } from "@hotwired/turbo-rails"
import { parseAnsi, PLAIN } from "logs/ansi"
import { parseStructured } from "logs/structured"
import { parseTime, clock } from "logs/time"
import { lowerOf, matchRanges, drawText } from "logs/highlight"

const MAX_LINES = 5_000        // rows kept in the page; the oldest go first
const BACKLOG = 200            // lines of history a new reader asks each container for (LiveLogs::BACKLOG)
const WAITING_AFTER = 10_000   // ms without anything from the agents
const RENEW_EVERY = 10_000     // ms between telling the channel this page is still open
const NEAR_BOTTOM = 4          // px from the end that still counts as the end

const STATUS = {
  rejected: "Stopped: reload the page to keep reading",
  connecting: "Connecting…",
  live: "Live",
  waiting: "Waiting for new lines",
  unavailable: "Not streaming"
}

const plural = (count, word) => `${count.toLocaleString("en-US")} ${word}${count === 1 ? "" : "s"}`

// Log text only ever reaches the page as text nodes and textContent, never as markup.
const tag = (name, className, text = "") => Object.assign(document.createElement(name), { className, textContent: text })

// One or several containers' logs, or an app's traffic. Subscribes to the
// channel it is given (LogsChannel or TrafficChannel) through Turbo's own
// cable consumer, which asks each container's agent for its last lines
// and then new ones. Lines from every source are kept in timestamp order (a
// new one almost always lands at the end), at most MAX_LINES of them, and
// the page is only touched once per animation frame.
//
// Each line is a record: its source, key (the timestamp, sortable), stream,
// title (Docker's timestamp), segments (the [{ text, classes }] runs drawn),
// for a JSON line pretty and hidden (see logs/structured), and for one the
// viewer wrote itself, notice. lower is the text the filter searches; element
// and text are the row and the span its message is drawn in.
export default class extends Controller {
  static targets = [ "filter", "stream", "wrap", "follow", "status", "scroller", "lines", "empty", "jump" ]
  static values = { channel: Object, sources: Array, targets: Object, empty: String }

  connect() {
    this.closed = false
    this.connected = false
    this.rejected = false
    this.lines = []
    this.structured = new WeakMap() // row → record, for expand
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

    this.heldPerSource = Math.max(BACKLOG, Math.ceil(MAX_LINES / this.sources.size))

    const longest = Math.max(...this.sourcesValue.map(source => source.label.length))
    this.element.style.setProperty("--source-width", `calc(${longest}ch + 1.25rem)`)

    this.#subscribe()
    this.ticker = setInterval(() => this.#drawStatus(), 1000)
    this.renewer = setInterval(() => this.subscription?.perform("renew"), RENEW_EVERY)
    this.#drawStatus()
  }

  disconnect() {
    clearInterval(this.ticker)
    clearInterval(this.renewer)
    cancelAnimationFrame(this.drawFrame)
    cancelAnimationFrame(this.filterFrame)
    this.closed = true
    this.subscription?.unsubscribe()
    this.subscription = null
  }

  // Actions

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
      record.expanded = tag("pre", "logs__json", record.pretty)
      row.append(record.expanded)
      if (this.follow) this.#setFollow(false) // reading one line: don't scroll it away
    }
    row.setAttribute("aria-expanded", record.expanded ? "true" : "false")
  }

  // The channel

  async #subscribe() {
    const subscription = await cable.subscribeTo(
      this.channelValue,
      {
        received: batch => this.#receive(batch),
        connected: () => { this.connected = true; this.lastActivityAt = performance.now(); this.#drawStatus() },
        disconnected: () => { this.connected = false; this.#drawStatus() },
        // The channel turned the page down: its grant expired (a page open
        // for half a day reconnecting), or the reader lost the right to logs.
        // Either way only a reload can tell, and Action Cable won't retry.
        rejected: () => { this.rejected = true; this.connected = false; this.#drawStatus() }
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

  // Batches into records

  #draw() {
    const batches = this.queue
    this.queue = []
    this.queued = 0

    let visible = 0
    for (const { source, batch } of batches) visible += this.#apply(source, batch)

    const excess = this.lines.length - MAX_LINES
    if (excess > 0) for (const record of this.lines.splice(0, excess)) record.element.remove()

    if (this.follow) this.#toBottom()
    else if (visible) { this.unseen += visible; this.#drawJump() }
    this.#drawEmpty()
    this.#drawStatus()
  }

  // Returns how many rows it added that are not filtered out.
  #apply(source, batch) {
    let visible = 0
    const add = record => { if (this.#insert(record)) visible++ }

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

    if (batch.dropped) add(this.#notice(source, "dropped", `${plural(batch.dropped, "line")} skipped: logged faster than the agent sends`, lines[0]?.key))
    for (const line of lines) add(line)
    if (batch.ended && !source.ended) {
      source.ended = true
      add(this.#notice(source, "ended", "Container stopped", lines.at(-1)?.key))
    }
    return visible
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
      const structured = parseStructured(raw.m, this.targetsValue)
      const segments = structured?.segments ?? parseAnsi(raw.m)
      records.push(this.#record({ source, key, stream: raw.s, title: raw.t, segments, pretty: structured?.pretty, hidden: structured?.hidden }))
    }
    return records
  }

  // Remembers a line for the backlog check, forgetting the oldest. A backlog
  // is a container's last BACKLOG lines, so each source keeps at least that
  // many, and all of them together about what the page holds, not that many each.
  #hold(source, identity) {
    source.held.add(identity)
    if (source.held.size > this.heldPerSource) source.held.delete(source.held.values().next().value)
  }

  #notice(source, notice, text, key = this.#now()) {
    return this.#record({ notice, source, key, segments: [ { text, classes: PLAIN } ] })
  }

  // Arrival time, but never before the newest line: what the viewer says goes at the end.
  #now() {
    return Math.max(Date.now(), this.lines.at(-1)?.key ?? 0)
  }

  #record(fields) {
    const plain = fields.segments.map(segment => segment.text).join("")
    // Ranges past the drawn text (in hidden fields) match the filter but draw no mark.
    const lower = lowerOf(fields.hidden ? `${plain}\n${fields.hidden}` : plain)
    return { ...fields, lower, painted: false, marked: false, element: null, text: null }
  }

  // Rows

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
    const row = tag("div", "logs__line")
    if (record.notice) row.dataset.notice = record.notice
    if (record.stream) row.dataset.stream = record.stream

    const time = tag("time", "logs__time", clock(record.key))
    if (record.title) time.dataset.tooltip = record.title
    row.append(time)

    if (this.sources.size > 1) {
      const chip = tag("span", "logs__source", record.source.label)
      Object.assign(chip.dataset, { tone: record.source.tone, tooltip: record.source.title })
      row.append(chip)
    }

    record.text = tag("span", "logs__text")
    record.element = row
    row.append(record.text)

    if (record.pretty) {
      row.classList.add("logs__line--json")
      this.structured.set(row, record)
    }
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

  // Following, and what the page says about itself

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
    this.emptyTarget.textContent = this.lines.length ? "No lines match." : this.emptyValue
  }

  #drawStatus() {
    const sources = [ ...this.sources.values() ]
    const state = this.rejected ? "rejected"
      : !this.connected ? "connecting"
      : sources.every(source => source.off || source.refused) ? "unavailable"
      : performance.now() - this.lastActivityAt > WAITING_AFTER ? "waiting"
      : "live"

    this.element.dataset.state = state === "rejected" ? "unavailable" : state
    if (this.statusTarget.textContent !== STATUS[state]) this.statusTarget.textContent = STATUS[state]
  }
}
