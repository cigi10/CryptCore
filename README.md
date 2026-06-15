# CryptCore : AES-256 Hardware Accelerator SoC on Artix-7

A fully pipelined AES-256 encryption core integrated into a MicroBlaze SoC on the Digilent Arty A7-100T. The core hits **1 block per clock cycle** throughput at **100 MHz**, which works out to **12.8 GB/s** of encryption bandwidth. Timing closure verified at 100 MHz with **WNS = +1.845 ns** and zero failing endpoints.

---

## Architecture

<img width="1920" height="1080" alt="arch" src="https://github.com/user-attachments/assets/6b12cc22-1a29-471c-81b7-e4d03ad2ea0e" />

The diagram above shows the full system. The 100 MHz oscillator on the Arty A7 feeds into an MMCM (via the Clocking Wizard), which cleans up the clock and drives everything on one global clock network. MicroBlaze sits at the center : it fetches instructions and data from BRAM over two separate LMB buses, and talks to all peripherals over a single AXI master port (M_AXI_DP). The AXI SmartConnect handles address decoding and fans that out to three slaves: the AES accelerator, UARTLite, and the interrupt controller. The Processor System Reset module makes sure nothing starts running until the MMCM has locked.

```
clk_in1_0 (100 MHz)
      |
  clk_wiz_1 (MMCM)
      |
      +--- MicroBlaze (32-bit soft CPU)
      |         | M_AXI_DP
      |         v
      |    AXI SmartConnect (1S / 3M)
      |         |
      |    +----+---------------+
      |    v    v               v
      |  aes256  axi_uartlite  axi_intc
      |  wrapper    (UART)     (IRQ)
      |
      +--- Local Memory (BRAM, ILMB + DLMB)
```

---

## AES-256 Pipeline

<img width="1920" height="1080" alt="pipeline" src="https://github.com/user-attachments/assets/e4913f0a-110d-457b-afd4-e8ce2a145a6e" />


The pipeline runs 29 stages with 29-cycle latency. The diagram shows how plaintext enters Stage 0 (the initial AddRoundKey), works through 13 rounds split into two registered half-stages each, then exits through the three-stage final round.

```
Plaintext -> [Stage 0: ARK0] -> [Stages 1-26: 13 rounds x 2 half-stages]
          -> [Stage 27: SubBytes] -> [Stage 28: ShiftRows] -> [Stage 29: ARK_final] -> Ciphertext
```

Each of the 13 full rounds is split into two registered half-stages:

- **Half A** : SubBytes + ShiftRows, registered into `stage[2i-1]`
- **Half B** : MixColumns + AddRoundKey, registered into `stage[2i]`

The final round has no MixColumns (per FIPS-197), so it gets three dedicated stages instead of two. Total: 1 + 26 + 3 = 30 pipeline registers, 29 clock cycles of latency.

### Why split each round in half?

A full AES round : SubBytes, ShiftRows, MixColumns, AddRoundKey : has way too much combinational logic to fit in a single 10 ns clock period. When I first tried running a full round per stage, synthesis failed timing badly. Splitting at the SubBytes/ShiftRows boundary worked because those two operations are actually pretty light (SubBytes is parallel LUT lookups, ShiftRows is free wiring), while MixColumns and AddRoundKey fill the second half without going over budget. Both halves end up roughly balanced in combinational depth, which is exactly what you want.

### The final round problem

The original version had SubBytes, ShiftRows, and AddRoundKey all chained combinationally into a single stage for the final round. That made it the critical path : it was longer than any of the regular half-stages. Splitting it into three separate registered stages (stages 27, 28, 29) fixed that and brought WNS up to +1.845 ns.

---

## AXI4-Lite Interface

<img width="1920" height="1080" alt="axi_flow" src="https://github.com/user-attachments/assets/8a131e7a-1cbc-48e0-8a4f-06573a0e2d7c" />

The transaction flow diagram shows the full sequence from key load through ciphertext readback. MicroBlaze sends 8 AXI writes to load the key, one write to trigger key expansion, 4 writes for plaintext, one write to start encryption, then polls STATUS until bit 0 goes high, then reads 4 ciphertext words.

### Register Map

<img width="1920" height="1080" alt="axi_regfile" src="https://github.com/user-attachments/assets/1ce3b460-e7e3-4a14-977a-61e054f80eab" />


| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CTRL | W | `[0]` start encrypt, `[1]` load key (both pulse 1 cycle) |
| 0x04 | STATUS | R | `[0]` done : set when ciphertext is ready, clears on next start |
| 0x08-0x24 | KEY[0..7] | W | 256-bit key, MSW first (KEY[0] = bits [255:224]) |
| 0x28-0x34 | PT[0..3] | W | 128-bit plaintext, MSW first |
| 0x38-0x44 | CT[0..3] | R | 128-bit ciphertext, MSW first (latched on `valid_out`) |

### Writing the AXI wrapper

The AXI slave was the most tedious part of this project. The AW (write address) and W (write data) channels are independent : the spec doesn't guarantee they arrive in the same cycle, so you need two separate latches and only execute the write when both are valid. I initially had a bug where I only checked for one of them, which worked fine in simulation (the testbench happened to always send them together) but would have broken on real hardware with a less cooperative master. The fix was adding `write_addr_valid` and `write_data_valid` flags and only committing the register write when both are set.

The other thing that bit me was the STATUS register. The first version never cleared `status_done` when a new encryption started, so the CPU would read a stale 1 from the previous operation and immediately think it was done. Added a clear in the `core_valid_in` branch of the always block and it worked after that.

### Polling vs interrupts

The interrupt controller (axi_intc_0) is wired up in the block design and UARTLite uses it. The AES wrapper doesn't connect to it : it just exposes STATUS[0] for polling. The reason is straightforward: at 100 MHz the pipeline finishes in 290 ns. Setting up and returning from an interrupt on MicroBlaze takes hundreds of nanoseconds to several microseconds, so interrupt overhead would actually be longer than the computation. Polling wins here. UART is different because a byte might not arrive for milliseconds, so burning CPU cycles waiting for it would be wasteful.

---

## Timing Closure

<img width="969" height="287" alt="image" src="https://github.com/user-attachments/assets/b85abfe0-f746-4d33-9485-5b5280f5b87b" />

Getting timing to close was the main challenge. Synthesis passed fine, but after place and route I had two violations.

### Fix 1 : key schedule fan-out

The original design had the AXI key registers feeding combinationally into `keyExpansion`, whose 1920-bit output fanned out directly to every `addRoundKey` instance across all 29 pipeline stages. The timing tool saw a path from the AXI register flip-flops, through 50+ levels of key schedule logic, through an addRoundKey, to a pipeline stage register : all in one clock cycle. Nothing closes that at 100 MHz.

The fix was a single register:

```verilog
reg [1919:0] round_keys_reg;
always @(posedge clk) begin
    if (key_ready)
        round_keys_reg <= round_keys_raw;
end
```

Now the timing tool sees two separate paths instead of one massive one. Each is closable in a single cycle.

The multicycle path constraint in the XDC handles the fact that `keyExpansion` takes 60 cycles to produce valid output:

```tcl
set_multicycle_path -setup 16 -from [get_cells *key_reg_reg*] \
                               -to   [get_cells *round_keys_reg_reg*]
set_multicycle_path -hold  15 -from [get_cells *key_reg_reg*] \
                               -to   [get_cells *round_keys_reg_reg*]
```

Without this constraint the tool treats it as a single-cycle path and flags it as a violation even though the design is functionally correct.

### Fix 2 : final round stage

Covered above under the pipeline section. Splitting the three-operation chain into three registered stages resolved it.

### Results

| Metric | Value |
|--------|-------|
| WNS | **+1.845 ns** |
| TNS | 0.000 ns |
| WHS | +0.031 ns |
| THS | 0.000 ns |
| Failing endpoints | **0** |
| Clock | 100 MHz |

The worst path after all fixes is a register-to-register connection between adjacent pipeline stages with almost no logic between them : it's basically just routing delay. Vivado reported 93.5% of that path's delay was routing and 6.5% was logic, which is typical for wide pipelines where 128-bit buses have to traverse the fabric.

### Remaining warnings

**TIMING-6** : Vivado creates two internal names for the same MMCM output clock (`clk_out1_crypto_soc_clk_wiz_1_1` and `clk_out1_crypto_soc_clk_wiz_1_1_1`). The timing tool sees two clocks with paths between them and warns about the unconstrained relationship. Fix is:

```tcl
set_clock_groups -physically_exclusive \
    -group [get_clocks clk_out1_crypto_soc_clk_wiz_1_1] \
    -group [get_clocks clk_out1_crypto_soc_clk_wiz_1_1_1]
```

**LUTAR-1** : a LUT is driving an async reset pin somewhere in the Xilinx IP hierarchy, not in any of my RTL. My pipeline uses synchronous resets throughout (`if (rst)` inside `always @(posedge clk)`), so this isn't from anything I wrote.

---

## Resource Utilization

<img width="695" height="478" alt="image" src="https://github.com/user-attachments/assets/60a2b8e3-111d-4a52-ad7e-3d86f397e97b" />

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 15,616 | 63,400 | 24.6% |
| Slice Registers | 11,461 | 126,800 | 9.0% |
| F7/F8 Muxes | 6,606 | - | - |
| Block RAM (36K) | 16 | 135 | 11.9% |
| DSPs | **0** | 240 | 0.0% |
| IOBs | 4 | 210 | 1.9% |
| MMCME2_ADV | 1 | 6 | 16.7% |

The F7/F8 mux count (6,606 total) is higher than it looks like it should be. That's the S-box. Each 256-entry `case` statement synthesizes as a tree of LUT6 -> MUXF7 -> MUXF8 cascades, and with 16 S-boxes running in parallel per SubBytes instance across 14 pipeline stages, it adds up fast.

Zero DSPs is worth noting : MixColumns uses GF(2^8) arithmetic, but all of that maps to shifts and XOR gates. No integer multiplication anywhere, so DSP48 blocks are completely unused.

The dominant flip-flop count comes from `round_keys_reg` (1,920 bits) plus the 29-stage data pipeline (128 bits × 29 stages = 3,712 bits), plus AXI state registers and the `vld` chain.

---

## Power

<img width="695" height="432" alt="image" src="https://github.com/user-attachments/assets/cff2f654-76f8-4374-be72-e4b79579d08b" />


| Component | Power |
|-----------|-------|
| Total on-chip | 0.713 W |
| Dynamic | 0.613 W |
| &nbsp;&nbsp;AES wrapper | 0.480 W (78% of dynamic) |
| &nbsp;&nbsp;MMCM | 0.106 W |
| &nbsp;&nbsp;MicroBlaze | 0.015 W |
| Static | 0.100 W |
| Junction temperature | 28.3°C |
| Max ambient | 81.7°C |

The AES wrapper dominates because all 29 pipeline stages are switching 128 bits of data every single clock cycle simultaneously. MicroBlaze running at the same 100 MHz only draws 0.015 W because most of its datapath is idle on any given instruction. The MMCM's 0.106 W is fixed overhead regardless of what the design does.

---

## Verification

<img width="1150" height="756" alt="image" src="https://github.com/user-attachments/assets/50d2747c-dc2b-44f7-9ed9-19b5aa1f8296" />

<img width="1150" height="717" alt="image" src="https://github.com/user-attachments/assets/85e1bd84-be09-43c1-bea4-4f7d4f4fd943" />


All tests run against NIST FIPS-197 official vectors in simulation.

| Test | Result |
|------|--------|
| NIST vector: key=`000102...1e1f`, pt=`00112233...eeff` -> `8ea2b7ca...6089` | PASS |
| All-zeros key and plaintext -> `dc95c078...2087` | PASS |
| All-zeros key, all-ones plaintext -> `acdace80...1347` | PASS |
| All-ones key, all-zeros plaintext -> `4bf85f1b...dcb` | PASS |
| Key change: different keys produce different ciphertext | PASS |
| Avalanche: single plaintext bit flip -> >48/128 output bits change | PASS |
| Reset: pipeline flush produces no ghost `valid_out` | PASS |
| Back-to-back: 4 consecutive blocks produce 4 consecutive outputs | PASS |
| AXI full flow (key load -> encrypt -> poll -> read CT) | PASS |
| STATUS register clears on new start, sets on completion | PASS |

Two separate testbenches were used on purpose. `aes256_core_tb` drives the pipeline directly (no AXI) and tests algorithmic correctness. `aes256_soc_tb` drives AXI signals through tasks that simulate CPU behavior and tests the wrapper logic. If a test fails in the SoC bench but passes in the core bench, the bug is in the AXI wrapper. If both fail, it's in the pipeline itself. That separation made debugging much faster.

The avalanche test XORs the ciphertext outputs for all-zeros plaintext vs plaintext with just the last bit flipped, then counts how many bits changed. AES should flip roughly 64 of 128 bits from a single input bit change : the test uses 48 as a conservative threshold. This is mainly there to catch a broken MixColumns, which would show up as almost no diffusion.

The reset test applies reset mid-pipeline (while a block is partially processed) and then waits more than 29 cycles to confirm no ghost `valid_out` appears. A spurious output here would be a real problem since the CPU would read stale ciphertext and think it was fresh.

---

## Key Design Decisions

**29 stages.** Each of AES-256's 14 rounds has too much combinational depth to run at 100 MHz as a single stage. Splitting each round into two registered half-stages keeps the per-stage logic thin enough. The exact split : SubBytes+ShiftRows in Half A, MixColumns+AddRoundKey in Half B : balances both halves reasonably well.

**Polling.** 290 ns pipeline latency. Interrupt overhead on MicroBlaze is in the same ballpark or worse, so polling is just more efficient here. Interrupts are reserved for UARTLite where arrival time is unpredictable.

**ECB mode.** Scoping decision. ECB keeps each block independent which makes pipeline throughput easy to measure and verify. For real use you'd need CTR or GCM.

---

## Limitations and Future Work

- **ECB only** : identical plaintext blocks produce identical ciphertext. CTR mode would be the practical next step and gives decryption for free.
- **Encryption only** : a decryption pipeline would roughly double area.
- **No authentication** : no MAC or GCM tag, so ciphertext can be tampered with undetected.
- **CPU-bottlenecked throughput** : 12-20 AXI transactions per block means the CPU is the bottleneck, not the pipeline. DMA would fix this.
- **Fixed AES-256** : AES-128 and AES-192 not supported. The parameter `nk=8, nr=14` is there but the pipeline depth is hardcoded for 14 rounds.

---

## Target Hardware

**Digilent Arty A7-100T** (xc7a100tcsg324-1)

| Pin | Signal | Notes |
|-----|--------|-------|
| E3 | `clk_in1_0` | 100 MHz on-board oscillator |
| C2 | `reset_rtl_0` | BTN0, active-low |
| A9 | `UART_0_rxd` | USB-UART bridge RX |
| D10 | `UART_0_txd` | USB-UART bridge TX |

---

## Repository Structure

```
cryptcore/
├── rtl/
│   ├── aes256_pipelined.v        # 29-stage AES-256 pipeline core
│   ├── aes256_axi_wrapper.v      # AXI4-Lite slave wrapper + register file
│   ├── sbox.v                    # AES S-box (256-entry LUT)
│   ├── addRoundKey.v
│   ├── encryptRound.v
│   ├── keyExpansion.v
│   ├── mixColumns.v
│   ├── shiftRows.v
│   └── subBytes.v
├── bd/
│   └── crypto_soc.bd             # Vivado block design (MicroBlaze SoC)
├── constraints/
│   └── cryptcore_wrapper.xdc     # Pin assignments + timing constraints
├── sim/
│   ├── aes256_core_tb.v          # Pipeline core testbench
│   └── aes256_soc_tb.v           # AXI wrapper testbench
├── diagrams/
│   ├── arch.png
│   ├── pipeline.png
│   ├── axi_flow.png
│   └── axi_regfile.png
└── reports/
    ├── timing_summary.rpt
    ├── utilization.rpt
    └── power.rpt
```

---

## Tools

- Vivado 2025.2 (synthesis, implementation, timing analysis)
- Vitis / SDK (MicroBlaze software)
- Vivado Simulator (functional simulation)
- Target: xc7a100tcsg324-1, speed grade -1
