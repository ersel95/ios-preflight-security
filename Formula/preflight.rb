class Preflight < Formula
  desc "iOS release-readiness preflight check (22 static analysis rules)"
  homepage "https://github.com/ersel95/ios-preflight-security"
  url "https://github.com/ersel95/ios-preflight-security/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "079132f15b89aac3a9c96cbf58b94d4d0d008c6a363ca8eebdbbe3cd3d8c2633"
  license "MIT"
  version "0.1.0"

  depends_on "python@3.12"
  depends_on "ripgrep" => :recommended

  def install
    libexec.install Dir["lib/*"]
    bin.install "bin/preflight"
  end

  test do
    assert_match "preflight", shell_output("#{bin}/preflight --version")
    assert_match "doctor", shell_output("#{bin}/preflight --help")
  end
end
