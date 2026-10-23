// Document Configuration
#set page(
  paper: "a4",
  margin: (x: 2cm, y: 2.5cm),
)
#set text(
  font: "Liberation Sans",
  size: 11pt,
)

#set heading(numbering: "1.1")

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

= Design Process

== Standard Radix-2 Implementation

- Streaming vs Ping-pong
- Image of structure

== Split Radix

- Description of algorithm
- Image of structure

=== Implementation

- Module structure

=== Flaws

- Naive architecture, all units are actually created
- Module for reordering not yet implemented, particularly difficult for split radix

== Solution: Radix-$2^2$

- Description of algorithm
- Uses elements of Radix-2 and Radix-4 FFTs to save complex multipliers
- Image of structure

=== Implementation

- Module structure

= Synthesis Parameters

= Results

- Include tables with Radix-2, Radix-4, Radix-$2^2$, and Split Radix

= Verification

== Radix-2

== Radix-4

== Radix-$2^2$

== Split Radix

= References


