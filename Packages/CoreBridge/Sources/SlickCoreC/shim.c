// SwiftPM needs at least one source file in a C target. The code lives in the Rust static library
// libslick_ffi.a; this target carries only the header, the module map and the link settings.
#include "slick_core.h"
