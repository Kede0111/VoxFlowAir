// VoxFlowAir Driver — constants shared by the driver, its tests and the app.
//
// Any identifier changed here must also be changed in
// Sources/VoxFlowAirCore/Virtual/VoxFlowAirDriverSupport.swift (checked by VoxFlowAirDriverTests).

#ifndef VoxFlowAirDriverShared_h
#define VoxFlowAirDriverShared_h

// Device visible to apps (OBS, FaceTime…): one stereo input.
// Base identifier and version, passed by Config/VoxFlowAir.xcconfig. The defaults
// keep the header usable on its own (editors, other build systems).
#ifndef VF_BUNDLE_ID
#define VF_BUNDLE_ID             "be.jackfrom.voxflowair"
#endif
#ifndef VF_VERSION
#define VF_VERSION               "0.0.0"
#endif

#define kVFDriver_MicName        "VoxFlowAir Micro"
#define kVFDriver_MicUID         VF_BUNDLE_ID ".driver.mic"

// Hidden device fed by VoxFlowAir: one stereo output, opened by its UID.
#define kVFDriver_FeedName       "VoxFlowAir Source (internal)"
#define kVFDriver_FeedUID        VF_BUNDLE_ID ".driver.feed"

#define kVFDriver_ModelUID       VF_BUNDLE_ID ".driver.model"
#define kVFDriver_Manufacturer   "VoxFlowAir"
#define kVFDriver_BundleID       VF_BUNDLE_ID ".driver"

#define VFDRIVER_VERSION         VF_VERSION

#define kVFDriver_Channels       2
// Size of the ring shared by the two devices (frames, power of two).
#define kVFDriver_RingFrames     32768
// Zero timestamp period (frames).
#define kVFDriver_ZeroTSPeriod   16384
// Common clock domain: both devices share the same virtual clock.
#define kVFDriver_ClockDomain    0x56584641u /* 'VXFA' */

#endif
