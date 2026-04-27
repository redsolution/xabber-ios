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
source 'https://github.com/webrtc-sdk/Specs.git'

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

def patch_devices_ocra_authentication(installer)
    ocra_header = installer.sandbox.root + 'XMPPFramework/Authentication/Devices-OCRA/DevicesOCRAAuthentication.h'
    ocra_implementation = installer.sandbox.root + 'XMPPFramework/Authentication/Devices-OCRA/DevicesOCRAAuthentication.m'
    return unless File.exist?(ocra_header) && File.exist?(ocra_implementation)

    File.chmod(0644, ocra_header)
    header = File.read(ocra_header)
    unless header.include?('hotpStringForTruncatedHash')
        marker = "- (NSString *)generateClientChallenge;\n"
        replacement = "#{marker}\n+ (NSString *)hotpStringForTruncatedHash:(uint32_t)truncatedHash digits:(NSInteger)digits;\n"
        raise 'Unable to patch DevicesOCRAAuthentication.h' unless header.include?(marker)
        File.write(ocra_header, header.sub(marker, replacement))
    end

    File.chmod(0644, ocra_implementation)
    implementation = File.read(ocra_implementation)
    unless implementation.include?('+ (NSString *)hotpStringForTruncatedHash:(uint32_t)truncatedHash digits:(NSInteger)digits')
        marker = <<~OBJC
            + (NSString *)mechanismName
            {
                return @"DEVICES-OCRA";
            }
        OBJC
        formatter = <<~OBJC

            + (NSString *)hotpStringForTruncatedHash:(uint32_t)truncatedHash digits:(NSInteger)digits
            {
                if (digits <= 0) {
                    return [NSString stringWithFormat:@"%u", truncatedHash];
                }

                NSUInteger modulus = 1;
                for (NSInteger index = 0; index < digits; index++) {
                    modulus *= 10;
                }

                NSUInteger pinValue = truncatedHash % modulus;
                return [NSString stringWithFormat:@"%0*lu", (int)digits, (unsigned long)pinValue];
            }
        OBJC
        raise 'Unable to patch DevicesOCRAAuthentication.m formatter' unless implementation.include?(marker)
        implementation = implementation.sub(marker, marker + formatter)
    end

    client_old = <<~OBJC
                unsigned long pinValue = truncatedHash % ((unsigned int)pow(10, clHotpLength));
                NSString *payload;
                if (clHotpLength == 4)
                {
                    payload = [NSString stringWithFormat:@"%04lu", pinValue];
                }
                else if (clHotpLength == 6)
                {
                    payload = [NSString stringWithFormat:@"%06lu", pinValue];
                }
                else if (clHotpLength == 8)
                {
                    payload = [NSString stringWithFormat:@"%08lu", pinValue];
                } else
                {
                    payload = [NSString stringWithFormat:@"%u", pinValue];
                }
    OBJC
    client_new = "            NSString *payload = [DevicesOCRA hotpStringForTruncatedHash:truncatedHash digits:clHotpLength];\n"
    implementation = implementation.sub(client_old, client_new)

    response_old = <<~OBJC
                unsigned long pinValue = truncatedHash % ((unsigned int)pow(10, hashLength));
                NSString *payload;
                if (hashLength == 4)
                {
                    payload = [NSString stringWithFormat:@"%04lu", pinValue];
                }
                else if (hashLength == 6)
                {
                    payload = [NSString stringWithFormat:@"%06lu", pinValue];
                }
                else if (hashLength == 8)
                {
                    payload = [NSString stringWithFormat:@"%08lu", pinValue];
                } else
                {
                    payload = [NSString stringWithFormat:@"%u", pinValue];
                }
    OBJC
    response_new = "            NSString *payload = [DevicesOCRA hotpStringForTruncatedHash:truncatedHash digits:hotpLength];\n"
    implementation = implementation.sub(response_old, response_new)

    unless implementation.include?('digits:clHotpLength') && implementation.include?('digits:hotpLength')
        raise 'Unable to patch DevicesOCRAAuthentication.m HOTP digit formatting'
    end

    File.write(ocra_implementation, implementation)
end

# to silence warning in comments in XMPPFramework
post_install do |installer|
    patch_devices_ocra_authentication(installer)
    installer.pods_project.targets.each do |target|
        puts target.name
        target.build_configurations.each do |config|
            config.build_settings['CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF'] = 'NO'
        config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
        end
    end
end
