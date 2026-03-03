##
##
##
##  This program is free software; you can redistribute it and/or
##  modify it under the terms of the GNU General Public License as
##  published by the Free Software Foundation; either version 3 of the
##  License.
##
##  This program is distributed in the hope that it will be useful,
##  but WITHOUT ANY WARRANTY; without even the implied warranty of
##  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
##  General Public License for more details.
##
##  You should have received a copy of the GNU General Public License along
##  with this program; if not, write to the Free Software Foundation, Inc.,
##  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
##
##
##
source 'https://cdn.cocoapods.org'
source 'https://github.com/webrtc-sdk/Specs.git'   # only if using WebRTC-SDK

platform :ios, '15.0'

use_frameworks!

def main_pods
    pod 'Alamofire'
    pod 'RealmSwift', :git => 'https://github.com/realm/realm-swift.git', :tag => 'v10.46.0'
    pod 'RxSwift'
    pod 'RxCocoa'
    pod 'RxRealm', :git => 'https://github.com/redsolution/RxRealm.git', :branch => 'update_podspec'
    pod 'CryptoSwift', :git => 'https://github.com/krzyzanowskim/CryptoSwift.git', :tag => '1.8.1'
    pod 'SwiftKeychainWrapper'
    pod 'Kingfisher', :git => 'https://github.com/redsolution/Klingfisher.git'
    pod 'Cache', :git => 'https://github.com/hyperoslo/Cache.git', :branch => 'master', :tag => '7.4.0'
    pod 'MaterialComponents/Palettes'
#    pod 'GoogleWebRTC'
    pod 'WebRTC-SDK'#, '~137.7151.12'
    pod 'LetterAvatarKit', '=1.2.3'
    pod 'DeepDiff'
    pod 'Punycode'
#    pod 'XMPPFramework/Swift', :path => '/Users/igor.boldin/projects/xabber/deps/XMPPFramework/'
    pod 'XMPPFramework/Swift', :git => 'https://github.com/redsolution/XMPPFramework', :branch => 'light'
    pod 'CocoaAsyncSocket', :git => 'https://github.com/robbiehanson/CocoaAsyncSocket', :branch => 'master'
    pod 'OpenSSL-Universal'
    pod 'Curve25519Kit', :git => 'https://github.com/redsolution/Curve25519Kit.git', :branch => 'mkirk/framework-friendly'
    pod 'SignalProtocolObjC', :git => 'https://github.com/redsolution/SignalProtocol-ObjC.git', :branch => 'master'
    pod 'YubiKit', :git => 'https://github.com/Yubico/yubikit-ios.git'
    
end


# to use pods in app target
target 'xabber' do
    main_pods
end

target 'xabberTests' do
    main_pods
end

target 'xabber-push-extension' do
    inherit! :search_paths
    pod 'SwiftKeychainWrapper'
    pod 'KissXML'
    pod 'CryptoSwift', :git => 'https://github.com/krzyzanowskim/CryptoSwift.git', :tag => '1.8.1'
    pod 'Curve25519Kit', :git => 'https://github.com/redsolution/Curve25519Kit.git', :branch => 'mkirk/framework-friendly'
end

# to silence warning in comments in XMPPFramework
post_install do |installer|
    installer.pods_project.targets.each do |target|
        puts target.name
        target.build_configurations.each do |config|
            config.build_settings['CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF'] = 'NO'
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
        end
    end
end
