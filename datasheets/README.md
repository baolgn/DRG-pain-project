# Hardware reference documents

This directory retains the manufacturer PDFs used to evaluate the proposed recording electronics. The selected chain combines the AD7606C-18 evaluation system, INA819 instrumentation amplifier and OPA2140 operational amplifier. The [development workflow](../docs/pre-coding-workflow.md) applies these documents to source loading, gain, noise, headroom, filtering and interface requirements. Component specifications do not establish the performance of an assembled recording system.

## Table of contents

1. [Converter and evaluation board](#converter-and-evaluation-board)
2. [Amplifiers](#amplifiers)
3. [Supporting application notes](#supporting-application-notes)

## Converter and evaluation board

The converter datasheet defines device behavior, while the evaluation-board documents describe the supplied board and its connections. Board revision, population, power and logic-level compatibility require inspection before electrical integration.

| Document | Purpose |
| --- | --- |
| [ad7606c-18.pdf](ad7606c-18.pdf) | Defines the eight-channel converter, input ranges, timing, configuration and digital interfaces. |
| [eval-ad7606c-fmcz-ug-1870.pdf](eval-ad7606c-fmcz-ug-1870.pdf) | Describes evaluation-board operation and configuration. |
| [eval-ad7606c18fmcz-schematic.pdf](eval-ad7606c18fmcz-schematic.pdf) | Shows the evaluation-board circuit and connector signals. |
| [eval-ad7606c18fmcz-layout.pdf](eval-ad7606c18fmcz-layout.pdf) | Shows the evaluation-board layout. |

## Amplifiers

The amplifier documents constrain the analog front end independently of converter resolution. The design must accommodate source impedance, input bias returns, offset, common-mode voltage, output swing and the required frequency response.

| Document | Purpose |
| --- | --- |
| [ina819.pdf](ina819.pdf) | Defines the INA819 instrumentation amplifier's electrical limits and behavior. |
| [opa2140.pdf](opa2140.pdf) | Defines the OPAx140 family used for the proposed filter stage. |

## Supporting application notes

These notes explain amplifier design considerations in several application contexts. Their example circuits and conditions require evaluation against the project's recording source and operating range.

| Document | Title |
| --- | --- |
| [sboa236a.pdf](sboa236a.pdf) | Simplify Voltage and Current Measurement in Battery Test Equipment. |
| [sboa341.pdf](sboa341.pdf) | Comprehensive Error Calculation for Instrumentation Amplifiers. |
| [sboa374.pdf](sboa374.pdf) | The Difference Between an Instrumentation Amplifier and a Current Sense Amplifier. |
| [sboa503.pdf](sboa503.pdf) | Importance of Input Bias Current Return Paths in Instrumentation Amplifier Applications. |
| [sboa508.pdf](sboa508.pdf) | Amplifier Input Common-Mode and Output-Swing Limitations. |
| [sbot035.pdf](sbot035.pdf) | OPA2140 EMI Immunity Performance. |
| [sbot037d.pdf](sbot037d.pdf) | Offset Correction Methods: Laser Trim, e-Trim™, and Chopper. |
| [sbot040c.pdf](sbot040c.pdf) | MUX-Friendly, Precision Operational Amplifiers. |
| [snoa975b.pdf](snoa975b.pdf) | How to Select Amplifiers for Pressure Transmitter Applications. |
| [sszt428.pdf](sszt428.pdf) | What Is an Instrumentation Amplifier? |
