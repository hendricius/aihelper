.PHONY: build test test-soak open clean clean-all load-env install uninstall release

release:
	@bash scripts/release.sh AIHelper.zip

# Reads only the keys it needs, one line at a time. Do NOT `export $(... | xargs)`
# the whole file: values containing spaces (e.g. SIGN_IDENTITY) get split into
# bogus tokens that leak into the environment and break xcodebuild.
load-env:
	@if [ -f .env ]; then \
		AIC=$$(grep -E '^AIC_API_KEY=' .env | head -1 | cut -d= -f2- | sed 's/^"//;s/"$$//'); \
		OAI=$$(grep -E '^OPENAI_API_KEY=' .env | head -1 | cut -d= -f2- | sed 's/^"//;s/"$$//'); \
		[ -n "$$AIC" ] && defaults write com.aihelper.app aicoordinator_api_key "$$AIC" || true; \
		[ -n "$$OAI" ] && defaults write com.aihelper.app openai_api_key "$$OAI" || true; \
		echo "Loaded API key(s) from .env"; \
	else \
		echo "No .env file found. Copy .env.example to .env and add your API key."; \
	fi

build: load-env
	xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Debug build

test:
	xcodebuild test -project AIHelper.xcodeproj -scheme AIHelper -destination 'platform=macOS' -quiet

# Keep Awake end-to-end check: sits through the real display-sleep timeout and verifies
# the display stayed on. Takes minutes — do not touch the keyboard or mouse while it runs,
# any input resets the idle timer and the result means nothing.
test-soak:
	AIHELPER_DISPLAY_SLEEP_SOAK=1 xcodebuild test -project AIHelper.xcodeproj -scheme AIHelper \
		-destination 'platform=macOS' -only-testing:AIHelperTests/CaffeineManagerTests

open: load-env
	open "$$(xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/AIHelper.app"

clean:
	xcodebuild -project AIHelper.xcodeproj -scheme AIHelper clean
	rm -rf ~/Library/Developer/Xcode/DerivedData/AIHelper-*

install: build
	@echo "Installing AIHelper to /Applications..."
	@# Kill running instance if any
	@pkill -x AIHelper 2>/dev/null || true
	@sleep 0.5
	@# Remove old app completely
	@rm -rf /Applications/AIHelper.app
	@# Copy new build
	@cp -R "$$(xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Debug -showBuildSettings 2>/dev/null | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$3}')/AIHelper.app" /Applications/
	@# Optional: sign with a real identity so macOS keeps the granted
	@# permissions (Accessibility, Screen Recording, ...) across reinstalls.
	@# Set SIGN_IDENTITY in .env or the environment; without it the build
	@# stays ad-hoc signed, which is fine but re-prompts after each install.
	@IDENTITY="$(SIGN_IDENTITY)"; \
	if [ -z "$$IDENTITY" ] && [ -f .env ]; then \
		IDENTITY=$$(grep -E '^SIGN_IDENTITY=' .env | head -1 | cut -d= -f2- | sed 's/^"//;s/"$$//'); \
	fi; \
	if [ -n "$$IDENTITY" ]; then \
		echo "Signing with: $$IDENTITY"; \
		codesign --force --deep --options runtime --timestamp \
			--entitlements AIHelper/AIHelper.entitlements \
			--sign "$$IDENTITY" /Applications/AIHelper.app || \
			echo "Signing failed - continuing with the ad-hoc signed build"; \
	fi
	@echo "Installed! Launching AIHelper..."
	@open /Applications/AIHelper.app

uninstall:
	@echo "Uninstalling AIHelper..."
	@pkill -x AIHelper 2>/dev/null || true
	@rm -rf /Applications/AIHelper.app
	@echo "AIHelper removed from Applications."

clean-all: clean
	@echo "Removing app data and caches..."
	@rm -rf ~/Library/Caches/com.aihelper.app
	@rm -rf ~/Library/Application\ Support/com.aihelper.app
	@echo "Cleaned all AIHelper data."
