# Evaluation-board electrical qualification

Reviewed 2026-11-05 for ACQ-R1 and the selected ULX3S v3.1.7 D&M target, LFE5U-85F-6BG381C. **Physical qualification has not passed: no board was available for inspection or testing.** This document verifies drawing-level routes, identifies a feasible integration direction and records the measurements needed before approving a connection. It is not a verified cable pinout or an instruction to power an uninspected assembly.

## Evidence and actual-assembly status

The supplied [board research](evidence/board-research-2026-11-03.md) was used and rechecked against the repository PDFs. The archived copy preserves the exact bytes supplied at `/home/bluto/Desktop/dorsalGanglionProject/docs/research/evaluation-board.md`; its old `microcontrollerProject` source links are historical paths. Use the portable PDF links below. The drawing revisions are different and must be matched to a future physical assembly, not silently treated as one inspected revision.

| Source | Identity | SHA-256 |
| --- | --- | --- |
| Supplied research | Reviewed 2026-11-03 | `29ba60313797807f46c6fdbc20d97caea26ca35b261bb1b18e98b11bbcf09532` |
| [Board guide](../../datasheets/eval-ad7606c-fmcz-ug-1870.pdf) | UG-1870 Rev. A, January 2021; hardware pp. 4–5 | `b4be6c27155bc673e7e4165fd599589b9aac2eef70fd59229533d265356f7f39` |
| [Schematic](../../datasheets/eval-ad7606c18fmcz-schematic.pdf) | 02_057655 Rev. C, four sheets; power/control sheet 2, analog sheet 3, FMC sheet 4 | `c0d9fbf0b7a80f8c135c3552b13b7c348b5b2591377459b5a2b2d92ec64d8717` |
| [Layout](../../datasheets/eval-ad7606c18fmcz-layout.pdf) | 08-057655 Rev. A film set, ten films/four copper layers | `f78b9d5c525b8de3adaaace75b7b5591dbaa5af613a226d2b91ee579886fe173` |
| [ADC datasheet](../../datasheets/ad7606c-18.pdf) | AD7606C-18 Rev. B; electrical limits, pin functions and serial timing | `73b8892ab44ca4291b8c145df3e0d5d1abee2149c962be3a88e381c3e3e4f007` |

Schematic sheets 2–4 and primary silkscreen film 1 were inspected visually, with enlarged power and control-routing views. The product photograph and layout artwork do not establish the identity or condition of a physical assembly. No assembly photographs or completed physical inventory are available. The existing [FPGA inventory example](../programming/inventory.example.json) explicitly has `physical_inspection_verified=false` and a placeholder USB serial. The new [inspection record](board-inventory.json) preserves unknown observations as null and qualification as false.

The PCB legend `EVAL-AD7606CFMCZ` does not distinguish an 18-bit from a 16-bit assembly. The selected ordering identity is EVAL-AD7606C18FMCZ; schematic U4 is AD7606C-18BSTZ. The future inspection must record actual U4 top marking, assembly/BOM revision, serial/asset ID, connector population, link/resistor population and photographs of both sides. ACQ-R1 additionally requires register ID `0x33`; that readback is not available now. The exact FPGA marking, speed grade, package, flash marking and board revision likewise remain unobserved despite their selected values in source files.

## Analog input routing

**Conditioned analog voltages enter the ADC.** No recording connector, neural-sample output, protocol or clock is inferred from the undecided Abbott connection. SMB shields, analog negative-input ground links and controller ground share AGND; this board provides no galvanic isolation or qualified biological front end.

Schematic sheet 3 corrects the ambiguous channel wording in UG-1870 Table 1: **J1–J8 are positive/negative sockets for channels 1–4, not eight independent channel sockets.**

| ADC channel | Positive route to U4 | Negative route to U4 | Required R1 interpretation |
| --- | --- | --- | --- |
| 1 | J1 center → R74 → CH1+ → R112 → VIN1+, pin 49 | J5 center → R110 → JP7 B; JP7 common → CH1− → R114 → VIN1−, pin 50 | JP7 A selects AGND for single-ended operation; J5 is not channel 5 |
| 2 | J2 → R75 → CH2+ → R168 → VIN2+, pin 51 | J6 → R165 → JP12 B; common → CH2− → R169 → VIN2−, pin 52 | JP12 A selects AGND; J6 is not channel 6 |
| 3 | J3 → R126 → CH3+ → R76 → VIN3+, pin 53 | J7 → R71 → JP13 B; common → CH3− → R78 → VIN3−, pin 54 | JP13 A selects AGND; J7 is not channel 7 |
| 4 | J4 → R124 → CH4+ → R96 → VIN4+, pin 55 | J8 → R92 → JP14 B; common → CH4− → R98 → VIN4−, pin 56 | JP14 A selects AGND; J8 is not channel 8 |
| 5 | P9/P10 CH5+ → R111 → VIN5+, pin 57 | P9/P10 CH5− → R113 → VIN5−, pin 58 | P13 fitted shunt grounds CH5−; verify it physically |
| 6 | P9/P10 CH6+ → R120 → VIN6+, pin 59 | P9/P10 CH6− → R121 → VIN6−, pin 60 | P15 fitted shunt grounds CH6− |
| 7 | P9/P10 CH7+ → R129 → VIN7+, pin 61 | P9/P10 CH7− → R130 → VIN7−, pin 62 | P16 fitted shunt grounds CH7− |
| 8 | P9/P10 CH8+ → JP8/JP10 bypass → R166 → VIN8+, pin 63 | P9/P10 CH8− → JP9/JP11 bypass → R167 → VIN8−, pin 64 | P14 grounds CH8−; JP8–JP11 A bypasses the optional amplifier mezzanine |

P6/P8 expose CH1+, CH1−, CH2+, CH2−, CH3+, CH3−, CH4+, CH4− in the drawn sequence; P9/P10 similarly expose channels 5–8. The sheet labels these nets but does not establish a photographed connector orientation. P8/P10 are marked DNI. Before using a terminal/header contact, verify its physical pin-one/orientation and continuity to the named net; do not assign a cable from an assumed top-to-bottom numbering. Parallel connector footprints may not both be fitted.

The shown series elements in these analog routes are 0 Ω. Differential capacitors C44/C62/C29/C38/C43/C45/C48/C61 and optional shunts are DNI in the drawing. Their footprints do not establish an installed anti-alias filter. The ADC's internal filter is separate; the conditioned ±2.5 V single-ended source still needs the qualified analog response and settling required by the [ADC profile](adc-profile.md). P7/P11 and JP8–JP11 can insert a channel-8 amplifier mezzanine only; they do not supply eight fitted INA819/OPA2140 channels.

## Power, enable and reference ownership

The candidate standalone arrangement uses external P4 power, local AVCC and one qualified 3.3 V interface supply arrangement. It requires an explicit adapter design and inspection; neither the ULX3S GPIO power pins nor a generic FMC cable are approved power sources by this review.

| Node/control | Documented route | Owner and acceptance condition |
| --- | --- | --- |
| P4 / EXT_SUPP+ | P4 positive → JP2 B; P4 return → AGND; guide specifies **7–9 V DC** | Qualified bench supply only, correct polarity/current limit; 12 V at the carrier does not authorize 12 V at P4 |
| JP2 / VIN | A selects `+12V_FMC` from P12 C35/C37; B selects P4; common is VIN | Exactly one supply selected; record shunt position and continuity before power |
| U2 / AVCC | VIN → R4 0 Ω → ADP7118ACPZN5.0 → R9 0 Ω → AVCC | U2 owns the 5 V rail; measure at U4 AVCC pins within 4.75–5.25 V under operating load |
| U3 / local 3.3 V | VIN → R11 0 Ω → ADP7118ACPZN3.3 → R17 0 Ω → JP3 A | U3 owns this rail when selected; measure actual voltage, ripple, startup and thermal behavior |
| CARRIER_POWER_GOOD | P12 D1 → both U2/U3 EN; **R2 and R7 are each shown 10 kΩ from this net to VIN** | Not presumed GPIO-safe. Verify both fitted values, shared net and EN voltage. With both pulls fitted, effective pull-up is 5 kΩ to unregulated VIN |
| JP3 / VDRIVE | A selects local U3 output; B selects `3P3VAUX` from P12 D32; common reaches U4 pin 23 | One qualified 3.3 V source only; no short between regulators. Verify paired FPGA VCCIO/ADC VDRIVE tracking and unpowered behavior |
| JP6 / REFSEL | JP6 common → R13 10 kΩ as drawn → U4 REFSELECT pin 34; also P12 C19 | Internal-reference R1 requires a confirmed high state; standalone guide calls for R13=0 Ω. Only the chosen strap/controller may own this net |
| Internal reference | U4 REFIN/REFOUT pin 42 → R1 0 Ω → REFIN_OUT | R1 source is the ADC internal reference; measure and record reference identity/value |
| P5 / U1 | P5 can connect ADR4525 output to REFIN_OUT | P5 disconnected for the internal-reference profile; no competing active reference |
| J9 | Center connects REFIN_OUT; shell contacts AGND | No external drive in R1; external-reference selection is unsupported |
| P3 | Drawn diagnostic header: 1 AGND, 2 “PIN OUT” routes to P12 H19/LA15_P, 3 VDRIVE, 4 AVCC; footprint marked DNI | R1 leaves contact 2 unassigned/high impedance; rail observation/access only after population check; never route AVCC into an FPGA I/O |

The enable pull-up is deliberate regulator circuitry, not evidence that D1 is a 3.3 V power-good output. [ADP7118 Rev. H](https://www.analog.com/media/en/technical-documentation/data-sheets/ADP7118.pdf), pp. 3, 5–6, permits EN tied to VIN for automatic startup; EN absolute maximum is 24 V and the guaranteed high threshold reaches 1.30 V. Those regulator limits do **not** apply to an ECP5 input. With P4 at 7–9 V, a released D1 can rise toward VIN through R2/R7. Keep D1 disconnected from FPGA logic in the candidate adapter unless a separate reviewed, voltage-rated open-drain/isolation circuit controls it. A qualified external supervisor may own that circuit; no such circuit is implemented or approved here. At 9 V, the nominal 5 kΩ pull would draw 1.8 mA when pulled low, before resistor tolerance and leakage. This is a design calculation, not a measured current.

Check bypass links R3/R15 (DNI), feedback/bypass parts R5/R6/R25/R26, capacitors and regulator identity against actual population. A wrong fitted bypass can defeat the assumed regulator path. Power LEDs alone establish neither rail accuracy nor ADC readiness. Record voltage at the ADC and FPGA, not just at a supply connector. Turning off either board while signals remain driven needs a proven isolation/back-power policy before connection.

## Digital routes and exclusive owners

The following are **schematic net references**, with P2 viewed by its numbered schematic contacts. They are not ULX3S ball assignments. The current programmable [LPF](../synth/fpga/drg5_ulx3s_programmable.lpf) contains CPU/flash/LED/UART pins and no ADC interface binding. A pin name such as FMC D1 is not FPGA package ball D1; the latter is already an LED in that LPF.

All active ADC logic signals use VDRIVE-referenced levels. “FPGA output” means the future acquisition sequencer, not CPU GPIO, a debugger, SDP-H1 and a standalone strap simultaneously. Service and capture take exclusive leases of the same outputs. Before FPGA configuration, external qualified pulls/isolation must maintain safe levels; an RTL reset value cannot guarantee a floating unconfigured pin.

| Signal / U4 pin | P2 contact | FMC P12 route / series part | Direction and R1 owner/state |
| --- | --- | --- | --- |
| SDI / DB13, 29 | 2 | G9 SDI_1 → R61 100 Ω → SDI → R37 0 Ω → U4 | FPGA → ADC; sequencer, low during conversion reads, command bits only in service |
| DOUTD / DB12, 28 | 3 | D14 DOUTD_1 ↔ R66 100 Ω ↔ DOUTD ↔ R41 0 Ω ↔ U4 | ADC output; unused in one-lane R1, controller high impedance |
| DOUTC / DB11, 27 | 4 | D11 DOUTC_1 ↔ R65 100 Ω ↔ DOUTC ↔ R38 0 Ω ↔ U4 | ADC output; unused, controller high impedance |
| DOUTB / DB10, 25 | 5 | C11 DOUTB_1 ↔ R64 100 Ω ↔ DOUTB ↔ R42 0 Ω ↔ U4 | ADC output; unused, including reset-default two-lane mode; controller high impedance |
| DOUTA / DB9, 24 | 6 | G7 DOUTA_1 ↔ R63 100 Ω ↔ DOUTA ↔ R39 0 Ω ↔ U4 | ADC → FPGA receiver; capture on falling SCLK; never drive from FPGA |
| FRSTDATA, 15 | 7 | G12 FRSTDATA_SDP ↔ R58 100 Ω ↔ FRSTDATA | ADC → optional observation input; not used as a substitute for R1 channel-ID/CRC checks |
| BUSY, 14 | 8 | H13 BUSY_SDP ↔ R56 100 Ω ↔ BUSY | ADC → FPGA synchronizer/edge monitor; every conversion must match its own rise/fall |
| CS, 13 | 9 | H10 CS_1 → R59 100 Ω → /CS | FPGA → ADC; idle high; R79 shown as 10 kΩ pull to VDRIVE |
| RD/SCLK, 12 | 10 | G6 SCLK_1 → R60 100 Ω → RD/SCLK | FPGA → ADC; idle high, 20 MHz nominal in R1 |
| RESET, 11 | 11 | C10 RESET_1 → R54 100 Ω → RESET | FPGA service/reset supervisor → ADC; idle low, full-reset pulse only while disarmed |
| WR, 10 | 12 | C14 WR_SDP → R62 100 Ω → /WR | Parallel control unused by serial R1; hold at a defined inactive high through the selected owner, not floating |
| CONVST, 9 | 13 | D12 CNVST_SDP → R57 100 Ω → CNVST | FPGA scheduler → ADC; idle low, on-time pulses only |
| RANGE, 8 | 14 | D15 RANGE_1 → R67 100 Ω → RANGE; JP4/R20 strap | Ignored in software mode, but keep one defined strap owner; do not use hardware range labels as the active R1 range |
| STBY, 7 | 15 | C15 STBY → R55 100 Ω → /STDBY; JP1/R8/R10 | Ignored in software mode; selected standalone high state avoids accidental hardware standby |
| OS2, 5 | 16 | H16 OS2 → R70 100 Ω → OSR2; S1 | Static high for software mode; exactly one strap or controller owner |
| OS1, 4 | 17 | H7 OS1 → R69 100 Ω → OSR1; S1 | Static high; no mode change while recording |
| OS0, 3 | 18 | G15 OS0 → R68 100 Ω → OSR0; S1 | Static high; no mode change while recording |
| AGND | 1 | Common ground plane | Signal return, not an isolated input or supply output |
| PAR/SER SEL, 6 | Not on P2 | C18 SERPAR; JP5 with R19/R21 | Static high for serial; one confirmed owner, no strap/FPGA contention |
| REFSELECT, 34 | Not on P2 | C19 REFSEL; JP6/R13 | Static high for internal reference; one confirmed owner |

The 100 Ω parts are series current-limiting links, **not level translators**. Sheet 2 says not to populate these FMC links when not using the FMC connector; the actual standalone population and selected access path must therefore be checked rather than assumed. P2 is on the ADC side of these links. The proposed P2/adapter route must not leave an attached carrier driving the same nets. The guide calls for particular standalone 0 Ω substitutions at R8/R10, R20, R19/R21 and R13; do not blindly convert every pull resistor to a short.

**R77 is a DNI compatibility link between CONVST and CS. It must be absent/open for R1's independent trigger and chip-select signals.** Verify the physical link and continuity before allowing both FPGA outputs to drive. The schematic's ground pulls on unused data pins also require population review: DB2–DB4 are tied to AGND for serial operation; the other unused parallel/multilane pins must remain in their documented inactive configuration, with controller pads high impedance. R1 must not accidentally enable parallel or extra-lane ownership during reset/service transitions.

P1 is a DNI parallel-header footprint. Its numbered contacts 1..16 are drawn as DB2, DB4, DB6, DB8, DB10, DB12, DB14, DB16/DB0, DB17/DB1, DB15, DB13, DB11, DB9, DB7, DB5 and DB3 respectively. Several are the same physical ADC pads used for serial signals; they are not independent GPIOs. R1 does not drive an attached parallel bus, and unused adapter pads remain high impedance.

Remaining FMC groups are outside the sample interface: board-present H2 is grounded; EEPROM U5 uses C30 SCL, C31 SDA, D32 3P3VAUX and GA address pins; SDA is bidirectional open-drain and SCL belongs to the controller if this bus is used. The drawing puts the I²C pull-up responsibility on the carrier. D30/D31 TDI/TDO are linked for FMC-chain continuity; the ADC mezzanine is not an FPGA programming target. Unused differential/clock/data contacts and VADJ are not spare approved power/ADC routes. An adapter must explicitly leave unused signals disconnected/high impedance and route adequate ground returns.

## Voltage and timing compatibility

The selected direct-interface envelope is ADC VDRIVE **3.135–3.465 V** and ECP5 LVCMOS33 VCCIO **3.135–3.465 V**, nominal 3.3 V. This is narrower than the ADC IC's capability and supersedes treating the previous 3.6 V profile limit as automatically ECP5-compatible. The [ECP5 datasheet, FPGA-DS-02012-3.4](https://www.latticesemi.com/view_document?document_id=50461), Tables 3.11–3.12, pp. 56–57, gives these FPGA supply limits, VIH≥2.0 V with input-high maximum 3.465 V, VIL≤0.8 V, VOH≥VCCIO−0.4 V and VOL≤0.4 V at the specified drive currents. ADC Rev. B Table 2 gives VIH≥0.7×VDRIVE, VIL≤0.2×VDRIVE and VOH≥VDRIVE−0.2 V / VOL≤0.2 V at 100 µA. Actual load, leakage, series drops and edge behavior must meet the conditions behind those limits.

| Nominal DC comparison at worst independent rail limits | Remaining static margin |
| --- | --- |
| FPGA high → ADC high | `(3.135−0.4) − 0.7×3.465 = 0.3095 V` |
| FPGA low → ADC low | `0.2×3.135 − 0.4 = 0.227 V` |
| ADC high → FPGA high | `(3.135−0.2) − 2.0 = 0.935 V` |
| ADC low → FPGA low | `0.8 − 0.2 = 0.6 V` |

These positive logic margins do not close the voltage gate. ADC digital inputs must not exceed VDRIVE+0.3 V: independent extremes permit a 3.465 V FPGA rail while ADC VDRIVE is 3.135 V, exceeding that bound by 30 mV even before overshoot. The integration must therefore establish a qualified shared/tracking supply arrangement, or qualified translation/isolation, and verify both powered and unpowered cases. Measured ADC-to-FPGA signal peaks, including overshoot and measurement uncertainty, must also remain within the ECP5 receiver limits; a nominal rail measurement alone does not establish that. Both directions need positive qualification margin against the receiver limits, not operation justified only by an absolute-maximum stress rating. JP3 A/B and actual adapter wiring determine that arrangement. Never parallel independent regulators merely to make their nominal labels agree. A shared supply also requires adequate current budget and safe sequencing; none is yet measured.

R1's idle-high SCLK, falling-edge DOUTA capture and nominal 14 µs frame deadline remain as defined in the [ADC profile](adc-profile.md). The [timing budget](timing-budget.md) now allocates tolerance, setup/hold, synchronization, routing and supervision explicitly. At VDRIVE≥3.1 V the ADC's maximum DOUT access is 15.7 ns against a nominal 25 ns half-cycle; the remaining 9.3 ns must cover FPGA/board/adapter delay, setup, skew and jitter under the specified load. Passing internal FPGA timing or a digital simulation does not qualify these board delays.

The timing review corrected two U4 pin numbers in this table: PAR/SER SEL is pin 6 and STBY is pin 7, as both datasheet Figure 8/Table 9 and schematic sheet 2 show. The earlier hardware-review evidence remains historical; this correction changes the current documentation, not an observed physical pinout.

No ADC-to-ULX3S GPIO/ball mapping, adapter PCB/cable, pull/isolation design or electrical measurement currently closes this interface. The selected ULX3S and ADC mezzanine can only be regarded as a **conditional engineering candidate**, not an inspected compatible pair. Their complete connection must reserve pins outside oscillator, flash, USB-UART, LEDs/buttons and other selected functions and provide a versioned adapter map/LPF before hardware admission.

## Inspection and release record

All physical rows below are pending because no board is available. “Drawing checked” is not a pass for the corresponding physical row.

| Gate | Required retained evidence | Present result |
| --- | --- | --- |
| Assembly identity | Both-side photographs, ADC marking, board/assembly revision, serial and populated connector/BOM comparison; exact FPGA/flash markings | Not performed |
| Unpowered route/ownership | Continuity from every chosen contact to U4 and FPGA pad, no swapped positive/negative inputs, R77 open, selected source/strap paths and no other driver | Not performed |
| Power/enable | P4/JP2 identity, U2/U3 and bypass population, R2/R7 values, D1 isolation, current-limited startup, rail and EN measurements | Not performed |
| Reference/VDRIVE | JP3/JP6/R13/P5/J9 state, actual reference value, paired VDRIVE/VCCIO bounds/tracking and power-off injection/isolation | Not performed |
| Static digital levels | Worst-case VIH/VIL/VOH/VOL/load checks for every signal and defined unconfigured/reset state | Calculation only; physical gate open |
| Timing | Actual SCLK/CS/CONVST/BUSY/DOUTA captures over required voltage/temperature/load range and documented board-delay constraints | Not performed |
| Analog | Qualified conditioned synthetic signals, per-channel continuity/order, input range, gain/filter/settling and endpoint behavior | Not performed |
| Runtime identity | Device ID `0x33`, complete configuration readback, interface pattern/status/CRC checks, reset/recovery outcomes | Not performed |

Review corrected the connector interpretation, exposed the VIN-level enable path, independently corrected its pull designator from an initial visual misread to **R2**, required R77 absence, and rejected a nominal-voltage-only compatibility claim. The electrical interface is documented to a concrete design-review boundary; **physical inspection and electrical qualification remain incomplete** until these observations and the adapter design exist. Acquisition must remain unavailable while this record is incomplete.
