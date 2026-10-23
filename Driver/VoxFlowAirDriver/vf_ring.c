#include "vf_ring.h"

#include <stdlib.h>
#include <string.h>

int vf_ring_init(vf_ring *r, uint32_t frames, uint32_t channels)
{
    uint32_t f = 1;
    while (f < frames) f <<= 1;
    r->frames = f;
    r->channels = channels;
    r->data = calloc((size_t)f * channels, sizeof(float));
    atomic_init(&r->writeEnd, VF_RING_NONE);
    atomic_init(&r->validStart, VF_RING_NONE);
    atomic_init(&r->gaps, 0);
    atomic_init(&r->resets, 0);
    return r->data ? 0 : -1;
}

void vf_ring_free(vf_ring *r)
{
    free(r->data);
    r->data = NULL;
}

void vf_ring_reset(vf_ring *r)
{
    // Invalidate first (the reader sees silence right away), then clear.
    atomic_store_explicit(&r->writeEnd, VF_RING_NONE, memory_order_release);
    atomic_store_explicit(&r->validStart, VF_RING_NONE, memory_order_release);
    if (r->data) memset(r->data, 0, (size_t)r->frames * r->channels * sizeof(float));
    atomic_fetch_add_explicit(&r->resets, 1, memory_order_relaxed);
}

// Copies [t, t+n) into the ring (n <= frames).
static void put(vf_ring *r, int64_t t, const float *src, uint32_t n)
{
    const uint32_t mask = r->frames - 1, ch = r->channels;
    uint32_t pos = (uint32_t)((uint64_t)t & mask);
    uint32_t first = r->frames - pos < n ? r->frames - pos : n;
    if (src) {
        memcpy(r->data + (size_t)pos * ch, src, (size_t)first * ch * sizeof(float));
        memcpy(r->data, src + (size_t)first * ch, (size_t)(n - first) * ch * sizeof(float));
    } else {
        memset(r->data + (size_t)pos * ch, 0, (size_t)first * ch * sizeof(float));
        memset(r->data, 0, (size_t)(n - first) * ch * sizeof(float));
    }
}

void vf_ring_write(vf_ring *r, int64_t t, const float *src, uint32_t n)
{
    if (!r->data || n == 0) return;
    if (n > r->frames) { src += (size_t)(n - r->frames) * r->channels; t += n - r->frames; n = r->frames; }

    int64_t end = atomic_load_explicit(&r->writeEnd, memory_order_relaxed);
    if (end == VF_RING_NONE || t + (int64_t)n <= end - (int64_t)r->frames || t > end + (int64_t)r->frames) {
        // First block, large jump back (clock reset) or jump too far ahead:
        // start over from an empty ring.
        if (end != VF_RING_NONE) vf_ring_reset(r);
        atomic_store_explicit(&r->validStart, t, memory_order_release);
        end = t;
    } else if (t > end) {
        // Gap: filled with silence so old content is never read back.
        put(r, end, NULL, (uint32_t)(t - end));
        atomic_fetch_add_explicit(&r->gaps, 1, memory_order_relaxed);
    }
    put(r, t, src, n);
    int64_t newEnd = t + (int64_t)n > end ? t + (int64_t)n : end;
    atomic_store_explicit(&r->writeEnd, newEnd, memory_order_release);
}

uint32_t vf_ring_read(vf_ring *r, int64_t t, float *dst, uint32_t n)
{
    const uint32_t ch = r->channels;
    memset(dst, 0, (size_t)n * ch * sizeof(float));
    if (!r->data || n == 0) return 0;
    int64_t end = atomic_load_explicit(&r->writeEnd, memory_order_acquire);
    int64_t start = atomic_load_explicit(&r->validStart, memory_order_acquire);
    if (end == VF_RING_NONE || start == VF_RING_NONE) return 0;
    // Valid window: [max(start, end - frames + margin), end).
    // The margin guards against the writer overwriting the area being read.
    int64_t lo = end - (int64_t)r->frames + 1024;
    if (lo < start) lo = start;
    int64_t a = t > lo ? t : lo;
    int64_t b = t + (int64_t)n < end ? t + (int64_t)n : end;
    if (b <= a) return 0;
    const uint32_t mask = r->frames - 1;
    uint32_t count = (uint32_t)(b - a);
    float *out = dst + (size_t)(a - t) * ch;
    uint32_t pos = (uint32_t)((uint64_t)a & mask);
    uint32_t first = r->frames - pos < count ? r->frames - pos : count;
    memcpy(out, r->data + (size_t)pos * ch, (size_t)first * ch * sizeof(float));
    memcpy(out + (size_t)first * ch, r->data, (size_t)(count - first) * ch * sizeof(float));
    return count;
}
