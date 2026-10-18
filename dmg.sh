version=$(head -n 5 pubspec.yaml | tail -n 1 | cut -d ' ' -f 2)
app=build/macos/Build/Products/Release/jhentai.app

# The extension host goes into the app, which is signed again afterwards:
# its runtime without entitlements (it runs in the app's sandbox), the app
# with its own.
flutter build macos --release -t lib/src/main.dart \
&& bash ext_host/desktop/package.sh $app/Contents/Resources \
&& find $app/Contents/Resources/exthost/jre -type f \( -perm -u+x -o -name "*.dylib" \) -exec codesign --force -s - {} \; \
&& codesign --force -s - --entitlements macos/Runner/Release.entitlements $app \
&& brew install create-dmg \
&& create-dmg --volname JHenTai-${version} --window-pos 200 120 --window-size 800 450 --icon-size 100 --app-drop-link 600 185 JHenTai-${version}.dmg $app
