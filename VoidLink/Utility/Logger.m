//
//  Logger.m
//  Moonlight
//
//  Created by Diego Waxemberg on 2/10/15.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "Logger.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

static const unsigned long long ControllerDiagnosticsMaximumFileSize = 1024 * 1024;
static char ControllerDiagnosticsQueueKey;

@implementation ControllerDiagnostics

+ (dispatch_queue_t)diagnosticsQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.voidlink.controller-diagnostics", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(queue, &ControllerDiagnosticsQueueKey,
                                    &ControllerDiagnosticsQueueKey, NULL);
    });
    return queue;
}

+ (NSString *)currentLogPath {
    NSURL *cacheDirectory = [[NSFileManager defaultManager] URLForDirectory:NSCachesDirectory
                                                                   inDomain:NSUserDomainMask
                                                          appropriateForURL:nil
                                                                     create:YES
                                                                      error:nil];
    NSURL *directory = [cacheDirectory URLByAppendingPathComponent:@"ControllerDiagnostics" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return [[directory URLByAppendingPathComponent:@"controller-diagnostics.jsonl"] path];
}

+ (void)rotateLogAtPath:(NSString *)path {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attributes[NSFileSize] unsignedLongLongValue] < ControllerDiagnosticsMaximumFileSize) return;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *olderPath = [path stringByAppendingString:@".2"];
    NSString *previousPath = [path stringByAppendingString:@".1"];
    [fileManager removeItemAtPath:olderPath error:nil];
    if ([fileManager fileExistsAtPath:previousPath]) [fileManager moveItemAtPath:previousPath toPath:olderPath error:nil];
    [fileManager moveItemAtPath:path toPath:previousPath error:nil];
}

+ (NSDictionary<NSString *, id> *)recordForEvent:(NSString *)event fields:(NSDictionary<NSString *, id> *)fields {
    static NSString *sessionIdentifier;
    static dispatch_once_t sessionOnceToken;
    dispatch_once(&sessionOnceToken, ^{
        sessionIdentifier = NSUUID.UUID.UUIDString;
    });

    NSMutableDictionary<NSString *, id> *record = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
    record[@"event"] = event ?: @"unknown";
    record[@"timestamp_utc"] = [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]];
    record[@"uptime_seconds"] = @(NSProcessInfo.processInfo.systemUptime);
    record[@"session_id"] = sessionIdentifier;
    return record;
}

+ (NSData *)jsonLineForRecord:(NSDictionary<NSString *, id> *)record {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingFragmentsAllowed error:&error];
    if (json == nil) {
        NSDictionary *fallback = @{
            @"event": @"diagnostic_serialization_error",
            @"timestamp_utc": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],
            @"error": error.localizedDescription ?: @"unknown"
        };
        json = [NSJSONSerialization dataWithJSONObject:fallback options:0 error:nil];
    }
    NSMutableData *line = [NSMutableData dataWithData:json ?: [NSData data]];
    [line appendBytes:"\n" length:1];
    return line;
}

+ (void)appendRecord:(NSDictionary<NSString *, id> *)record {
    NSString *path = [self currentLogPath];
    [self rotateLogAtPath:path];
    NSData *line = [self jsonLineForRecord:record];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (file == nil) return;
    @try {
        [file seekToEndOfFile];
        [file writeData:line];
    }
    @catch (__unused NSException *exception) {
        // Diagnostics must never interrupt input handling or app startup.
    }
    @finally {
        [file closeFile];
    }
}

+ (void)recordEvent:(NSString *)event fields:(NSDictionary<NSString *,id> *)fields {
    dispatch_queue_t queue = [self diagnosticsQueue];
    static dispatch_once_t sessionStartToken;
    dispatch_once(&sessionStartToken, ^{
        NSDictionary *sessionRecord = [self recordForEvent:@"diagnostics_session_started" fields:@{}];
        dispatch_async(queue, ^{
            [self appendRecord:sessionRecord];
        });
    });
    NSDictionary *record = [self recordForEvent:event fields:fields];
    dispatch_async(queue, ^{
        [self appendRecord:record];
    });
}

+ (NSURL *)exportURL {
    dispatch_queue_t queue = [self diagnosticsQueue];
    __block NSURL *createdExportURL = nil;
    void (^buildExport)(void) = ^{
        NSString *path = [self currentLogPath];
        NSURL *directory = [NSURL fileURLWithPath:[path stringByDeletingLastPathComponent] isDirectory:YES];
        NSMutableData *exportData = [NSMutableData data];

        NSDictionary *metadata = @{
            @"event": @"export_metadata",
            @"timestamp_utc": [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]],
            @"app_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
            @"app_build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
            @"os_version": UIDevice.currentDevice.systemVersion ?: @"unknown",
            @"device_model": UIDevice.currentDevice.model ?: @"unknown",
            @"note": @"A zero return is the client-side API success result; it does not confirm Sunshine or DS4Windows received the packet."
        };
        [exportData appendData:[self jsonLineForRecord:metadata]];

        for (NSString *suffix in @[@".2", @".1", @""]) {
            NSString *candidatePath = suffix.length == 0 ? path : [path stringByAppendingString:suffix];
            NSData *contents = [NSData dataWithContentsOfFile:candidatePath];
            if (contents != nil) [exportData appendData:contents];
        }

        NSString *exportName = [NSString stringWithFormat:@"VoidLink-controller-diagnostics-%@.jsonl",
                                [[NSISO8601DateFormatter new] stringFromDate:[NSDate date]]];
        exportName = [exportName stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        createdExportURL = [directory URLByAppendingPathComponent:exportName];

        BOOL exportWritten = [exportData writeToURL:createdExportURL options:NSDataWritingAtomic error:nil];
        if (!exportWritten) return;

        NSArray<NSURL *> *existingExports = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:directory
                                                                           includingPropertiesForKeys:nil
                                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                                error:nil];
        NSPredicate *exportPredicate = [NSPredicate predicateWithBlock:^BOOL(NSURL *fileURL, NSDictionary *bindings) {
            return [fileURL.lastPathComponent hasPrefix:@"VoidLink-controller-diagnostics-"];
        }];
        NSMutableArray<NSURL *> *oldExports = [[existingExports filteredArrayUsingPredicate:exportPredicate] mutableCopy];
        [oldExports sortUsingComparator:^NSComparisonResult(NSURL *first, NSURL *second) {
            return [first.lastPathComponent compare:second.lastPathComponent];
        }];
        while (oldExports.count > 3) {
            NSURL *oldestExport = oldExports.firstObject;
            [[NSFileManager defaultManager] removeItemAtURL:oldestExport error:nil];
            [oldExports removeObjectAtIndex:0];
        }
    };

    if (dispatch_get_specific(&ControllerDiagnosticsQueueKey) != NULL) {
        buildExport();
    } else {
        dispatch_sync(queue, buildExport);
    }

    return createdExportURL;
}

@end

#if defined(NDEBUG)
static LogLevel LoggerLogLevel = LOG_I;
#else
// Debug is too spammy during discovery
// static LogLevel LoggerLogLevel = LOG_D;
static LogLevel LoggerLogLevel = LOG_I;
#endif

void LogTagv(LogLevel level, NSString* tag, NSString* fmt, va_list args) {
    NSString* levelPrefix = @"";

    if (level < LoggerLogLevel) {
        return;
    }

    switch(level) {
        case LOG_D:
            levelPrefix = PRFX_DEBUG;
            break;
        case LOG_I:
            levelPrefix = PRFX_INFO;
            break;
        case LOG_W:
            levelPrefix = PRFX_WARN;
            break;
        case LOG_E:
            levelPrefix = PRFX_ERROR;
            break;
        default:
            levelPrefix = @"";
            assert(false);
            break;
    }
    NSString* prefixedString;
    if (tag) {
        prefixedString = [NSString stringWithFormat:@"%@ (%@) %@", levelPrefix, tag, fmt];
    } else {
        prefixedString = [NSString stringWithFormat:@"%@ %@", levelPrefix, fmt];
    }
    NSLogv(prefixedString, args);
}

void LogTag(LogLevel level, NSString* tag, NSString* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogTagv(level, tag, fmt, args);
    va_end(args);
}
