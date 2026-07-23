# LLPL Hardware Support

Import the hardware layer directly:

```swift
import "stdlib/hw/hw.llpl"
```

This module is intended for freestanding/kernel code. It avoids classes and
uses plain structs plus namespace functions so common descriptors do not
allocate.

## MMIO

```swift
let status: hw.MmioU32 = hw.mmio_u32(device_base + STATUS_OFFSET)
let value: u32 = hw.mmio_read_u32(status)
hw.mmio_write_u32(status, value | 1)
hw.mmio_update_u32(status, MODE_MASK, MODE_RUNNING) // read-modify-write
```

Every access (`_u8`/`_u16`/`_u32`/`_u64`) comes in three tiers, from fastest
to strongest-ordered:

- `mmio_read_u32_relaxed`/`mmio_write_u32_relaxed` - the bare access, no
  barrier at all. Use when ordering several back-to-back accesses under one
  manual `hw.Barrier.*` call yourself.
- `mmio_read_u32`/`mmio_write_u32` - a per-access read/write barrier
  (`Barrier.read()`/`Barrier.write()`), the right default for ordinary
  same-device register access.
- `mmio_read_u32_fenced`/`mmio_write_u32_fenced` - a full `Barrier.full()`
  (`mfence`) instead, for the stronger ordering a DMA/CPU cache-coherency
  boundary needs (the same barrier `dma_sync_for_device`/`dma_sync_for_cpu`
  below already reach for).

`mmio_update_*` does a plain (non-relaxed, non-fenced) read-modify-write:
`(old & ~clear_mask) | set_mask`.

Reads/writes are real inline-asm accesses with a `"memory"` clobber (not a
plain C dereference), so they can't be reordered or optimized away - the
same guarantee `hal.llpl`'s `outb`/`inb` port-I/O helpers rely on, just
applied to memory-mapped rather than port-mapped registers.

### RegisterBlock

For a device with several registers at fixed offsets from one base address:

```swift
let rb: hw.RegisterBlock = hw.register_block(device_base, /* size */ 0x100, /* align */ 4)
if hw.register_block_is_valid(rb) {
    let ctrl: hw.MmioU32 = hw.reg32(rb, CTRL_OFFSET)
    hw.mmio_write_u32(ctrl, hw.mmio_read_u32(ctrl) | ENABLE_BIT)
}
```

`reg8`/`reg16`/`reg32`/`reg64` turn a block + byte offset into the matching
`MmioU*` handle. `register_block_is_valid` checks the base is aligned;
`register_block_offset_valid(rb, offset, width)` additionally checks one
specific access both stays inside `size` and lands on a `width`-aligned
address.

To keep hand-written offset constants honest against a datasheet's layout,
declare it as a `packed struct` and let `#assert_offset` catch any drift at
compile time (see `test/hw_register_block_demo.llpl` for the full pattern):

```swift
packed struct DeviceRegs {
    let data: u32
    let status: u32
    let ctrl: u32
}
#assert_size DeviceRegs 12
#assert_offset DeviceRegs.status 4
#assert_offset DeviceRegs.ctrl 8

const STATUS_OFFSET: u64 = 4
const CTRL_OFFSET: u64 = 8
```

The struct itself is never overlaid on device memory directly (a struct
field access through a raw pointer isn't guaranteed volatile) - it exists
purely so reordering or resizing `DeviceRegs`'s fields breaks the build
until the offset constants above are updated to match.

## Cache And Barriers

```swift
hw.Barrier.compiler()
hw.Barrier.read()
hw.Barrier.write()
hw.Barrier.full()
hw.Barrier.invalidate_page(addr)
```

These lower to x86-style inline assembly barriers/instructions.

## DMA Buffers

```swift
let buf: hw.DmaBuffer = hw.dma_buffer(phys, virt, bytes, 16, hw.CachePolicy.WRITE_BACK)
if hw.dma_is_valid(buf) {
    hw.dma_sync_for_device(&buf)
}
```

The DMA helpers track physical/virtual addresses, size, alignment,
cacheability, and ownership (`hw.DmaOwner.CPU` or `hw.DmaOwner.DEVICE`).

## Paging

```swift
let region: hw.PageRegion = hw.page_region(virt, phys, bytes, hw.page_flags_mmio())
if hw.page_region_is_valid(region) {
    // hand to a target-specific mapper
}
```

The paging helpers provide typed region descriptors, page alignment helpers,
and common permission flag combinations.

## Device Descriptors

Use `#device "path.lldev"` to generate constants from a small descriptor:

```text
device E1000
base 0xF0000000
irq 11
reg CTRL 0x0000 u32
reg STATUS 0x0008 u32
dma RX_RING 16 4096 16
```

This expands to namespaced constants:

```swift
E1000.BASE
E1000.IRQ
E1000.Reg.CTRL
E1000.Width.CTRL
E1000.Dma.RX_RING_ENTRIES
E1000.Dma.RX_RING_BYTES
E1000.Dma.RX_RING_ALIGN
```
