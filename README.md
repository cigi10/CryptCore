# CryptCore
CryptCore - AES-256 Hardware Accelerator SoC on Artix-7

A fully pipelined AES-256 encryption core integrated into a MicroBlaze SoC on the Digilent Arty A7-100T (Xilinx Artix-7). The core achieves **1 block per clock cycle** throughput at **100 MHz**, delivering **12.8 GB/s** of encryption bandwidth. Timing closure verified at 100 MHz with **WNS = +1.845 ns** and zero failing endpoints.

## Architecture

```
clk_in1_0 (100 MHz)
      │
  clk_wiz_1 (MMCM)
      │
      ├─── MicroBlaze (32-bit soft CPU)
      │         │ M_AXI_DP
      │         ▼
      │    AXI SmartConnect (1S / 3M)
      │         │
      │    ┌────┼──────────────┐
      │    ▼    ▼              ▼
      │  aes256  axi_uartlite  axi_intc
      │  wrapper    (UART)     (IRQ)
      │
      └─── Local Memory (BRAM, ILMB + DLMB)
```

### AES-256 Pipeline -> 29 stages, 29-cycle latency

```
Plaintext ─► [Stage 0: ARK0] ─► [Stages 1–26: 13 rounds × 2 half-stages]
           ─► [Stage 27: SubBytes] ─► [Stage 28: ShiftRows] ─► [Stage 29: ARK_final] ─► Ciphertext
```

Each of the 13 full rounds is split into two registered half-stages:

- **Half A** - SubBytes + ShiftRows → registered into `stage[2i−1]`
- **Half B** - MixColumns + AddRoundKey → registered into `stage[2i]`

The final round (no MixColumns per FIPS-197) occupies three dedicated stages. Total: 1 + 26 + 3 = 30 pipeline stages, resulting in 29 clock cycles of latency.

### AXI4-Lite Register Map

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | CTRL | W | `[0]` start encrypt · `[1]` load key (both pulse 1 cycle) |
| 0x04 | STATUS | R | `[0]` done - set when ciphertext is ready, clears on next start |
| 0x08–0x24 | KEY[0..7] | W | 256-bit key, MSW first (KEY[0] = bits [255:224]) |
| 0x28–0x34 | PT[0..3] | W | 128-bit plaintext, MSW first |
| 0x38–0x44 | CT[0..3] | R | 128-bit ciphertext, MSW first (latched on `valid_out`) |

## Results

### Timing (Vivado 2025.2, post-route physopt, xc7a100tcsg324-1)

| Metric | Value |
|--------|-------|
| WNS | **+1.845 ns** |
| TNS | 0.000 ns |
| WHS | +0.031 ns |
| THS | 0.000 ns |
| Failing endpoints | **0** |
| Clock | 100 MHz |

### Resource Utilization (xc7a100tcsg324-1)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 15,616 | 63,400 | 24.6% |
| Slice Registers | 11,461 | 126,800 | 9.0% |
| F7/F8 Muxes | 6,606 | - | - |
| Block RAM (36K) | 16 | 135 | 11.9% |
| DSPs | **0** | 240 | 0.0% |
| IOBs | 4 | 210 | 1.9% |
| MMCME2_ADV | 1 | 6 | 16.7% |

Zero DSPs: all GF(2⁸) arithmetic in MixColumns maps to LUTs and XOR gates - no integer multipliers needed.

### Power (vector-less, typical process, 25°C ambient)

| Component | Power |
|-----------|-------|
| Total on-chip | 0.713 W |
| Dynamic | 0.613 W |
| - AES wrapper | 0.480 W (78% of dynamic) |
| - MMCM | 0.106 W |
| - MicroBlaze | 0.015 W |
| Static | 0.100 W |
| Junction temperature | 28.3°C |
| Max ambient | 81.7°C |

The AES wrapper dominates dynamic power because all 29 pipeline stages switch 128 bits of data simultaneously every clock cycle.

### Verification

All tests against NIST FIPS-197 official vectors pass in simulation.

| Test | Result |
|------|--------|
| NIST vector: key=`000102...1e1f`, pt=`00112233...eeff` → `8ea2b7ca...6089` | PASS |
| All-zeros key and plaintext → `dc95c078...2087` | PASS |
| All-zeros key, all-ones plaintext → `acdace80...1347` | PASS |
| All-ones key, all-zeros plaintext → `4bf85f1b...dcb` | PASS |
| Key change: different keys produce different ciphertext | PASS |
| Avalanche: single plaintext bit flip → >48/128 output bits change | PASS |
| Reset: pipeline flush produces no ghost `valid_out` | PASS |
| Back-to-back: 4 consecutive blocks produce 4 consecutive outputs | PASS |
| AXI full flow (key load → encrypt → poll → read CT) | PASS |
| STATUS register clears on new start, sets on completion | PASS |

## Repository Structure

```
cryptcore/
├── rtl/
│   ├── aes256_pipelined.v        # 29-stage AES-256 pipeline core
│   ├── aes256_axi_wrapper.v      # AXI4-Lite slave wrapper + register file
│   └── sbox.v                    # AES S-box (256-entry LUT)
├── bd/
│   └── cryptcore.bd             # Vivado block design (MicroBlaze SoC)
├── constraints/
│   └── cryptcore_wrapper.xdc    # Pin assignments + timing constraints
├── sim/
│   ├── aes256_core_tb.v          # Pipeline core testbench (NIST vectors, avalanche, throughput)
│   └── aes256_soc_tb.v           # AXI wrapper testbench (full CPU transaction flow)
└── reports/
    ├── timing_summary.rpt
    ├── utilization.rpt
    └── power.rpt
```

## Key Design Decisions

**Why 29 stages?** 
Each of AES-256's 14 rounds contains too much combinational logic to fit within a 10 ns clock period at 100 MHz. Splitting each round into two registered half-stages - SubBytes + ShiftRows in the first, MixColumns + AddRoundKey in the second - keeps per-stage logic depth within timing budget. The final round's three stages balance depth with the rest of the pipeline.

**Why polling instead of interrupts for AES done?** 
The pipeline latency is 290 ns (29 cycles at 100 MHz). MicroBlaze interrupt handling overhead is on the order of hundreds of nanoseconds to microseconds - comparable to or greater than the computation itself. Polling is more efficient for predictable, short latencies. The UARTLite uses interrupts because a byte can arrive at any time and the wait could be milliseconds.

**Why ECB mode?** 
Deliberate scoping decision. Each block encrypts independently with no inter-block dependencies, which isolates the pipeline's performance cleanly. Production use would require CTR or GCM mode.

## Limitations and Future Work

- **ECB mode only** - CTR or GCM mode needed for real use
- **Encryption only** - CTR mode would give decryption for free
- **No authentication** - no MAC/GCM tag
- **CPU-bottlenecked throughput** - DMA would fully utilize the 1 block/cycle pipeline capacity
- **Fixed AES-256** - AES-128 and AES-192 not supported

## Target Hardware

**Digilent Arty A7-100T** (xc7a100tcsg324-1)

| Pin | Signal | Notes |
|-----|--------|-------|
| E3 | `clk_in1_0` | 100 MHz on-board oscillator |
| C2 | `reset_rtl_0` | BTN0, active-low |
| A9 | `UART_0_rxd` | USB-UART bridge RX |
| D10 | `UART_0_txd` | USB-UART bridge TX |

## Tools

- Vivado 2025.2 (synthesis, implementation, timing analysis)
- Vitis / SDK (MicroBlaze software development)
- Vivado Simulator (functional simulation)
- Target: xc7a100tcsg324-1, speed grade -1
