#!/bin/sh
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
toolbin_dir="$(cd "$(dirname "$0")/../../../toolbin" && pwd)"
export PATH="$toolbin_dir:/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
exec /bin/sh /opt/homebrew/share/flutter/packages/flutter_tools/bin/xcode_backend.sh "$@"
