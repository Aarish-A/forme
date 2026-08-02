# Forme — common tasks.
# Every command CI runs is defined here, so `make ci` locally is the same check.

# Per-worktree overrides, gitignored and optional. Only needed when two
# worktrees build at the same time: unit tests are hosted in the app, so both
# runs install com.forme.app and the second overwrites the first mid-test.
# Give one of them its own SIMULATOR here and they stop colliding.
-include Local.mk

PROJECT   := Forme.xcodeproj
SCHEME    := Forme
SIMULATOR ?= iPhone 17 Pro
DESTINATION := platform=iOS Simulator,name=$(SIMULATOR)
BUNDLE_ID := com.forme.app

# Local.mk is gitignored, so it never shows up in `git status`. Say when it's
# in effect, or a stale one silently redirects every build and `make ci` quietly
# stops matching CI.
$(if $(wildcard Local.mk),$(info Local.mk in effect — SIMULATOR=$(SIMULATOR)))

# Build into the repo so the .app is at a predictable path and `make clean`
# actually clears the cache Xcode's UI would otherwise keep separately.
DERIVED    := DerivedData
APP_SIM    := $(DERIVED)/Build/Products/Debug-iphonesimulator/$(SCHEME).app
APP_DEVICE := $(DERIVED)/Build/Products/Debug-iphoneos/$(SCHEME).app

# The first connected iPhone. Override with `make device DEVICE_ID=...`.
DEVICE_ID ?=

# xcbeautify makes xcodebuild output readable. Optional — falls back to `cat`.
FORMATTER := $(shell command -v xcbeautify 2>/dev/null || echo cat)

# The versions CI pins. Local tools must match, or the format-on-save hook
# rewrites files in a way CI then rejects.
SWIFTFORMAT_VERSION := $(shell awk '$$1 == "swiftformat" { print $$2 }' .tool-versions)
SWIFTLINT_VERSION   := $(shell awk '$$1 == "swiftlint" { print $$2 }' .tool-versions)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## One-time setup for a fresh clone
	@command -v swiftlint >/dev/null || brew install swiftlint
	@command -v swiftformat >/dev/null || brew install swiftformat
	@command -v xcbeautify >/dev/null || brew install xcbeautify
	@test -f Config/Secrets.xcconfig \
		|| (cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig \
			&& echo "Created Config/Secrets.xcconfig — add your Supabase values.")
	@xcodebuild -resolvePackageDependencies -project $(PROJECT) -derivedDataPath $(DERIVED) >/dev/null
	@$(MAKE) --no-print-directory tools
	@echo "Ready. Run 'make test'."

.PHONY: tools
tools: ## Check local tool versions match the ones CI pins
	@ok=1; \
	have=$$(swiftformat --version); \
	if [ "$$have" != "$(SWIFTFORMAT_VERSION)" ]; then \
		echo "swiftformat $$have installed, CI pins $(SWIFTFORMAT_VERSION) — brew upgrade swiftformat"; ok=0; \
	fi; \
	have=$$(swiftlint version); \
	if [ "$$have" != "$(SWIFTLINT_VERSION)" ]; then \
		echo "swiftlint $$have installed, CI pins $(SWIFTLINT_VERSION) — brew upgrade swiftlint"; ok=0; \
	fi; \
	test $$ok -eq 1

.PHONY: build
build: ## Build the app for the simulator
	@set -o pipefail && xcodebuild build \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) | $(FORMATTER)

.PHONY: test
test: ## Run unit and UI tests
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -enableCodeCoverage YES | $(FORMATTER)

.PHONY: unit
unit: ## Run unit tests only (fast)
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) -only-testing:FormeTests | $(FORMATTER)

.PHONY: run
run: ## Build and launch in the simulator, streaming its output
	@set -o pipefail && xcodebuild build \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath $(DERIVED) | $(FORMATTER)
	@xcrun simctl boot '$(SIMULATOR)' 2>/dev/null || true
	@open -a Simulator
	@xcrun simctl install '$(SIMULATOR)' '$(APP_SIM)'
	@xcrun simctl launch --console-pty '$(SIMULATOR)' $(BUNDLE_ID)

.PHONY: device
device: ## Build and launch on a connected iPhone
	@id='$(DEVICE_ID)'; \
	[ -n "$$id" ] || id=$$(xcodebuild -showdestinations \
		-project $(PROJECT) -scheme $(SCHEME) 2>/dev/null \
		| grep 'platform:iOS,' | grep -oE 'id:[0-9A-F-]{20,}' | sed 's/id://' | head -1); \
	[ -n "$$id" ] || { echo "No iPhone found. Connect one, unlock it, and trust this Mac."; exit 1; }; \
	set -o pipefail && xcodebuild build \
		-project $(PROJECT) -scheme $(SCHEME) -destination "platform=iOS,id=$$id" \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates | $(FORMATTER) \
	&& xcrun devicectl device install app --device "$$id" '$(APP_DEVICE)' >/dev/null \
	&& xcrun devicectl device process launch --device "$$id" --console $(BUNDLE_ID)

.PHONY: logs
logs: ## Stream the app's Log.* output from the simulator
	@xcrun simctl spawn '$(SIMULATOR)' log stream --level debug \
		--predicate 'subsystem == "$(BUNDLE_ID)"'

# Diagnostics. A scan writes a JSON report of what it measured — stage counts
# and the distribution behind every threshold. Pulling it here is how a
# threshold gets tuned from evidence instead of from a screenshot. There is no
# way to stream a physical device's Log.* output from a terminal (`log stream`
# has no device flag, and `devicectl ... --console` only bridges stdout), so the
# report file is the transport, not the log.
.PHONY: diag
diag: ## Pull scan reports off the connected iPhone into ./diagnostics
	@mkdir -p diagnostics
	@id='$(DEVICE_ID)'; \
	[ -n "$$id" ] || id=$$(xcodebuild -showdestinations \
		-project $(PROJECT) -scheme $(SCHEME) 2>/dev/null \
		| grep 'platform:iOS,' | grep -oE 'id:[0-9A-F-]{20,}' | sed 's/id://' | head -1); \
	[ -n "$$id" ] || { echo "No iPhone found. Connect one, unlock it, and trust this Mac."; exit 1; }; \
	xcrun devicectl device copy from --device "$$id" \
		--domain-type appDataContainer --domain-identifier $(BUNDLE_ID) \
		--source 'Library/Application Support/Diagnostics' \
		--destination diagnostics
	@find diagnostics -name '*.json' | head -5

# Separate directory from `make diag`. `make unit` runs real scans against stub
# services and writes a report each time, so merging the two would bury the one
# measurement taken against a real photo library under a pile of three-photo
# fixtures — with `latest.json` the first casualty.
.PHONY: diag-sim
diag-sim: ## Copy scan reports out of the simulator into ./diagnostics/sim
	@mkdir -p diagnostics/sim
	@container=$$(xcrun simctl get_app_container '$(SIMULATOR)' $(BUNDLE_ID) data 2>/dev/null); \
	[ -n "$$container" ] || { echo "Not installed on '$(SIMULATOR)'. Run 'make run' first."; exit 1; }; \
	cp -R "$$container/Library/Application Support/Diagnostics/." diagnostics/sim/ 2>/dev/null \
		|| { echo "No reports yet — run a scan first."; exit 1; }
	@find diagnostics/sim -name '*.json' | head -5

.PHONY: destinations
destinations: ## List the simulators and devices you can build for
	@xcodebuild -showdestinations -project $(PROJECT) -scheme $(SCHEME) 2>/dev/null \
		| grep -E 'platform:iOS'

.PHONY: lint
lint: ## Check style with SwiftLint
	@swiftlint lint --strict

.PHONY: format
format: ## Rewrite sources with SwiftFormat
	@swiftformat .

.PHONY: format-check
format-check: ## Verify formatting without rewriting
	@swiftformat --lint .

.PHONY: ci
ci: tools format-check lint test ## Everything CI runs

.PHONY: clean
clean: ## Remove build artefacts
	@xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) >/dev/null
	@rm -rf DerivedData
	@echo "Cleaned."
