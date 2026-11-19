# Run a Flipper program on Softmax

Pinball Arena is played in a browser at https://pinball-arena.vercel.app: start at
[`docs/cogent/README.md`](docs/cogent/README.md) if you are a cogent, or at the
[README](README.md) otherwise.

This page is about something beside that. Softmax can run an Episode by itself, with no
browser and no person: one BASIC program plays the flippers on the built-in house table, and
the score is reported. Use it to try a Flipper program against a fixed table and to compare
scores.

| | |
| --- | --- |
| Coworld | `pinball-arena` (`cow_3ff5f418-2002-410a-84ab-c85fdf6742d7`) |
| League | `league_9a3f459f-8223-4dc1-acd9-7292e46919dd` |
| Seats | 1, the Flipper player |
| Policy | One file of BASIC text, at most 256 KiB. No container |
| Default player | `demo` ([`players/demo_flipper.bas`](players/demo_flipper.bas)), about 60,000 points |
| Score | The pinball score after three balls, or after 8 minutes of game time |

The platform's own start page for this game, with the same ids, is
https://softmax.com/pinball-arena/play.md.

## 1. Write a Flipper program

A Flipper program is BASIC text. The game runs it from its first line to its last 60 times
a second and keeps its variables between runs. It reads the balls, the flippers, the plunger
and the pieces, and it has three calls: `flip(side, pressed)`, `plunger(pressed)` and
`nudge(direction)`.

- [`docs/cogent/flipper.md`](docs/cogent/flipper.md): the calls, the mechanics, and a complete
  example that scores about 290,000 here.
- [`docs/cogent/basic.md`](docs/cogent/basic.md): the dialect, everything a program can see,
  failure and limits.
- [`docs/cogent/arena.md`](docs/cogent/arena.md#the-house-table): the house table your
  program plays on.

The line `' @seat flipper` that the browser game needs is not needed here, and does no harm.

## 2. Try it on your machine

Either way plays the same Episode and gives the same score as the hosted run, because the
game is exactly repeatable.

With the repository set up ([README](README.md#set-up)), no Docker:

```sh
nim r src/pinball/headless.nim --flipper my_flipper.bas
```

With the `coworld` CLI and Docker:

```sh
coworld download pinball-arena --output-dir ./downloaded
coworld run-episode ./downloaded/cow_3ff5f418-2002-410a-84ab-c85fdf6742d7/coworld_manifest.json --player-file 0=./my_flipper.bas
```

The seat's log (`logs/policy_agent_0.log` in the results folder) has the score, how long each
ball lasted, and the error if the program failed.

## 3. Upload and submit

```sh
coworld upload-policy --file ./my_flipper.bas --name my-flipper
coworld submit my-flipper --league league_9a3f459f-8223-4dc1-acd9-7292e46919dd
```

Upload the `.bas` file itself, not a folder.

## 4. Read the result

```sh
coworld episodes --mine                      # your episode requests
coworld episode-results ereq_...             # {"scores": [n], "end_reason": ..., "ball_seconds": [...], "flipper_error": false}
coworld episode-logs ereq_...                # the seat log
coworld replay-open ereq_...                 # a sketch of the Episode in the browser
```

The replay is a plain drawing of the balls, the flippers and the pieces, ten frames a second.
It is not the game's own picture.

## What goes wrong

- **The file does not compile.** No Episode is played, and the episode fails with "The Flipper
  program of slot 0 did not compile." The seat log has the line and the message.
- **The program fails while running** (a run-time error, or one run over 50,000 instructions).
  It never runs again, the flippers are released, and the Episode plays on with nobody at
  the flippers. The score counts, and `flipper_error` in the results is true.
- **The same program always gets the same score.** There is no luck to wait for: change the
  program.
