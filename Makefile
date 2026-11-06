# Build on macOS with Xcode installed: `make` (silent) or `make LOG=1` (with logging).
# Produces one dylib for LiveContainer's GLOBAL tweak folder (next to LCExtForward.apps):
# it converts appexes in LiveContainer itself ("Load Tweaks to Self"), forwards
# extensions in opted-in guest apps, and runs them as LiveProcess payload.
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $(SDK) -fobjc-arc -O2
LOG ?= 0

all: LCExtForward.dylib

LCExtForward.dylib: LCExtForward.m lcef_macho.c lcef_macho.h
	$(CLANG) -DLCEF_LOG=$(LOG) -dynamiclib -framework Foundation \
		-install_name @rpath/LCExtForward.dylib -o $@ LCExtForward.m lcef_macho.c

clean:
	rm -f LCExtForward.dylib LCExtForwardHost.dylib
