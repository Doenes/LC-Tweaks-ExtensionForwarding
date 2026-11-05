# Build on macOS with Xcode installed: `make` (silent) or `make LOG=1` (logs in the per-app tweak).
# Produces two dylibs:
#   LCExtForward.dylib      -> per-app tweak folder (guest hook + LiveProcess payload)
#   LCExtForwardHost.dylib  -> global tweak folder  (import hook; needs "Tweaks selber in LiveContainer laden")
SDK := $(shell xcrun --sdk iphoneos --show-sdk-path)
CLANG := xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $(SDK) -fobjc-arc -O2
LOG ?= 0

all: LCExtForward.dylib LCExtForwardHost.dylib

LCExtForward.dylib: LCExtForward.m
	$(CLANG) -DLCEF_LOG=$(LOG) -dynamiclib -framework Foundation \
		-install_name @rpath/LCExtForward.dylib -o $@ $<

LCExtForwardHost.dylib: LCExtForwardHost.m lcef_macho.c
	$(CLANG) -dynamiclib -framework Foundation \
		-install_name @rpath/LCExtForwardHost.dylib -o $@ $^

clean:
	rm -f LCExtForward.dylib LCExtForwardHost.dylib
