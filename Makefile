TARGET = iphone:clang:latest:14.0
ARCHS = arm64 arm64e

ifeq ($(GITHUB_ACTIONS),true)
    export INSTALL = 0
    export FINALPACKAGE = 1
endif

export DEBUG = 0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DY4K

DY4K_FILES = Tweak.x
DY4K_CFLAGS = -fobjc-arc -w
DY4K_FRAMEWORKS = Photos
export THEOS_STRICT_LOGOS=0
export ERROR_ON_WARNINGS=0
export LOGOS_DEFAULT_GENERATOR=internal

include $(THEOS_MAKE_PATH)/tweak.mk

clean::
	@echo "==> Cleaning packages..."
	@rm -rf .theos packages
