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

.PHONY: project build build-ci test test-kit test-ui coverage format format-check lint generate update-spec

project:            ## Regenerate KoF22Post.xcodeproj from project.yml
	xcodegen generate

build:              ## Build the app for the simulator
	$(XCODEBUILD) -destination '$(DESTINATION)' build

build-ci:           ## Build for the simulator without signing (CI, CodeQL)
	$(XCODEBUILD) -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

test: test-kit test-ui

test-kit:           ## Core unit tests (fast, macOS, no simulator)
	cd Packages/KoF22Kit && swift test

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
	rm -f Packages/KoF22Kit/Sources/KoF22API/Generated/*.swift
	$(GENERATOR) generate openapi/openapi.yaml --config openapi/openapi-generator-config.yaml \
		--output-directory Packages/KoF22Kit/Sources/KoF22API/Generated

update-spec:        ## Pull the live spec from api.kof22.com and regenerate
	scripts/update-spec.sh
	$(MAKE) generate
