# Homebrew cask for mikko. Lives in the tap repo Anemo-Studio/homebrew-tap as
# Casks/mikko.rb, so people install with:
#   brew install --cask anemo-studio/tap/mikko
# scripts/release.sh prints the version and sha256 to paste here for each release.
cask "mikko" do
  version "0.4.0"
  sha256 "507113d37411c871b5568b93a65832f592065d40dd5122b1d54540e5dfa816bf"

  url "https://github.com/Anemo-Studio/mikko-app/releases/download/v#{version}/mikko-#{version}.zip"
  name "mikko"
  desc "See and stop what your AI coding agents left running, and reclaim dev disk space"
  homepage "https://mikko.app"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "mikko.app"
  binary "#{appdir}/mikko.app/Contents/Helpers/mikko"

  zap trash: [
    "~/Library/Application Support/mikko",
    "~/Library/Preferences/app.mikko.Mikko.plist",
  ]
end
