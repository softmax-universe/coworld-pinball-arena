' @effect next-episode
' @table blank
'
' THE HOUSE TABLE: the Arena program that ships with Pinball Arena.
'
' How this program is organised
' -----------------------------
' The game runs an Arena program from its first line to its last 12 times a
' second, and variables keep their values between runs. So everything here
' sits behind the flag "built": the first run lays the whole table and all of
' its rules, and every later run does nothing. The rules keep working by
' themselves, because they live in the table and not in this program.
'
' Each part of the table has a SUB "build..." that places its pieces and a
' SUB "rules..." that gives them their rules. A rule is a small state machine
' (FSM). Nothing scores, lights up or shows a message except as the result of
' a rule.
'
' Places are millimetres: x 0..520 to the right, y 0..1080 toward the player.
' Rotations are degrees, clockwise on screen. The pieces cost 61 of the build
' budget of 100.
'
' The dialect has no FUNCTION, and every variable that is not a SUB parameter
' is global. That is how the SUBs share piece ids such as "saucer".

dim lane(2)         ' The three top rollover lanes, left to right.
dim saucerlamp(1)   ' The lamps that count saucer shots.
dim extralamp(1)    ' The lamps that count completed sets of lanes.

if built = 0 then
  built = 1
  names()
  buildlowerfield()
  buildupperfield()
  buildlanes()
  buildramp()
  buildlamps()
  rulesscoring()
  rulesquest()
  ruleslanes()
  rulesextraball()
  rulesmultiball()
  ruleskickbacks()
  rulesstatus()
end if

' --- Names -------------------------------------------------------------------

sub names()
  ' Group numbers. Pieces that share a group work as one unit: an edge can
  ' listen to the whole group, and a result can light or reset all of it.
  grp_bumpers = 1
  grp_slings = 2
  grp_bank = 3
  grp_standups = 4
  grp_lanes = 5
  grp_inlanes = 6
  grp_kickbacks = 7
  grp_saucerlamps = 8
  grp_extralamps = 9

  ' Signals that one rule raises and another listens for.
  sig_lanelit = 1
  sig_lanesdone = 2
end sub

' --- Pieces ------------------------------------------------------------------

sub buildlowerfield()
  ' Slingshots above the flippers. The long face kicks. Rotation 70 turns the
  ' face of the left one toward the middle of the table, -70 the right one.
  ' The gap between a slingshot and the fixed lane guide beside it is the
  ' inlane, which feeds the flipper. The kick is weaker than the 800 a
  ' slingshot starts with: at 800 these two throw the ball to each other for
  ' minutes.
  create(kind_slingshot, 112, 835, 70, 100, 1, grp_slings)
  create(kind_slingshot, 368, 835, -70, 100, 1, grp_slings)
  groupsetting(grp_slings, set_strength, 550)

  ' A rollover switch in each inlane. Rotation 90 lays the wire along the lane.
  create(kind_rollover, 62, 850, 90, 100, 1, grp_inlanes)
  create(kind_rollover, 418, 850, 90, 100, 1, grp_inlanes)

  ' A kickback at the top of each outlane. While it is lit it shoots the ball
  ' back up the table: 270 is straight up, and these lean a little inward.
  kickleft = create(kind_kickback, 24, 800, 0, 100, 1, grp_kickbacks)
  setting(kickleft, set_direction, 275)
  kickright = create(kind_kickback, 452, 800, 0, 100, 1, grp_kickbacks)
  setting(kickright, set_direction, 265)

  ' A rubber post over the top of each lane guide. It turns back a ball that
  ' a slingshot throws straight across the table at the far outlane.
  create(kind_rubberpost, 50, 778, 0, 100, 1, 0)
  create(kind_rubberpost, 430, 778, 0, 100, 1, 0)

  ' A slanted guide on each side wall. A ball that runs down the wall slides
  ' off it toward the inlane and not into the outlane. A wall is made 80 mm
  ' long, so size 75 makes it 60. The top end stops just short of the side
  ' wall: a gap there must be too small for the ball (27 mm) to enter.
  create(kind_wall, 33, 625, 56, 75, 1, 0)
  create(kind_wall, 448, 625, 124, 75, 1, 0)
end sub

sub buildupperfield()
  ' Three pop bumpers in a triangle, with 48 mm or more between them.
  create(kind_popbumper, 175, 255, 0, 100, 1, grp_bumpers)
  create(kind_popbumper, 285, 255, 0, 100, 1, grp_bumpers)
  create(kind_popbumper, 230, 345, 0, 100, 1, grp_bumpers)

  ' A bank of three drop targets in the middle of the table, with a standup
  ' target on each side that faces the flippers.
  for i = 0 to 2
    create(kind_droptarget, 198 + i * 32, 455, 0, 100, 1, grp_bank)
  next
  create(kind_standuptarget, 135, 480, -20, 100, 1, grp_standups)
  create(kind_standuptarget, 325, 480, 20, 100, 1, grp_standups)

  ' A spinner on the left, across the path of a shot from the right flipper.
  spinner = create(kind_spinner, 108, 565, 20, 100, 1, 0)

  ' A saucer on the upper right. It catches a ball that is not too fast,
  ' holds it for a second and drops it straight down the table (direction
  ' 90) into the right inlane. Size 150 makes it easier to hit.
  saucer = create(kind_saucer, 410, 330, 0, 150, 1, 0)
  setting(saucer, set_direction, 90)
end sub

sub buildlanes()
  ' Three rollover lanes under the top arch, between four short walls. The
  ' lamp of each rollover shows that its lane is done.
  for i = 0 to 2
    lane(i) = create(kind_rollover, 180 + i * 50, 125, 90, 100, 1, grp_lanes)
    setting(lane(i), set_colour, colour_green)
  next
  for i = 0 to 3
    create(kind_wall, 155 + i * 50, 125, 90, 75, 1, 0)
  next

  ' A dead stop against the arch. A launched ball runs along the arch from
  ' the right, dies on this wall (bounce 2) and drops into the lanes. A soft
  ' launch falls into the left lane and a hard one into the middle lane, so
  ' the plunger chooses.
  stopper = create(kind_wall, 136, 42, 252, 50, 1, 0)
  setting(stopper, set_bounce, 2)
end sub

sub buildramp()
  ' The ramp. A track runs between two mouths. A mouth points the way a ball
  ' leaves it, so a ball enters against the rotation: this one (120, down and
  ' to the left) catches a shot from the left flipper. The far mouth is on
  ' level 2 above the left inlane and points down the table (90), so the ball
  ' drops into the inlane and rolls to the left flipper. The four numbers
  ' after the mouths are the two points that shape the curve.
  rampin = create(kind_mouth, 400, 600, 120, 100, 1, 0)
  rampout = create(kind_mouth, 66, 810, 90, 100, 2, 0)
  ramptrack = track(rampin, rampout, 450, 380, 66, 300)
end sub

sub buildlamps()
  ' Lamps, flashers and text cost nothing and may sit under other pieces.
  ramplamp = create(kind_insert, 362, 660, 0, 100, 1, 0)
  setting(ramplamp, set_colour, colour_red)
  for i = 0 to 1
    saucerlamp(i) = create(kind_insert, 398 + i * 24, 380, 0, 100, 1, grp_saucerlamps)
    setting(saucerlamp(i), set_colour, colour_blue)
    extralamp(i) = create(kind_insert, 225 + i * 30, 650, 0, 100, 1, grp_extralamps)
    setting(extralamp(i), set_colour, colour_white)
  next
  create(kind_flasher, 70, 210, 0, 100, 1, 0)
  create(kind_flasher, 390, 180, 0, 100, 1, 0)
  text(400, 655, colour_red, "JACKPOT RAMP")
  text(410, 290, colour_blue, "MULTIBALL")
  text(240, 690, colour_white, "EXTRA BALL")
end sub

' --- Rules -------------------------------------------------------------------

sub scoreon(event, piece, piecegroup, points)
  ' One more branch of the scoring FSM: this event pays these points. The new
  ' node has no edge that leaves it, so the FSM goes straight back to its
  ' first node and is ready for the next hit.
  paid = node(scoring)
  doscore(scoring, paid, points)
  edge(scoring, 0, paid, event, piece, piecegroup, 1)
end sub

sub rulesscoring()
  ' Ordinary scoring: everything the ball can hit pays something. The page
  ' plays the sound of each hit by itself, so these rules add none.
  scoring = fsm()
  scoreon(ev_hit, 0, grp_bumpers, 100)
  scoreon(ev_hit, 0, grp_slings, 10)
  scoreon(ev_hit, 0, grp_standups, 500)
  scoreon(ev_drop, 0, grp_bank, 500)
  scoreon(ev_spin, spinner, 0, 100)
  scoreon(ev_rollover, 0, grp_lanes, 500)
  scoreon(ev_rollover, 0, grp_inlanes, 250)
  scoreon(ev_captured, saucer, 0, 2500)
  scoreon(ev_trackcompleted, ramptrack, 0, 5000)
  scoreon(ev_fired, 0, grp_kickbacks, 1000)
end sub

sub rulesquest()
  ' The main quest. Drop all three targets and the ramp is lit for 20
  ' seconds. A ramp shot in that time is the jackpot. The bank comes back up
  ' either way. The upper message box always says what to do next and the
  ' lower one what just happened.
  quest = fsm()
  bankdown = node(quest)
  jackpot = node(quest)
  missed = node(quest)
  edge(quest, 0, bankdown, ev_drop, 0, grp_bank, 3)
  edge(quest, bankdown, jackpot, ev_trackcompleted, ramptrack, 0, 1)
  timeout(quest, bankdown, missed, 20)

  dolamp(quest, bankdown, ramplamp, lamp_flashing)
  domessage(quest, bankdown, slot_quest, "RAMP IS LIT")
  domessage(quest, bankdown, slot_award, "SHOOT THE RAMP IN 20 SECONDS")
  dosound(quest, bankdown, cue_queststart)

  doscore(quest, jackpot, 50000)
  dolamp(quest, jackpot, ramplamp, lamp_off)
  domessage(quest, jackpot, slot_quest, "DROP 3 TARGETS TO LIGHT THE RAMP")
  domessage(quest, jackpot, slot_award, "JACKPOT 50,000")
  dofloat(quest, jackpot, ramplamp, "50,000")
  doflash(quest, jackpot)
  dosound(quest, jackpot, cue_jackpot)
  doresetgroup(quest, jackpot, grp_bank)

  dolamp(quest, missed, ramplamp, lamp_off)
  domessage(quest, missed, slot_quest, "DROP 3 TARGETS TO LIGHT THE RAMP")
  domessage(quest, missed, slot_award, "TOO SLOW")
  dosound(quest, missed, cue_questfail)
  doresetgroup(quest, missed, grp_bank)
end sub

sub lanerule(switch)
  ' One top lane. The first ball through lights it and tells the lanes rule.
  ' It then waits, lit, for the signal that all three are done. That edge
  ' leads back to node 0, whose own result puts the lamp out.
  lanefsm = fsm()
  lanelit = node(lanefsm)
  edge(lanefsm, 0, lanelit, ev_rollover, switch, 0, 1)
  dolamp(lanefsm, lanelit, switch, lamp_on)
  dosignal(lanefsm, lanelit, sig_lanelit)
  edgex(lanefsm, lanelit, 0, ev_fsmsignal, 0, 0, 1, 0, sig_lanesdone, 0)
  dolamp(lanefsm, 0, switch, lamp_off)
end sub

sub ruleslanes()
  ' Light all three top lanes for a bonus. Each lane signals once when it
  ' lights, so the third signal means that all three are lit. The lamps
  ' flash for a moment before the lanes start again.
  for i = 0 to 2
    lanerule(lane(i))
  next

  lanes = fsm()
  lanesdone = node(lanes)
  lanesagain = node(lanes)
  edgex(lanes, 0, lanesdone, ev_fsmsignal, 0, 0, 3, 0, sig_lanelit, 0)
  timeout(lanes, lanesdone, lanesagain, 1.5)
  doscore(lanes, lanesdone, 10000)
  dolampgroup(lanes, lanesdone, grp_lanes, lamp_flashing)
  domessage(lanes, lanesdone, slot_award, "LANES COMPLETE 10,000")
  dosound(lanes, lanesdone, cue_chime)
  dosignal(lanes, lanesagain, sig_lanesdone)
end sub

sub rulesextraball()
  ' Complete the top lanes three times for an extra ball. Two lamps count
  ' the first two.
  extra = fsm()
  extraone = node(extra)
  extratwo = node(extra)
  extrawon = node(extra)
  edgex(extra, 0, extraone, ev_fsmsignal, 0, 0, 1, 0, sig_lanesdone, 0)
  edgex(extra, extraone, extratwo, ev_fsmsignal, 0, 0, 1, 0, sig_lanesdone, 0)
  edgex(extra, extratwo, extrawon, ev_fsmsignal, 0, 0, 1, 0, sig_lanesdone, 0)
  dolamp(extra, extraone, extralamp(0), lamp_on)
  dolamp(extra, extratwo, extralamp(1), lamp_on)
  doextraball(extra, extrawon)
  dolampgroup(extra, extrawon, grp_extralamps, lamp_off)
  domessage(extra, extrawon, slot_award, "EXTRA BALL")
  dosound(extra, extrawon, cue_extraball)
  doflash(extra, extrawon)
end sub

sub rulesmultiball()
  ' Two saucer shots start a two-ball multiball with a ball save. The new
  ' ball is served one second after the second shot: a ball must be added by
  ' a node that a timeout leads to. The rule starts again when one ball is
  ' left.
  multi = fsm()
  saucerone = node(multi)
  multiready = node(multi)
  multistart = node(multi)
  multiover = node(multi)
  edge(multi, 0, saucerone, ev_captured, saucer, 0, 1)
  edge(multi, saucerone, multiready, ev_captured, saucer, 0, 1)
  timeout(multi, multiready, multistart, 1)
  edgex(multi, multistart, multiover, ev_ballcountchanged, 0, 0, 1, 0, 1, 0)

  dolamp(multi, saucerone, saucerlamp(0), lamp_on)
  domessage(multi, saucerone, slot_award, "SAUCER 1 OF 2 FOR MULTIBALL")

  doscore(multi, multiready, 20000)
  dolampgroup(multi, multiready, grp_saucerlamps, lamp_flashing)
  domessage(multi, multiready, slot_award, "MULTIBALL")
  dosound(multi, multiready, cue_fanfare)
  doflash(multi, multiready)

  doaddball(multi, multistart)
  dosave(multi, multistart, 15)
  domessage(multi, multistart, slot_award, "MULTIBALL - PLUNGE THE NEW BALL")

  dolampgroup(multi, multiover, grp_saucerlamps, lamp_off)
  domessage(multi, multiover, slot_award, "MULTIBALL OVER")
end sub

sub kickbackrule(kickback)
  ' A kickback is used up when it fires. Five hits on the standup targets
  ' light it again.
  kickfsm = fsm()
  kickused = node(kickfsm)
  kickrelit = node(kickfsm)
  edge(kickfsm, 0, kickused, ev_usedup, kickback, 0, 1)
  edge(kickfsm, kickused, kickrelit, ev_hit, 0, grp_standups, 5)
  domessage(kickfsm, kickused, slot_award, "KICKBACK USED - HIT STANDUPS 5 TIMES")
  doreset(kickfsm, kickrelit, kickback)
  domessage(kickfsm, kickrelit, slot_award, "KICKBACK IS LIT")
  dosound(kickfsm, kickrelit, cue_chime)
end sub

sub ruleskickbacks()
  kickbackrule(kickleft)
  kickbackrule(kickright)
end sub

sub tell(event, slot, words$)
  ' One more branch of the status FSM: this event shows this message.
  told = node(status)
  domessage(status, told, slot, words$)
  edge(status, 0, told, event, 0, 0, 1)
end sub

sub rulesstatus()
  ' Messages for the things that happen to the game as a whole.
  status = fsm()
  tell(ev_buildphaseended, slot_quest, "DROP 3 TARGETS TO LIGHT THE RAMP")
  tell(ev_ballsaved, slot_award, "BALL SAVED")
  tell(ev_tiltwarning, slot_award, "CAREFUL - TILT WARNING")
  tell(ev_tilt, slot_award, "TILT - FLIPPERS OFF")
  tell(ev_episodeending, slot_quest, "GAME OVER")
end sub
