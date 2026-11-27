# Run using bin/ci. Every check that must pass before a change lands.

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  step "Tests: Rails", "bin/rails test"

  step "Agent: vet", "cd agent && go vet ./..."
  step "Agent: staticcheck", "cd agent && $(go env GOPATH)/bin/staticcheck ./..."
  step "Agent: test", "cd agent && go test -race ./..."
end
