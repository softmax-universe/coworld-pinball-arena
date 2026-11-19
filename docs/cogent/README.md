# Getting started as a cogent

You are the cogent (AI agent) of a person who has the Pinball Arena coworld open in their
browser. This page tells you what the game is and what you can do in it, and it helps you
set up your own knowledge base about it, so that in later sessions you can act without
reading everything again.

Nothing about the game is sent to you in the chat: the chat is only you and the person.
What you need to know is in this folder.

## The game in one minute

Pinball Arena is a pinball game for two players. It runs in the person's browser.

| Seat | Aim | What it does |
| --- | --- | --- |
| **Arena player** | That the Flipper player has fun and gets better at pinball. It has no score and is not trying to win | Builds the table and makes every rule. Nothing scores, lights or shows text unless a rule says so |
| **Flipper player** | The highest score | Works the two flippers, the plunger and nudges |

One game is an **Episode**: a build phase of 10 seconds at most while the table is laid,
then three balls, and at most 8 minutes of play.

Unless the person asks for something else, they play the flippers and you are the Arena
player. You can also play the flippers, or both seats. Take the flippers only when the
person asks you to. When nobody has given the table a program, the built-in program `house`
runs it.

## What you can do

Everything goes over the connection you already have with the page (AIDE). There is nothing
else to connect to, and the game answers only while the person has the page open.

| To | You send |
| --- | --- |
| Give a seat a BASIC program that the game runs by itself | `policy.create`, `policy.update` |
| Ask which programs you have deployed | `policy.list` |
| Run BASIC calls once, at once, for either seat | `surface.act` with the request `run` |
| Read the table: balls, pieces, score, messages, rules | `surface.act` with the request `state` |
| Follow what happens on the table | `surface.act` with the request `subscribe` |

The page sends you a `surface.event`, without being asked, when an Episode ends
(`episode.summary`) and when a program fails (`program.failed`). You answer each one with
`{"data": {}}`.

A program and direct control use the same BASIC calls. A program runs inside the game, 12
times a second for the Arena seat and 60 times a second for the Flipper seat, so it reacts
to the ball with no delay. Direct control is for trying a call and for single changes.

## Where everything is

Each fact is in one place. Find it here.

| You want to know | Read |
| --- | --- |
| The exact messages: `policy.create`, `policy.update`, `policy.list`, `surface.act`, `surface.event`, their shapes, answers and errors | [game-api.md](game-api.md) |
| What the page expects from you when it sends a `surface.event` | [game-api.md](game-api.md#what-the-page-expects-from-you) |
| The requests of `surface.act`: `run`, `state`, `subscribe`, `restart`, `programs.*` | [game-api.md](game-api.md#the-methods) |
| The fields of the state and of the Episode summary | [game-api.md](game-api.md#state), [game-api.md](game-api.md#episodesummary) |
| How a program runs, the BASIC dialect, the view, the constants, maths, failure, limits | [basic.md](basic.md) |
| The table's fixed parts, keep-out zones and build limits | [arena.md](arena.md#the-table) |
| Every piece: cost, size, behaviour, events, settings | [arena.md](arena.md#pieces) |
| Rules: state machines, edges, results, events | [arena.md](arena.md#rules) |
| Worked table programs, and the built-in house table | [arena.md](arena.md#examples), [arena.md](arena.md#the-house-table) |
| What makes a table fun and fair | [arena.md](arena.md#making-a-table-that-is-fun-and-fair) |
| The Flipper calls, flipper and plunger mechanics, ball save, tilt, an example program | [flipper.md](flipper.md) |
| The built-in programs in full | [`players/house.bas`](../../players/house.bas), [`players/demo_flipper.bas`](../../players/demo_flipper.bas) |
| How the game and the page are built | [`docs/architecture.md`](../architecture.md) |
| Running a Flipper program on Softmax with no browser, for a score | [`play.md`](../../play.md) |

## Set up your knowledge base

Read the four pages of this folder once, in this order: this one, [game-api.md](game-api.md),
[basic.md](basic.md), [arena.md](arena.md). Read [flipper.md](flipper.md) when you are first
asked to play the flippers. While you read, save what follows in whatever long-term notes
your workspace gives you. The aim is that a later session can start from your notes and
open a reference page only for a detail.

**1. A card of facts that do not change often.** Small enough to keep word for word. Start
from this and correct it as you learn:

```
Pinball Arena coworld: a pinball game in the person's browser. Two seats.
- Arena seat (my default): build the table and its rules. Aim: the person has fun and
  improves. No score for me.
- Flipper seat (only when asked): flippers, plunger, nudge. Aim: highest score.
- Episode: build phase (10 s at most), 3 balls, 8 minutes at most.
I act over my AIDE connection with the page. The page must be open.
Every message carries the game's Coworld scope {scope: "coworld", coworld, league}. I send
the same scope the page sends me, or I get "forbidden".
- policy.create / policy.update {name, scope, blob: {kind: "text", text}} -> {name, version}.
  Deploys a BASIC program and makes it active. "' @seat flipper" at the top = Flipper program.
  Arena directives at the top: ' @effect next-episode | next-ball | now, ' @table blank | house.
- policy.list {scope} -> {items: [{name, version}]}. My deployed programs. List before I
  choose create or update. The built-in house and demo are not listed.
- surface.act {scope, data: {method, params}} -> {data: {result}} or {data: {error}}.
  Methods: run {seat, source}, state, subscribe, unsubscribe, restart,
  programs.list, programs.get {name}, programs.activate {seat, name}, programs.remove {name}.
- surface.event from the page: episode.summary, program.failed (always),
  game.messages (after subscribe). I answer each with {data: {}}, promptly.
Programs run inside the game: Arena 12 times a second, Flipper 60. Variables persist.
What run builds is gone at the next Episode. Nothing scores without a rule.
```

**2. Pointers, not copies.** The reference tables (pieces, events, settings, constants, the
view) are long and change with the code. Do not copy them into your notes. Save the table
"Where everything is" above, or your own version of it, and open the page when you need a
number. Note the commit of the repository you read (`git rev-parse --short HEAD`), and when
the commit has changed, check your card against [game-api.md](game-api.md) again.

**3. Lessons from your own mistakes.** A short list that you add to. It usually starts with
the ones in "Things that catch people out" below. Add an entry each time a `program.failed`
or a refused edit teaches you something about the BASIC dialect or the table.

**4. What you know about this person.** The game stores nothing about them for you. Keep:
what kind of tables they asked for and liked, how well they play (ball times and scores
from the summaries), and what you promised to try next.

**5. Your programs.** The page keeps deployed programs in that one browser only. Keep the
source of every program you deploy, with its name and version, and one line on what it was
for and how the Episodes on it went. `policy.list` tells you what the browser still has,
and the request `programs.get` gives a program's source back.

## A first session

1. **Look at the table.** Send a `surface.act` whose `data` is `{"method": "state"}`. The
   answer's `data.result` has the phase, the score, the pieces and `programs`, which says who
   holds each seat.
2. **Deploy a small table.** Send `policy.create` with the name `first-table` and this text:

   ```basic
   ' @effect next-episode
   ' @table blank
   ' A pop bumper that pays 100 points on every hit.
   if built = 0 then
     built = 1
     bumper = create(kind_popbumper, 240, 400, 0, 100, 1, 0)

     rule = fsm()
     paid = node(rule)
     doscore(rule, paid, 100)
     edge(rule, 0, paid, ev_hit, bumper, 0, 1)
     ready()
   end if
   ```

   The answer is `{name, version}`. The program takes the table at the start of the next
   Episode, so tell the person to press "restart now", or send the request `restart`.
3. **Read what comes back.** When the Episode ends you get an `episode.summary`: the score,
   how long each ball lasted, how often each piece was hit, which rule nodes fired, and any
   edit that was refused. If the program did not compile or stopped, you get a
   `program.failed` with the message. Answer both with `{"data": {}}`.
4. **Change it.** Send `policy.update` with the same name and the whole new text. Say in the
   chat what you changed and what the person should try.
5. **Try direct control.** `{"method": "run", "params": {"seat": "arena", "source": "print budgetleft"}}`
   answers with the build budget that is left. What `run` builds lasts until the Episode
   ends, so anything that should stay belongs in a program.
6. **Write down what you learned**, as the section above says.

To play the flippers instead, deploy a program whose top comment lines include
`' @seat flipper`. [flipper.md](flipper.md#an-example) has a complete one.

## Things that catch people out

- **A table with no rules scores 0.** Hitting a piece is worth nothing until a rule pays for it.
- **A program runs again and again.** It runs from its first line every time, with its
  variables kept. Build once behind a flag (`if built = 0 then`), and never wait in a loop.
- **A refused call returns a negative number and does nothing.** Check what `create` returns,
  and read `rejectedEdits` in the summary.
- **Call `ready()` when the table is built**, or the person waits the full 10 seconds for
  the first ball.
- **The person cannot see your rules.** Lamps and the two message boxes are how they learn
  what to do.
- **`policy.create` answering with a version does not mean the program compiled.** The game
  compiles it a moment later. If it fails you get a `program.failed`; if none follows, it
  compiled.
- **A request with the wrong scope is refused.** Send the Coworld scope the page uses
  ([game-api.md](game-api.md#the-scope)), not the workspace scope.
- **The game is exactly repeatable.** The same programs and the same inputs give the same
  Episode.

## Try a program without the page

With the repository set up (the [README](../../README.md#set-up)), the command-line runner
plays one whole Episode as fast as the machine goes and prints the same summary the page
sends:

```sh
nim r src/pinball/headless.nim --arena my_table.bas       # your table, the demo program flips
nim r src/pinball/headless.nim --flipper my_flipper.bas   # your Flipper program, the house table
nim r src/pinball/headless.nim --arena my_table.bas --flipper my_flipper.bas
```

A program that does not compile stops the runner with the error and exit code 1. A program
that fails while running is printed to standard error. Use this to check a program before
you deploy it. `--flipper` says which seat a program is for, so the `' @seat flipper` line
is not needed here, and does no harm.
