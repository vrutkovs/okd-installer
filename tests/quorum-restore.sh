#!/bin/bash
mkdir -p ~/.ssh || true
cp "${KUBE_SSH_KEY_PATH}" ~/.ssh/id_rsa
chmod 0600 ~/.ssh/id_rsa
if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

openshift-tests run-dr quorum-restore -o /tmp/artifacts/e2e.log --junit-dir /tmp/artifacts/junit
