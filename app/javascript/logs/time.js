// Docker's RFC3339Nano as a sortable number: milliseconds, plus the digits
// below a millisecond as a fraction of one. null when it isn't a timestamp.
const TIMESTAMP = /^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$/

export function parseTime(text) {
  const match = TIMESTAMP.exec(text)
  if (!match) return null

  const fraction = (match[2] ?? "").padEnd(3, "0")
  const milliseconds = Date.parse(`${match[1]}.${fraction.slice(0, 3)}${match[3]}`)
  return Number.isNaN(milliseconds) ? null : milliseconds + Number(`0.${fraction.slice(3) || "0"}`)
}

const pad = (number, width = 2) => String(number).padStart(width, "0")

// HH:MM:SS.mmm in the reader's time zone.
export function clock(milliseconds) {
  const time = new Date(milliseconds)
  return `${pad(time.getHours())}:${pad(time.getMinutes())}:${pad(time.getSeconds())}.${pad(time.getMilliseconds(), 3)}`
}
