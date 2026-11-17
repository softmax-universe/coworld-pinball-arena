## Fixed-point geometry for capsules. Nothing here multiplies two lengths:
## a length is only ever multiplied by a unit vector, so values stay far
## below the point where `Fixed` wraps.

import types

proc radians*(degrees: Fixed): Fixed =
  degrees * FixedPi / 180'i32

proc closestPointOnSegment*(point, a, b: FixedVec2): FixedVec2 =
  let
    span = b - a
    length = span.length
  if length == 0'fx:
    return a
  let unit = span / length
  a + unit * clamp(dot(point - a, unit), 0'fx, length)

proc onOppositeSides(a, b, c, d: FixedVec2): bool =
  ## True when `c` and `d` lie strictly on opposite sides of the line a-b.
  let
    unit = normalize(b - a)
    sideC = cross(unit, c - a)
    sideD = cross(unit, d - a)
  (sideC > 0'fx and sideD < 0'fx) or (sideC < 0'fx and sideD > 0'fx)

proc segmentDistance*(a, b, c, d: FixedVec2): Fixed =
  ## The shortest distance between the segments a-b and c-d.
  if onOppositeSides(a, b, c, d) and onOppositeSides(c, d, a, b):
    return 0'fx
  # Segments that do not cross are nearest at an end of one of them.
  result = distance(a, closestPointOnSegment(a, c, d))
  result = min(result, distance(b, closestPointOnSegment(b, c, d)))
  result = min(result, distance(c, closestPointOnSegment(c, a, b)))
  result = min(result, distance(d, closestPointOnSegment(d, a, b)))

proc capsulesOverlap*(first, second: Collider): bool =
  segmentDistance(first.a, first.b, second.a, second.b) < first.radius + second.radius
