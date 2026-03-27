class Kb < Formula
  desc "Markdown knowledge base for humans and AI agents"
  homepage "https://github.com/LostWarrior/knowledge-base"
  url "https://github.com/LostWarrior/knowledge-base/releases/download/v0.1.0/kb-0.1.0.tar.gz"
  sha256 "b0cb09e20cc8cd199e6c3ae2b23ffb664b01228e22ca36599c8da01d388d18f4"
  license "MIT"

  depends_on "bash"

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    system bin/"kb", "help"
  end
end
