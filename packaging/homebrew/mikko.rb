# Homebrew cask for mikko. Lives in the tap repo Anemo-Studio/homebrew-tap as
# Casks/mikko.rb, so people install with:
#   brew install --cask anemo-studio/tap/mikko
# scripts/release.sh prints the version and sha256 to paste here for each release.
cask "mikko" do
  version "0.2.1"
  sha256 "9516ccba93552f5e1d826f638f36691551019b5485442cacf52b793813bd1276"

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
