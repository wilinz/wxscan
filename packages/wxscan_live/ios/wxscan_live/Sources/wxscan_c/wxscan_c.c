// The C target exists only to carry `include/wxscan.h`, whose structs the
// Swift side reads out of the scanner's results. Swift Package Manager will
// not accept a target with no source file in it, so here is one.
//
// Under CocoaPods there is no separate target: the header lands in the pod's
// umbrella header and the Swift files see the same declarations without
// importing anything. That is why the imports over there are guarded with
// `#if canImport(wxscan_c)`.
#include "wxscan.h"
