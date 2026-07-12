.PHONY: all clean run check-limine

LLPL = ../../llpl
CC = gcc
LD = ld
QEMU = qemu-system-x86_64

LIMINE_DIR ?= /usr/share/limine

CFLAGS = -m64 -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -fno-omit-frame-pointer -fno-optimize-sibling-calls -Wall -Wextra -O2 -I. -mcmodel=kernel -fno-pie -mno-red-zone -mno-sse -mno-sse2 -mno-mmx -mno-80387
LDFLAGS = -m elf_x86_64 -T linker.ld -nostdlib

KERNEL_LLPL = kernel.llpl
KERNEL_C = kernel.c
KERNEL_O = kernel.o
RUNTIME_SRC = ../../runtime/runtime.c
RUNTIME_O = runtime.o
KERNEL_ELF = kernel.elf
ISO = kernel.iso

all: $(ISO)

check-limine:
	@test -f "$(LIMINE_DIR)/limine-bios.sys" || \
		(echo "Limine assets not found in LIMINE_DIR=$(LIMINE_DIR)"; \
		 echo "Install Limine or run: make LIMINE_DIR=/path/to/limine"; exit 1)
	@test -f "$(LIMINE_DIR)/limine-bios-cd.bin" || \
		(echo "Missing $(LIMINE_DIR)/limine-bios-cd.bin"; exit 1)
	@test -f "$(LIMINE_DIR)/limine-uefi-cd.bin" || \
		(echo "Missing $(LIMINE_DIR)/limine-uefi-cd.bin"; exit 1)
	@command -v limine >/dev/null || \
		(echo "limine command not found on PATH"; exit 1)

$(KERNEL_C): $(KERNEL_LLPL) stdint.h stddef.h stdarg.h
	@echo "Compiling LLPL..."
	cd ../.. && dub build
	$(LLPL) $(KERNEL_LLPL) -o $(KERNEL_C)

$(KERNEL_O): $(KERNEL_C)
	@echo "Compiling kernel..."
	$(CC) $(CFLAGS) -I../../runtime -c $(KERNEL_C) -o $(KERNEL_O)

$(RUNTIME_O): $(RUNTIME_SRC)
	@echo "Compiling runtime..."
	$(CC) $(CFLAGS) -c $(RUNTIME_SRC) -o $(RUNTIME_O)

$(KERNEL_ELF): $(KERNEL_O) $(RUNTIME_O) linker.ld
	@echo "Linking kernel..."
	$(LD) $(LDFLAGS) $(KERNEL_O) $(RUNTIME_O) -o $(KERNEL_ELF)

$(ISO): $(KERNEL_ELF) limine.conf check-limine
	@echo "Creating Limine ISO..."
	@rm -rf isodir
	@mkdir -p isodir/boot/limine isodir/EFI/BOOT
	@cp $(KERNEL_ELF) isodir/boot/kernel.elf
	@cp limine.conf isodir/limine.conf
	@cp limine.conf isodir/boot/limine/limine.conf
	@cp $(LIMINE_DIR)/limine-bios.sys isodir/boot/limine/
	@cp $(LIMINE_DIR)/limine-bios-cd.bin isodir/boot/limine/
	@cp $(LIMINE_DIR)/limine-uefi-cd.bin isodir/boot/limine/
	@cp $(LIMINE_DIR)/BOOTX64.EFI isodir/EFI/BOOT/BOOTX64.EFI 2>/dev/null || true
	xorriso -as mkisofs -b boot/limine/limine-bios-cd.bin \
		-no-emul-boot -boot-load-size 4 -boot-info-table \
		--efi-boot boot/limine/limine-uefi-cd.bin \
		-efi-boot-part --efi-boot-image --protective-msdos-label \
		isodir -o $(ISO)
	limine bios-install $(ISO)

run: $(ISO)
	$(QEMU) -cdrom $(ISO) -serial stdio -m 256

clean:
	rm -f $(KERNEL_C) $(KERNEL_O) $(RUNTIME_O) $(KERNEL_ELF) $(ISO)
	rm -rf isodir
