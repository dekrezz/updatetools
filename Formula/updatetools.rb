# frozen_string_literal: true

# Homebrew formula for updatetools. This repository is also the tap:
#   brew tap dekrezz/updatetools https://github.com/dekrezz/updatetools
#   brew trust --formula dekrezz/updatetools/updatetools
#   brew install updatetools
#   brew install --HEAD updatetools
#
# Stable installs pin the tagged release tarball. --HEAD tracks main via git.
class Updatetools < Formula
  desc "Update everything updatable on this Mac"
  homepage "https://github.com/dekrezz/updatetools"
  url "https://github.com/dekrezz/updatetools/archive/refs/tags/2026.09.23.tar.gz"
  sha256 "71738d1cebc9b31fb80905ed54328698cacdc36213a7aa6f53df52ccc68564e9"
  license "Apache-2.0"
  head "https://github.com/dekrezz/updatetools.git", branch: "main"

  def install
    # Stamp the version so `updatetools --version` works outside a git
    # worktree. Stable installs get the release tag; HEAD installs get the
    # checkout revision. A Cellar copy is not a checkout.
    rev = if build.head?
      Utils.git_short_head
    else
      version.to_s
    end
    if rev.present?
      inreplace "updatetools", /^# UPDATETOOLS_REV=.*/, "# UPDATETOOLS_REV=#{rev}"
    end
    bin.install "updatetools"
  end

  test do
    assert_match "Usage", shell_output("#{bin}/updatetools --help")
    assert_match(/updatetools /, shell_output("#{bin}/updatetools --version"))
  end
end
