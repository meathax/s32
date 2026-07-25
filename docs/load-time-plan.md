# Sega System 32 load-time plan

## Objective

Reduce time from selecting an MRA to releasing the core's ROM-load reset without
changing the fixed ROM stream layout, SDRAM destinations, byte order, MCU
descramble mapping, or boot gate behavior.

## Implemented

1. MiSTer HPS file I/O is now enabled in 16-bit mode (WIDE=1). The official
   HPS contract increments ioctl_addr by two and supplies a 16-bit ioctl_dout
   word, so the host sends two ROM bytes per transfer.
2. s32_rom_loader has a WIDE parameter. The live top selects WIDE=1; the
   default byte-mode implementation remains available for older integrations
   and existing tests.
3. Wide index-0 transfers emit one complete little-endian SDRAM word per host
   transaction. The MCU path still applies the inverse address permutation and
   emits the same external SDRAM word address/data. The V25 invalidation pulse is
   retained.
4. Wide index-2/index-3 transfers load complete EEPROM words. The NVRAM upload
   adapter returns complete 16-bit words in wide mode and retains byte-mode
   behavior for compatibility.
5. The SDRAM write controller now keeps a row open across same-row ROM words,
   using explicit precharge only for row changes, reads, refresh, and the next
   transfer class. This removes repeated ACT/RCD overhead while preserving the
   original word address/data/byte-enable contract. The scrambled MCU addresses
   naturally take the safe row-change path when they do not match the open row.
6. The Debug Video OSD modes and their live video override were removed as
   requested. This trims diagnostic datapath logic from the eventual
   configuration image.
7. The Alien3/Jurassic Park gun radial-response experiment was removed from the
   live source and archived separately; the stable per-axis aim path is active.

## Verification completed without an RBF build

- WIDE loader: descriptor, main-CPU SDRAM word, MCU inverse mapping, EEPROM,
  and boot-gate test pass.
- Existing byte-mode ROM loader regression passes.
- EEPROM/NVRAM regression passes.
- End-to-end byte-mode HPS/SDRAM loader regression passes.
- SDRAM row-open throughput test passes: 16 same-row words use one ACT and no
  inter-word precharge; row changes still use explicit precharge/activate.

## Deferred hardware measurement

Do not build an RBF yet. After an explicit build request, compare:

- RBF configuration time;
- time from MRA transfer start to rom_loaded;
- total ROM transfer time for a large sprite-heavy set;
- first-frame/first-input readiness.

The WIDE change should roughly halve host-side ROM transfer transactions while
leaving the fixed stream offsets and SDRAM map unchanged. Hardware measurement
is required before claiming a numeric speedup.
