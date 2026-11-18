# The script hosts

The code that lets a BASIC program play a seat. This page is for people who change that
code. **What a program can see and call is documented for its authors in
[`docs/cogent/`](../../../docs/cogent/README.md)**:

| Topic | Page |
| --- | --- |
| How a program runs, the dialect, the view, the constants, maths, failure, limits | [`basic.md`](../../../docs/cogent/basic.md) |
| The Arena calls, pieces and rules | [`arena.md`](../../../docs/cogent/arena.md) |
| The Flipper calls | [`flipper.md`](../../../docs/cogent/flipper.md) |

When you add or change a call, a view name, a constant or a limit here, change that page in
the same commit.

## Files

| File | What it holds |
| --- | --- |
| `hosts.nim` | `loadScript`, `decide`, the budgets |
| `base.nim` | The `Script` type and `give`, the one place where a call becomes a command |
| `view.nim`, `view.bas` | The view: the named numbers and the `balls` / `pieces` records |
| `common_api.nim` | Constants and maths, for both seats |
| `flipper_api.nim` | The Flipper seat calls |
| `arena_api.nim` | The Arena seat calls |

The language is Bassy BASIC (`deps/bassy/docs/language.md`).

## How it works

- `loadScript(seat, source)` compiles a program with the calls of one seat and returns a
  `Script`. Check `status` and `error`. A compiled program keeps its variables, so the driver
  loads a new `Script` each time a program takes its seat.
- `decide(script, table)` fills the view, then runs the program once from the top with a
  fresh instruction budget. It does nothing once the status is not `scriptRunning`.
- **A call becomes a command.** Each BASIC call that changes the table builds a `Command`
  and hands it to `give`, which applies it at once through `simulation.apply`, appends it to
  `script.issued`, and returns the outcome to BASIC: the new id or index (or 1) when
  accepted, `-ord(RejectReason)` when rejected.
- `script.issued` holds every command of the latest decision, in order, rejected ones
  included. The driver records them all for the replay, because a rejected edit is logged in
  the table and is part of its state hash. When a Flipper program fails, the releases of the
  flippers and the plunger are in `issued` on that decision.
- `script.output` holds the last 16 printed lines, oldest first.
- **Direct control** uses the same path: the driver's `run` message compiles the lines it is
  given as a throwaway `Script` and calls `decide` once (`runSource` in `game.nim`).

## Details that are easy to miss

- **The view names are registered from the list that fills them** (`viewNumbers` in
  `view.nim`), so the two cannot drift apart. The record types are declared in a BASIC
  prelude (`view.bas`) that is put in front of the author's source; `withAuthorLine` corrects
  the line numbers of compile errors back to the author's lines. A program can write to
  `balls` and `pieces`, and the host overwrites them before the next decision.
- **The constants are generated from the enums** in `sim/types.nim`: a prefix plus the enum
  value's name without its own prefix, in lower case (`ckPopBumper` becomes
  `kind_popbumper`). Adding an enum value adds the constant; the lists in `basic.md` must be
  updated by hand.
- **`track(...)` is seven commands**: the track piece, then `set_controlax`, `set_controlay`,
  `set_controlbx`, `set_controlby`, `set_moutha`, `set_mouthb`. The mouths come last because
  the track is checked against the pieces in its way once both are set. If a command is
  rejected, the track piece is removed again (an eighth command).
- **A node result is checked in two steps.** Adding it checks only its own values (score
  size, signal number, text). The pieces it names are not checked then, because a rule may
  name a piece that is built later. An edit result is checked when it runs.
- **Each program has its own random generator** with a fixed seed per seat, so `rnd` gives
  the same numbers in every Episode.
- **Budgets** are constants at the top of `hosts.nim`. Bassy also meters "work": an
  instruction is one unit, a host call 16 more, and a string operation its length in bytes.
  The work budget is 20 times the instruction budget, so only a program that works on long
  strings reaches it first. Both overruns are reported as `scriptOverBudget`, told from
  other errors by Bassy's exact messages (`BudgetMessages`).
- **Bassy gives no line number for run-time errors.**
