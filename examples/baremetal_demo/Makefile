.PHONY: all clean run run-direct test-persistence

# Compiler and tools
LLPL = ../../llpl
NASM = nasm
CC = gcc
LD = ld
QEMU = qemu-system-x86_64

NASMFLAGS = -f elf64
CFLAGS = -m64 -ffreestanding -nostdlib -nostdinc -fno-builtin -fno-stack-protector -fno-omit-frame-pointer -fno-optimize-sibling-calls -Wall -Wextra -O2 -I. -mcmodel=kernel -fno-pie -mno-red-zone -mno-sse -mno-sse2 -mno-mmx -mno-80387
LDFLAGS = -m elf_x86_64 -T linker64.ld -nostdlib
BOOT_SRC = boot64.asm

# Files
LLPL_SRC = kernel.llpl
C_SRC = kernel.c
RUNTIME_SRC = ../../runtime/runtime.c
KERNEL_BIN = kernel.bin
ISO = kernel.iso
DISK_IMG = disk.img

all: $(ISO)

# Compile LLPL to C (module resolution picks up every imported file
# automatically via the `import` statements in kernel.llpl; listed here
# too just so `make` knows to recompile when any of them change)
$(C_SRC): $(LLPL_SRC) hal.llpl console.llpl gdt.llpl idt.llpl backtrace.llpl fb.llpl kbd.llpl pagealloc.llpl kheap.llpl ata.llpl vfs.llpl tmpfs.llpl task.llpl shell.llpl ../../prelude.llpl
	@echo "Compiling LLPL..."
	cd ../.. && dub build
	$(LLPL) $(LLPL_SRC) -o $(C_SRC)

# Assemble boot code
boot.o: $(BOOT_SRC)
	@echo "Assembling boot code..."
	$(NASM) $(NASMFLAGS) $(BOOT_SRC) -o boot.o

# Compile kernel
kernel.o: $(C_SRC)
	@echo "Compiling kernel..."
	$(CC) $(CFLAGS) -I../../runtime -c $(C_SRC) -o kernel.o

# Compile runtime
runtime.o: $(RUNTIME_SRC)
	@echo "Compiling runtime..."
	$(CC) $(CFLAGS) -c $(RUNTIME_SRC) -o runtime.o

# Link kernel
$(KERNEL_BIN): boot.o kernel.o runtime.o
	@echo "Linking kernel..."
	$(LD) $(LDFLAGS) boot.o kernel.o runtime.o -o $(KERNEL_BIN)

# Create ISO - including two small files loaded as multiboot2 modules
# (grub.cfg's `module2` directive) purely to give tmpfs.llpl something
# real to expose; their exact content is asserted by TmpFS.selftest().
$(ISO): $(KERNEL_BIN)
	@echo "Creating ISO..."
	@mkdir -p isodir/boot/grub
	@cp $(KERNEL_BIN) isodir/boot/kernel.bin
	@printf "Hello from a GRUB module!" > isodir/boot/hello.txt
	@printf "This file was never written to the VFS disk - TmpFS reads it directly out of the memory GRUB already loaded it into." > isodir/boot/readme.txt
	@echo 'set timeout=0' > isodir/boot/grub/grub.cfg
	@echo 'set default=0' >> isodir/boot/grub/grub.cfg
	@echo 'menuentry "LLPL Bare-Metal Demo" {' >> isodir/boot/grub/grub.cfg
	@echo '    multiboot2 /boot/kernel.bin' >> isodir/boot/grub/grub.cfg
	@echo '    module2 /boot/hello.txt hello.txt' >> isodir/boot/grub/grub.cfg
	@echo '    module2 /boot/readme.txt readme.txt' >> isodir/boot/grub/grub.cfg
	@echo '}' >> isodir/boot/grub/grub.cfg
	@grub-mkrescue -o $(ISO) isodir 2>/dev/null || echo "Note: grub-mkrescue not found, ISO not created"

# The VFS's (vfs.llpl) backing store - a plain rule with no dependency
# that would force recreation, so it persists across ordinary `make` runs
# the same way real disk state should (only `clean`, below, wipes it).
# Must match vfs.llpl's DISK_SECTORS constant (16MB / 512-byte sectors).
$(DISK_IMG):
	dd if=/dev/zero of=$(DISK_IMG) bs=1M count=16

# Run in QEMU (prefer ISO for multiboot); serial output goes to stdout.
# QEMU assigns the extra `-drive ...,if=ide` (with no explicit index) as
# the primary IDE master alongside `-cdrom` - verified, not merely
# assumed, but still just "this is what QEMU happens to do today", the
# same "trust the target" spirit as the rest of this demo's hardware
# handling (see ata.llpl).
run: $(ISO) $(DISK_IMG)
	@echo "Running kernel in QEMU..."
	$(QEMU) -cdrom $(ISO) -drive file=$(DISK_IMG),format=raw,if=ide -serial stdio -m 256

# Alternative: run kernel binary directly (may not work on all QEMU versions)
run-direct: $(KERNEL_BIN) $(DISK_IMG)
	@echo "Running kernel directly in QEMU..."
	$(QEMU) -kernel $(KERNEL_BIN) -drive file=$(DISK_IMG),format=raw,if=ide -serial stdio

# Automated, no-human-typing proof that VFS.llpl's filesystem survives a
# reboot: boot once against a *fresh* disk image (self-formats,
# VFS.selftest() creates /selftest/proof.txt and reports SELFTEST: PASS),
# then boot a *second* time against that *same* image (not recreated) and
# confirm selftest() finds /selftest/proof.txt still there
# (PERSISTENCE: PASS) instead of reporting a first-boot SKIP.
test-persistence: $(ISO)
	rm -f $(DISK_IMG) /tmp/llpl_persistence_boot1.log /tmp/llpl_persistence_boot2.log
	$(MAKE) $(DISK_IMG)
	@echo "Boot 1 (fresh disk) ..."
	timeout 10 $(QEMU) -cdrom $(ISO) -drive file=$(DISK_IMG),format=raw,if=ide \
		-serial file:/tmp/llpl_persistence_boot1.log -display none -m 256 || true
	@grep -q "PERSISTENCE: SKIP (first boot)" /tmp/llpl_persistence_boot1.log && \
		echo "  boot 1: PERSISTENCE: SKIP (first boot) - expected" || \
		(echo "  boot 1: FAILED - expected a first-boot SKIP"; cat /tmp/llpl_persistence_boot1.log; exit 1)
	@grep -q "SELFTEST: PASS" /tmp/llpl_persistence_boot1.log && \
		echo "  boot 1: SELFTEST: PASS" || \
		(echo "  boot 1: FAILED - SELFTEST did not pass"; cat /tmp/llpl_persistence_boot1.log; exit 1)
	@echo "Boot 2 (same disk image) ..."
	timeout 10 $(QEMU) -cdrom $(ISO) -drive file=$(DISK_IMG),format=raw,if=ide \
		-serial file:/tmp/llpl_persistence_boot2.log -display none -m 256 || true
	@grep -q "PERSISTENCE: PASS" /tmp/llpl_persistence_boot2.log && \
		echo "  boot 2: PERSISTENCE: PASS - proof.txt survived the reboot" || \
		(echo "  boot 2: FAILED - proof.txt did not survive"; cat /tmp/llpl_persistence_boot2.log; exit 1)
	@grep -q "SELFTEST: PASS" /tmp/llpl_persistence_boot2.log && \
		echo "  boot 2: SELFTEST: PASS" || \
		(echo "  boot 2: FAILED - SELFTEST did not pass"; cat /tmp/llpl_persistence_boot2.log; exit 1)
	@echo "test-persistence: ALL PASS"

# Clean build artifacts - *including* the disk image (this wipes any
# persisted VFS data too, by design: clean means every generated
# artifact, not "everything except the disk").
clean:
	rm -f *.o $(C_SRC) $(KERNEL_BIN) $(ISO) $(DISK_IMG)
	rm -rf isodir
