#!/bin/sh
# Build Elite Force for iPhone and iPad and assemble "Elite Force.app".
#
#   ios/make-app.sh                       Simulator build  -> dist/ios-sim/Elite Force.app (ad-hoc signed)
#   SDK=iphoneos ios/make-app.sh          device build     -> dist/ios/Elite Force.app
#
# Device builds are signed with an "Apple Development" identity and a development
# provisioning profile that matches BUNDLE_ID (an app-specific one or the team's "*"
# wildcard profile Xcode makes). Override with SIGN_IDENTITY=<sha1 or name> and
# PROFILE=<path to .mobileprovision>.
#
#   NO_BUILD=1     re-bundle the existing build outputs only
#   INSTALL=<udid> also install on that device (devicectl) or booted Simulator ("booted")
#
# Needs Xcode, cmake, ninja and pkg-config; ios/build-deps.sh is run when its output is missing.
set -eu

SDK="${SDK:-iphonesimulator}"
MIN_IOS="${MIN_IOS:-15.0}"
APP_NAME="${APP_NAME:-Elite Force}"
BUNDLE_ID="${BUNDLE_ID:-org.voyagersp.ios}"
VERSION="${VERSION:-1.5.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
JOBS="$(sysctl -n hw.ncpu)"
case "$SDK" in
	iphonesimulator) TAG=sim; OUTDIR="$ROOT/dist/ios-sim"; PLATFORM=iPhoneSimulator ;;
	iphoneos) TAG=dev; OUTDIR="$ROOT/dist/ios"; PLATFORM=iPhoneOS ;;
	*) echo "SDK must be iphonesimulator or iphoneos" >&2; exit 1 ;;
esac
DEPS="$ROOT/build-ios-deps/$SDK/install"
GAME_BUILD="$ROOT/build-ios/$TAG/efgame"
ENGINE_BUILD="$ROOT/build-ios/$TAG/engine"
APP="$OUTDIR/$APP_NAME.app"

ios_cmake() {
	cmake -G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" \
		-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_FIND_ROOT_PATH="$DEPS" "$@"
}

if [ -z "${NO_BUILD:-}" ]; then
	[ -f "$DEPS/lib/libSDL2.dylib" ] && [ -d "$DEPS/Frameworks/MoltenVK.framework" ] ||
		SDK="$SDK" MIN_IOS="$MIN_IOS" "$ROOT/ios/build-deps.sh"
	ios_cmake -S "$ROOT/efgame" -B "$GAME_BUILD"
	cmake --build "$GAME_BUILD" -j"$JOBS"
	ios_cmake -S "$ROOT/EFAndroid-SP/app/jni/engine" -B "$ENGINE_BUILD" \
		-DEF_DEPS_PREFIX="$DEPS" -DEF_FFMPEG_PREFIX="$DEPS" -DEF_APP_VERSION="$VERSION"
	cmake --build "$ENGINE_BUILD" -j"$JOBS"
fi

ENGINE="$ENGINE_BUILD/efsp.app/efsp"
[ -f "$ENGINE" ] || ENGINE="$ENGINE_BUILD/efsp"

echo "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Frameworks" "$APP/baseEF" "$APP/cmod"
cp "$ENGINE" "$APP/$APP_NAME"
cp "$GAME_BUILD/libefgame.dylib" "$GAME_BUILD/libefui.dylib" "$APP/Frameworks/"
# the bundled libraries, under the install names the engine was linked against
for lib in $(otool -L "$ENGINE" | awk '/@rpath\//{print $1}' | sed 's|@rpath/||'); do
	case "$lib" in
		*.framework/*) ;;
		*) cp -L "$DEPS/lib/$lib" "$APP/Frameworks/$lib" ;;
	esac
done
# FFmpeg's libraries link each other by install name too
for f in "$APP/Frameworks/"libav*.dylib "$APP/Frameworks/"libsw*.dylib; do
	for lib in $(otool -L "$f" | awk 'NR>1 && /@rpath\//{print $1}' | sed 's|@rpath/||'); do
		[ -f "$APP/Frameworks/$lib" ] || cp -L "$DEPS/lib/$lib" "$APP/Frameworks/$lib"
	done
done
cp -R "$DEPS/Frameworks/MoltenVK.framework" "$APP/Frameworks/"
cp "$ROOT/ios/baseEF/"*.cfg "$APP/baseEF/"
CMOD="$(ls "$ROOT"/macos/cmod/pakcmod-release-*.pk3 2>/dev/null | sort | tail -1 || true)"
if [ -n "$CMOD" ]; then
	cp "$CMOD" "$APP/cmod/"
	echo "cMod game modules: $(basename "$CMOD")"
fi
mkdir -p "$APP/licenses"
cp "$ROOT/LICENSE" "$APP/licenses/AwayTeamEF-LICENSE.txt"
cp "$DEPS/MoltenVK-LICENSE" "$APP/licenses/MoltenVK-LICENSE.txt"
cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP/licenses/"

# nothing may point outside the bundle or the system
bad=0
for f in "$APP/$APP_NAME" "$APP/Frameworks/"*.dylib; do
	if otool -L "$f" | awk 'NR>1{print $1}' | grep -v -E '^(@rpath/|@loader_path/|@executable_path/|/usr/lib/|/System/)'; then
		echo "error: $f links outside the bundle" >&2; bad=1
	fi
done
[ $bad = 0 ] || exit 1

# ---- app icon (asset catalog with the single 1024 px icon) ----
ICONWORK="$ROOT/build-ios/$TAG/icon"
rm -rf "$ICONWORK" && mkdir -p "$ICONWORK/Assets.xcassets/AppIcon.appiconset"
cp "$ROOT/ios/AppIcon-1024.png" "$ICONWORK/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
cat > "$ICONWORK/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'EOF'
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
EOF
printf '{ "info" : { "author" : "xcode", "version" : 1 } }\n' > "$ICONWORK/Assets.xcassets/Contents.json"
xcrun actool "$ICONWORK/Assets.xcassets" --compile "$APP" --platform "$SDK" \
	--minimum-deployment-target "$MIN_IOS" --app-icon AppIcon \
	--target-device iphone --target-device ipad \
	--output-partial-info-plist "$ICONWORK/partial.plist" >/dev/null

# ---- Info.plist ----
PLIST="$APP/Info.plist"
SDKVER="$(xcrun --sdk "$SDK" --show-sdk-version)"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$PLATFORM</string></array>
	<key>DTPlatformName</key><string>$SDK</string>
	<key>DTPlatformVersion</key><string>$SDKVER</string>
	<key>DTSDKName</key><string>$SDK$SDKVER</string>
	<key>MinimumOSVersion</key><string>$MIN_IOS</string>
	<key>LSRequiresIPhoneOS</key><true/>
	<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
	<key>UIRequiredDeviceCapabilities</key><array><string>arm64</string><string>metal</string></array>
	<key>UILaunchScreen</key><dict><key>UIColorName</key><string></string></dict>
	<key>UIStatusBarHidden</key><true/>
	<key>UIViewControllerBasedStatusBarAppearance</key><true/>
	<key>UIRequiresFullScreen</key><true/>
	<key>UISupportedInterfaceOrientations</key>
	<array><string>UIInterfaceOrientationLandscapeRight</string><string>UIInterfaceOrientationLandscapeLeft</string></array>
	<key>UISupportedInterfaceOrientations~ipad</key>
	<array><string>UIInterfaceOrientationLandscapeRight</string><string>UIInterfaceOrientationLandscapeLeft</string></array>
	<key>UIApplicationSupportsIndirectInputEvents</key><true/>
	<key>UIApplicationSceneManifest</key>
	<dict>
		<key>UIApplicationSupportsMultipleScenes</key><false/>
		<key>UISceneConfigurations</key>
		<dict>
			<key>UIWindowSceneSessionRoleApplication</key>
			<array><dict>
				<key>UISceneConfigurationName</key><string>Default</string>
				<key>UISceneDelegateClassName</key><string>IOSSceneDelegate</string>
			</dict></array>
		</dict>
	</dict>
	<key>UIFileSharingEnabled</key><true/>
	<key>LSSupportsOpeningDocumentsInPlace</key><true/>
	<key>GCSupportsControllerUserInteraction</key><true/>
	<key>GCSupportedGameControllers</key>
	<array><dict><key>ProfileName</key><string>ExtendedGamepad</string></dict></array>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Holomatch looks for game servers and players on your local network.</string>
	<key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
EOF
# the icon keys actool wrote (CFBundleIcons, CFBundleIcons~ipad)
/usr/libexec/PlistBuddy -c "Merge $ICONWORK/partial.plist" "$PLIST" >/dev/null
plutil -lint "$PLIST" >/dev/null
printf 'APPL????' > "$APP/PkgInfo"

# ---- signing ----
if [ "$SDK" = iphonesimulator ]; then
	IDENTITY=-
	ENTITLEMENTS=""
else
	IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')}"
	[ -n "$IDENTITY" ] || { echo "error: no Apple Development signing identity" >&2; exit 1; }
	if [ -z "${PROFILE:-}" ]; then
		# the newest development profile for this bundle id, else the team wildcard
		PROFILE=""
		best=""
		for p in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
			"$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision; do
			[ -f "$p" ] || continue
			security cms -D -i "$p" > "$ICONWORK/p.plist" 2>/dev/null || continue
			appid="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$ICONWORK/p.plist" 2>/dev/null || true)"
			getall="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:get-task-allow' "$ICONWORK/p.plist" 2>/dev/null || true)"
			[ "$getall" = true ] || continue	# development profiles only
			case "$appid" in
				*."$BUNDLE_ID") PROFILE="$p"; break ;;
				*.\*) [ -n "$best" ] || best="$p" ;;
			esac
		done
		[ -n "$PROFILE" ] || PROFILE="$best"
	fi
	[ -n "$PROFILE" ] || { echo "error: no development provisioning profile for $BUNDLE_ID (or a wildcard)" >&2; exit 1; }
	cp "$PROFILE" "$APP/embedded.mobileprovision"
	security cms -D -i "$PROFILE" > "$ICONWORK/profile.plist"
	TEAM="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$ICONWORK/profile.plist")"
	ENTITLEMENTS="$ICONWORK/entitlements.plist"
	cat > "$ENTITLEMENTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key><string>$TEAM.$BUNDLE_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAM</string>
	<key>get-task-allow</key><true/>
</dict>
</plist>
EOF
	echo "Signing with \"$IDENTITY\", profile $(/usr/libexec/PlistBuddy -c 'Print :Name' "$ICONWORK/profile.plist")"
fi

for f in "$APP/Frameworks/"*.dylib; do
	codesign --force --sign "$IDENTITY" --timestamp=none "$f"
done
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Frameworks/MoltenVK.framework"
if [ -n "$ENTITLEMENTS" ]; then
	codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
else
	codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION ($BUILD), $SDK, iOS >= $MIN_IOS, $(du -sh "$APP" | cut -f1))"

if [ -n "${INSTALL:-}" ]; then
	if [ "$SDK" = iphonesimulator ]; then
		xcrun simctl install "$INSTALL" "$APP"
	else
		xcrun devicectl device install app --device "$INSTALL" "$APP"
	fi
	echo "Installed on $INSTALL"
fi
