class Kb < Formula
  desc "Markdown knowledge base for humans and AI agents"
  homepage "https://github.com/LostWarrior/knowledge-base"
  url "https://github.com/LostWarrior/knowledge-base/releases/download/v0.1.0/kb-0.1.0.tar.gz"
  sha256 "917ba565767d62fb3d891bd667d376bdbe23ba551c1bd23e3bd4f5e928f6ffec"
  license "MIT"

  depends_on "bash"

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    system bin/"kb", "help"
  end
end
