# Writes public/{400,404,406-unsupported-browser,422,500}.html: static pages
# Rails serves when it can't render one of its own, and public/error-pages.css.
# No JavaScript, light and dark, and fine in old browsers. The styles are a
# file of their own, not a <style>: Rails renders the 406 page from a
# controller, under a CSP that blocks inline styles.
#
#   ruby script/error_pages.rb
PAGES = {
  "400" => [ "Bad request", "The request didn't make sense to Meridian. Go back and try again." ],
  "404" => [ "Not found", "Nothing lives at this address. It may have moved, or it was removed." ],
  "406-unsupported-browser" => [ "Browser too old", "Meridian needs a current version of Chrome, Edge, Firefox or Safari." ],
  "422" => [ "Change rejected", "Meridian couldn't accept that change, often because the page was open too long. Reload it and try again." ],
  "500" => [ "Something went wrong", "Meridian hit an error it didn't expect and has logged it. Try again in a moment." ]
}.freeze

LOGO = '<svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" aria-hidden="true">' \
  '<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><path d="m4.5 15.5 15-7"/></svg>'.freeze

CSS = <<~CSS
  :root { color-scheme: light dark; --canvas: #fafafa; --card: #fff; --ink: #18181b; --muted: #52525b; --line: #e4e4e7; --accent: #4338ca; --on-accent: #fff; }
  @media (prefers-color-scheme: dark) { :root { --canvas: #111113; --card: #09090b; --ink: #f4f4f5; --muted: #a1a1aa; --line: #27272a; --accent: #818cf8; --on-accent: #1e1b4b; } }
  * { box-sizing: border-box; }
  body { display: grid; place-items: center; min-height: 100svh; margin: 0; padding: 1rem; background: var(--canvas); color: var(--ink); font: 14px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { width: 100%; max-width: 26rem; display: flex; flex-direction: column; gap: 1.5rem; }
  .brand { display: flex; align-items: center; justify-content: center; gap: .5rem; color: var(--ink); font-size: 1.125rem; font-weight: 600; text-decoration: none; }
  .brand svg { color: var(--accent); }
  .card { padding: 1.5rem; border: 1px solid var(--line); border-radius: 8px; background: var(--card); }
  .code { margin: 0 0 .25rem; font: 500 12px ui-monospace, "SF Mono", Menlo, monospace; color: var(--muted); }
  h1 { margin: 0 0 .5rem; font-size: 1.125rem; letter-spacing: -.01em; }
  p { margin: 0; color: var(--muted); }
  a.home { display: inline-flex; align-items: center; height: 2rem; margin-top: 1.25rem; padding: 0 .75rem; border-radius: 6px; background: var(--accent); color: var(--on-accent); font-weight: 500; text-decoration: none; }
CSS

File.write(File.expand_path("../public/error-pages.css", __dir__), CSS)
puts "public/error-pages.css"

PAGES.each do |file, (title, message)|
  code = file.to_i
  File.write(File.expand_path("../public/#{file}.html", __dir__), <<~HTML)
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta name="robots" content="noindex">
        <title>#{title} (#{code}) · Meridian</title>
        <link rel="icon" href="/icon.svg" type="image/svg+xml">
        <link rel="stylesheet" href="/error-pages.css">
      </head>
      <body>
        <main>
          <a class="brand" href="/">#{LOGO} Meridian</a>
          <div class="card">
            <p class="code">#{code}</p>
            <h1>#{title}</h1>
            <p>#{message}</p>
            <a class="home" href="/">Back to the board</a>
          </div>
        </main>
      </body>
    </html>
  HTML
  puts "public/#{file}.html"
end
