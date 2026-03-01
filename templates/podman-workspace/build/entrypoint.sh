#!/bin/bash
set -e

TARGET_USER="${CODER_USERNAME:-coder}"
TARGET_HOME="/home/$TARGET_USER"

if [ "$TARGET_USER" != "coder" ] && id coder &>/dev/null; then
  usermod -l "$TARGET_USER" coder
  groupmod -n "$TARGET_USER" coder
  usermod -d "$TARGET_HOME" "$TARGET_USER"

  # Seed PVC with skeleton home content on first run
  if [ -d "/home/coder" ] && [ ! -f "$TARGET_HOME/.bashrc" ]; then
    cp -a /home/coder/. "$TARGET_HOME/" 2>/dev/null || true
  fi
  rm -rf /home/coder

  chown -R "$TARGET_USER":"$TARGET_USER" "$TARGET_HOME"

  if [ -f /etc/sudoers.d/coder ]; then
    sed -i "s/coder/$TARGET_USER/g" /etc/sudoers.d/coder
    mv /etc/sudoers.d/coder "/etc/sudoers.d/$TARGET_USER" 2>/dev/null || true
  fi
else
  # Ensure home ownership even when username is already "coder"
  chown -R coder:coder "$TARGET_HOME" 2>/dev/null || true
fi

export HOME="$TARGET_HOME"

# Ensure rootless Podman user namespace mappings exist after user rename.
if ! grep -q "^${TARGET_USER}:" /etc/subuid 2>/dev/null; then
  echo "${TARGET_USER}:100000:65536" >> /etc/subuid
fi
if ! grep -q "^${TARGET_USER}:" /etc/subgid 2>/dev/null; then
  echo "${TARGET_USER}:100000:65536" >> /etc/subgid
fi

exec runuser -u "$TARGET_USER" -- "$@"
