import { CONTROLS } from "logs/ansi"

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

// kamal-proxy's request lines (kamal-proxy v0.10.3, internal/server/
// logging_middleware.go) read as what happened: the status, the request, how
// long it took, the container that answered and who asked. Behind Cloudflare,
// "who" is the visitor, their country and the Cloudflare location, when the
// app's Kamal config logs those headers. A query string (often a long cache
// buster) shows as "?…"; it and the rest stay searchable and open on a click.
const REQUEST_DRAWN = [ "time", "level", "msg", "status", "method", "host", "path", "duration",
  "remote_addr", "req_cf_connecting_ip", "req_cf_ipcountry", "req_cf_ray" ]

// A line as { segments, hidden, pretty }, or null when it isn't one JSON
// object: segments are the [{ text, classes }] runs drawn, hidden is the
// fields left off the line (they still answer the filter), and pretty is the
// whole object, indented. targets names the containers kamal-proxy sends
// requests to, by short id.
export function parseStructured(message, targets) {
  const text = message.trim()
  if (!text.startsWith("{") || !text.endsWith("}")) return null
  let object
  try { object = JSON.parse(text) } catch { return null }
  if (!object || typeof object !== "object" || Array.isArray(object)) return null

  const present = key => object[key] !== "" && object[key] !== null
  const fields = keys => keys.map(key => `${key}=${shown(object[key])}`).join(" ")
  const pretty = () => JSON.stringify(object, null, 2)

  if (isRequest(object)) {
    const hidden = fields(Object.keys(object).filter(key => !REQUEST_DRAWN.includes(key) && present(key)))
    return { segments: requestSegments(object, targets), hidden, pretty: pretty() }
  }

  const scalar = key => typeof object[key] === "string" || typeof object[key] === "number"
  const level = LEVEL_KEYS.find(scalar), said = MESSAGE_KEYS.find(scalar)
  const skip = new Set([ level, said, ...TIME_KEYS.filter(scalar) ])

  const segments = []
  if (level) {
    const value = object[level]
    const name = typeof value === "number" ? (NUMERIC_LEVELS[value] ?? String(value)) : value
    segments.push({ text: name.toUpperCase(), classes: [ "json-level", `json-level--${levelTone(name)}` ] })
  }
  if (said) segments.push({ text: (segments.length ? " " : "") + String(object[said]), classes: [ "json-message" ] })

  const keys = Object.keys(object).filter(key => !skip.has(key) && present(key))
  const rank = key => FIRST_KEYS.includes(key) ? FIRST_KEYS.indexOf(key) : FIRST_KEYS.length
  keys.sort((a, b) => rank(a) - rank(b))
  for (const key of keys.slice(0, INLINE_FIELDS)) {
    const tone = valueTone(key, object[key])
    segments.push({ text: (segments.length ? "  " : "") + key, classes: [ "json-key" ] })
    segments.push({ text: "=", classes: [ "json-key" ] })
    segments.push({ text: shown(object[key]).replace(CONTROLS, ""), classes: tone ? [ "json-value", tone ] : [ "json-value" ] })
  }
  const rest = keys.slice(INLINE_FIELDS)
  if (rest.length) segments.push({ text: `  +${rest.length} more`, classes: [ "json-more" ] })
  if (!segments.length) return null

  return { segments, hidden: fields(rest), pretty: pretty() }
}

// Any JSON value as text. A parsed object can hold its own "toString" key,
// which String() and template strings would call, and throw on.
const asText = value => value !== null && typeof value === "object" ? JSON.stringify(value) : String(value)

// A value as a key=value field shows it: strings bare unless they need quotes.
function shown(value) {
  if (typeof value === "string") return /[\s"=]/.test(value) ? JSON.stringify(value) : value
  return JSON.stringify(value)
}

function levelTone(level) {
  const word = String(level).toLowerCase()
  if (/^(err|error|fatal|panic|crit|critical|alert|emerg|emergency)/.test(word)) return "bad"
  if (/^warn/.test(word)) return "warn"
  if (/^(info|notice)/.test(word)) return "info"
  return "quiet"
}

function statusTone(status) {
  if (status >= 500) return "bad"
  if (status >= 400) return "warn"
  if (status >= 300) return "quiet"
  return "ok"
}

// An error field, and a 5xx or 4xx status field, stand out.
function valueTone(key, value) {
  if (key === "error" || key === "err") return "json-value--bad"
  if (key !== "status") return null

  const tone = statusTone(Number(asText(value)))
  return tone === "bad" || tone === "warn" ? `json-value--${tone}` : null
}

const isRequest = object => object.msg === "Request" && typeof object.status === "number" && typeof object.method === "string" && typeof object.path === "string"

function requestSegments(object, targets) {
  const segments = []
  const add = (text, ...classes) => { if (text) segments.push({ text: asText(text).replace(CONTROLS, ""), classes }) }
  add(String(object.status), "json-level", `json-level--${statusTone(object.status)}`)
  add(` ${object.method} `, "json-message")
  add(`${asText(object.host ?? "")}${object.path}`, "json-message")
  if (object.query) add("?…", "json-more")
  if (typeof object.duration === "number") add(`  ${took(object.duration)}`, "json-value")
  const container = answeredBy(object, targets)
  if (container) { add("  → ", "json-key"); add(container, "json-value") }

  const edge = typeof object.req_cf_ray === "string" ? object.req_cf_ray.split("-")[1] : null
  const from = [ object.req_cf_connecting_ip || object.remote_addr, object.req_cf_ipcountry, edge && `via ${edge}` ]
    .filter(Boolean).map(asText).join(" ")
  if (from) { add("  from ", "json-key"); add(from, "json-value") }
  return segments
}

// kamal-proxy logs nanoseconds.
function took(nanoseconds) {
  const milliseconds = nanoseconds / 1e6
  if (milliseconds < 10) return `${milliseconds.toFixed(1)} ms`
  if (milliseconds < 1000) return `${Math.round(milliseconds)} ms`
  return `${(milliseconds / 1000).toFixed(milliseconds < 10_000 ? 2 : 1)} s`
}

// The container's name for a target, "<short id>:<port>", when Meridian knows it.
function answeredBy(object, targets) {
  const target = typeof object.target === "string" ? object.target : ""
  const id = target.split(":")[0]
  return Object.hasOwn(targets, id) ? targets[id] : (target || object.service || "")
}
