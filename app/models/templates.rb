# Files under templates/ with %{name} placeholders. Plain substitution, so the
# shell and YAML inside them never need escaping.
module Templates
  def self.render(name, **vars)
    Rails.root.join("templates", name).read.gsub(/%\{(\w+)\}/) { vars.fetch(Regexp.last_match(1).to_sym) }
  end
end
