#!/usr/bin/env bash

cd $APPCENTER_SOURCE_DIRECTORY/..

echo "Building for branch $APPCENTER_BRANCH"

# Clone the Celestia repo (modified)
git clone https://github.com/${GITHUB_USERNAME}/Celestia --branch $APPCENTER_BRANCH --single-branch
cd Celestia
git submodule update --init
cd ..

# Clone the CelestiaCore repo
git clone https://${GITHUB_USERNAME}:${GITHUB_ACCESS_TOKEN}@github.com/${GITHUB_USERNAME}/CelestiaCore --branch $APPCENTER_BRANCH --single-branch
cd CelestiaCore
git submodule update --init
ln -sf libs/dependency/${PLATFORM_ID} thirdparty
cd ..

# Install gettext, needed for translation
brew install gettext

# Download AppCenter
cd $APPCENTER_SOURCE_DIRECTORY
brew install wget
wget https://github.com/microsoft/appcenter-sdk-apple/releases/download/${APPCENTER_VERSION}/AppCenter-SDK-Apple-XCFramework-${APPCENTER_VERSION}.zip
unzip -qq AppCenter-SDK-Apple-XCFramework-${APPCENTER_VERSION}.zip 'AppCenter-SDK-Apple/*'
ln -sf AppCenter-SDK-Apple AppCenter
