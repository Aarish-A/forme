# Forme — common tasks.
# Every command CI runs is defined here, so `make ci` locally is the same check.

PROJECT   := Forme.xcodeproj
SCHEME    := Forme
SIMULATOR ?= iPhone 17
DESTINATION := platform=iOS Simulator,name=$(SIMULATOR)

# xcbeautify makes xcodebuild output readable. Optional — falls back to `cat`.
FORMATTER := $(shell command -v xcbeautify 2>/dev/null || echo cat)

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
	@xcodebuild -resolvePackageDependencies -project $(PROJECT) >/dev/null
	@echo "Ready. Run 'make test'."

.PHONY: build
build: ## Build the app for the simulator
	@set -o pipefail && xcodebuild build \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' | $(FORMATTER)

.PHONY: test
test: ## Run unit and UI tests
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-enableCodeCoverage YES | $(FORMATTER)

.PHONY: unit
unit: ## Run unit tests only (fast)
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-only-testing:FormeTests | $(FORMATTER)

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
ci: format-check lint test ## Everything CI runs

.PHONY: clean
clean: ## Remove build artefacts
	@xcodebuild clean -project $(PROJECT) -scheme $(SCHEME) >/dev/null
	@rm -rf DerivedData
	@echo "Cleaned."
