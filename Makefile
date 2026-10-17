# Bifold — skróty do budowania. Wymaga: Xcode 27, XcodeGen (brew install xcodegen).
SCHEME = Bifold
DERIVED = build/DerivedData
APP = $(DERIVED)/Build/Products/Debug/Bifold.app

.PHONY: bootstrap generate build release test test-release run strings perf-fixture clean

bootstrap:
	git submodule update --init --recursive
	./scripts/build-hexfiend.sh
	$(MAKE) generate

generate:
	xcodegen generate --quiet

build:
	xcodebuild -project Bifold.xcodeproj -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build -quiet

release:
	xcodebuild -project Bifold.xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -skipPackagePluginValidation -skipMacroValidation build -quiet

test:
	cd Packages/BifoldKit && swift test

# Testy wydajności w konfiguracji Release (kryterium 100 000 plików < 1 s).
test-release:
	cd Packages/BifoldKit && BIFOLD_PERF_STRICT=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceTests

run: build
	open $(APP)

strings:
	python3 scripts/gen-strings.py

# Katalog testowy ze 100 000 plików: /tmp/bifold-100k
perf-fixture:
	mkdir -p /tmp/bifold-100k && cd /tmp/bifold-100k && seq 1 100000 | xargs -n 1000 touch

clean:
	rm -rf build
