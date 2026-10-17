// Public Photoshop memory APIs shared by the isolated settings host and probe.
#pragma once
#include "PIHandleSuite.h"
#include "PIBufferSuite.h"
#include <pthread.h>

namespace ProbeMemory {
constexpr size_t limit = 512 * 1024 * 1024;
struct alignas(16) Block { size_t size; bool locked; };
static size_t used = 0;
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

static size_t available() {
    pthread_mutex_lock(&mutex);
    size_t result = limit - used;
    pthread_mutex_unlock(&mutex);
    return result;
}

static Ptr allocate(size_t size) {
    pthread_mutex_lock(&mutex);
    Block *block = nullptr;
    if (size <= limit - used) block = static_cast<Block *>(malloc(sizeof(Block) + (size ? size : 1)));
    if (block) { block->size = size; block->locked = false; used += size; }
    pthread_mutex_unlock(&mutex);
    return block ? reinterpret_cast<Ptr>(block + 1) : nullptr;
}

static size_t sizeOf(Ptr pointer) {
    return pointer ? (reinterpret_cast<Block *>(pointer) - 1)->size : 0;
}

static void dispose(Ptr pointer) {
    if (!pointer) return;
    Block *block = reinterpret_cast<Block *>(pointer) - 1;
    pthread_mutex_lock(&mutex);
    used -= block->size;
    pthread_mutex_unlock(&mutex);
    free(block);
}

static Handle newHandle(int32 size) {
    if (size < 0) return nullptr;
    auto handle = reinterpret_cast<Handle>(allocate(sizeof(Ptr)));
    if (!handle) return nullptr;
    *handle = allocate(size);
    if (!*handle) { dispose(reinterpret_cast<Ptr>(handle)); return nullptr; }
    return handle;
}

static void disposeHandle(Handle handle) {
    if (handle) { dispose(*handle); dispose(reinterpret_cast<Ptr>(handle)); }
}

static int32 handleSize(Handle handle) { return handle ? int32(sizeOf(*handle)) : 0; }

static OSErr resizeHandle(Handle handle, int32 size) {
    if (!handle || size < 0) return paramErr;
    Ptr replacement = allocate(size);
    if (!replacement) return memFullErr;
    size_t previous = sizeOf(*handle);
    memcpy(replacement, *handle, previous < size_t(size) ? previous : size_t(size));
    dispose(*handle);
    *handle = replacement;
    return noErr;
}

static Ptr lockHandle(Handle handle, Boolean) {
    if (handle) (reinterpret_cast<Block *>(handle) - 1)->locked = true;
    return handle ? *handle : nullptr;
}
static void unlockHandle(Handle handle) {
    if (handle) (reinterpret_cast<Block *>(handle) - 1)->locked = false;
}
static void recoverSpace(int32) {}
static void setHandleLock(Handle handle, Boolean lock, Ptr *address, Boolean *oldLock) {
    if (address) *address = handle ? *handle : nullptr;
    Block *block = handle ? reinterpret_cast<Block *>(handle) - 1 : nullptr;
    if (oldLock) *oldLock = block && block->locked;
    if (block) block->locked = lock;
}

static OSErr allocateBuffer64(int64 size, BufferID *buffer) {
    if (!buffer || size < 0) return paramErr;
    *buffer = reinterpret_cast<BufferID>(allocate(size_t(size)));
    return *buffer ? noErr : memFullErr;
}
static OSErr allocateBuffer(int32 size, BufferID *buffer) { return allocateBuffer64(size, buffer); }
static Ptr lockBuffer(BufferID buffer, Boolean) { return reinterpret_cast<Ptr>(buffer); }
static void unlockBuffer(BufferID) {}
static void freeBuffer(BufferID buffer) { dispose(reinterpret_cast<Ptr>(buffer)); }
static int32 space32() { return int32(available()); }
static int64 space64() { return int64(available()); }
static OSErr reserve(int32 size) { return size >= 0 && size_t(size) <= available() ? noErr : memFullErr; }

static Ptr newBuffer64(unsigned64 *requested, unsigned64 minimum) {
    size_t amount = requested ? size_t(*requested) : size_t(minimum);
    size_t capacity = available();
    if (amount < minimum) amount = size_t(minimum);
    if (amount > capacity) amount = capacity;
    if (amount < minimum) return nullptr;
    Ptr pointer = allocate(amount);
    if (pointer && requested) *requested = amount;
    return pointer;
}
static Ptr newBuffer(unsigned32 *requested, unsigned32 minimum) {
    unsigned64 size = requested ? *requested : minimum;
    Ptr pointer = newBuffer64(&size, minimum);
    if (pointer && requested) *requested = unsigned32(size);
    return pointer;
}
static void disposeBuffer(Ptr *buffer) {
    if (buffer) { dispose(*buffer); *buffer = nullptr; }
}
static unsigned32 bufferSize32(Ptr buffer) { return unsigned32(sizeOf(buffer)); }
static unsigned64 bufferSize64(Ptr buffer) { return sizeOf(buffer); }
static unsigned32 bufferSpace32() { return unsigned32(available()); }
static unsigned64 bufferSpace64() { return available(); }

static HandleProcs handles = {kCurrentHandleProcsVersion, kCurrentHandleProcsCount,
    newHandle, disposeHandle, handleSize, resizeHandle, lockHandle, unlockHandle, recoverSpace, disposeHandle};
static BufferProcs buffers = {kCurrentBufferProcsVersion, kCurrentBufferProcsCount,
    allocateBuffer, lockBuffer, unlockBuffer, freeBuffer, space32, reserve, allocateBuffer64, space64};
static PSHandleSuite1 picaHandles1 = {newHandle, disposeHandle, setHandleLock, handleSize, resizeHandle, recoverSpace};
static PSHandleSuite2 picaHandles2 = {newHandle, disposeHandle, disposeHandle, setHandleLock, handleSize, resizeHandle, recoverSpace};
static PSBufferSuite1 picaBuffers1 = {newBuffer, disposeBuffer, bufferSize32, bufferSpace32};
static PSBufferSuite2 picaBuffers2 = {newBuffer, disposeBuffer, bufferSize32, bufferSpace32,
    newBuffer64, bufferSize64, bufferSpace64};

static const void *suite(const char *name, int32 version) {
    if (!strcmp(name, kPSHandleSuite)) {
        if (version == 1) return &picaHandles1;
        if (version == 2) return &picaHandles2;
    }
    if (!strcmp(name, kPSBufferSuite)) {
        if (version == 1) return &picaBuffers1;
        if (version == 2) return &picaBuffers2;
    }
    return nullptr;
}
}
