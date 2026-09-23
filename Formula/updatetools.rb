# frozen_string_literal: true

# Homebrew formula for updatetools. This repository is also the tap:
#   brew tap dekrezz/updatetools https://github.com/dekrezz/updatetools
#   brew install --HEAD updatetools
#
# Head-only on purpose: there is no release tag yet, so a stable url/sha256
# of HEAD would rot on every commit. Install tracks main via git.
class Updatetools < Formula
  desc "Update everything updatable on this Mac"
  homepage "https://github.com/dekrezz/updatetools"
  head "https://github.com/dekrezz/updatetools.git", branch: "main"
  license "Apache-2.0"

  def install
    # Stamp the checkout revision so `updatetools --version` works outside a
    # git worktree (Homebrew Cellar installs are not a checkout).
    rev = Utils.git_short_head
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
