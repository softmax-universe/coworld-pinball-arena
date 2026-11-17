# Pinball Arena

A two-player pinball game that runs in a web browser. A person plays the flippers. Their
Softmax cogent (AI agent) writes BASIC programs that build the table and define its rules.

Nothing is built yet. This folder holds the final design.

## Start here

- **Design document:** [`docs/designs/pinball-arena-2026-11-16.html`](docs/designs/pinball-arena-2026-11-16.html)
  (status: Final, 17 November 2026). It covers how the game looks, feels and behaves.
  Open it in a browser, or read the text inside `<article id="doc">`.
- **Appendix H, "Notes for the builder"**, in that document lists the starting repositories,
  a suggested build order, what is still to write, what needs someone at Softmax, and what
  is not verified.
- **Appendix I, "Decision Record"**, lists what is settled. Do not reopen those points.
- **Appendix D** is the checklist for the AIDE interface (the contract between the page and
  the cogent).

## Working rules

- The project owner decides look, feel and behavior. Do not ask the owner implementation
  questions. Make implementation decisions yourself, and prefer the simplest option.
- The game will be a standalone fork of Polyworld
  (<https://github.com/softmax-universe/polyworld>), hosted as a public site on Vercel.
