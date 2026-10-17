#pragma once

// The immutable arrays live through the entire bulk-settings call.
struct InputFiles {
    NSArray<NSURL *> *urls;
    XPlatFileSpec *files = nullptr;
    SPPlatformFileSpecificationW *legacy = nullptr;
    uint32 *flags = nullptr;
    Handle *params = nullptr;
    bool load(NSString *path) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        id request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![request isKindOfClass:NSDictionary.class] || ![request[@"version"] isEqual:@1]) return false;
        NSArray *paths = request[@"images"];
        if (![paths isKindOfClass:NSArray.class] || paths.count == 0 || paths.count > UINT32_MAX) return false;
        NSMutableArray *images = [NSMutableArray array];
        for (id path in paths) {
            if (![path isKindOfClass:NSString.class] || ![path isAbsolutePath]) return false;
            NSURL *url = [NSURL fileURLWithPath:path];
            if (![url checkResourceIsReachableAndReturnError:nil]) return false;
            [images addObject:url];
        }
        urls = images;
        files = static_cast<XPlatFileSpec *>(calloc(urls.count, sizeof(XPlatFileSpec)));
        legacy = static_cast<SPPlatformFileSpecificationW *>(calloc(urls.count, sizeof(SPPlatformFileSpecificationW)));
        flags = static_cast<uint32 *>(calloc(urls.count, sizeof(uint32)));
        params = static_cast<Handle *>(calloc(urls.count, sizeof(Handle)));
        if (!files || !legacy || !flags || !params) return false;
        for (NSUInteger i = 0; i < urls.count; ++i) {
            files[i].mFileSpecVersion = kXPlatFileSpecVersion;
            files[i].mFileReference = (__bridge CFURLRef)urls[i];
            if (!CFURLGetFSRef((__bridge CFURLRef)urls[i], &legacy[i].mReference)) return false;
        }
        return true;
    }
    void configure(FormatRecord &record) {
        record.fileCount = uint32(urls.count);
        record.fileSpecX = files;
        record.fileSpec2 = legacy;
        record.bulkFlags = flags;
        record.bulkParams = params;
    }
    bool requestsPixels() const {
        for (NSUInteger i = 0; i < urls.count; ++i) if (flags[i] & PIFmtBulkOpenMask) return true;
        return false;
    }
    ~InputFiles() {
        if (params) for (NSUInteger i = 0; i < urls.count; ++i) if (params[i]) ProbeMemory::disposeHandle(params[i]);
        free(files); free(legacy); free(flags); free(params);
    }
};
