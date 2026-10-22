# Spine 3.6 runtime

`spine-webgl.js` is the unmodified Esoteric Software Spine Runtimes 3.6
browser bundle, obtained from Sallyn0225/eidolon-sc at commit
8a31a358fc9347f88d2108bd74b7945d6c51912a,
frontend/public/vendor/spine-3.6/spine-webgl.js.
Its original license is retained in LICENSE; this code is not covered by
the application's license. The player.js adapter and Android host are
application integration code. No character model is bundled.

The Android host serves a fixed allowlist from an isolated HTTPS origin.
Network, file and content access and navigation are disabled. Model bytes
are supplied in memory through Flutter's platform channel. The JavaScript
bridge only reports ready/error events. Both import validation and playback
use the same engine, including texture decoding, clipping correction and
premultiplied-alpha rendering.
