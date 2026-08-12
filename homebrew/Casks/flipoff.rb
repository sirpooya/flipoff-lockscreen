cask "flipoff" do
  version "1.2.7"
  # sha256 of the release zip — recompute for whichever tag this points at
  # (`shasum -a 256 FlipOff-vX.Y.Z.zip`); left as :no_check until this cask is
  # actually wired into a CI step that fills it in per release.
  sha256 :no_check

  url "https://github.com/sirpooya/flipoff-lockscreen/releases/download/v#{version}/FlipOff-v#{version}.zip"
  name "FlipOff"
  desc "Menu-bar lock that baits snoops into thinking your Mac isn't locked"
  homepage "https://github.com/sirpooya/flipoff-lockscreen"

  depends_on macos: :sonoma

  app "FlipOff.app"

  zap trash: [
    "~/Library/Preferences/in.pooya.flipoff.plist",
  ]
end
