# Bifold — skróty do budowania. Wymaga: Xcode 27, XcodeGen (brew install xcodegen).
SCHEME = Bifold
DERIVED = build/DerivedData.noindex
APP = $(DERIVED)/Build/Products/Debug/Bifold.app
# Bundle id tylko w Config/Brand.xcconfig.
BUNDLE_ID := $(shell awk -F' = ' '/^BIFOLD_BUNDLE_ID/{print $$2}' Config/Brand.xcconfig)
# Jeden cel (Apple Silicon) — bez ostrzeżenia „Using the first of multiple matching destinations”.
XCODEBUILD = xcodebuild -project Bifold.xcodeproj -scheme $(SCHEME) -destination 'platform=macOS,arch=arm64' \
	-derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation

.PHONY: bootstrap generate build release test test-release run strings clean version installer unregister

bootstrap:
	git submodule update --init --recursive
	./scripts/build-hexfiend.sh
	$(MAKE) generate

generate:
	xcodegen generate --quiet

build:
	./scripts/set-version.sh
	$(XCODEBUILD) -configuration Debug build -quiet
	@$(MAKE) -s unregister >/dev/null

# Aplikacja jest tylko arm64; ARCHS dotyczy też celów pakietów SPM (w Release budowałyby się także dla x86_64).
release:
	./scripts/set-version.sh
	$(XCODEBUILD) -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build -quiet
	@$(MAKE) -s unregister >/dev/null

test:
	cd Packages/BifoldKit && swift test

# Testy ze ścisłymi limitami czasu (BIFOLD_PERF_STRICT=1) w konfiguracji Release: wydajność (100 000 plików
# < 1 s) i terminy serwera agenta (AgentServerHardeningTests).
test-release:
	cd Packages/BifoldKit && BIFOLD_PERF_STRICT=1 swift test -c release -Xswiftc -enable-testing \
	  --filter 'PerformanceTests|AgentServerHardeningTests'

run: build
	open $(APP)

# Usuwa z systemu (Launchpad, „Otwórz za pomocą”) wszystkie kopie Bifolda poza /Applications.
unregister:
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
	  | awk -v id='$(BUNDLE_ID)' '/^path:/{p=$$0} $$1=="identifier:" && $$2==id {print p}' | sed 's/^path: *//; s/ (0x[0-9a-f]*)$$//' | grep -v '^/Applications/' | sort -u \
	  | while read -r p; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$$p"; echo "wyrejestrowano $$p"; done

strings:
	python3 scripts/gen-strings.py

# Wersja z historii gita (jak w CantatePresenter): 1 + PR/10 . PR mod 10 . commity od ostatniego PR.
version:
	@./scripts/version.sh

# Instalatory DMG i PKG w dist/ (podpis: scripts/signing.sh). Wydanie na GitHubie: scripts/release.sh.
installer:
	./scripts/build-installer.sh

clean:
	rm -rf build
