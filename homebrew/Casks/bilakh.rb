cask "bilakh" do
  version "1.1.1"
  sha256 "94a4ad96650f395e21fcb112c4904621cce1442cfef9d4919feccdbeedbdf9b4"

  url "https://github.com/sorkila/bilakh/releases/download/v#{version}/Bilakh.dmg"
  name "Bilakh"
  desc "Cover your Mac screen while AI agents keep running"
  homepage "https://getbilakh.com"

  depends_on macos: :sonoma

  app "Bilakh.app"

  zap trash: [
    "~/Library/Preferences/com.eriknielsen.bilakh.plist",
  ]
end
