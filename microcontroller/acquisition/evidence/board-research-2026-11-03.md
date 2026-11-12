# AD7606C evaluation board research

Reviewed 3 November 2026. This is project reference documentation, not a wiring procedure or an implemented design. The physical source of the recording signal has not been decided.

## Sources and coverage

| Local source | Revision and coverage |
| --- | --- |
| [UG-1870](/home/bluto/Desktop/microcontrollerProject/datasheets/eval-ad7606c-fmcz-ug-1870.pdf) | Rev. A, January 2021, all 15 pages read; hardware tables and capture/configuration figures inspected visually |
| [Board schematic](/home/bluto/Desktop/microcontrollerProject/datasheets/eval-ad7606c18fmcz-schematic.pdf) | Drawing 02_057655 Rev. C, all 4 sheets read and visually inspected |
| [Board layout](/home/bluto/Desktop/microcontrollerProject/datasheets/eval-ad7606c18fmcz-layout.pdf) | Drawing family 08-057655 Rev. A, all 10 films visually inspected |

The board guide covers both the 18-bit and 16-bit variants. The PCB marking EVAL-AD7606CFMCZ alone does not distinguish the mounted converter. The selected assembly is EVAL-AD7606C18FMCZ. Record the physical assembly revision, ADC marking and installed component options before applying the documents. The schematic and layout revisions differ; these PDFs do not prove that every shipped board has identical population or routing.

## Hardware organization

UG-1870 pp. 1 and 4 describes an ADC mezzanine, not a microcontroller or a complete neural acquisition instrument. U4 is the AD7606C-18, U2/U3 are ADP7118 5 V/3.3 V LDOs, U1 is an optional ADR4525 external reference, and P12 is the FMC carrier connection. The supplied host path is SDP-H1 plus USB plus ACE. P1/P2/P3 provide additional access, with some headers marked DNI in the schematic. The actual board must be inspected for fitted parts.

### Power and reference

UG-1870 Tables 1 and 2, pp. 4–5, and schematic sheet 2 establish these choices:

| Item | Documented function and constraints |
| --- | --- |
| P4 | External supply terminal, specified by the guide as 7–9 V DC |
| JP2 | A selects the carrier's 12 V rail; B selects P4. This does not make 12 V a documented P4 operating input. |
| U2/U3 | Generate AVCC 5 V and digital 3.3 V; their enable signals use CARRIER_POWER_GOOD in the schematic |
| JP3 | A selects local 3.3 V for VDRIVE; B selects carrier 3.3 V. The board options are not an automatic 1.8 V conversion even though the ADC IC permits lower VDRIVE. |
| JP6 and REF SELECT | A selects the ADC internal reference; B selects an external reference, subject to the standalone resistor configuration below |
| P5 | Connects the on-board ADR4525 into REFIN/REFOUT when an external reference is selected; leave disconnected for the ADC internal reference or J9 external source |
| J9 | External reference input; do not drive this node against another enabled reference |

Schematic sheet 2 includes 0.1 µF AVCC/VDRIVE decoupling, a populated 10 µF bulk AVCC capacitor, 1 µF REGCAPA/REGCAPD capacitors, a 10 µF capacitor across the tied REFCAPA/REFCAPB node to ground, and a 0.1 µF REFIN/REFOUT capacitor. Additional optional capacitors and bypass links are marked DNI. These are assembly facts from the drawing, not independently measured values. The IC datasheet remains the authority for capacitor requirements and power sequencing.

### Analog input routing

Schematic sheet 3 and layout film 1 resolve an ambiguity in UG-1870 Table 1: **J1–J8 are not eight independent channel sockets.** They are the positive and negative terminals for channels 1–4.

| ADC channel | Positive SMB | Negative SMB | Negative input ground option |
| --- | --- | --- | --- |
| 1 | J1 | J5 | JP7 A grounds V1−; B routes J5 |
| 2 | J2 | J6 | JP12 A grounds V2−; B routes J6 |
| 3 | J3 | J7 | JP13 A grounds V3−; B routes J7 |
| 4 | J4 | J8 | JP14 A grounds V4−; B routes J8 |
| 5 | Terminal/header access | Terminal/header access | P13 grounds V5− when fitted |
| 6 | Terminal/header access | Terminal/header access | P15 grounds V6− when fitted |
| 7 | Terminal/header access | Terminal/header access | P16 grounds V7− when fitted |
| 8 | Terminal/header access | Terminal/header access | P14 grounds V8− when fitted |

P6/P8 carry the ± signals for channels 1–4; P9/P10 carry them for channels 5–8. Parallel connector footprints may not both be populated. Channel 8 alone can be diverted through the optional amplifier mezzanine at P7/P11: JP8–JP11 position A bypasses it, and position B inserts it. This does not provide eight installed INA819/OPA2140 channels.

Each channel drawing contains optional input filtering footprints, but the shown series elements are 0 Ω and the differential capacitors and shunts are DNI. Examples are C44, C62, C29, C38, C43, C45, C48 and C61. Therefore an application-specific external neural anti-alias filter is **not established by these footprints**. The ADC's integrated filters are a separate function. SMB shells, negative-input ground jumpers and the controller interface share AGND; differential measurement here is not galvanic isolation.

### Digital interface and standalone straps

Schematic sheet 2 exposes the ADC data bus at P1 and control/serial signals at P2. DB9–DB12 are shared with DOUTA–DOUTD, and DB13 with SDI. The board drawing explicitly names four serial output nets; the ADC's eight-lane feature must be traced through its alternate DB pins and the carrier before selecting it. Do not assume the named four DOUT nets are the only possible paths or that all eight lanes are already supported by the carrier.

The guide's standalone settings require resistor configuration as well as jumpers:

| Control | Board option in UG-1870 Table 2 |
| --- | --- |
| STBY | JP1 A ties high; B ties low. Standalone instructions call for R8/R10 changed to 0 Ω links. |
| RANGE | JP4 A selects ±10 V; B selects ±5 V in hardware mode. Standalone instructions call for R20 = 0 Ω. Software mode ignores RANGE. |
| PAR/SER SEL | JP5 A selects serial; B selects parallel. Standalone instructions call for R19/R21 = 0 Ω. |
| REF SELECT | JP6 A selects internal, B external. Standalone instructions call for R13 = 0 Ω. |
| OS0–OS2 | S1 is open by default and the carrier normally drives these lines. Standalone S1 settings establish mode/oversampling; all high selects software mode. |

The drawings show 10 kΩ pulls, 0 Ω routing links and 100 Ω series protection on the carrier control signals. Do not convert every pull or resistor to 0 Ω without checking the particular net, selected jumper contact and actual board. Some user-guide resistor names and drawing population choices are awkward; use continuity checks and board revision matching during a later bench review. The standalone ADC interface also needs the regulator-enable/power-good state accounted for. Moving JP2 alone is not proof that an unconnected carrier path will power every rail correctly.

Schematic sheet 4 maps signals to the 160-contact FMC-LPC connector. Important examples are SCLK G6, DOUTA G7, SDI G9, DOUTB C11, DOUTC D11, DOUTD D14, CONVST D12, BUSY H13, RESET C10 and CS H10. These are **drawing references for later verification**, not an approved cable pinout. Also shown are an M24C02 board-identification EEPROM on I²C, grounded board-presence H2, CARRIER_POWER_GOOD on D1, 12 V on C35/C37, 3.3 V auxiliary on D32, and VADJ marked unused. The EEPROM is not a sample buffer. The carrier generates sampling timing and captures converter data.

## Layout films

| PDF page | Film | Observation |
| --- | --- | --- |
| 1 | Primary silkscreen | Analog connectors on the left, ADC centrally, carrier connector on the right; reference/power near the top, digital controls below/right |
| 2 | L1 top copper | Input traces converge at the ADC; digital bus routes to carrier; ground copper fills the remaining areas |
| 3 | L2 ground | Broad internal ground plane with via/through-hole clearances |
| 4 | L3 power | Internal power distribution and ground/copper regions |
| 5 | L4 bottom copper | Back-side routing, decoupling/reference connections and FMC access |
| 6 | Secondary silkscreen | Locations of underside decoupling, pulls and connector references; mirrored plot conventions require care |
| 7 | Secondary paste mask | Bottom assembly paste apertures |
| 8 | Primary paste mask | Top assembly paste apertures, including ADC leads |
| 9 | Secondary solder mask | Bottom exposed pads and connector clearances |
| 10 | Primary solder mask | Top exposed pads and connector clearances |

This is a four-copper-layer board, not ten copper layers. The film set does not supply a fabrication stackup, copper thickness, controlled impedance specification, a complete BOM or a machine-readable netlist. It supports placement/routing review, not a verified reproduction or exact analog parasitic model.

## What the supplied evaluation software actually does

UG-1870 pp. 3 and 6–8 cover Windows installation, drivers and connection of SDP-H1. No installation was performed. Pages 9–11 expose per-channel input range, bandwidth, calibration, diagnostic mux, oversampling, serial/parallel mode and reference selection. The memory map offers readback and comparison as well as writes; a future implementation should likewise distinguish requested settings from confirmed hardware state.

Pages 12–15 describe waveform, histogram and FFT views. Capture length and sampling rate are configurable; channels must be enabled before capture. Data is first gathered into the FPGA and then transferred to the PC once a frame is complete. The guide explicitly describes continuous mode as repeated batches of the single-capture operation. **That is not evidence of lossless, gap-free streaming.** XML export includes capture data and settings. FFT analysis supports selectable windows, fundamental/harmonic-bin settings, single-tone/two-tone analysis, SNR and distortion measurements. These are ADC evaluation features, not biomarker validation.

The Python/MATLAB automation mentioned on p. 13 controls ACE; Python availability does not remove the proprietary Windows dependency. The ESD and evaluation-use notices are on p. 15. No performance or biological recording result has been measured in this project.

## Ubuntu and open-source implications

ADI explicitly describes [ACE as proprietary and Windows based](https://wiki.analog.com/resources/tools-software/ace/userguide). It cannot be the required project workflow. The existence of a new [Evaluation Studio](https://www.analog.com/en/resources/evaluation-hardware-and-software/embedded-development-software/evaluation-studio.html), whose page currently labels Linux as coming soon, does not establish an available open-source Ubuntu solution either. These were checked on 3 November 2026.

The upstream [Linux AD7606 SPI driver](https://github.com/torvalds/linux/blob/master/drivers/iio/adc/ad7606_spi.c) contains an AD7606C-18 device match and declares GPL v2. The [ADI no-OS AD7606 driver](https://github.com/analogdevicesinc/no-OS/blob/main/drivers/adc/ad7606/ad7606.c) is another reference to inspect for reuse. Neither fact proves that SDP-H1 works on Ubuntu, that the installed kernel includes the needed version, or that every ADC mode achieves its maximum rate. The selected controller, port implementation, source license and complete build path still need validation.

For a future custom RISC-V design, a plausible division is hardware sampling/capture plus buffered processing under the CPU. That is an engineering inference, not a selected implementation. The interface must preserve all 18 bits, respect timing and provide timestamps and overrun detection independently of an FFT task. A carrier or FPGA choice must pass the project's full open-source build requirement before adoption; a freely downloadable proprietary FPGA suite would not satisfy it.
