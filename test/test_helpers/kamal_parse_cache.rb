# Parsing starts Kamal in a fresh Ruby process, about half a second a time,
# and most tests sync the same fixture repository in their setup. The same
# files always parse the same way, so each test process parses a set once and
# hands every later caller its own copy. Failures aren't kept: they raise anew.
module KamalParseCache
  RESULTS = {}

  def parse(files, entries)
    key = Digest::SHA256.hexdigest(Marshal.dump([ files.to_a.sort, entries ]))
    Marshal.load(RESULTS[key] ||= Marshal.dump(super))
  end
end

KamalConfig.singleton_class.prepend(KamalParseCache)
