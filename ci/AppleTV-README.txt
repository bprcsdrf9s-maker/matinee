Matinee for Apple TV
====================

Install from your Mac with Xcode (free Apple ID; reinstall every 7 days):

1. On the Apple TV: Settings > Remotes and Devices > Remote App and Devices.
   Keep that screen open. The Mac and Apple TV must be on the same Wi-Fi.
2. On the Mac: open Matinee.xcodeproj in Xcode. Wait for "Resolving packages" to finish.
3. Xcode > Settings > Accounts: add your Apple ID if it isn't there.
4. Window > Devices and Simulators: your Apple TV appears under Discovered. Click Pair and
   enter the code shown on the TV.
5. In the toolbar, pick the "MatineeTV" scheme and your Apple TV as the destination.
6. Click the MatineeTV target > Signing & Capabilities > Team: pick "<your name> (Personal Team)".
   If the bundle identifier is taken, change "com.daniel.matinee.tv" to anything unique.
7. Press Run (Cmd+R). Matinee appears on the Apple TV home screen.

With a free Apple ID the app stops opening after 7 days. Repeat step 7 to renew it.
