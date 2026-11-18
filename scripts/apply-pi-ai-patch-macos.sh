#!/usr/bin/env bash
set -euo pipefail

# macOS adaptation of apply-pi-ai-patch.sh.
# Differences from the Ubuntu script:
#   - runs as any user (no `dsh` account check); the Ubuntu host uses the `dsh`
#     user, this Mac uses the login user (macai0).
#   - resolves the pi-ai copies dynamically instead of hardcoding three ROOTs.
#     On this Mac layout (docs/11-macos-host-install.md) in-box bundles such as
#     `@deepseek-ai/dsh-base` and `@deepseek-ai/dsh-web-app` always load from the
#     dsh installation, so `@earendil-works/pi-ai` exists only once under
#     `$HOME/apps/harness`. The Ubuntu layout has one copy per profile because
#     each profile installs its own bundle tree. Scanning for the file covers
#     both layouts.

CHECK_ONLY=0
if [[ ${1:-} == "--check" ]]; then
  CHECK_ONLY=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

ROOTS=(
  "$HOME/apps/harness"
  "$HOME/.dsh/profiles/web"
  "$HOME/.dsh/profiles/dsh-tui"
)

need_patch=0
targets=()

found_any=0
for root in "${ROOTS[@]}"; do
  file="$root/node_modules/@earendil-works/pi-ai/dist/api/openai-completions.js"
  if [[ ! -f $file ]]; then
    continue
  fi
  found_any=1
  if grep -q 'Array.isArray(choice.delta.content)' "$file"; then
    echo "PATCHED: $file"
  else
    echo "NOT_PATCHED: $file"
    targets+=("$file")
    need_patch=1
  fi
done

if (( ! found_any )); then
  echo "error: no pi-ai copy found under any known root; check the harness install" >&2
  exit 1
fi

if (( CHECK_ONLY )); then
  if (( need_patch )); then
    exit 1
  fi
  exit 0
fi

if (( ! need_patch )); then
  echo "All pi-ai copies are already patched."
  exit 0
fi

python3 - "${targets[@]}" <<'PY'
from pathlib import Path
import sys

needle = """                    if (choice.delta.content !== null &&
                        choice.delta.content !== undefined &&
                        choice.delta.content.length > 0) {"""

patch = """                    if (Array.isArray(choice.delta.content)) {
                        const thinkingText = choice.delta.content
                            .filter((block) => block?.type === "thinking")
                            .map((block) => Array.isArray(block?.thinking)
                                ? block.thinking.map((part) => typeof part?.text === "string" ? part.text : "").join("")
                                : "")
                            .join("");
                        const textText = choice.delta.content
                            .filter((block) => block?.type === "text")
                            .map((block) => typeof block?.text === "string" ? block.text : "")
                            .join("");
                        if (thinkingText.length > 0) choice.delta.reasoning_content = (choice.delta.reasoning_content ?? "") + thinkingText;
                        choice.delta.content = textText;
                    }
                    if (choice.delta.content !== null &&
                        choice.delta.content !== undefined &&
                        choice.delta.content.length > 0) {"""

for name in sys.argv[1:]:
    path = Path(name)
    source = path.read_text()
    if "Array.isArray(choice.delta.content)" in source:
        print(f"already patched: {path}")
        continue
    if needle not in source:
        raise SystemExit(f"needle not found; pi-ai structure changed: {path}")
    backup = path.with_suffix(path.suffix + ".orig")
    if not backup.exists():
        backup.write_text(source)
    path.write_text(source.replace(needle, patch, 1))
    print(f"patched: {path}")
PY

for file in "${targets[@]}"; do
  node --check "$file"
done

echo "pi-ai compatibility patch applied."
