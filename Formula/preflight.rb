class Preflight < Formula
  desc "iOS release-readiness preflight check (22 static analysis rules)"
  homepage "https://github.com/ersel95/ios-preflight-security"
  url "https://github.com/ersel95/ios-preflight-security/archive/refs/tags/v0.1.0.tar.gz"
  # `brew install ./Formula/preflight.rb` ile lokal denemek için sha256'yı boş
  # bırakabilirsin; release tarball'ı için aşağıdaki komutla doldur:
  #   curl -sL https://github.com/ersel95/ios-preflight-security/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
  sha256 "REPLACE_AFTER_FIRST_RELEASE"
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
