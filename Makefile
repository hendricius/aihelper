.PHONY: build open clean clean-all load-env install uninstall release

release:
	@bash scripts/release.sh AIHelper.zip

load-env:
	@if [ -f .env ]; then \
		export $$(grep -v '^#' .env | xargs) && \
		[ -n "$$AIC_API_KEY" ] && defaults write com.aihelper.app aicoordinator_api_key "$$AIC_API_KEY" || true; \
		[ -n "$$OPENAI_API_KEY" ] && defaults write com.aihelper.app openai_api_key "$$OPENAI_API_KEY" || true; \
		echo "Loaded API key(s) from .env"; \
	else \
		echo "No .env file found. Copy .env.example to .env and add your API key."; \
	fi

build: load-env
	xcodebuild -project AIHelper.xcodeproj -scheme AIHelper -configuration Debug build

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
