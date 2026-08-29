CC      = x86_64-w64-mingw32-gcc
CFLAGS  = -O2 -Wall -Wextra \
           -D_WIN32_WINNT=0x0A00 \
           -DWINVER=0x0A00 \
           -DUNICODE -D_UNICODE
LDFLAGS = -lkernel32 -ladvapi32

TARGET  = dse-patcher.exe
SRCS    = main.c km_rw.c dse.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS) km_rw.h dse.h
	$(CC) $(CFLAGS) -o $@ $(SRCS) $(LDFLAGS)
	@echo ""
	@echo "Built: $(TARGET)"
	@echo "Copy dse-patcher.exe + RTCore64.sys (from MSI Afterburner) to the guest."

clean:
	rm -f $(TARGET) *.o
