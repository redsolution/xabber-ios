# xabber-ios
Open source XMPP client for iOS is not publicly released yet, and is in alpha-testing stage. Testers are welcome, email us **info@xabber.com**

This repository does not contain issues so far, and is necessary for beta-testers to leave feedback. Please restrain yourself from feature requests (OMEMO folks, we're looking at you), we know what we need to do. Goal of this beta testing stage is to establish reliable message delivery to iOS without disclosing message contents to third party.

More information on known issues and on joining BetaTesting is in [wiki](../../wiki)


### Quick build instructions (for beta testers)

**Prerequisites:** macOS with recent Xcode (15.0+ recommended), CocoaPods 1.12+

**Steps:**

1. Clone: `git clone git@github.com:redsolution/xabber-ios.git`
2. Install:  
   `cd xabber-ios && pod install`
3. Build: `open xabber.xcworkspace`  
   → In Xcode select signing team and run on simulator/device
