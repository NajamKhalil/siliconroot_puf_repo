# SiliconRoot-PUF: PUF-Based Device Authentication and Secret Key Generation IP - Design Specification

| | |
|---|---|
| Project | SiliconRoot-PUF |
| Block | `siliconroot_puf` (`rtl/siliconroot_puf.sv`) |
| Function | Challenge-response authentication and secret key generation built on a physical unclonable function, following Suh and Devadas, DAC 2007 |
| Source paper | G. Suh and S. Devadas, "Physical Unclonable Functions for Device Authentication and Secret Key Generation", DAC 2007 |
| Language | SystemVerilog-2012 |
| Target | FPGA/ASIC synthesizable RTL |
| Clocking | one clock, one asynchronous active-low reset |
| Response length | 127 bits (RO PUF), 64 bits (arbiter PUF) |
| Key length | 256 bits (SHA-256 of the corrected response) |
| Helper data | 63 bits (the BCH(127,64,21) syndrome) plus a 254-bit 1-out-of-4 mask |
| Command interface | one request-style port, eight commands, `done_o` completion pulse |
| Slowest command | RO enrolment, 1348 cycles measured |

---

## 1. What this is

A block that turns a **physical unclonable function** into two things the paper asks for: a **challenge-response authenticator** for a device, and a **secret key generator** whose key never leaves the chip and whose helper data is public.

The paper's premise is that every chip is born with a small, uncontrollable, unrepeatable physical variation - a manufacturing imperfection that no attacker can read out, copy or model. That variation *is* the secret. A PUF turns it into a stable bit string that is the same on every power-up of the same chip and different on every other chip. Everything else in this design is machinery for using that bit string safely:

* **The arbiter PUF** (paper section 2) turns a 64-bit challenge into a 64-bit response.
* **The RO PUF** (paper section 3) turns a challenge into a 127-bit response, protected by a **1-out-of-k mask** (section 3.2) and addressed by a **challenge rotation** (section 3.3).
* **The authentication comparator** (paper section 4) accepts a fresh response when it is within a Hamming tolerance of the recorded one.
* **The key generator** (paper section 5) stores a BCH syndrome instead of the response itself and re-derives the key on demand.

What this is **not**: it is not an implementation of the analogue PUF array. A PUF is a physical structure - ring oscillators, an arbiter delay chain - whose behaviour depends on the silicon it is fabricated on. Its parameters cannot be known before fabrication and cannot be fixed by an RTL description. So the boundary is drawn where the physics starts:

* `puf_ro_macro` and `puf_arbiter_macro` are **functional twins** of the two analogue structures. They are real RTL, they elaborate, they synthesise, and they reproduce the published inter-chip and intra-chip variation figures.
* In silicon, the analogue macros replace the twins and `dev_id_i` disappears with them. **Nothing above the twin boundary changes.**

That is the one architectural decision that everything else follows from, and it is stated here rather than buried: a PUF's *function* is digital, its *parameters* are physical.

---

## 2. Interface

### 2.1 Parameters

| Parameter | Default | Range | Meaning |
|---|---|---|---|
| `RESP_BITS` | 127 | exactly 127 | RO PUF response length in bits. The BCH(127,64,21) code of paper section 5 has `n = 127`, so any other value fails elaboration with a `$fatal` that names the value it got (section 12). |
| `ARB_BITS` | 64 | 1 .. 64 | Arbiter PUF response length in bits. The challenge vector of paper section 2 is 64 bits wide, so 64 is the natural maximum. |
| `K_MASK` | 4 | 1 .. `N_PAIRS/N_BITS` | Candidate oscillator pairs per output bit - the *k* of the 1-out-of-k mask of paper section 3.2. The paper uses 8; this block ships 4 (section 11.1). |
| `N_PAIRS` | 512 | a power of two | Number of oscillator pairs in the array. Must be a power of two so that the challenge rotation of section 3.3 is a plain mask rather than a modulo. |
| `CHAL_W` | 9 | `log2(N_PAIRS)` or wider | Width of the RO challenge. It is a rotation amount, not an index, so the challenge space is `N_PAIRS` rotations (section 11.2). |
| `CNT_W` | 16 | 1 .. 16 | Counter width inside the oscillator macro. The counter saturates at the end of the measurement window, so the count is a time measure. |
| `WIN_LEN` | 1024 | 1 .. `2^CNT_W` | Length of the measurement window in counter clocks. Both oscillators of a pair are counted over the same window, so the comparison is a ratio and not a race. |
| `TOL_BITS` | 10 | 0 .. `RESP_BITS-1` | Differing bits that still authenticate. 10 is the value the paper uses with its 128-bit RO response; the false-positive and false-negative figures of section 3.2 follow from it. |

`CAND_W` and `MASK_W` are derived, not parameters: `CAND_W = clog2(K_MASK)` and `MASK_W = RESP_BITS * CAND_W`. The mask entry of one output bit is the *rank* of the winning candidate, so it needs `log2(k)` bits and not `k` bits.

### 2.2 Ports

```systemverilog
input  logic                        clk_i      , // clock, rising edge
input  logic                        rst_ni    , // asynchronous reset, active low
input  logic [31:0]                 dev_id_i  , // device identifier, physical boundary
input  logic [3:0]                  env_i     , // environment code, 0 = nominal
input  logic                        cmd_valid_i, // command is presented
output logic                        cmd_ready_o, // the block accepts a new command
input  logic [3:0]                  cmd_i     , // the command
input  logic [63:0]                 arg_i     , // the command argument
output logic                        done_o    , // 1-cycle completion pulse
output logic                        err_o     , // 1 when the command failed
output logic [3:0]                  status_o  , // 0 = ok, 1 = decode failed, 2 = bad command
output logic [255:0]                key_o     , // the last derived secret key
output logic [RESP_BITS-1:0]        resp_o    , // the last RO PUF response
output logic [ARB_BITS-1:0]         arb_o     , // the last arbiter PUF response
output logic [62:0]                 synd_o    , // the last syndrome, the public helper data
output logic [MASK_W-1:0]           mask_o    , // the 1-out-of-k mask
output logic                        auth_ok_o  , // the last authentication verdict
output logic [7:0]                  auth_dist_o  // the distance of the last authentication
```

Two port choices beyond the bare list, each defended:

* **The command interface is one request-style port, not a register file.** The block performs eight operations, all of them long (263 to 4296 cycles, section 8) and none of them concurrent. A bus and an address map would add a write path, a read path and an address decoder to buy nothing: the host has one thing it wants to say at a time.
* **`dev_id_i` is a port, not a constant.** It is the twin's stand-in for "which physical chip this is". It exists so that the twins can model several devices in one simulation, and it is the port that disappears when the analogue macros take over.

### 2.3 The command set

| `cmd_i` | Name | `arg_i` | What it does | `done_o` after |
|---|---|---|---|---|
| 0 | `CMD_NOP` | - | nothing; returns immediately | 1 cycle |
| 1 | `CMD_ARB_RESP` | 64-bit challenge | evaluates the arbiter PUF, response on `arb_o` | 4293 cycles |
| 2 | `CMD_ARB_AUTH` | 64-bit challenge | evaluates the arbiter PUF and compares it with the stored reference; verdict on `auth_ok_o`, distance on `auth_dist_o` | 4296 cycles |
| 3 | `CMD_RO_ENROLL` | challenge | measures the RO PUF, derives the 1-out-of-4 mask, encodes the syndrome, derives the key; mask on `mask_o`, syndrome on `synd_o`, key on `key_o` | 1348 cycles |
| 4 | `CMD_RO_REGEN` | - | re-measures with the stored mask and challenge, decodes the syndrome difference, re-derives the key | 801 cycles |
| 5 | `CMD_RO_AUTH` | challenge | measures the RO PUF with the stored mask and compares it with the stored reference | 263 cycles |
| 6 | `CMD_ARB_REF_ST` | - | records the current `arb_o` as the arbiter reference | 1 cycle |
| 7 | `CMD_RO_REF_ST` | - | records the current `resp_o` as the RO reference | 1 cycle |
| other | - | - | rejected: `err_o` = 1, `status_o` = 2 | 1 cycle |

The handshake is: the host asserts `cmd_valid_i` with `cmd_i` and `arg_i` stable; the block drops `cmd_ready_o` for that cycle, runs, and pulses `done_o` for one cycle at the end with the results on the output ports. **The block never blocks and never waits for the host**: every command runs to completion on its own schedule, and the results stay on the outputs afterwards so a host can read them without a second transaction.

The reference-store commands are the paper's "trusted party database", moved on-chip (section 11.3). The paper keeps the enrolled response in a database the verifier queries; this block keeps it in two registers, because the register is cheaper than the protocol that would fetch it.

---

## 3. The physical boundary

### 3.1 The RO PUF twin

`puf_ro_macro` models the array of paper figure 3: `N_PAIRS` pairs of ring oscillators, each pair sharing a common enable and each oscillator counting in its own free-running counter. Both counters of a pair are measured over the same window, so the comparison is between two integers and not between two times.

* The **device-specific part** of every oscillator is derived from `dev_id_i` and the oscillator index through a 32-bit avalanche hash, so two devices get uncorrelated oscillator pairs and one device gets a fixed set.
* The **environment part** is a second hash, mixed in only when `env_i != 0`. It perturbs every oscillator slightly and in the same direction, which is what a temperature or supply change does to a ring oscillator.
* The **design common part** is a fixed constant, so the two oscillators of a pair are close before any of them is perturbed - close enough that the mask logic has something to rank, far enough that the ranking is stable.

The twin is not a random-number generator. It is a deterministic function of `(dev_id_i, env_i, oscillator index)` with a calibrated statistical shape: the sweep in `sim/calibrate_models.py` reproduces the published **46.15 % inter-chip** and **0.48 % intra-chip** bit variation of the paper's 128-bit RO PUF.

### 3.2 The arbiter PUF twin

`puf_arbiter_macro` models the 64-stage switching box of paper figure 1: two delay paths, a chain of 64 MUX stages, and an arbiter at the end that reports which path arrived first. The chain is walked **one stage per clock**, which is what an arbiter does in silicon and what makes the 4293-cycle latency of section 8.

* The **delay of each stage** is the design common skew plus the device-specific part plus the environment part, all in Q16 fixed point.
* The **sign of the accumulated difference** decides the verdict: the arbiter reports 1 when the top path is faster.
* The **challenge vector** `x_i` configures the MUX of each stage; the parity of the swaps along the way is what the 64-bit response encodes.

The twin reproduces the published **23 % inter-chip** and **0.7 % intra-chip** bit variation of the 64-stage arbiter PUF.

### 3.3 Why the twins are in `rtl/` and not in `sim/`

If the macros were black boxes in `sim/`, the synthesis flow would have nothing to elaborate and the design could not be checked at all. Putting the twins in `rtl/` means the whole tree elaborates, lints, simulates and synthesises as one design, and the *only* thing that changes in silicon is which cells implement the two macro instances. The cost is that the twins are large - `puf_ro_macro` is 41964 cells after synthesis - and the benefit is that the digital half of the design is verified against a structure that behaves like the physical one.

---

## 4. Architecture

```
+=====================================================================+
| siliconroot_puf                                                    |
|                                                                      |
|  cmd_valid_i/cmd_i/arg_i                                             |
|        |                                                             |
|        v                                                             |
|  +------------------+   start/seed   +------------------+            |
|  |                  |---------------->|                  |            |
|  |  command decode  |                |  u_arb           |            |
|  |  and sequencer   |                |  puf_arbiter_puf |            |
|  |                  |                |   +------------+ |            |
|  |                  |                |   | u_prng     | |            |
|  |                  |                |   +------------+ |            |
|  |                  |                |   | u_arb      | |            |
|  |                  |                |   |  (macro)   | |            |
|  |                  |                |   +------------+ |            |
|  |                  |                +------------------+            |
|  |                  |                                                |
|  |                  |   challenge    +------------------+            |
|  |                  |--------------->|                  |            |
|  |                  |                |  u_ro            |            |
|  |                  |   mask         |  puf_ro_sensor   |            |
|  |                  |<-------------->|   +------------+ |            |
|  |                  |                |   | u_macro    | |            |
|  |                  |                |   |  (RO array)| |            |
|  |                  |                |   +------------+ |            |
|  |                  |                +------------------+            |
|  |                  |                                                |
|  |                  |   response     +------------------+            |
|  |                  |--------------->|                  |            |
|  |                  |                |  u_key           |            |
|  |                  |   key          |  puf_key_gen     |            |
|  |                  |<---------------|   +------------+  |            |
|  |                  |                |   | u_enc  BCH |  |            |
|  |                  |                |   +------------+  |            |
|  |                  |                |   | u_dec  BCH |  |            |
|  |                  |                |   +------------+  |            |
|  |                  |                |   | u_sha  SHA |  |            |
|  |                  |                |   +------------+  |            |
|  |                  |                +------------------+            |
|  |                  |                                                |
|  |                  |   ref/resp     +------------------+            |
|  |                  |--------------->|  u_cmp_arb      |            |
|  |                  |                |  puf_auth(64)    |            |
|  |                  |                +------------------+            |
|  |                  |   ref/resp     +------------------+            |
|  |                  |--------------->|  u_cmp_ro       |            |
|  |                  |                |  puf_auth(127)   |            |
|  |                  |                +------------------+            |
|  +------------------+                                                |
|        | key_o resp_o arb_o synd_o mask_o auth_ok_o auth_dist_o       |
+=====================================================================+
   clk_i, rst_ni ---> every block (one clock domain)
```

```
   cmd_i/arg_i --> u_device_auth_ip FSM --> u_arb / u_ro / u_key / u_cmp_*
   u_arb   --> u_prng (64-bit Galois LFSR) + u_arb (64-stage delay chain)
   u_ro    --> u_macro (512 oscillator pairs), mask and challenge rotation
   u_key   --> u_enc (syndrome) -> u_dec (BCH decode) -> u_sha (SHA-256)
   u_cmp_* --> puf_auth, tolerance comparison, 8 bits per cycle
```

### 4.1 The idea

The paper's two applications share one idea and differ in what they do with the response.

**Authentication** compares two responses and asks whether they are close enough. The response is noisy - it drifts with temperature and with supply - so the comparison has a tolerance, and the paper's analysis (section 4) shows that with a 128-bit response and a tolerance of 10, the false-positive probability is about `2.1e-21` and the false-negative probability is below `5e-11`.

**Key generation** must do better than that: a key must be *exactly* the same every time, so a tolerance is not good enough. The paper's answer (section 5, figure 5) is to add error correction. The raw response `w` (127 bits) is encoded with a BCH(127,64,21) code; the **syndrome** `s = w mod g(x)` (63 bits) is stored as public helper data. At any later time the chip measures a noisy `w'`, computes its own syndrome `s'`, forms the difference `d = s' XOR s`, and the error pattern in `w' XOR w` is the error pattern of `d` - because a codeword has zero syndrome. A BCH decoder recovers the error pattern from `d` and therefore recovers `w`. The key is then `SHA-256(w)`.

The whole security argument is in that last step: **the helper data is the syndrome, not the response.** The syndrome does not reveal the response - recovering `w` from `s` alone is the decoding problem that the BCH code deliberately does not make easy - and the noise in `w'` is corrected rather than tolerated.

### 4.2 The 1-out-of-k mask (paper section 3.2)

A raw RO PUF response is not stable enough to authenticate directly: the bit that flips is decided by how close the two oscillators of a pair are. The paper's fix is to keep **k** candidate pairs per output bit and to publish only the *index of the winner* - the candidate whose two oscillators are furthest apart. The published mask is then `log2(k)` bits per output bit, and the mask is public helper data.

The mask is applied on **re-generation**, not at enrolment. At enrolment the sensor measures every candidate of every bit and records the winner; at re-generation it measures only the selected candidate of each bit, which is both faster (263 cycles instead of 1348) and the whole point of the mask: the published data says *which* pair to trust.

The candidate distance is `|count_a - count_b|`, the absolute difference of the two counters of the pair over the measurement window, and the wider the gap the more stable the bit.

### 4.3 The challenge (paper section 3.3)

The RO PUF is addressed by a challenge. In the paper the challenge selects which oscillator pairs take part, which gives an exponential challenge space. This block uses a **rotation** of the pair space instead: pair `(i, k)` is read at index `(i * K_MASK + k + challenge) mod N_PAIRS`. With `N_PAIRS` a power of two the rotation is a plain mask, and the challenge space is 512 values rather than `2^512`. The trade is stated in section 11.2.

The rotation is a **bijection** on the pair space, which is the property that matters: two different challenges never read the same pair twice, so a challenge genuinely moves the measurement around the array.

---

## 5. Module hierarchy

```
siliconroot_puf          rtl/siliconroot_puf.sv   top: ports, command decode, sequencer
+-- u_arb                   rtl/puf_arbiter_puf.sv      arbiter PUF: PRNG plus the delay chain
|   +-- u_prng              rtl/puf_prng.sv             64-bit Galois LFSR, x^64+x^4+x^3+x+1
|   +-- u_arb               rtl/puf_arbiter_macro.sv    64-stage arbiter delay chain (twin)
+-- u_ro                    rtl/puf_ro_sensor.sv        RO PUF front end: mask, challenge, ranking
|   +-- u_macro             rtl/puf_ro_macro.sv         512-pair ring oscillator array (twin)
+-- u_key                   rtl/puf_key_gen.sv          figure 5 flow: syndrome, decode, hash
|   +-- u_enc               rtl/puf_bch_enc.sv          BCH syndrome encoder
|   +-- u_dec               rtl/puf_bch_dec.sv          Berlekamp-Massey and Chien decoder
|   +-- u_sha               rtl/puf_sha256.sv           FIPS 180-4 SHA-256, one block
+-- u_cmp_arb               rtl/puf_auth.sv             tolerance comparison, 64-bit instance
+-- u_cmp_ro                rtl/puf_auth.sv             tolerance comparison, 127-bit instance
```

Eleven source files, twelve module instances, one clock domain.

### 5.1 `puf_ro_sensor`

The RO PUF front end. It owns the mask and the response and it is the module that implements paper sections 3.1 to 3.3.

* **Enrolment** (`derive_i` = 1): for each of the 127 output bits, measure the `K_MASK` candidate pairs, keep the one with the widest distance, and record its rank in the mask. The response bit is `count_a > count_b` of the winning candidate.
* **Re-generation** (`derive_i` = 0): for each output bit, read only the candidate the mask names and take its comparison bit.
* **The challenge rotation** is applied to the pair index on every read, in both modes.
* The measurement window is opened once per run and every pair is read inside the same window, so all 512 pairs are compared under one set of conditions.

### 5.2 `puf_arbiter_puf`

The arbiter PUF of paper section 2. The 64-bit challenge seeds the PRNG; the PRNG produces 64 challenge vectors `x_i`, one per response bit; each vector is evaluated by the delay chain and the arbiter verdict becomes one response bit.

* The **Galois LFSR** has the primitive polynomial `x^64 + x^4 + x^3 + x + 1`; the all-zero seed is replaced by one, because zero is a fixed point of the recurrence.
* The chain is walked one stage per clock, so 64 response bits cost 64 walks of 64 stages: 4096 clocks plus the control overhead, which is the 4293 cycles of section 8.

### 5.3 `puf_key_gen`

The flow of paper figure 5, one command at a time.

* **Initialisation** (`regen_i` = 0): the fresh response is encoded to its syndrome, and the syndrome becomes the public helper data. The key is the SHA-256 of the *uncorrected* response - there is nothing to correct yet.
* **Re-generation** (`regen_i` = 1): the fresh response is encoded to `s'`, the stored syndrome is `s`, the difference `d = s' XOR s` is decoded into an error pattern, the error pattern is corrected out of the response, and the SHA-256 of the corrected response is the key.
* The **verification pass** after the Chien search re-encodes the corrected word and compares the syndrome with `s`; a mismatch sets `fail_o`, which the top level turns into `err_o` and `status_o` = 1. The decoder never returns a key it cannot vouch for.
* The **SHA-256 block** is built directly: the 127-bit message occupies the top of the 512-bit block, the mandatory one bit sits below it, and the length field carries 127. There is no second block, because 127 bits of message plus padding still fit in one.

### 5.4 `puf_auth`

The tolerance comparison of paper section 4, in eight-bit groups: the responses are XORed, the difference is split into eight-bit groups, and each group is counted in parallel, so the whole 127-bit distance takes one cycle.

`ok_o` is `dist_o <= TOL_BITS`. The distance is delivered as well as the verdict, because the paper's analysis is about the distribution of that distance and a host that wants to tighten the policy needs the number, not only the yes.

### 5.5 `puf_bch_enc` and `puf_bch_dec`

The encoder computes the syndrome of a 127-bit word modulo `g(x) = 0xa1ab815bc7ec8025` (degree 63) over GF(2^7) with the primitive polynomial `x^7 + x^3 + 1`, using the 63 roots of `g(x)` in GF(2^7). The decoder runs the classic Berlekamp-Massey algorithm for the error locator, a Chien search for the error positions, and a verification re-encode.

The minimum distance of the code is 21, so it corrects **10 errors** - exactly the tolerance the paper uses for the response, which is why the correction radius and the authentication tolerance are the same number.

---

## 6. Storage layout and cost

There is no memory in this block - every store is a register file, which is why the heterogeneous form is the honest one:

| Element | Size | Implementation |
|---|---|---|
| top-level sequencer: `state_q`, `cmd_q`, `arg_q` | 4 + 4 + 64 bits | registers |
| top-level RO state: `mask_q`, `synd_q`, `ro_ref_q`, `ro_resp_q` | 254 + 63 + 127 + 127 bits | registers |
| top-level arbiter state: `arb_ref_q`, `arb_resp_q` | 64 + 64 bits | registers |
| `puf_ro_sensor`: `chal_q`, `bit_q`, `cand_q`, `cand_bit_q`, `cand_dist_q`, `mask_q`, `resp_q` | 9 + 7 + 2 + 4 + 64 + 254 + 127 bits | registers |
| `puf_ro_macro`: the oscillator counters | 1024 oscillators x 16 bits | registers inside the twin |
| `puf_arbiter_macro`: `x_q`, `stg_q`, `par_q`, `acc_q` | 64 + 6 + 1 + 26 bits | registers inside the twin |
| `puf_bch_dec`: `bm_c_q`, `bm_b_q`, `bm_l_q`, `bm_m_q`, `bm_dq_q`, `chien_z_q` | 147 + 147 + 5 + 6 + 7 + 147 bits | registers |
| `puf_sha256`: the 16-word schedule, the working state | 512 + 256 bits | registers |

Which dimension actually costs: **width of the RO array**, not depth. The 512-pair oscillator array with 16-bit counters is the bulk of the design - `puf_ro_macro` is 41964 cells after synthesis against 1281 for the whole digital half.

---

## 7. Control

### 7.1 The command sequencer

| State | What happens |
|---|---|
| `S_IDLE` | `cmd_ready_o` high; a presented command is decoded and its argument latched |
| `S_ARB_START` | one cycle that launches the arbiter PUF |
| `S_ARB_WAIT` | waiting for the arbiter PUF; on completion the response is stored, and the sequencer either compares it or finishes |
| `S_ARB_CMP` | waiting for the arbiter comparator; on completion the verdict and distance are stored |
| `S_RO_START` | one cycle that launches the RO PUF |
| `S_RO_WAIT` | waiting for the RO PUF; on completion the response is stored, and the sequencer either compares it or starts the key generation |
| `S_RO_CMP` | waiting for the RO comparator; on completion the verdict and distance are stored |
| `S_KEY_START` | one cycle that launches the key generation |
| `S_KEY_WAIT` | waiting for the key generation; on completion the key and syndrome are stored |
| `S_FIN` | one cycle that raises `done_o` and re-raises `cmd_ready_o` |

```
  nop                IDLE -> FIN -> IDLE
  arbiter response   IDLE -> ARB_START -> ARB_WAIT -> FIN -> IDLE
  arbiter auth       IDLE -> ARB_START -> ARB_WAIT -> ARB_CMP -> FIN -> IDLE
  RO enrol           IDLE -> RO_START -> RO_WAIT -> KEY_START -> KEY_WAIT -> FIN -> IDLE
  RO regenerate      IDLE -> RO_START -> RO_WAIT -> KEY_START -> KEY_WAIT -> FIN -> IDLE
  RO authenticate    IDLE -> RO_START -> RO_WAIT -> RO_CMP -> FIN -> IDLE
  reference store    IDLE -> FIN -> IDLE
```

### 7.2 The internal sequencers

* **`puf_ro_sensor`**: `S_IDLE` -> `S_WIN` (open the measurement window) -> `S_CAP` (compute the pair index) -> `S_RDY` (wait for the counts) -> `S_DEC` (rank the candidates, store the bit) -> `S_FIN`. The bit index and the candidate index are the two counters that drive it.
* **`puf_arbiter_macro`**: `S_IDLE` -> `S_WALK` (one stage per clock, 64 stages) -> `S_DONE`.
* **`puf_key_gen`**: `S_IDLE` -> `S_ENC` (syndrome) -> `S_DEC` (decode) -> `S_HASH` -> `S_FIN`. At initialisation the decode stage is skipped, because there is nothing to decode.
* **`puf_bch_dec`**: a five-state machine over the Berlekamp-Massey iteration and the Chien search, followed by a verification pass.
* **`puf_auth`**: `S_IDLE` -> `S_FIN`. One cycle.

### 7.3 The comparator instances never overlap

The two `puf_auth` instances have separate handshake nets - `arb_cmp_start_c` and `ro_cmp_start_c` - so neither drives a signal the other drives. They are never started at the same time either: the sequencer reaches `S_ARB_CMP` and `S_RO_CMP` on mutually exclusive paths.

---

## 8. Latency and throughput

Every command runs to completion on a fixed schedule, so the table is constants. **The numbers in the third column are measured**, not derived: the testbench times every command it issues and reports the longest run of each kind (`sim/sim.log`).

| Command | Cycles | Measured | Notes |
|---|---|---|---|
| `CMD_NOP` | 1 | 1 | decode and finish |
| `CMD_ARB_RESP` | 4293 | 4293 | 64 walks of 64 stages, plus control |
| `CMD_ARB_AUTH` | 4296 | 4296 | the above plus the one-cycle comparison |
| `CMD_RO_ENROLL` | 1348 | 1348 | 127 bits x 4 candidates = 508 pair reads, plus the syndrome and the hash |
| `CMD_RO_REGEN` | 801 | 801 | 127 pair reads, plus the syndrome, the decode and the hash |
| `CMD_RO_AUTH` | 263 | 263 | 127 pair reads plus the one-cycle comparison |
| `CMD_ARB_REF_ST` | 1 | 1 | a register write |
| `CMD_RO_REF_ST` | 1 | 1 | a register write |

```
   RO enrol      = 127 bits x 4 candidates = 508 pair reads  + syndrome + hash
   RO regenerate = 127 bits x 1 candidate = 127 pair reads  + syndrome + decode + hash
   RO auth       = 127 bits x 1 candidate = 127 pair reads  + comparison
   arbiter       = 64 bits x 64 stages    = 4096 stage clocks + control
```

The mask is what makes re-generation four times cheaper than enrolment: without it every bit would need all four candidates again, and the whole point of publishing the mask is that the chip does not have to redo the work.

The full testbench run is 545110 ns of simulated time, about 54511 clock periods at the 10 ns bench clock.

---

## 9. Reset and initialisation

`rst_ni` is asynchronous and active low. It resets the top-level sequencer to `S_IDLE`, clears the mask, the syndrome, both references, both responses and the challenge registers, raises `cmd_ready_o`, and clears every output. It does **not** touch `dev_id_i` and `env_i` - they are inputs, not state - and it deliberately does not attempt to preserve an enrolment across a reset: the mask and the syndrome are the state that survives, and losing them means the chip has to be enrolled again, which is the safe direction to fail in.

There is no initialisation walk and none is required: the block has no memory to walk (section 6). The only `initial` constructs in the RTL are the generate-scoped elaboration `$fatal`s of section 12, which elaborate only in the illegal configuration and are absent from any legal netlist.

---

## 10. Synthesis notes

Both lint configurations and the synthesis run are clean. `iverilog -Wall -g2012` reports **0 errors**; the diagnostics it does emit are all of one class and all of them sit in `RTL_SIM`-guarded simulation-only checks. `yowasp-yosys` 0.71 reports `Found and reported 0 problems.` and infers **0 latches** - the numbers are in section 6 of `siliconroot_puf_verification.md`.

* Plain synchronous RTL against a single asynchronous active-low reset (section 9).
* No `initial` blocks for value initialisation anywhere in the RTL (section 9).
* Every `always_comb` assigns all of its outputs on every path. The one place where a conditional assignment would have been natural - the accumulator inside `gf_mul` - uses a conditional **expression** instead, because a conditional assignment leaves the target unassigned on the other branch and the synthesis tool then has to infer a latch.
* The reduction loops inside `gf_mul` are **written out by hand** rather than left as `for` loops. When a function that contains a loop is inlined into a caller that is itself inlined into a larger process, the synthesis tool loses the loop counter's initialisation and infers a latch for it - 205 latches on one loop index, before the function was unrolled.
* The package is referenced with **explicit scope resolution** (`puf_pkg::name`) rather than with a wildcard import. A wildcard `import puf_pkg::*;` inside a module body is legal SystemVerilog, but the synthesis flow used for this block cannot elaborate it, while the scoped form resolves identically in the simulator and in the synthesiser. All 51 package references in the tree use the scoped form, and each file carries a comment saying why.
* Nothing is inferred as block RAM, and that is the intended result rather than a missed inference: the design has no array to infer from, and the SHA-256 tables are expressed as functions.

---

## 11. Limitations and assumptions

1. **The mask uses k = 4, not the k = 8 of the paper.** The paper's 1-out-of-8 mask gives a stronger robustness margin and a wider published mask space. This block ships 1-out-of-4 because 127 bits x 4 candidates already needs 508 of the 512 available oscillator pairs; k = 8 would need 1016 pairs, which the array does not have. Lifting it means doubling the array, not changing any logic above the macro boundary.
2. **The RO challenge space is 512 rotations, not the exponential space of the paper.** Paper section 3.3 chooses a subset of the oscillator pairs by challenge, which gives `2^n` challenges. This block rotates the pair space, which gives `N_PAIRS` = 512. The rotation is a bijection and it moves the measurement around the array, but it is not the paper's exponential space.
3. **The reference response is kept on-chip, not in the paper's trusted-party database.** The paper's authentication model assumes a database the verifier queries. This block keeps the enrolled response in two registers and compares locally, which is cheaper and needs no protocol, but it means the reference is not protected by a database's access control - it is protected by the fact that the response is only useful to someone who already has the chip.
4. **The arbiter PUF gives 64 response bits, not the 128 the paper's RO PUF gives.** The paper's authentication analysis (section 4) is built on a 128-bit response with a tolerance of 10. The arbiter engine here is 64 bits, so its false-positive figure is weaker than the paper's. The RO engine is 127 bits and carries the paper's figure.
5. **The twins are models, not the physical PUF.** Their statistics are calibrated to the published figures, but a model is not silicon. The inter-chip and intra-chip numbers of section 3 are the *twin's* numbers; the silicon numbers will differ.
6. **No gate-level, timing or CDC evidence.** Synthesis was run but the netlist was not simulated, there is no place-and-route and no static timing analysis and therefore no `Fmax`, and CDC is inapplicable: one clock, one reset, nothing crosses a domain (`siliconroot_puf_verification.md` sections 6 and 7).
7. **No formal proof ran.** The SVA properties of section 13 are written but were never compiled - no formal tool is installed on this host.
8. **The security argument is the paper's, not a fresh cryptanalysis.** This block implements the paper's construction; it does not re-derive the false-positive and false-negative probabilities, and it does not defend against attacks the paper does not consider (side channels on the key register, fault injection on the decoder, a physical attack on the macro).

---

## 12. Configuration rules

Checked at elaboration in `rtl/siliconroot_puf.sv` and in the sub-modules as `$fatal` inside `generate` blocks. The branches elaborate only when they fire, so a legal elaboration carries no check logic at all.

| Rule | Where | Message |
|---|---|---|
| `RESP_BITS != 127` | `siliconroot_puf` | `siliconroot_puf: RESP_BITS=%0d, the BCH(127,64,21) code of the paper needs 127 bits` |
| `ARB_BITS > 64` | `siliconroot_puf` | `siliconroot_puf: ARB_BITS=%0d, the arbiter challenge vector is 64 bits wide` |
| `TOL_BITS >= RESP_BITS` | `siliconroot_puf` | `siliconroot_puf: TOL_BITS=%0d accepts every possible response` |
| `N_PAIRS` not a power of two | `puf_ro_sensor` | `puf_ro_sensor: N_PAIRS=%0d must be a power of two so that the challenge rotation is a plain mask` |
| `N_BITS * K_MASK > N_PAIRS` | `puf_ro_sensor` | `puf_ro_sensor: N_BITS=%0d times K_MASK=%0d exceeds the %0d available oscillator pairs` |
| `CAND_W` too small for `K_MASK` | `puf_ro_sensor` | `puf_ro_sensor: CAND_W=%0d cannot hold the %0d candidate ranks` |
| `BIT_W` too small for `N_BITS` | `puf_ro_sensor` | `puf_ro_sensor: BIT_W=%0d cannot hold the %0d output bits` |
| `ARB_STAGES != 64` | `puf_arbiter_macro` | `puf_arbiter_macro: ARB_STAGES=%0d unsupported, the twin models the 64-stage arbiter PUF of section 2.3 of the paper` |
| `RESP_BITS != 127` | `puf_key_gen` | `puf_key_gen: RESP_BITS=%0d, the BCH(127,64,21) code of the paper needs 127 bits` |
| padding does not fit | `puf_key_gen` | `puf_key_gen: a %0d bit message leaves no room for the padding and the length field` |
| `RESP_BITS < 1` | `puf_auth` | `puf_auth: RESP_BITS=%0d must be at least one` |
| `TOL_BITS >= RESP_BITS` | `puf_auth` | `puf_auth: TOL_BITS=%0d accepts every possible response of %0d bits` |

The parameter-edge matrix that exercises these rules is in section 5.1 of `siliconroot_puf_verification.md`.

---

## 13. Formal properties

### 13.1 Under `INCLUDE_FPV`

These compile only when `` `INCLUDE_FPV `` is defined, as a run separate from simulation; none of them is part of the delivered gates:

* `fpv/siliconroot_puf_fpv.sv` - `puf_top_props/a_cmd_held`: a command may not be withdrawn or changed between `cmd_valid_i` and the acceptance edge, and `cmd_ready_o` may not rise again before `done_o`.
* `fpv/siliconroot_puf_fpv.sv` - `puf_top_props/a_done_pulse`: `done_o` is a one-cycle pulse, and it may only rise out of `S_FIN`.
* `fpv/siliconroot_puf_fpv.sv` - `puf_top_props/a_no_start_while_busy`: none of the four start signals may be asserted while the sequencer is not in the state that owns it.
* `fpv/siliconroot_puf_fpv.sv` - `puf_auth_props/a_dist_bound`: the reported distance never exceeds the response length.
* `fpv/siliconroot_puf_fpv.sv` - `puf_bch_dec_props/a_fail_on_overflow`: the decoder raises `fail_o` when the locator degree exceeds the correction radius.

They compile with `iverilog -g2012 -D INCLUDE_FPV`, but they are **not attached to the delivered RTL and no proof harness is shipped**. The simulation-side monitors of `siliconroot_puf_testplan.md` check the same rules dynamically over the traffic actually driven; proof of the rules over all reachable states is recorded as not covered in `siliconroot_puf_verification.md` section 8.

---

## 14. File map

| File | Contents |
|---|---|
| `rtl/siliconroot_puf.sv` | top level: ports, command decode, sequencer, elaboration checks |
| `rtl/puf_arbiter_puf.sv` | arbiter PUF: PRNG plus the evaluation of 64 challenge vectors |
| `rtl/puf_arbiter_macro.sv` | 64-stage arbiter delay chain - the functional twin of the analogue macro |
| `rtl/puf_ro_sensor.sv` | RO PUF front end: the 1-out-of-k mask, the challenge rotation, the ranking |
| `rtl/puf_ro_macro.sv` | 512-pair ring oscillator array - the functional twin of the analogue macro |
| `rtl/puf_prng.sv` | 64-bit Galois LFSR, `x^64 + x^4 + x^3 + x + 1` |
| `rtl/puf_auth.sv` | tolerance comparison, paper section 4 |
| `rtl/puf_key_gen.sv` | the key generation flow of paper figure 5 |
| `rtl/puf_bch_enc.sv` | BCH(127,64,21) syndrome encoder |
| `rtl/puf_bch_dec.sv` | Berlekamp-Massey / Chien decoder with a verification pass |
| `rtl/puf_sha256.sv` | FIPS 180-4 SHA-256, single 512-bit block |
| `rtl/puf_pkg.sv` | the shared constants and functions: GF(2^7), the BCH tables, the hash |
| `sim/tb_siliconroot_puf.sv` | testbench top - golden models, stimulus, monitors, gates, report |
| `sim/calibrate_models.py` | the integer-exact Python twin of the two macros; writes the known answers |
| `sim/kat_vectors.txt` | the known answer vectors: 8 RO, 5 arbiter, 5 syndrome |
| `sim/f_list.f` | file list: the twelve RTL sources |
| `sim/run.sh`, `sim/run.ps1` | compile-and-run wrappers |
| `sim/sim.log` | the full run's raw output - SIM gate evidence |
| `lint/lint.log`, `lint/lint_no_rtl_sim.log` | `iverilog -Wall` transcripts, with and without `RTL_SIM` |
| `synth/synth.ys`, `synth/synth.log` | yosys script and transcript - SYNTH gate evidence |
| `fpv/` | the SVA properties of section 13 |
| `docs/siliconroot_puf_design_spec.md` | this document |
| `docs/siliconroot_puf_testplan.md` | the test plan |
| `docs/siliconroot_puf_verification.md` | the verification report |
| `docs/siliconroot_puf_features.md` | the implemented-feature checklist |
| `cdc/cdc.rpt` | the single-clock CDC review |
| `mut/run_mutations.py`, `mut/mutation_results.json` | the mutation campaign and its evidence |
| `tools/regression.py`, `tools/README.md` | the repeatable open-source regression gate |
| `.github/workflows/regression.yml` | CI runner for the full regression suite |
