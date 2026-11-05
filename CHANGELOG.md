# Changelog

CPU milestone dates identify the development steps in the project schedule. Captured tests retain their own execution dates and source hashes; a milestone date does not backdate a later simulation, proof, or mapping run. The step ranges below do not assign individual source files to dates without a corresponding record.

## 2026-11-05

The project overview now introduces the complete DRG recording and analysis scope, with installation instructions and linked sections for the microcontroller, development documentation and hardware references. Every README includes a table of contents, and the component guides retain the architecture diagrams. Evidence checksum manifests update only the README entries affected by navigation changes; captured test data and recorded execution-source hashes remain unchanged.

The project documentation now separates the implemented CPU, local platform, firmware, programming tools, and verification runners from the proposed recording and analysis system. Component guides contain the architecture diagrams, and the microcontroller guide provides implementation tables and execution flows. Host instructions distinguish the Linux development environment from unverified Windows and macOS workflows.

The active verification helpers use paths under [microcontroller/verification](microcontroller/verification/README.md). [acceptance.py](microcontroller/release/acceptance.py) stages current source and documentation, and [bootstrap_tools.py](microcontroller/release/bootstrap_tools.py) requires an explicit dependency manifest. The local-fabric target in the [test Makefile](microcontroller/tests/Makefile) supplies the runner's evidence argument. These changes do not alter the RTL or establish a new hardware qualification result.

## 2026-11-04

The CPU development milestone covers steps 19 through 24. The [implementation guide](microcontroller/README.md) describes the current component boundaries, while individual captured checks retain their narrower scope and later source-attribution limits.

## 2026-11-03

The CPU development milestone covers steps 14 through 18.

## 2026-11-02

The CPU development milestone covers steps 12 and 13.

## 2026-11-01

The CPU development milestone covers steps 6 through 11.

## 2026-10-30

The CPU development milestone covers steps 1 through 5.
