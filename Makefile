# Build, test, format, lint and code generation. CI runs these same targets
# (K22-CI-03); CONTRIBUTING.md documents them.
SIM ?= iPhone 18 Pro
DESTINATION ?= platform=iOS Simulator,name=$(SIM)
XCODEBUILD = xcodebuild -project KoF22Post.xcodeproj -scheme KoF22Post -skipPackagePluginValidation
GENERATOR = Tools/OpenAPIGen/.build/release/swift-openapi-generator
# Hand-written Swift only; generated code is excluded by path (K22-CODE-25).
SWIFT_SOURCES = App Shared ShareExtension Widgets UITests scripts \
	Packages/KoF22Kit/Package.swift Packages/KoF22Kit/Sources/KoF22Kit \
	Packages/KoF22Kit/Sources/KoF22UI Packages/KoF22Kit/Tests Tools/OpenAPIGen/Package.swift

.PHONY: project build build-ci build-codeql test test-kit test-ui coverage format format-check lint generate update-spec

project:            ## Regenerate KoF22Post.xcodeproj from project.yml
	xcodegen generate

build:              ## Build the app for the simulator
	$(XCODEBUILD) -destination '$(DESTINATION)' build

build-ci:           ## Build for the simulator without signing (CI, CodeQL)
	$(XCODEBUILD) -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO $(BUILD_FLAGS) build

# CodeQL traces the build; SwiftPM's manifest sandbox (sandbox-exec) cannot be spawned
# under the tracer ("Bad CPU type in executable"), so the CodeQL build turns it off.
build-codeql:       ## build-ci without the SwiftPM manifest sandbox, for CodeQL tracing
	$(MAKE) build-ci BUILD_FLAGS="-IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES"

test: test-kit test-ui

test-kit:           ## Core unit tests (fast, macOS, no simulator); data goes to a temp folder
	cd Packages/KoF22Kit && KOF22_DATA_DIR="$$(mktemp -d)" swift test

coverage:           ## Unit tests with the 100% line-coverage gate on KoF22Kit (K22-TEST-10)
	scripts/check-coverage.sh

test-ui:            ## XCUITests against the in-process mock API
	$(XCODEBUILD) -destination '$(DESTINATION)' -only-testing:KoF22PostUITests test

format:             ## Rewrite Swift files with the shared swift-format configuration
	swift format --in-place --recursive $(SWIFT_SOURCES)

format-check:       ## Fail when any Swift file is not formatted (CI)
	swift format lint --strict --recursive $(SWIFT_SOURCES)

lint:               ## SwiftLint with the shared configuration, warnings fail
	swiftlint lint --strict --quiet

$(GENERATOR): Tools/OpenAPIGen/Package.swift
	cd Tools/OpenAPIGen && swift build -c release --product swift-openapi-generator

generate: $(GENERATOR)  ## Regenerate the API client from openapi/openapi.yaml
	scripts/prepare-spec.sh build/openapi-for-generator.yaml
	rm -f Packages/KoF22Kit/Sources/KoF22API/Generated/*.swift
	$(GENERATOR) generate build/openapi-for-generator.yaml --config openapi/openapi-generator-config.yaml \
		--output-directory Packages/KoF22Kit/Sources/KoF22API/Generated

update-spec:        ## Show how the live spec differs; APPLY=1 replaces the copy and regenerates
	APPLY=$(APPLY) scripts/update-spec.sh
	@if [ "$(APPLY)" = "1" ]; then $(MAKE) generate; fi
