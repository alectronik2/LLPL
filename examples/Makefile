.PHONY: all clean run run-32bit

# Compiler and tools
LLPL = ../llpl
NASM = nasm
CC = gcc
LD = ld
QEMU = qemu-system-x86_64

# Architecture selection (64bit or 32bit)
ARCH ?= 64bit

# 64-bit flags
ifeq ($(ARCH),64bit)
NASMFLAGS = -f elf64
CFLAGS = -m64 -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -Wall -Wextra -O2 -I. -mcmodel=kernel -fno-pie -mno-red-zone -mno-sse -mno-sse2 -mno-mmx -mno-80387
LDFLAGS = -m elf_x86_64 -T linker64.ld -nostdlib
BOOT_SRC = boot64.asm
else
# 32-bit flags
NASMFLAGS = -f elf32
CFLAGS = -m32 -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -Wall -Wextra -O2 -I.
LDFLAGS = -m elf_i386 -T linker.ld -nostdlib
BOOT_SRC = boot.asm
endif

# Files
LLPL_SRC = kernel.llpl
C_SRC = kernel.c
RUNTIME_SRC = ../runtime/runtime.c
KERNEL_BIN = kernel.bin
ISO = kernel.iso

all: $(ISO)

# Compile LLPL to C
$(C_SRC): $(LLPL_SRC)
	@echo "Compiling LLPL..."
	cd .. && dub build
	$(LLPL) $(LLPL_SRC) -o $(C_SRC)

# Assemble boot code
boot.o: $(BOOT_SRC)
	@echo "Assembling boot code ($(ARCH))..."
	$(NASM) $(NASMFLAGS) $(BOOT_SRC) -o boot.o

# Compile kernel
kernel.o: $(C_SRC)
	@echo "Compiling kernel..."
	$(CC) $(CFLAGS) -I../runtime -c $(C_SRC) -o kernel.o

# Compile runtime
runtime.o: $(RUNTIME_SRC)
	@echo "Compiling runtime..."
	$(CC) $(CFLAGS) -c $(RUNTIME_SRC) -o runtime.o

# Link kernel
$(KERNEL_BIN): boot.o kernel.o runtime.o
	@echo "Linking kernel..."
	$(LD) $(LDFLAGS) boot.o kernel.o runtime.o -o $(KERNEL_BIN)

# Create ISO
$(ISO): $(KERNEL_BIN)
	@echo "Creating ISO..."
	@mkdir -p isodir/boot/grub
	@cp $(KERNEL_BIN) isodir/boot/kernel.bin
	@echo 'menuentry "LLPL Kernel" {' > isodir/boot/grub/grub.cfg
	@echo '    multiboot2 /boot/kernel.bin' >> isodir/boot/grub/grub.cfg
	@echo '}' >> isodir/boot/grub/grub.cfg
	@grub-mkrescue -o $(ISO) isodir 2>/dev/null || echo "Note: grub-mkrescue not found, ISO not created"

# Run in QEMU (prefer ISO for multiboot)
run: $(ISO)
	@echo "Running kernel in QEMU..."
	$(QEMU) -cdrom $(ISO) -nographic 

# Alternative: run kernel binary directly (may not work on all QEMU versions)
run-direct: $(KERNEL_BIN)
	@echo "Running kernel directly in QEMU..."
	$(QEMU) -kernel $(KERNEL_BIN) -serial stdio

# Build 32-bit version
run-32bit:
	$(MAKE) clean
	$(MAKE) ARCH=32bit run

# Clean build artifacts
clean:
	rm -f *.o $(C_SRC) $(KERNEL_BIN) $(ISO)
	rm -rf isodir
