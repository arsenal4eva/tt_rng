# Minute TRNG — Technical Write-up
`tt_um_trng_arsenal4eva` · Tiny Tapeout (GF180MCU) · 50 MHz project clock

## 1. What this project is

A **true random number generator (TRNG)** for Tiny Tapeout. Unlike a PRNG
(LFSR, xorshift — deterministic, reproducible from a seed), this design harvests
**physical entropy**: the thermal/flicker-noise jitter of free-running ring
oscillators built from real foundry standard cells. On silicon the bitstream is
nondeterministic; in simulation a 32-bit LFSR stands in for the oscillators so
the digital back-end (synchronizer → debiaser → packer → hold register) can be
verified cycle-accurately.

Top-level interface (Tiny Tapeout standard):

| Port | Direction | Meaning |
|---|---|---|
| `ui_in[0]` | in | TRNG enable (ANDed with `ena`) |
| `ui_in[1]` | in | Test mode: stream raw bytes, skip the 60 s hold |
| `uo_out[7:0]` | out | `entropy_byte` (test mode) or latched `random_value` (normal mode) |
| `uio_*` | — | Unused, tied 0 (`uio_oe = 0`) |
| `clk` / `rst_n` | in | 50 MHz project clock, async-active-low reset |

## 2. Architecture, stage by stage

```
                    ┌─────────────┐
                    │ RO ×4 (13/29/53/101 clkinv stages)
                    │ free-running, async to clk
                    └──────┬──────┘
                           │ entropy_async = ro13 ^ ro29 ^ ro53 ^ ro101
              ┌────────────┴────────────┐
              │ 2-FF synchronizer       │  entropy_meta → entropy_sync
              │ (* async_reg *)         │  1 clk latency, kills metastability
              └────────────┬────────────┘
                           │ 1 sample / clock
              ┌────────────┴────────────┐
              │ Von Neumann debiaser    │  pair (0,1)→0, (1,0)→1, drop 00/11
              │ vn_first_bit/have_first │  2 clocks per candidate bit
              └────────────┬────────────┘
                           │ ≤1 clean bit / 2 clocks
              ┌────────────┴────────────┐
              │ Byte packer             │  vn_byte[6:0]+bit, vn_count 0→7
              │ entropy_byte + ready    │  8 clean bits = 1 byte
              └────────────┬────────────┘
                           │ byte + strobe
              ┌────────────┴────────────┐
              │ Minute hold register    │  random_value <= entropy_byte
              │ minute_counter to 3e9   │  every 60 s @ 50 MHz (1000 clks in sim)
              └────────────┬────────────┘
                           │  uo_out = test_mode ? entropy_byte : random_value
```

### 2.1 Entropy source — 4× ring oscillators, XOR-combined

`trng_ring_osc` (src/project.v) is a loop of `DEPTH` inverters. `DEPTH` **must be
odd** — an even loop latches, an odd loop has no stable state and oscillates at
`f ≈ 1 / (2 · DEPTH · t_pd)`. Four instances use **co-prime odd depths
13 / 29 / 53 / 101** so the oscillators run at four unrelated frequencies and
never lock into a fixed phase relationship. Their outputs are XORed:

```verilog
assign entropy_async = ro_125 ^ ro_251 ^ ro_503 ^ ro_1001; // net names are historical;
// driven by the 13 / 29 / 53 / 101 -stage rings respectively
```

Why XOR four instead of sampling one? A single RO sampled by `clk` can sit in a
long 0/1 run (bias) or, worst case, injection-lock to a clock harmonic and go
fully deterministic. XORing four mutually-prime oscillators guarantees the
combined signal toggles far faster than `clk` and that no single oscillator's
phase dominates — the sampled stream's transitions come from the *relative
drift* of the rings, which is exactly the component most perturbed by physical
jitter. This is the standard multi-oscillator TRNG construction (cf. Sunar et
al.), and XOR is free: one 4-input XOR tree per design.

Crucially, the inverters are **real foundry cells** —
`gf180mcu_fd_sc_mcu7t5v0__clkinv_1` with `(* keep, dont_touch *)` — not RTL
`not` gates (see §5.2 for why the flow forces this). On silicon each `clkinv`
contributes genuine propagation-delay jitter; in sim (`VERILATOR`/`__ICARUS__`)
the module ties `osc_out = 0` and the top level substitutes the LFSR (§2.6).

### 2.2 Clock-domain crossing — 2-flop synchronizer

`entropy_async` is asynchronous to `clk` (on silicon it toggles at hundreds of
MHz, unrelated to the 50 MHz project clock). Sampling it directly into logic
risks **metastability**: a flop catching a transition can hover mid-rail and
resolve unpredictably late. The design passes it through two back-to-back
flops marked `(* async_reg = "true" *)` (tells the tool to place them adjacent
and not optimize the chain away):

```verilog
entropy_meta <= entropy_async;   // first catch — may go metastable
entropy_sync <= entropy_meta;    // settles for 1 full clock before use
```

Cost: `entropy_sync` lags the pins by exactly **one clock**. You can see this in
the waveform: `entropy_meta` first rises at t = 210 ns, `entropy_sync` follows
at t = 230 ns — a clean 20 ns (1-cycle) skew that persists for the whole run
(§4.1).

### 2.3 De-biasing — Von Neumann extractor

Raw jitter samples are never 50/50 — one RO phase may dominate, routing may
favor 1s. The Von Neumann corrector removes *any* constant bias with a
beautifully simple property: for a biased-but-independent stream with P(1) = p,
the pairs `01` and `10` are **equally likely** (both `p(1−p)`). So:

| Pair (first, second) | Output | Why |
|---|---|---|
| (0, 1) | **0** | valid, unbiased |
| (1, 0) | **1** | valid, unbiased |
| (0, 0), (1, 1) | *dropped* | carry no entropy either way |

Implementation is a 2-state toggle. On alternating clocks `vn_have_first` is 0
("capture": latch `entropy_sync` into `vn_first_bit`) then 1 ("compare":
evaluate the pair, emit or drop, clear the flag). `vn_have_first` therefore
toggles **every single clock** (visible in the trace from t = 210 ns), while
`vn_count` advances only when a pair is *accepted* — compare the trace:
`vn_count` steps at 270, 310, 350, 430, 590 ns (accepted pairs) and stalls
across dropped 00/11 pairs. Throughput cost: 2 clocks per candidate bit, more
when pairs are dropped. With a fast-toggling source (sim LFSR, or fast XORed
ROs on silicon), a byte still completes in a few dozen clocks.

### 2.4 Byte packer

Accepted bits shift into `vn_byte[6:0]`; `vn_count` counts 0→7. On the 8th
accepted bit (`vn_count == 7`) the full byte `{vn_byte, new_bit}` lands in
`entropy_byte` and `entropy_byte_ready` strobes high. In the measured run the
**first byte (0xE8 = 232) lands at t = 1110 ns — ~45 clocks after enable**,
then bytes arrive roughly every 300–600 ns (15–30 clocks; the LFSR source
toggles nearly every clock so few pairs are dropped).

### 2.5 Minute hold register

`random_value` is the only thing a normal-mode user sees, and it updates only
when `minute_counter == MINUTE_COUNT`:

- **Silicon:** 32-bit counter to **2 999 999 999 ≈ 60 s @ 50 MHz**. A fresh
  8-bit secret about once a minute — the "Minute TRNG" name.
- **Sim:** 16-bit counter to **999 = 1000 clocks = 20 µs**, so tests don't run
  for a simulated minute.

The measured trace confirms the exactly-20 µs cadence:
`entropy_byte_ready` sets at t = 1110 ns and is **consumed at t = 20190 ns**
(20190 − 190 = 20000 ns = 1000 × 20 ns ✓), and `random_value` steps
`0 → 13 → 144 → 79 → 21 → 184 …` at 20190, 40190, 60190, 80190, 100190 ns —
a metronomic 20 µs grid. If no fresh byte is ready at the tick, the old value
is simply held (no stale-flag bug: `ready` is only cleared on consume).

When `trng_enable` (ena & ui_in[0]) is low, **everything** resets to zero —
synchronizer, VN state, packer, counter — so a disabled TRNG provably leaks
nothing on `uo_out`.

### 2.6 Simulation stand-in (LFSR)

Under `VERILATOR`/`__ICARUS__` the PDK cells don't exist, so the top level
replaces the four ROs with a 32-bit maximal-ish LFSR
(`x^32+x^22+x^2+x+1` style taps 31/21/1/0, seeded `0xA5C37F19`) advanced once
per clock, with `entropy_async = sim_entropy[0]`. **This is test scaffolding,
not the entropy source**: it exercises the synchronizer/VN/packer/hold timing
with a fast-toggling stream, but its output is deterministic. The GL (gate-level
netlist) simulation in the GDS flow uses the real `clkinv` cells and no LFSR.

## 3. How to read the waveforms (GTKWave: `test/tb.fst`)

Load `test/tb.fst` (`test/tb.gtkw` has a saved signal layout). Stimulus in the
measured run: reset 0–100 ns, idle to 200 ns, `ui_in = 0b11` (enable + test
mode) from 200 ns.

**"If this wave goes high, why does that one go low" — the causal chains:**

1. **`clk` → `entropy_meta` → `entropy_sync`.** Each rising `clk` copies the
   async source one stage forward. `meta` is the raw catch (may carry sim
   glitches — in silicon, possible metastability), `sync` is the settled copy
   exactly one clock behind. *If `meta` goes high at clock N, `sync` goes high
   at clock N+1, unconditionally* — it's a shift register, no gating.
2. **`entropy_sync` + `vn_have_first` → `vn_first_bit` / `vn_count`.** When
   `have_first` is low, the current `sync` sample is *latched* into `first_bit`
   (capture half). When high, the pair is *judged* (compare half): 01 appends a
   0 to `vn_byte` and bumps `vn_count`; 10 appends a 1; 00/11 leave both
   untouched. *So if `vn_count` stalls for several clocks while `have_first`
   keeps toggling, you are watching biased pairs being discarded — the
   debiaser doing its job, not a stuck circuit.*
3. **`vn_count == 7` + accepted pair → `entropy_byte` + `entropy_byte_ready↑`.**
   The byte register only moves on the 8th accepted bit; `ready` stays high
   until the minute tick consumes it. In test mode nothing consumes it, so
   `ready` simply remains high while `entropy_byte` keeps refreshing underneath
   (253 `entropy_byte` edges vs 17 `ready` edges in the run).
4. **`minute_counter == 999` → `random_value <= entropy_byte`, `ready↓`,
   counter wraps.** The 20 µs grid in `random_value` (13, 144, 79, 21, 184…)
   is the heartbeat to look for: *if `random_value` steps exactly on that grid
   in sim, the whole pipeline — ROs→sync→VN→packer→hold — is alive.*
5. **`uo_out` = mux.** Test mode (`ui_in[1]=1`): follows `entropy_byte`
   (hyperactive, ~0.5 µs per change). Normal mode: follows `random_value`
   (steps every 20 µs sim / 60 s silicon). *If `uo_out` looks frozen in normal
   mode, that is correct behavior between ticks — switch to test mode to see
   the live stream.*

## 4. Measured numbers (20 ns clock, enable @ 200 ns)

| Event | Time | Note |
|---|---|---|
| `entropy_meta` first toggle | 210 ns | 1st sync stage catches source |
| `entropy_sync` first toggle | 230 ns | exactly +1 clock (sync latency proven) |
| `vn_count` 0→1 | 270 ns | first accepted VN pair |
| First `entropy_byte` = 0xE8 (232) | 1110 ns | 8 accepted bits in ~45 clocks |
| Byte rate (test mode) | ~300–600 ns/byte | 15–30 clocks; LFSR source |
| `ready` consumed, `random_value` = 13 | 20190 ns | 1000-clock sim minute ✓ |
| `random_value` cadence | every 20000 ns | 13 → 144 → 79 → 21 → 184 → … |
| Distinct bytes, 5000 cycles | 116 / 256 | LFSR stream; silicon distribution will differ |

## 5. Learnings, failures, successes

### 5.1 Failure: SKY130 cells on a GF180 shuttle
The first RTL instantiated `sky130_fd_sc_hd__inv_2` directly, but the GDS
workflow hardens for **`gf180mcuD`** — there is no `sky130_*` cell there, so
lint/synthesis/precheck could never pass. Lesson: **the PDK in
`.github/workflows/gds.yaml` is the ground truth; every hard cell reference
must exist in that exact PDK version.** Verified against the mapped netlist in
a failed run's logs, which showed the real cell prefix
`gf180mcu_fd_sc_mcu7t5v0__`.

### 5.2 Failure: Yosys rejects combinational loops (×4)
Rewriting the rings with generic RTL `not` gates moved the failure to
`Checker.YosysSynthChecks`: `found logic loop in module $paramod\trng_ring_osc`
— one error per oscillator. The TT flow treats *any* RTL-level combinational
loop as a hard error, and a ring oscillator **is** a combinational loop, so no
RTL-gate formulation can ever pass. Fix: instantiate the loop out of **real
PDK stdcells** (`...__clkinv_1`, `.I`/`.ZN` pinout confirmed from the mapped
netlist). To Yosys' RTL loop check the ring is now opaque hierarchical cells;
to the back-end it maps 1:1 to silicon. Lesson: **in a hardened-flow TRNG, the
entropy loop must live below the abstraction level the loop-checker inspects.**

### 5.3 Failure: bogus Verilator lint code
A `/* verilator lint_off CIRCULAR */` pragma killed step `01-verilator-lint`:
`CIRCULAR` is not a Verilator message class. Only `UNOPTFLAT`/`COMBDLY` remain.
Lesson: check pragma codes against the installed Verilator manual (v5.044 here),
not memory.

### 5.4 Gotcha: simulators elaborate uninstantiated modules
`trng_ring_osc` must carry its **own** `VERILATOR`/`__ICARUS__` tie-off even
though the top level never instantiates it in sim — Icarus elaborates every
module in the compilation and errors on the unknown PDK cell otherwise. The
original code had this guard; removing it broke even local sim. Related trap:
`` `elsif __ICARUS__ `` tests *defined-ness*, so passing `-D__ICARUS__` (empty)
still selects the branch — but it also *shadows* nothing here; the real fix was
the in-module guard, after which plain `iverilog` works with no `-D` at all.

### 5.5 Successes
- **Methodology**: multi-oscillator XOR + 2-FF sync + Von Neumann + packer +
  hold is the textbook jitter-TRNG pipeline, and each stage's timing is now
  measured, not assumed (§4).
- **Area**: ring depths 125/251/503/1001 → 13/29/53/101 cut ~1879 inverters to
  ~196 with identical topology (odd, co-prime) — comfortably inside one tile.
- **Reproducibility**: `test/requirements.txt` pinned to `cocotb==2.1.0`;
  `test.yaml` gate (`errors="0" failures="0"`) passes locally.
- **Waveform proof**: the 1-clock sync skew, the VN accept/drop rhythm, the
  exact 1000-clock hold cadence, and 116 distinct bytes / 5000 cycles are all
  captured above — anyone with `tb.fst` can check every claim.

## 6. What "better" would look like (future work)
- **Online health monitoring**: repetition-count + adaptive-proportion tests
  (NIST SP 800-90B) with a fail flag on `uio_out` — currently a silent stall is
  indistinguishable from bad luck without statistical post-processing.
- **Post-processing**: a lightweight conditioner (e.g. SHA-256 absorb or at
  least an LFSR whitener) so raw bias never reaches the pins even if one RO
  dies.
- **GL-sim entropy proof**: collect the gate-level RO bitstream and run
  `dieharder`/ent to demonstrate the silicon path (not just the LFSR stand-in)
  produces full-entropy bytes.
- **PVT characterization**: RO frequency spread across corners from the STA
  reports, to confirm the rings can't harmonically lock to 50 MHz anywhere in
  the operating range.
