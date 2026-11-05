# ACQ-R1 ADC profile

This is the sole ADC profile admitted by the [first implementation contract](contract.md). Values below are implementation requirements, not measured board results. A failed requirement leaves `ACQ-R1_AVAILABLE=false`; there is no fallback to fewer channels, missing CRC, another rate or another device.

## Sources and scope

The pinned local references are [AD7606C-18 Rev. B](../../datasheets/ad7606c-18.pdf), 79 pages, and [UG-1870 Rev. A](../../datasheets/eval-ad7606c-fmcz-ug-1870.pdf), 15 pages. Their SHA-256 values are respectively `73b8892ab44ca4291b8c145df3e0d5d1abee2149c962be3a88e381c3e3e4f007` and `b4be6c27155bc673e7e4165fd599589b9aac2eef70fd59229533d265356f7f39`. Page numbers below are printed document pages. The [official datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/ad7606c-18.pdf?isDownload=true) and [official guide](https://www.analog.com/media/en/technical-documentation/user-guides/eval-ad7606c-fmcz-ug-1870.pdf) were checked on 2026-11-05.

Relevant datasheet locations: startup/reset pp. 9–10, serial timing p. 12, operating modes pp. 35–36, software/serial interface pp. 42–50, diagnostics/CRC pp. 52–55, register summary/details pp. 60–78. UG-1870 pp. 4–5 identifies evaluation-board power/reference/pin routing. The board's standalone mux/resistor/jumper ownership must be inspected; these settings do not assert that a bare FPGA can be connected without electrical qualification.

Rev. B contains inconsistent 16-bit/24-bit prose in an 18-bit device's serial-status description (p. 49), a 128-bit CRC-coverage statement (p. 54), and a polynomial/hex presentation that must not substitute for a complete CRC convention. R1 explicitly uses 18+8 bits/channel and the convention below. ADI's [no-OS AD7606 driver](https://github.com/analogdevicesinc/no-OS/blob/main/drivers/adc/ad7606/ad7606.c), functions `ad7606_spi_data_read`, `ad7606_spi_reg_read` and CRC-table initialization, corroborates the 208-bit data/status coverage, `0x755B` taps and zero initialization. The external driver is corroboration, not a new build dependency; the numeric contract here remains fixed if that URL changes. Physical known-pattern checks remain required.

## Pins and complete recording image

Use `OS2:0=111`, `PAR/SER=1`, `REFSELECT=1`, normal power, internal reference, one DOUTA. Other DOUT pins are not captured or used as alternate lanes. VDRIVE must remain within the qualified **3.1–3.6 V** interface range (nominal 3.3 V), including tolerances; the FPGA bank must support the actual voltage. ADC analog rails/reference and all input-pin limits must meet the pinned datasheet. This narrower VDRIVE range is an R1 engineering restriction, not the ADC's complete supply capability.

All addresses and values in this table are hexadecimal. Each address in a range is written and read back individually; a range is not an auto-increment assumption. Readback compares all defined fields and reserved-zero bits. Read-only and W1C registers are handled separately below.

| Register address | Final byte | Meaning |
| --- | --- | --- |
| `02` CONFIG | `40` | Status enabled; one DOUT; internal OS clock selection; normal operation |
| `03`..`06` RANGE pairs | `00` each | All eight channels ±2.5 V single-ended |
| `07` BANDWIDTH | `00` | All eight channels low bandwidth |
| `08` OVERSAMPLING | `00` | Oversampling and padding disabled |
| `09`..`10` GAIN | `00` each | No ADC gain correction |
| `11`..`18` OFFSET | `80` each | Neutral offset code on all channels |
| `19`..`20` PHASE | `00` each | No interchannel phase delay |
| `21` DIGITAL_DIAG_ENABLE | `3F` | ROM, memory-map, interface CRC, invalid register read/write and BUSY-stuck checks enabled; counters and interface test disabled |
| `23` OPEN_DETECT_ENABLE | `00` | Open-circuit detector disabled |
| `28`..`2B` diagnostic mux | `00` each | External analog channel inputs |
| `2C` open-detection queue | `00` | Automatic open-detection queue disabled |

Read ID `2F` and require exact `33`: part code 3, silicon revision 3. Other silicon revisions require a future profile revision and qualification, not just a family-name match. Reserved addresses are never accessed. `01` STATUS is read/logged before its reset-detect indication is cleared by the read. `22` DIGITAL_DIAG_ERR and `24` OPEN_DETECTED are read/logged before any W1C clearing; write only the observed defined bits, then re-read and require zero. An unexpected nonzero error during qualification fails the attempt; clearing it is evidence collection, not a retry that erases the failure. A known reset indication from the commanded full reset is expected and logged.

Open-detect disabled is deliberate: the ADC's open flag cannot certify electrode continuity, and its test stimulus must not silently alter the analog chain. No dynamic gain/range/filter/phase change or register service occurs during RUN, STOPPING or DRAINING. A detected configuration mismatch closes the epoch and requires requalification.

## Startup and exclusive service sequence

1. Qualify stable supplies, reference routing, clocks, digital voltages and sole ownership of the ADC pins. Keep CONVST low, CS high, SCLK high and SDI low. Wait **2.1 seconds** after stable power before the full-reset sequence; loss of qualification cancels the attempt. This exceeds the first-start combined power/setup requirement, rather than treating the ordinary short post-reset delay as first-power readiness.
2. Drive full RESET high for **10 µs**, then low. Wait **1 ms** before register traffic. R1 uses no intentional partial reset and never generates a pulse in the ADC's undefined reset-duration interval. Recovery also uses this full sequence; three seconds is the complete command deadline, not an unbounded retry budget.
3. Track reset-default protocol: ADC-data mode, two DOUT lanes selected, interface CRC disabled. Enter register mode with a read command; discard the first unassociated response. Verify ID and log reset/error status. No default conversion output is a recording record.
4. While register CRC is still disabled, write/verify the recording image except `21`. Write `21=3F` using the old **16-bit** register framing; subsequent transfers use **24 bits**. Verify `21` using the newly enabled CRC8 convention. A width/readback/CRC mismatch fails qualification; do not probe alternative conventions until one appears to work.
5. Read and log STATUS to clear the expected reset indication, require no unexpected error flags, then write/verify `21=BF` to enable the fixed interface pattern. Leave registers with a zero write to address `00` using the current CRC framing. Perform exactly **two** test conversions at the 1600-tick cadence, with normal BUSY checks, one DOUT, status and CRC. Both must match the eight patterns and healthy statuses below; any mismatch fails. These service conversions have no epoch/slot identity and are reported only in the service result.
6. Re-enter registers, write/verify `21=3F`, read/log STATUS and errors, then verify the entire final image and ID. Leave registers by the zero write to `00`. Release service ownership only with CS/SCLK high, CONVST/SDI low and BUSY low. Publish READY only if the descriptor's independent analog-settling and clock/memory qualification also passes. Register success alone cannot assert readiness.

SDI request bytes are `(0x40 | address), 0x00` for reads, and `address, data` for writes; the six-bit address must be from the allowed register set. A read response belongs to the **previous** register command, not the address just sent. R1 reads each register with two requests to that same address and uses only the second response, checking its CRC when enabled. The first response after mode entry is discarded. Register output and conversion output are never fed to the same record assembler without an explicit mode/owner tag.

Before CRC enable, each register command has 16 clocks. After enable it has 24: the two command bytes then CRC8, MSB first. CRC8 uses polynomial taps `0x07`, initial zero, no reflection/final XOR and direct byte/bit recurrence over the preceding 16 wire bits. The received two-byte register response has its own CRC8, checked independently of the request CRC. The enable transaction follows the old framing; disabling CRC is not used by R1 outside full reset.

## Serial framing, status and timing

The first DOUTA MSB becomes available after CS falls. SCLK idles high; the controller captures on falling edges and changes SDI on rising edges. The ADC updates DOUTA after rising edges and samples SDI on falling edges: CPOL=1, CPHA=0 (mode 2). A generic mode-0 assumption is incorrect. SCLK high and low each last two 80 MHz ticks; the first falling edge follows CS assertion by four ticks (50 ns). CS remains asserted for all 224 capture edges; after the final falling edge, return SCLK high after two ticks, then deassert CS two ticks later. CS stays high for at least four ticks before another transaction.

Conversion read begins only after the outstanding trigger's matched, synchronized BUSY rise/fall; no read during conversion. Request CS within four ticks of the recognized BUSY fall. The complete transfer therefore fits the conservative sum: 160 ticks to BUSY fall + 4 to CS + 4 setup + 896 serial budget + 4 hold + 4 receiver/CRC resolution = **1072 ticks (13.4 µs)**. R1's final deadline is **1120 ticks (14 µs)** from trigger, leaving 48 ticks margin within that budget and 480 ticks before the next slot. The existing README's older 13 µs proposal is superseded. A failure to meet any intermediate or final deadline invalidates the slot and closes the epoch.

All numbers above are digital design bounds. At the physical pins, qualify clock tolerance/jitter, output skew, round-trip board delay, FPGA input setup/hold and synchronization. Table 5 gives DOUT access up to 15.7 ns at VDRIVE ≥3.1 V; a nominal 25 ns half-cycle must still cover the entire board/setup path. CS-to-DOUT maximum is 18 ns; R1's 50 ns first-edge spacing supplies a separate first-bit budget. Merely dividing 80 MHz by four does not prove pin timing.

For each channel in order V1, V2, …, V8, capture sample bits17..0 then status bits7..0; then capture CRC bits15..0. There is no byte padding between 26-bit pairs. Status bits are reset-detect[7], digital-error[6], open-detected[5], reserved[4:3], channel ID[2:0]. Healthy statuses are exactly `00 01 02 03 04 05 06 07`. Status IDs must match their positions; never reorder data based on a corrupt ID. Any full/partial ADC reset or reset-detect flag during recording terminates the epoch. Raw status is retained even when integrity fails, with validity policy from the contract.

## Frozen ADC CRC16 and independent checks

The CRC16 shift register starts at zero at each frame. Consume the **208** sample/status bits in wire order. For each bit, XOR it with the old CRC bit15, shift left within 16 bits, and XOR `0x755B` if that feedback bit is one. There is no reflection, final XOR, byte swapping or appended zero-bit pass. Compare the resulting 16-bit value directly with the MSB-first trailer; exclude the trailer from computation. Full polynomial divisor is `0x1755B`.

The mathematical check `06 4E` produces `2137` (datasheet Table 28). It checks the convention, not the channel framing. The fixed interface-test patterns from Table 29 are the following raw 18-bit values in V1..V8 order:

| Channel | Raw18 hex | Sign-extended decimal |
| --- | --- | --- |
| V1 | `2ACCA` | −86838 |
| V2 | `15CC5` | 89285 |
| V3 | `2A33A` | −89286 |
| V4 | `15335` | 86837 |
| V5 | `0CAAC` | 51884 |
| V6 | `0C55C` | 50524 |
| V7 | `33AA3` | −50525 |
| V8 | `33553` | −51885 |

With healthy statuses `00..07`, packed payload hex is `ab328015cc501a8ce80953350332ab010c55c05cea8c1b355307` and CRC16 is `3EE1`. With reset bit7 set on all eight statuses, CRC16 is `ADB3`; this is a verification vector, not an allowed healthy startup-test result. Include negative controls that flip payload/status/trailer bits, reorder channels, truncate the frame, deliver a stale frame and alter CRC coverage/initialization. The acceptance capture must agree with an independent checker and actual ADC patterns; a model copying the DUT's implementation is insufficient evidence.

Nominal ADC-pin voltage decoding for this bipolar range is `signed_code × 2.5 / 131072` volts, with actual scale/offset uncertainty supplied by calibration. Upstream electrode/source voltage requires the separately measured analog transfer function. The endpoint flags and stored codes do not prove the front end stayed linear.
