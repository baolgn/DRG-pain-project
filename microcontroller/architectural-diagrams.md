# Architecture diagrams

The architecture is organized by subsystem so that diagrams remain next to their implementation descriptions. The [microcontroller overview](README.md) explains the current scope and the distinction between implemented RTL, synthetic models and proposed recording hardware.

| Subsystem | Description and diagrams |
| --- | --- |
| CPU | [Five-stage pipeline, module responsibilities and interfaces](rtl/README.md) |
| Acquisition | [Sampling, capture, ownership and controlled stopping](acquisition/README.md) |
| Memory | [Local memory and proposed recording storage services](memory/README.md) |
| Signal processing | [Synthetic workload and proposed analysis pipeline](signal-processing/README.md) |
