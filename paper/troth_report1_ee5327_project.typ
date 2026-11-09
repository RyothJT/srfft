// Document Configuration
#set page(
  paper: "a4",
  margin: (x: 2cm, y: 2.5cm),
)
#set text(
  font: "Times New Roman",
  size: 12pt,
)

// #set heading(numbering: "1.1")

#show raw.where(block: true): it => block(
  breakable: true,
  fill: rgb("#f6f8fa"),
  stroke: (left: 3pt + rgb("#0969da")),
  inset: (x: 10pt, y: 10pt),
  radius: (right: 4pt),
  width: 100%,
  clip: true,
  [
    #set text(size: 0.65em, font: "DejaVu Sans Mono")
    #it
  ],
)
#let r22 = [radix-$2^2$]
#let R22 = [Radix-$2^2$]

// Title Page / Cover Header
#align(center)[
  #text(size: 20pt, weight: "bold")[
    EE5327 VLSI Design Lab (Section 4)
  ]

  #v(1em)

  EE5327 VLSI Design Project, Report 1

  #v(1.5em)

  Submitted by: Justin Troth

  Email ID: troth004\@umn.edu
]

#pagebreak()

// Table of Contents
#outline(
  title: "Table of Contents",
  depth: 2,
)

#pagebreak()

// Actual report

= Introduction

This report explores the design, verification, and synthesis of
streaming FFT architectures, focusing on radix-2, radix-4,
split-radix, and #r22 implementations. The designs are
evaluated in terms of functional correctness, silicon area, and timing
performance, with particular emphasis on the suitability of
#r22 for single-path delay-feedback (SDF) architectures.

== Design Process

I decided on implementing a streaming single delay path feedback (SDF)
FFT as it has more practical uses for topics I am personally
interested in, such as 4G/5G wireless baseband processing, radar
systems, and optical communications.

A ping-pong architecture stores intermediate data in
shared memory blocks and reuses a single processing engine across
multiple clock cycles, while a streaming architecture dedicates
independent hardware resources to each stage for continuous, real-time
data processing.

I started by designing the radix-2 and radix-4 implementations. These
served as practice for the split-radix implementation and gave me
baselines to compare against. I managed to get a split radix
configuration partially working, but in a naive architecture with a
recursively calling top module. This results in a massive silicon
area, as each stage is synthesized individually rather than having one
unit per stage, as is common in other implementations.

Constant geometry in @kwong_sr_fft was also explored, but my
implementation could not produce correct results, and as such was not
synthesized.

Ultimately, I designed a #r22 FFT. This variation is common for
streaming FFTs because it achieves the reduced memory requirements and
high throughput of a radix-4 architecture while retaining the minimal
complex multiplier count and simple control logic characteristic of a
radix-2 pipelined design.

== Standard Implementations

The standard radix-2 FFT algorithm recursively decomposes an N-point
discrete Fourier transform into two interleaved N/2-point transforms
using butterfly computation units. Structurally, it consists of
sequential stages separated by delay feedback shift registers of
halving lengths.

The radix-4 FFT algorithm recursively decomposes an N-point
discrete Fourier transform into four interleaved N/4-point
transforms using radix-4 butterfly units. Each stage processes four
data samples and reduces the number of stages compared with Radix-2.

#figure(
  image("r2_r4_diagram.png", width: 100%),
  caption: [Block diagram of (a) radix-2 and (b) radix-4 butterfly. Source: @kwong_sr_fft],
)

== Split Radix Implementation

The split-radix butterfly combines radix-2 and radix-4 decomposition
to reduce the number of arithmetic operations compared with
conventional radix-2 and radix-4 FFT algorithms. However, its
irregular dataflow and nonuniform butterfly structures complicate
hardware implementation, particularly in streaming architectures,
where control logic, data routing, and delay management become more
complex. These challenges can increase design complexity and make
efficient pipelining and hardware resource utilization more difficult.

#figure(
  image("sr_diagram.png", width: 100%),
  caption: [(a) Signal flow graph of 16-point split-radix FFT. (b) L-shaped butterfly. Source: @kwong_sr_fft],
)

=== Issues in Implementation

The initial implementation uses a naive architecture in which all
processing units are instantiated, unlike typical streaming
architectures that optimize hardware reuse and resource allocation.
The data-reordering module has not yet been implemented, as reordering
is particularly challenging for split-radix due to its irregular
dataflow. Additionally, the architecture introduces complex and costly
wire routing during physical placement, making it poorly suited to a
streaming implementation. The current design also produces incorrect
results, indicating that further development and verification are
required.

== Solution: #R22

The #R22 FFT combines elements of Radix-2 and Radix-4 algorithms to
reduce computational complexity. It decomposes each radix-4-equivalent
stage into two radix-2 stages. This structure reduces the number of
complex multipliers while maintaining an efficient pipelined
architecture.

#R22 is well suited to SDF architectures because its two radix-2
stages can be implemented using simple butterfly units and
delay-feedback paths. Its regular dataflow supports efficient hardware
reuse, while the reduced number of nontrivial complex multiplications
helps lower area and power consumption. This makes it attractive for
high-throughput streaming FFT designs that process one sample per
clock cycle. For that reason, I chose to transition to this
architecture after failing to implement split-radix.

#R22 can look similar to radix-4 in a block diagram, but it decomposes
the computation into two radix-2 stages, resulting in differences in
the placement of twiddle-factor multiplications and the internal
dataflow.

=== Implementation

Implementation generally follows the theory described in @dimeo2025.

#raw(
  "
.
├── control
│   ├── fft_control_fsm.sv
│   └── twiddle_addr_gen.sv
├── math
│   ├── cadd_sub.sv
│   ├── cmult.sv
│   └── trivial_rot.sv
├── memory
│   ├── delay_buffer.sv
│   ├── reorder_buffer.sv
│   ├── sram_dummy.sv
│   └── twiddle_rom.sv
├── pkg
│   └── fft_pkg.sv
├── r2
│   ├── bf2_core.sv
│   └── r2_fft_top.sv
├── r22
│   ├── r22_butterfly1.sv
│   ├── r22_butterfly2.sv
│   ├── r22_fft_top.sv
│   ├── r22_stage_pair.sv
│   ├── r22_twiddle_stage.sv
│   └── r2_butterfly.sv
└── r4
    ├── bf4_core.sv
    └── r4_fft_top.sv

",
  block: true,
)

The stage pair instantiates butterfly 1, which feeds into butterfly 2,
and finally into the twiddle stage. The stage pair is roughly
equivalent to a radix-4 stage, spanning two stages, although indexing
is different between them so they are not directly interchangeable.

*Butterfly 1*: Performs the first radix-2 butterfly operation on
incoming samples using a delay-feedback buffer to compute complex
additions and subtractions without requiring any twiddle factor
rotation.

*Butterfly 2*: Performs the second radix-2 butterfly operation across a
halved delay span, conditionally applying a trivial −j phase rotation
(multiplying via real-imaginary swapping and sign negation) on the
difference path without hardware multipliers.

*Twiddle Stage*: Looks up the full non-trivial stage twiddle factors
from `twiddle_rom.sv` and rotates the qualified butterfly outputs using a
pipelined complex multiplier before data passes to the next stage
pair.

= Verification

A testbench capable of accepting the top level modules of any of the
following algorithm was implemented.

However, it currently does not support radix-4 indexing, so with out a
reorder buffer for radix-4 it will mark some results as incorrect,
when in fact they are just out of order.

The testbench has five stages:

1. Impulse
2. DC
3. Sine wave
4. Cosine wave
5. Noise

The first two are useful for checking basic functionality. It is easy
to track where the impulse signal travels when being processed by each
stage. The sine and cosine waves are more complex signals which have
simple outputs: two distinct peaks which are easy to visually verify.
The final noise test is there to prove that the ordering is correct
and to establish general functionality.

There is effectively no margin of error within any of the working
implementations. However, there is still the potential for
quantization error with frequencies misaligned to the framing window.
As a result, a tolerance of plus or minus the number of FFT points was
implemented. This proved necessary to pass sine wave tests with the
sine wave not perfectly aligned to the frame.

The input signal is on top in blue, with output below in orange.

== Radix-2

#figure(
  image("r2_waveform.png", width: 80%),
  caption: "Radix-2 verification waveform.",
)

== Radix-4

#figure(
  image("r4_waveform.png", width: 80%),
  caption: "Radix-4 verification waveform.",
)

As mentioned previously, the testbench can not handle radix-4
ordering, and as such raises errors due to improper ordering.

== Radix-*$2^2$*

#figure(
  image("r22_waveform.png", width: 80%),
  caption: "Radix-$2^2$ verification waveform.",
)

== Split Radix

#figure(
  image("sr_waveform.png", width: 80%),
  caption: "Radix-2 verification waveform.",
)

My implementation attempt comes close to correct for the impulse and
DC inputs but it is clear that the outputs incorrectly for sine,
cosine, and random noise.

= Results

SRAM libraries were not provided for this project. As such all memory
is implemented as basic DFFs. Additionally, reorder buffers are not
considered to be part of the FFT itself; they were designed to verify
functionality, but were not evaluated in the area or cell count
measurements.

#figure(
  raw(
    read("fft_constraints.tcl"),
    lang: "tcl",
    block: true,
  ),
  caption: [Synthesis Parameters],
) <synthesis-parameters>

Because of the highly pipelined nature of the design, it is able to perform at speeds well above 800 MHz with little detriment to area. Synthesis results at 2.5 GHz are also provided in the table below.

#block(breakable: false)[
  #figure(
    table(
      columns: (
        2.2fr,
        1.35fr,
        0.55fr,
        0.8fr,
        0.65fr,
        0.85fr,
        0.8fr,
        0.8fr,
        0.8fr,
        0.75fr,
      ),
      align: (
        left,
        left,
        center,
        center,
        center,
        center,
        center,
        center,
        center,
        center,
      ),
      inset: 4pt,
      stroke: 0.5pt,

      table.header(
        [*Paper / Design*],
        [*FFT Type*],
        [*Size*],
        [*Word Size*],
        [*Node*],
        [*Area (µm²)*],
        [*Seq. gates*],
        [*Comb. gates*],
        [*Total gates*],
        [*Clock (MHz)*],
      ),

      [Jung et al. (2019), conventional @jung2019],
      [Radix-$2^2$ SDF],
      [256],
      [12-bit],
      [65 nm],
      [180,000\*],
      [40,800],
      [20,975\*],
      [61,775],
      [300],

      [Jung et al. (2019), optimized @jung2019],
      [Radix-$2^2$ SDF],
      [256],
      [12-bit],
      [65 nm],
      [],
      [20,320],
      [20,076\*],
      [40,396],
      [300],

      [Di Meo et al. (2025), standard @dimeo2025],
      [Radix-$2^2$ SDF],
      [256],
      [16-bit input],
      [28 nm],
      [34,300],
      [],
      [],
      [],
      [100],

      [Di Meo et al. (2025), LOBA @dimeo2025],
      [Radix-$2^2$ SDF, approximate],
      [256],
      [16-bit input],
      [28 nm],
      [27,000],
      [],
      [],
      [],
      [100],

      [This Report],
      [Radix-2 SDF],
      [256],
      [16-bit input],
      [14 nm],
      [18,156],
      [10,595],
      [20,002],
      [30,600],
      [800],

      // [This Report],
      // [Radix-4 SDF],
      // [256],
      // [16-bit input],
      // [14 nm],
      // [15,686],
      // [9,259],
      // [17,101],
      // [26,364],
      // [800],

      [This Report],
      [Radix-4 SDF],
      [256],
      [16-bit input],
      [14 nm],
      [15,043],
      [9,054],
      [16,029],
      [25,087],
      [800],


      [This Report],
      [#R22 SDF],
      [256],
      [16-bit input],
      [14 nm],
      [14,659],
      [9,083],
      [15,827],
      [24,913],
      [800],

      [This Report],
      [#R22 SDF],
      [256],
      [16-bit input],
      [14 nm],
      [15,202],
      [9,083],
      [18,095],
      [27,181],
      [2,500],

      // [Yu and Yen (2015) @yu2015],
      // [Pipelined SDF, radix to verify],
      // [128–2048],
      // [12-bit],
      // [90 nm],
      // [0.783],
      // [NR],
      // [NR],
      // [NR],
      // [40],
    ),
    caption: [Comparison of area and implementation metrics for FFT architectures],
  )
]

#v(4pt)
#text(size: 9pt)[
  \*The 0.18 mm² area is from a comparison table. Sequential gate counts are based on reported delay-element counts; combinational counts are calculated by subtracting sequential counts from total gates.
]

The proposed designs show lower area and sequential gate counts than
the reference implementations, with #R22 achieving the lowest area
among the 14 nm designs. Radix-4 was found to be 13.6% smaller than
the baseline radix-2, and #r22 was found to be 19.3% smaller than
radix-2 and 6.5% smaller than radix-4 at 800 MHz. Additionally, there
is room for far higher clock speeds with the proposed designs, as
demonstrated by the result at 2.5 GHz resulting in a mere 3.7%
increase in area compared to 800 MHz.

The substantial difference in sequential gate counts between the
reference (specifically @jung2019, optimized) and proposed designs is
likely due to inconsistencies or inaccuracies in the reported values,
including differences in how delay elements, registers, and synthesis
overhead are counted. The lack of dedicated storage elements further
complicates comparison. Therefore, these comparisons should be treated
cautiously until the implementations are verified under consistent
assumptions for word size, pipeline structure, and gate-count
methodology.

= Conclusion

#R22 provided the best area efficiency among the successfully
synthesized 14 nm designs, reducing area by 19.3% compared with the
Radix-2 baseline while maintaining high operating frequencies.
Although the split-radix implementation remained incomplete due to
data-reordering and routing challenges, the results demonstrate the
advantages of regular, pipelined architectures for streaming FFT
processing. Comparisons with published designs remain subject to
uncertainty due to differences in implementation and gate-count
methodologies.

#bibliography("references.bib", style: "ieee")

