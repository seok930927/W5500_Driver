
# Set DEBUG=1 to build debug driver (coexists with stock driver)
# Set DEBUG=0 to build as stock driver replacement
DEBUG ?= 1

ifeq ($(DEBUG),1)
obj-m += w5100_debug.o
obj-m += w5100_spi_debug.o
w5100_debug-objs     := w5100.o
w5100_spi_debug-objs := w5100-spi.o
ccflags-y            += -DW5XXX_DEBUG
else
obj-m += w5100.o
obj-m += w5100_spi.o
w5100_spi-objs := w5100-spi.o
endif

KDIR  := /lib/modules/$(shell uname -r)/build
SRC   := $(shell pwd)
BUILD := $(SRC)/build

all: modules dtbo

modules:
	$(MAKE) -C $(KDIR) M=$(SRC) modules
	mkdir -p $(BUILD)
	mv $(SRC)/*.ko $(SRC)/*.o $(SRC)/*.mod $(SRC)/*.mod.c \
		$(SRC)/modules.order $(SRC)/Module.symvers $(BUILD)/ 2>/dev/null || true
	find $(SRC) -maxdepth 1 \( -name ".*.cmd" -o -name ".*.d" \) -delete

dtbo:
	dtc -I dts -O dtb -o $(BUILD)/w5500-debug.dtbo $(SRC)/w5500-overlay.dts

clean:
	rm -rf $(BUILD)
	$(MAKE) -C $(KDIR) M=$(SRC) clean
