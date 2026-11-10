#!/usr/bin/env bash
# Compiles the runtime's Foundation-only Swift with test/swift/main.swift and
# runs it. macOS only; needs Xcode's command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
src=darwin/assistant_actions/Sources/assistant_actions
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
swiftc -module-name assistant_actions -o "$out/tests" \
  "$src/AssistantValues.swift" "$src/AssistantInbox.swift" "$src/AssistantSnapshot.swift" "$src/AssistantQuery.swift" "$src/AssistantSpotlight.swift" "$src/AssistantMatch.swift" \
  "$src/AssistantComparison.swift" "$src/AssistantRichValues.swift" "$src/AssistantHostCalls.swift" \
  "$src/AssistantReply.swift" "$src/AssistantDialog.swift" "$src/AssistantInteraction.swift" \
  "$src/AssistantCardView.swift" \
  "$src/AssistantActivityAttributes.swift" "$src/AssistantLiveActivities.swift" \
  test/swift/main.swift
"$out/tests"
