#!/usr/bin/env bash
set -eu
# Expand the Windows HID path inside Bash, avoiding native MSYS argv globbing.
: "${ROAMING_SSH_FIDO_DEVICE:?Missing selected USB device}"
exec /usr/bin/ssh-keygen -O "device=$ROAMING_SSH_FIDO_DEVICE" "$@"
