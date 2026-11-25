# A "server": sshd plus its own Docker daemon, for Kamal to deploy to.
FROM docker:27-dind
RUN apk add --no-cache --upgrade openssh openssh-client-common bash curl && (passwd -u root 2>/dev/null || sed -i 's/^root:!/root:*/' /etc/shadow 2>/dev/null || true)
COPY entrypoint.sh /usr/local/bin/lab-server
ENTRYPOINT ["/usr/local/bin/lab-server"]
