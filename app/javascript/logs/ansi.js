// A log message as runs of text, [{ text, classes }], ready to draw as text
// nodes. Log text comes from containers, so it only ever reaches the page as
// text, never as markup.

// Control characters, other than tab and newline, are cut from whatever is drawn.
export const CONTROLS = /[\x00-\x08\x0b-\x1f\x7f]/g

// The classes of an unstyled run, shared so plain lines allocate nothing.
export const PLAIN = Object.freeze([])

// ANSI, as the agent passes it through. SGR colours and styles become
// classes; every other escape sequence (cursor moves, OSC titles…) is cut.
const ESCAPE = /\x1b(?:\[([0-?]*)[ -/]*([@-~])|\][^\x07\x1b]*(?:\x07|\x1b\\)?|[@-Z\\-_]|[\s\S]?)/g
const RESET = Object.freeze({ color: null, bold: false, dim: false, italic: false, underline: false })

const isColor = code => (code >= 30 && code <= 37) || (code >= 90 && code <= 97)

function applySgr(style, params) {
  const codes = params === "" ? [ 0 ] : params.split(";").map(code => code === "" ? 0 : Number(code))
  const next = { ...style }

  for (let index = 0; index < codes.length; index++) {
    const code = codes[index]
    if (code === 0) Object.assign(next, RESET)
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
  return classes.length ? classes : PLAIN
}

export function parseAnsi(message) {
  if (!message.includes("\x1b")) return [ { text: message.replace(CONTROLS, ""), classes: PLAIN } ]

  const segments = []
  let style = RESET
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
