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
```

MMIO reads/writes use volatile pointers and explicit read/write barriers.

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
