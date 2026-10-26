# Bifold — skróty do budowania. Wymaga: Xcode 27, XcodeGen (brew install xcodegen).
SCHEME = Bifold
DERIVED = build/DerivedData.noindex
APP = $(DERIVED)/Build/Products/Debug/Bifold.app
# Bundle id tylko w Config/Brand.xcconfig.
BUNDLE_ID := $(shell awk -F' = ' '/^BIFOLD_BUNDLE_ID/{print $$2}' Config/Brand.xcconfig)

.PHONY: bootstrap generate build release test test-release run strings perf-fixture clean version installer unregister

bootstrap:
	git submodule update --init --recursive
	./scripts/build-hexfiend.sh
	$(MAKE) generate

generate:
	xcodegen generate --quiet

build:
	./scripts/set-version.sh
	xcodebuild -project Bifold.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build -quiet
	@$(MAKE) -s unregister >/dev/null

release:
	./scripts/set-version.sh
	xcodebuild -project Bifold.xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build -quiet

test:
	cd Packages/BifoldKit && swift test

# Testy wydajności w konfiguracji Release (kryterium 100 000 plików < 1 s).
test-release:
	cd Packages/BifoldKit && BIFOLD_PERF_STRICT=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceTests

run: build
	open $(APP)

# Usuwa z systemu (Launchpad, „Otwórz za pomocą”) wszystkie kopie Bifolda poza /Applications.
unregister:
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
	  | awk -v id='$(BUNDLE_ID)' '/^path:/{p=$$0} $$1=="identifier:" && $$2==id {print p}' | sed 's/^path: *//; s/ (0x[0-9a-f]*)$$//' | grep -v '^/Applications/' | sort -u \
	  | while read -r p; do /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$$p"; echo "wyrejestrowano $$p"; done

strings:
	python3 scripts/gen-strings.py

# Katalog testowy ze 100 000 plików: /tmp/bifold-100k
perf-fixture:
	mkdir -p /tmp/bifold-100k && cd /tmp/bifold-100k && seq 1 100000 | xargs -n 1000 touch

# Wersja z historii gita (jak w CantatePresenter): 1 + PR/10 . PR mod 10 . commity od ostatniego PR.
version:
	@./scripts/version.sh

# Instalatory DMG i PKG w dist/ (podpis: scripts/signing.sh). Wydanie na GitHubie: scripts/release.sh.
installer:
	./scripts/build-installer.sh

clean:
	rm -rf build
