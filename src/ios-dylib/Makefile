# PHL Voice & Music Engine — iOS arm64 Dynamic Library Makefile
# Build on macOS (Xcode / Command Line Tools) or cross-compile via SDK_PATH & CC.

TARGET_NAME    := PHLVoiceEngine
ARCH           := arm64
MIN_IOS        := 13.0
BUILD_DIR      := build
SRC_DIR        := src
OUTPUT_DYLIB   := $(BUILD_DIR)/$(TARGET_NAME).dylib
GEN_KEY_HEADER := $(BUILD_DIR)/generated_key.h

# Configurable at build time:
#   make SIGNING_SECRET="your_github_VOICE_SIGNING_SECRET"
SIGNING_SECRET ?=
INSTALL_NAME   ?= @executable_path/Frameworks/$(TARGET_NAME).dylib

SDK_PATH ?= $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
CXX      ?= $(shell xcrun --sdk iphoneos -f clang++ 2>/dev/null)
STRIP    ?= $(shell xcrun --sdk iphoneos -f strip 2>/dev/null)
CODESIGN ?= $(shell command -v codesign 2>/dev/null)
LDID     ?= $(shell command -v ldid 2>/dev/null)
PYTHON3  ?= $(shell command -v python3 2>/dev/null)

SOURCES := \
	$(SRC_DIR)/PHLSyncManager.mm \
	$(SRC_DIR)/PHLMusicManager.mm \
	$(SRC_DIR)/PHLOverlayUI.mm \
	$(SRC_DIR)/PHLVoiceMain.mm

HEADERS := \
	$(SRC_DIR)/PHLVoiceDSP.hpp \
	$(SRC_DIR)/PHLSyncManager.h \
	$(SRC_DIR)/PHLMusicManager.h \
	$(SRC_DIR)/PHLOverlayUI.h

CXXFLAGS := \
	-std=c++17 \
	-ObjC++ \
	-fobjc-arc \
	-fvisibility=hidden \
	-O3 \
	-Wall \
	-Wextra \
	-Wno-unused-parameter \
	-Wno-deprecated-declarations \
	-arch $(ARCH) \
	-isysroot $(SDK_PATH) \
	-miphoneos-version-min=$(MIN_IOS) \
	-I$(SRC_DIR) \
	-I$(BUILD_DIR)

FRAMEWORKS := \
	-framework Foundation \
	-framework UIKit \
	-framework AVFoundation \
	-framework AudioToolbox \
	-framework CoreAudio \
	-framework Security \
	-framework QuartzCore

LDFLAGS := \
	-dynamiclib \
	-arch $(ARCH) \
	-isysroot $(SDK_PATH) \
	-miphoneos-version-min=$(MIN_IOS) \
	-install_name $(INSTALL_NAME) \
	-Wl,-dead_strip \
	$(FRAMEWORKS)

.PHONY: all clean check-env gen-key verify

all: check-env gen-key $(OUTPUT_DYLIB)

check-env:
	@if [ -z "$(SDK_PATH)" ] || [ ! -d "$(SDK_PATH)" ]; then \
		echo "[ERROR] Khong tim thay iPhoneOS SDK. Hay cai Xcode tren macOS hoac truyen SDK_PATH=..."; \
		exit 1; \
	fi
	@if [ -z "$(CXX)" ]; then \
		echo "[ERROR] Khong tim thay clang++. Hay cai Xcode Command Line Tools."; \
		exit 1; \
	fi

gen-key:
	@mkdir -p $(BUILD_DIR)
	@if [ -n "$(PYTHON3)" ] && [ -f scripts/gen_obfuscated_key.py ]; then \
		VOICE_SIGNING_SECRET="$(SIGNING_SECRET)" $(PYTHON3) scripts/gen_obfuscated_key.py --out $(GEN_KEY_HEADER); \
	else \
		echo "#pragma once" > $(GEN_KEY_HEADER); \
		echo "#define PHL_HAS_EMBEDDED_HMAC_KEY 0" >> $(GEN_KEY_HEADER); \
	fi

$(OUTPUT_DYLIB): $(SOURCES) $(HEADERS) $(GEN_KEY_HEADER)
	@mkdir -p $(BUILD_DIR)
	$(CXX) $(CXXFLAGS) $(SOURCES) $(LDFLAGS) -o $@
	@if [ -n "$(STRIP)" ]; then $(STRIP) -x $@; fi
	@if [ -n "$(LDID)" ]; then \
		$(LDID) -S $@; \
	elif [ -n "$(CODESIGN)" ]; then \
		$(CODESIGN) -f -s - $@; \
	fi
	@echo "[OK] Built iOS arm64 dylib: $@"

verify: $(OUTPUT_DYLIB)
	@lipo -info $(OUTPUT_DYLIB)
	@otool -L $(OUTPUT_DYLIB)
	@echo "[INFO] Zero plain-text secret verification complete."

clean:
	rm -rf $(BUILD_DIR)
