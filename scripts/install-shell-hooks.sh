#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_HOOK="$PROJECT_DIR/scripts/terminal-grid-hooks.zsh"
TARGET_HOOK="$HOME/.terminal-grid-menubar-hooks.zsh"
ZSHRC="$HOME/.zshrc"

cp "$SOURCE_HOOK" "$TARGET_HOOK"

START_MARK="# >>> terminal-grid-menubar hooks >>>"
END_MARK="# <<< terminal-grid-menubar hooks <<<"

if [[ ! -f "$ZSHRC" ]]; then
  touch "$ZSHRC"
fi

if ! grep -Fq "$START_MARK" "$ZSHRC"; then
  cat >> "$ZSHRC" <<EOF_BLOCK

$START_MARK
if [ -f "$TARGET_HOOK" ]; then
  source "$TARGET_HOOK"
fi
$END_MARK
EOF_BLOCK
fi

echo "Installed shell hooks to: $TARGET_HOOK"
echo "Updated: $ZSHRC"
