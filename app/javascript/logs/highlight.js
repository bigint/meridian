// The filter's matches in a line, drawn as <mark>s over its runs of text.

const MAX_MARKS = 200 // highlights drawn in one line

// Lower case that never changes a text's length, so match offsets from the
// lower-cased copy still point into the original.
export function lowerOf(text) {
  const lower = text.toLowerCase()
  if (lower.length === text.length) return lower
  return Array.from(text, character => { const small = character.toLowerCase(); return small.length === character.length ? small : character }).join("")
}

// [from, to) offsets of each match of an already lower-cased query.
export function matchRanges(lower, query) {
  const ranges = []
  for (let from = lower.indexOf(query); from !== -1 && ranges.length < MAX_MARKS; from = lower.indexOf(query, from + query.length)) {
    ranges.push([ from, from + query.length ])
  }
  return ranges
}

// Replaces container's children with the segments, each styled run a <span>,
// and the parts inside ranges (offsets into the segments' joined text) as
// <mark>s. Ranges past the end of the text draw nothing.
export function drawText(container, segments, ranges) {
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
