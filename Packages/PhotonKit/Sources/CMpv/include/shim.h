// libmpv's public headers, from mpv v0.41.0, under the ISC license that each file states.
//
// Only the types and constants are used. Photon never links libmpv: `MpvLibrary` loads it at run time
// from the app's Frameworks folder and looks up each function, so that the package builds and tests
// without it, and an app without it simply has no fallback engine.
#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"
#include "mpv/stream_cb.h"
