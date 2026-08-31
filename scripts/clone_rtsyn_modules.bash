#!/usr/bin/env bash
set -euo pipefail

owner="${RTSYN_GITHUB_OWNER:-seregioo}"
target_dir="${1:-$PWD}"

repos=(
  rtsyn
  rtsyn-abi
  rtsyn-adder
  rtsyn-api
  rtsyn-collection
  rtsyn-defaults
  rtsyn-engine
  rtsyn-forwarder
  rtsyn-measurement-tool
  rtsyn-mock
  rtsyn-module-device-comedi
  rtsyn-module-device-template
  rtsyn-module-generator
  rtsyn-module-loader
  rtsyn-module-plugin-template
  rtsyn-node
  rtsyn-port
  rtsyn-runtime
  rtsyn-spsc
  rtsyn-test-utils
  rtsyn-thread
  rtsyn-ui
  rtsyn-value
  rtsyn-xmake-repo
)

usage() {
  cat <<USAGE
Usage: $(basename "$0") [target-directory]

Clone or update all RTSyn repositories into target-directory.

Environment:
  RTSYN_GITHUB_OWNER  GitHub owner or organization. Default: seregioo
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mkdir -p "$target_dir"

for repo in "${repos[@]}"; do
  destination="$target_dir/$repo"
  url="https://github.com/$owner/$repo.git"

  if [[ -d "$destination/.git" ]]; then
    printf 'update %s at %s\n' "$repo" "$destination"
    git -C "$destination" fetch --prune
    git -C "$destination" pull --ff-only
    git -C "$destination" submodule update --init --recursive
    continue
  fi

  if [[ -e "$destination" ]]; then
    printf 'skip %s: path exists and is not a git checkout: %s\n' "$repo" "$destination" >&2
    continue
  fi

  printf 'clone %s -> %s\n' "$url" "$destination"
  git clone --recurse-submodules "$url" "$destination"
done
