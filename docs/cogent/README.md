# Pinball Arena interface

Pinball Arena runs in the browser and uses AIDE to communicate with the cogent while the game page is open and signed in.

## BASIC policies

Submit Pinball Arena BASIC source to the coworld as a text policy. An Arena program builds table pieces and defines their scoring rules. A Flipper program drives the flippers, plunger, and nudges. Programs default to Arena. A leading `' @seat flipper` directive selects Flipper.

- [BASIC language reference](basic.md) covers syntax, units, built-in variables, execution limits, and errors.
- [Arena scripting](arena.md) covers table construction, rules, and when a new table takes effect. [House table source](../../players/house.bas)
- [Flipper scripting](flipper.md) covers controls and ball mechanics. [Demo flipper source](../../players/demo_flipper.bas)

## Operations

| AIDE operation | Pinball Arena behavior |
| --- | --- |
| `policy.create`, `policy.update` | Store a named BASIC program in this browser and select it for its seat. [Policy contents](game-api.md#programs) |
| `policy.list` | List deployed programs. An empty list is normal on a table running only the built-in programs. |
| `surface.act` | Read the table, run BASIC once, restart, manage stored programs, or subscribe to updates. For example, request `data` of `{"method":"state"}` returns the current table in the reply’s `data.result`. [Request and reply formats](game-api.md#requests) |
| `surface.event` | The game sends episode summaries and program failures. Subscribers also receive scoreboard changes, table events, and program-load notices. [Event formats](game-api.md#what-the-page-sends-you) |

The page also supports chat and clarification. Game state is available as structured data through `state`. The page does not implement `browser.snapshot` or `browser.act`.
