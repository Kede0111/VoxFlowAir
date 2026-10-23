// Audio ring indexed by sample time, shared between the "Source" device (written by
// VoxFlowAir) and the "Micro" device (read by apps). One writer, one reader, lock-free.
//
// Guarantees:
//  - a frame is read back only if it was written since the last reset and is still
//    inside the ring window; otherwise the reader gets silence;
//  - a gap in the writes (VoxFlowAir late, stopped, restarted) is filled with silence:
//    old audio is never replayed in a loop.

#ifndef vf_ring_h
#define vf_ring_h

#include <stdatomic.h>
#include <stdint.h>

#define VF_RING_NONE INT64_MIN

typedef struct vf_ring {
    float *data;               // frames × channels, interleaved
    uint32_t frames;           // power of two
    uint32_t channels;
    _Atomic int64_t writeEnd;  // sample time after the last written frame (VF_RING_NONE: nothing)
    _Atomic int64_t validStart;// first valid frame since the last reset
    _Atomic uint64_t gaps;     // gaps filled with silence (diagnostics)
    _Atomic uint64_t resets;   // resets (diagnostics)
} vf_ring;

// 0 on success. `frames` is rounded up to the next power of two.
int  vf_ring_init(vf_ring *r, uint32_t frames, uint32_t channels);
void vf_ring_free(vf_ring *r);
// Forgets all content (when the writer stops or starts).
void vf_ring_reset(vf_ring *r);
// Writes n interleaved frames starting at sample time `t`.
void vf_ring_write(vf_ring *r, int64_t t, const float *src, uint32_t n);
// Reads n interleaved frames starting at `t`; invalid frames are 0.
// Returns the number of valid frames copied.
uint32_t vf_ring_read(vf_ring *r, int64_t t, float *dst, uint32_t n);

#endif
