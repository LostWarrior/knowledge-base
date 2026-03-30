#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <version> <sha256>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FORMULA_PATH="${REPO_ROOT}/Formula/kb.rb"

version="$1"
sha256="$2"

cat > "${FORMULA_PATH}" <<EOF
class Kb < Formula
  desc "Markdown knowledge base for humans and AI agents"
  homepage "https://github.com/LostWarrior/knowledge-base"
  url "https://github.com/LostWarrior/knowledge-base/releases/download/v${version}/kb-${version}.tar.gz"
  sha256 "${sha256}"
  license "AGPL-3.0-only"

  depends_on "bash"

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    system bin/"kb", "help"
  end
end
EOF
