TARGET := iphone:clang:latest:14.0
ARCHS  := arm64 arm64e
INSTALL_TARGET_PROCESSES := RobloxPlayer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := neko
neko_FILES := Tweak.mm Api.mm
neko_FRAMEWORKS := Foundation UIKit WebKit UniformTypeIdentifiers
neko_CFLAGS := -fobjc-arc -std=c++17 -Wno-deprecated-declarations
neko_LIBRARIES := substrate

include $(THEOS_MAKE_PATH)/tweak.mk
