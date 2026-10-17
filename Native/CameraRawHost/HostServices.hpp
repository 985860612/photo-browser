// Public Adobe SDK services used by the isolated settings host.
#pragma once
#include "PIFormat.h"
#include "PIProperties.h"
#include "MemorySuites.hpp"

namespace CameraRawServices {
static SPBasicSuite basic;
static bool pixelTransferRequested = false;

static OSErr getProperty(PIType, PIType key, int32, intptr_t *simple, Handle *complex) {
    if (simple) *simple = 0;
    if (complex) *complex = nullptr;
    if (key == propVersion && simple) {
        *simple = 25 << 16;
        return noErr;
    }
    // No invented serial numbers, access tokens, or licensing properties.
    return errPlugInPropertyUndefined;
}
static OSErr setProperty(PIType, PIType, int32, intptr_t, Handle) { return errPlugInPropertyUndefined; }
static PropertyProcs properties = {kCurrentPropertyProcsVersion, kCurrentPropertyProcsCount, getProperty, setProperty};

static const void *findSuite(const char *name, int32 version) {
    if (!name) return nullptr;
    if (!strcmp(name, kSPBasicSuite) && version == kSPBasicSuiteVersion) return &basic;
    if (!strcmp(name, kPIPropertySuite) && version == kPIPropertySuiteVersion) return &properties;
    return ProbeMemory::suite(name, version);
}
static SPErr acquire(const char *name, int32 version, const void **suite) {
    if (!suite) return kSPBadParameterError;
    *suite = findSuite(name, version);
    return *suite ? kSPNoError : kSPSuiteNotFoundError;
}
static SPErr release(const char *name, int32 version) {
    return findSuite(name, version) ? kSPNoError : kSPSuiteNotFoundError;
}
static SPBoolean equal(const char *a, const char *b) { return a && b && !strcmp(a, b); }
static SPErr allocate(size_t size, void **block) {
    if (!block) return kSPBadParameterError;
    *block = ProbeMemory::allocate(size);
    return *block ? kSPNoError : kSPOutOfMemoryError;
}
static SPErr dispose(void *block) { ProbeMemory::dispose(static_cast<Ptr>(block)); return kSPNoError; }
static SPErr reallocate(void *block, size_t size, void **replacement) {
    if (!replacement) return kSPBadParameterError;
    auto pointer = ProbeMemory::allocate(size);
    *replacement = pointer;
    if (!pointer) return kSPOutOfMemoryError;
    size_t previous = ProbeMemory::sizeOf(static_cast<Ptr>(block));
    if (previous) memcpy(pointer, block, previous < size ? previous : size);
    ProbeMemory::dispose(static_cast<Ptr>(block));
    return kSPNoError;
}
static SPErr undefined() { return kSPUnimplementedError; }
static Boolean abort() { return false; }
static void progress(int32, int32) {}
static OSErr advance() {
    pixelTransferRequested = true;
    return errPlugInHostInsufficient;
}
static void configure(FormatRecord &record) {
    basic = {acquire, release, equal, allocate, dispose, reallocate, undefined};
    record.sSPBasic = &basic;
    // Compatibility profile verified with ACR 18.1.1. This is not a complete Photoshop host.
    record.hostSig = '8BIM';
    record.hostModes = 1 << plugInModeRGBColor;
    record.maxData = 256 * 1024 * 1024;
    record.abortProc = abort;
    record.progressProc = progress;
    record.advanceState = advance;
    record.propertyProcs = &properties;
    record.handleProcs = &ProbeMemory::handles;
    record.bufferProcs = &ProbeMemory::buffers;
    record.HostSupports32BitCoordinates = true;
    record.hostSupportsPluginOpeningFile = true;
}
}
