CC = clang
CODESIGN ?= /usr/bin/codesign
ARCHS ?= arm64 x86_64
MACOSX_DEPLOYMENT_TARGET ?= 26.0
ARCH_FLAGS = $(foreach arch,$(ARCHS),-arch $(arch))
CFLAGS = -Wall -Wextra -O2 $(ARCH_FLAGS) -mmacosx-version-min=$(MACOSX_DEPLOYMENT_TARGET)
LDLIBS = -framework IOKit -framework CoreFoundation
TARGET = fanfan-smcd

all: $(TARGET)

$(TARGET): fanfan-smcd.c smc.h
	$(CC) $(CFLAGS) -o $(TARGET) fanfan-smcd.c $(LDLIBS)
	$(CODESIGN) --force --sign - --identifier fanfan-smcd $(TARGET)

clean:
	rm -f $(TARGET)

.PHONY: all clean
