#!/bin/sh
# Xcode Cloud post-clone hook. The project and Package.resolved are committed, so
# nothing is generated here; this only lets Xcode Cloud build the Swift packages
# non-interactively (package plugins and macros would otherwise ask for trust).
set -eu

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
echo "Xcode Cloud: package plugin and macro validation skipped for $CI_WORKFLOW"
