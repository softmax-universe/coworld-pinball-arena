## The printed playfield, embedded in both the native game and the browser build.
import pixie/fileformats/jpeg
import pixie/common

proc playfieldImage*(): Image =
  const print = staticRead("../../../web/art/orbital-flight.jpg")
  decodeJpeg(print)
