class Kb < Formula
  desc "Markdown knowledge base for humans and AI agents"
  homepage "https://github.com/LostWarrior/knowledge-base"
  url "https://github.com/LostWarrior/knowledge-base/releases/download/v0.1.1/kb-0.1.1.tar.gz"
  sha256 "dbf34ec774d4345892b1bb55ae4e17d6732c1f6da23fb7ba5ab0b0ea491ccc84"
  license "MIT"

  depends_on "bash"

  def install
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    system bin/"kb", "help"
  end
end
