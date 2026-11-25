# A GitHub Actions self-hosted runner with Kamal, for the lab network.
FROM ubuntu:24.04
ARG RUNNER_VERSION=2.338.2
ARG KAMAL_VERSION=2.12.0
ENV DEBIAN_FRONTEND=noninteractive RUNNER_ALLOW_RUNASROOT=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq openssh-client ruby-full build-essential libyaml-dev sudo \
    && gem install kamal -v "$KAMAL_VERSION" --no-document \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /runner
RUN arch=$(uname -m | sed 's/aarch64/arm64/; s/x86_64/x64/') \
    && curl -fsSL "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz" | tar xz \
    && ./bin/installdependencies.sh >/dev/null
COPY entrypoint.sh /usr/local/bin/lab-runner
ENTRYPOINT ["/usr/local/bin/lab-runner"]
