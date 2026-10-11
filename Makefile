# Build, test and code generation. CI runs `make test`.
SIM ?= iPhone 18 Pro
DESTINATION ?= platform=iOS Simulator,name=$(SIM)
XCODEBUILD = xcodebuild -project KoF22Post.xcodeproj -scheme KoF22Post -skipPackagePluginValidation
GENERATOR = Tools/OpenAPIGen/.build/release/swift-openapi-generator

.PHONY: project build test test-kit test-ui generate update-spec run

project:            ## Regenerate KoF22Post.xcodeproj from project.yml
	xcodegen generate

build:              ## Build the app for the simulator
	$(XCODEBUILD) -destination '$(DESTINATION)' build

test: test-kit test-ui

test-kit:           ## Core unit tests (fast, macOS, no simulator)
	cd Packages/KoF22Kit && swift test

test-ui:            ## XCUITests against the in-process mock API
	$(XCODEBUILD) -destination '$(DESTINATION)' -only-testing:KoF22PostUITests test

$(GENERATOR): Tools/OpenAPIGen/Package.swift
	cd Tools/OpenAPIGen && swift build -c release --product swift-openapi-generator

generate: $(GENERATOR)  ## Regenerate the API client from openapi/openapi.yaml
	rm -f Packages/KoF22Kit/Sources/KoF22API/Generated/*.swift
	$(GENERATOR) generate openapi/openapi.yaml --config openapi/openapi-generator-config.yaml \
		--output-directory Packages/KoF22Kit/Sources/KoF22API/Generated

update-spec:        ## Pull the live spec from api.kof22.com and regenerate
	scripts/update-spec.sh
	$(MAKE) generate
