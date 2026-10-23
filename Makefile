ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Roblox
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = neko
neko_FILES = Tweak.xm Api.mm
neko_CFLAGS = -fobjc-arc -I$(THEOS_PROJECT_DIR)/vendor/luau/include -I$(THEOS_PROJECT_DIR)/vendor/luau/include/Luau
neko_FRAMEWORKS = Foundation UIKit UniformTypeIdentifiers
neko_LIBRARIES = substrate
neko_LDFLAGS = -L$(THEOS_PROJECT_DIR)/vendor/luau/lib -lLuau.VM -lLuau.Compiler
include $(THEOS_MAKE_PATH)/tweak.mk
