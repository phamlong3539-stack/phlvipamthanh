#import "PHLOverlayUI.h"
#import "PHLSyncManager.h"
#import "PHLVoiceDSP.hpp"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mutex>
#include <objc/runtime.h>
#include <vector>

#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

#pragma mark - Built-in Mach-O Symbol Rebinding (Zero Jailbreak Substrate Dependency)

namespace {

struct PHLRebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

struct PHLRebindingsEntry {
    std::vector<PHLRebinding> rebindings;
};

static PHLRebindingsEntry *g_rebindingsEntry = nullptr;
static const void *g_selfImageBase = nullptr;

static void *stripPtrAuth(void *ptr) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(ptr, ptrauth_key_function_pointer);
#else
    return ptr;
#endif
}

static void *signPtrAuth(void *ptr, void **slot) {
#if __has_feature(ptrauth_calls)
    if (!ptr) return nullptr;
    (void)slot;
    return ptrauth_sign_unauthenticated(stripPtrAuth(ptr), ptrauth_key_function_pointer, 0);
#else
    (void)slot;
    return ptr;
#endif
}

static void rebindSymbolsInSection(
    const struct section_64 *section,
    intptr_t slide,
    struct nlist_64 *symtab,
    char *strtab,
    uint32_t *indirectSymtab,
    const std::vector<PHLRebinding> &rebindings
) {
    uint32_t *indirectIndices = indirectSymtab + section->reserved1;
    void **indirectBindings = reinterpret_cast<void **>(static_cast<uintptr_t>(slide) + section->addr);
    const size_t count = section->size / sizeof(void *);

    vm_size_t pageSize = vm_page_size;
    uintptr_t startAddr = reinterpret_cast<uintptr_t>(indirectBindings);
    uintptr_t pageStart = startAddr & ~(pageSize - 1);
    uintptr_t endAddr = startAddr + section->size;
    vm_size_t protectSize = ((endAddr - pageStart + pageSize - 1) / pageSize) * pageSize;

    // Ensure __DATA_CONST / __AUTH_CONST is writable during rebinding
    vm_protect(mach_task_self(), pageStart, protectSize, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);

    for (size_t i = 0; i < count; ++i) {
        uint32_t symtabIndex = indirectIndices[i];
        if (symtabIndex == INDIRECT_SYMBOL_ABS || symtabIndex == INDIRECT_SYMBOL_LOCAL ||
            symtabIndex == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtabOffset = symtab[symtabIndex].n_un.n_strx;
        char *symbolName = strtab + strtabOffset;
        if (!symbolName || symbolName[0] == '\0' || symbolName[1] == '\0') {
            continue;
        }
        const char *unmangled = (symbolName[0] == '_') ? (symbolName + 1) : symbolName;
        for (const auto &rb : rebindings) {
            if (std::strcmp(unmangled, rb.name) == 0) {
                if (rb.replaced && *(rb.replaced) == nullptr) {
                    *(rb.replaced) = stripPtrAuth(indirectBindings[i]);
                }
                indirectBindings[i] = signPtrAuth(rb.replacement, &indirectBindings[i]);
                break;
            }
        }
    }
}

static void rebindSymbolsForImage(const struct mach_header *header, intptr_t slide) {
    if (!g_rebindingsEntry || !header || header->magic != MH_MAGIC_64) return;
    if (g_selfImageBase && header == g_selfImageBase) return;

    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    const struct mach_header_64 *hdr64 = reinterpret_cast<const struct mach_header_64 *>(header);
    uintptr_t cur = reinterpret_cast<uintptr_t>(header) + sizeof(struct mach_header_64);

    const struct segment_command_64 *linkeditSeg = nullptr;
    const struct symtab_command *symtabCmd = nullptr;
    const struct dysymtab_command *dysymtabCmd = nullptr;

    for (uint32_t i = 0; i < hdr64->ncmds; ++i) {
        const struct load_command *cmd = reinterpret_cast<const struct load_command *>(cur);
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto *seg = reinterpret_cast<const struct segment_command_64 *>(cmd);
            if (std::strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkeditSeg = seg;
            }
        } else if (cmd->cmd == LC_SYMTAB) {
            symtabCmd = reinterpret_cast<const struct symtab_command *>(cmd);
        } else if (cmd->cmd == LC_DYSYMTAB) {
            dysymtabCmd = reinterpret_cast<const struct dysymtab_command *>(cmd);
        }
        cur += cmd->cmdsize;
    }

    if (!linkeditSeg || !symtabCmd || !dysymtabCmd || dysymtabCmd->nindirectsyms == 0) return;

    uintptr_t linkeditBase = static_cast<uintptr_t>(slide) + linkeditSeg->vmaddr - linkeditSeg->fileoff;
    auto *symtab = reinterpret_cast<struct nlist_64 *>(linkeditBase + symtabCmd->symoff);
    char *strtab = reinterpret_cast<char *>(linkeditBase + symtabCmd->stroff);
    auto *indirectSymtab = reinterpret_cast<uint32_t *>(linkeditBase + dysymtabCmd->indirectsymoff);

    cur = reinterpret_cast<uintptr_t>(header) + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < hdr64->ncmds; ++i) {
        const struct load_command *cmd = reinterpret_cast<const struct load_command *>(cur);
        if (cmd->cmd == LC_SEGMENT_64) {
            const auto *seg = reinterpret_cast<const struct segment_command_64 *>(cmd);
            if (std::strcmp(seg->segname, SEG_DATA) == 0 ||
                std::strcmp(seg->segname, "__DATA_CONST") == 0 ||
                std::strcmp(seg->segname, "__AUTH") == 0 ||
                std::strcmp(seg->segname, "__AUTH_CONST") == 0) {
                const auto *sections = reinterpret_cast<const struct section_64 *>(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; ++j) {
                    uint8_t secType = sections[j].flags & SECTION_TYPE;
                    if (secType == S_LAZY_SYMBOL_POINTERS || secType == S_NON_LAZY_SYMBOL_POINTERS) {
                        rebindSymbolsInSection(&sections[j], slide, symtab, strtab, indirectSymtab, g_rebindingsEntry->rebindings);
                    }
                }
            }
        }
        cur += cmd->cmdsize;
    }
}

static void phlDyldAddImageCallback(const struct mach_header *mh, intptr_t vmaddr_slide) {
    rebindSymbolsForImage(mh, vmaddr_slide);
}

static void installFishhookRebindings(const std::vector<PHLRebinding> &rebindings) {
    g_rebindingsEntry = new PHLRebindingsEntry{rebindings};
    _dyld_register_func_for_add_image(phlDyldAddImageCallback);
}

#pragma mark - Hook Diagnostics & Deduplication State

static std::atomic<bool> g_avAudioHooked{false};
static std::atomic<bool> g_audioUnitHooked{false};
static std::atomic<bool> g_audioQueueHooked{false};

static std::atomic<uint64_t> g_avAudioCallbacks{0};
static std::atomic<uint64_t> g_audioUnitCallbacks{0};
static std::atomic<uint64_t> g_audioQueueCallbacks{0};

static std::atomic<uint64_t> g_lastAudioUnitRenderNs{0};
static std::atomic<double> g_lastAudioUnitSampleTime{-1.0};

static uint64_t currentMachNanoseconds() noexcept {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) {
        mach_timebase_info(&tb);
    }
    return (mach_absolute_time() * tb.numer) / tb.denom;
}

#pragma mark - AudioUnit Stream Format Lock-Free Cache

struct PHLAudioUnitEntry {
    std::atomic<uintptr_t> unitPtr{0};
    AudioStreamBasicDescription asbd{};
    std::atomic<bool> hasFormat{false};
};

constexpr size_t kMaxTrackedUnits = 16;
static PHLAudioUnitEntry g_trackedUnits[kMaxTrackedUnits];

static AudioStreamBasicDescription defaultMicASBD() noexcept {
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = 48000.0;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    asbd.mBytesPerPacket = sizeof(Float32);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = sizeof(Float32);
    asbd.mChannelsPerFrame = 1;
    asbd.mBitsPerChannel = 32;
    return asbd;
}

static void cacheAudioUnitFormat(AudioUnit unit, const AudioStreamBasicDescription &asbd) noexcept {
    if (!unit || asbd.mSampleRate < 8000.0) return;
    uintptr_t key = reinterpret_cast<uintptr_t>(unit);
    for (size_t i = 0; i < kMaxTrackedUnits; ++i) {
        if (g_trackedUnits[i].unitPtr.load(std::memory_order_acquire) == key) {
            g_trackedUnits[i].asbd = asbd;
            g_trackedUnits[i].hasFormat.store(true, std::memory_order_release);
            return;
        }
    }
    for (size_t i = 0; i < kMaxTrackedUnits; ++i) {
        uintptr_t expected = 0;
        if (g_trackedUnits[i].unitPtr.compare_exchange_strong(expected, key, std::memory_order_acq_rel)) {
            g_trackedUnits[i].asbd = asbd;
            g_trackedUnits[i].hasFormat.store(true, std::memory_order_release);
            return;
        }
    }
}

static bool lookupCachedAudioUnitFormat(AudioUnit unit, AudioStreamBasicDescription &outAsbd) noexcept {
    uintptr_t key = reinterpret_cast<uintptr_t>(unit);
    for (size_t i = 0; i < kMaxTrackedUnits; ++i) {
        if (g_trackedUnits[i].unitPtr.load(std::memory_order_acquire) == key &&
            g_trackedUnits[i].hasFormat.load(std::memory_order_acquire)) {
            outAsbd = g_trackedUnits[i].asbd;
            return true;
        }
    }
    return false;
}

#pragma mark - AudioUnit Hooks (RemoteIO / VoiceProcessingIO)

typedef OSStatus (*AudioUnitRenderFn)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
typedef OSStatus (*AudioUnitSetPropertyFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);

static AudioUnitRenderFn orig_AudioUnitRender = nullptr;
static AudioUnitSetPropertyFn orig_AudioUnitSetProperty = nullptr;

static OSStatus hooked_AudioUnitSetProperty(
    AudioUnit inUnit,
    AudioUnitPropertyID inID,
    AudioUnitScope inScope,
    AudioUnitElement inElement,
    const void *inData,
    UInt32 inDataSize
) {
    if (inID == kAudioUnitProperty_StreamFormat &&
        inScope == kAudioUnitScope_Output &&
        inElement == 1 &&
        inData &&
        inDataSize >= sizeof(AudioStreamBasicDescription)) {
        const auto *asbd = static_cast<const AudioStreamBasicDescription *>(inData);
        cacheAudioUnitFormat(inUnit, *asbd);
    }

    AudioUnitSetPropertyFn fn = orig_AudioUnitSetProperty ? orig_AudioUnitSetProperty : AudioUnitSetProperty;
    return fn(inUnit, inID, inScope, inElement, inData, inDataSize);
}

static OSStatus hooked_AudioUnitRender(
    AudioUnit inUnit,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData
) {
    AudioUnitRenderFn fn = orig_AudioUnitRender ? orig_AudioUnitRender : AudioUnitRender;
    OSStatus status = fn(inUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);

    // Bus 1 on RemoteIO / VoiceProcessingIO is always the microphone capture bus.
    if (status == noErr && inBusNumber == 1 && ioData != nullptr && inNumberFrames > 0) {
        AudioStreamBasicDescription asbd;
        if (!lookupCachedAudioUnitFormat(inUnit, asbd)) {
            UInt32 propSize = sizeof(AudioStreamBasicDescription);
            if (AudioUnitGetProperty(inUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, &propSize) == noErr) {
                cacheAudioUnitFormat(inUnit, asbd);
            } else {
                asbd = defaultMicASBD();
                cacheAudioUnitFormat(inUnit, asbd);
            }
        }

        phl::dsp::VoiceDSPProcessor::shared().processAudioBufferList(ioData, inNumberFrames, asbd);
        g_lastAudioUnitRenderNs.store(currentMachNanoseconds(), std::memory_order_relaxed);
        g_lastAudioUnitSampleTime.store(inTimeStamp ? inTimeStamp->mSampleTime : -1.0, std::memory_order_relaxed);
        g_audioUnitCallbacks.fetch_add(1, std::memory_order_relaxed);
    }

    return status;
}

#pragma mark - AudioQueueInput Hook

typedef OSStatus (*AudioQueueNewInputFn)(
    const AudioStreamBasicDescription *,
    AudioQueueInputCallback,
    void *,
    CFRunLoopRef,
    CFStringRef,
    UInt32,
    AudioQueueRef _Nullable *
);
typedef OSStatus (*AudioQueueDisposeFn)(AudioQueueRef, Boolean);

static AudioQueueNewInputFn orig_AudioQueueNewInput = nullptr;
static AudioQueueDisposeFn orig_AudioQueueDispose = nullptr;

struct PHLAudioQueueContext {
    AudioStreamBasicDescription format;
    AudioQueueInputCallback origCallback;
    void *origUserData;
    AudioQueueRef queueRef;
};

static std::vector<PHLAudioQueueContext *> g_aqContexts;
static std::mutex g_aqContextsMutex;

static void phlAudioQueueInputCallbackProxy(
    void *inUserData,
    AudioQueueRef inAQ,
    AudioQueueBufferRef inBuffer,
    const AudioTimeStamp *inStartTime,
    UInt32 inNumberPacketDescriptions,
    const AudioStreamPacketDescription *inPacketDescs
) {
    auto *ctx = static_cast<PHLAudioQueueContext *>(inUserData);
    if (!ctx) return;

    if (inBuffer && inBuffer->mAudioData && inBuffer->mAudioDataByteSize > 0 && ctx->format.mBytesPerFrame > 0) {
        UInt32 frames = inBuffer->mAudioDataByteSize / ctx->format.mBytesPerFrame;
        if (frames > 0) {
            AudioBufferList list;
            list.mNumberBuffers = 1;
            list.mBuffers[0].mNumberChannels = ctx->format.mChannelsPerFrame;
            list.mBuffers[0].mDataByteSize = inBuffer->mAudioDataByteSize;
            list.mBuffers[0].mData = inBuffer->mAudioData;

            phl::dsp::VoiceDSPProcessor::shared().processAudioBufferList(&list, frames, ctx->format);
            g_audioQueueCallbacks.fetch_add(1, std::memory_order_relaxed);
        }
    }

    if (ctx->origCallback) {
        ctx->origCallback(ctx->origUserData, inAQ, inBuffer, inStartTime, inNumberPacketDescriptions, inPacketDescs);
    }
}

static OSStatus hooked_AudioQueueNewInput(
    const AudioStreamBasicDescription *inFormat,
    AudioQueueInputCallback inCallbackProc,
    void *inUserData,
    CFRunLoopRef inCallbackRunLoop,
    CFStringRef inCallbackRunLoopMode,
    UInt32 inFlags,
    AudioQueueRef *outAQ
) {
    AudioQueueNewInputFn fn = orig_AudioQueueNewInput ? orig_AudioQueueNewInput : AudioQueueNewInput;
    if (!inFormat || !inCallbackProc) {
        return fn(inFormat, inCallbackProc, inUserData, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ);
    }

    auto *ctx = new PHLAudioQueueContext{*inFormat, inCallbackProc, inUserData, nullptr};
    OSStatus st = fn(inFormat, phlAudioQueueInputCallbackProxy, ctx, inCallbackRunLoop, inCallbackRunLoopMode, inFlags, outAQ);
    if (st == noErr && outAQ && *outAQ) {
        ctx->queueRef = *outAQ;
        std::lock_guard<std::mutex> lock(g_aqContextsMutex);
        g_aqContexts.push_back(ctx);
    } else {
        delete ctx;
    }
    return st;
}

static OSStatus hooked_AudioQueueDispose(AudioQueueRef inAQ, Boolean inImmediate) {
    AudioQueueDisposeFn fn = orig_AudioQueueDispose ? orig_AudioQueueDispose : AudioQueueDispose;
    OSStatus st = fn(inAQ, inImmediate);
    std::lock_guard<std::mutex> lock(g_aqContextsMutex);
    for (auto it = g_aqContexts.begin(); it != g_aqContexts.end(); ++it) {
        if ((*it)->queueRef == inAQ) {
            delete *it;
            g_aqContexts.erase(it);
            break;
        }
    }
    return st;
}

} // namespace

#pragma mark - AVAudioInputNode Swizzling

static void (*orig_installTapOnBus)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, AVAudioFormat *, AVAudioNodeTapBlock) = nullptr;

static void hooked_installTapOnBus(
    id selfObj,
    SEL _cmd,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock tapBlock
) {
    if (!orig_installTapOnBus) return;

    if (!tapBlock || ![selfObj isKindOfClass:[AVAudioInputNode class]]) {
        orig_installTapOnBus(selfObj, _cmd, bus, bufferSize, format, tapBlock);
        return;
    }

    AVAudioNodeTapBlock origCopy = [tapBlock copy];
    AVAudioNodeTapBlock wrappedBlock = ^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        if (buffer && buffer.frameLength > 0 && buffer.format) {
            // Avoid double processing if AudioUnitRender(bus 1) already ran for this cycle
            const uint64_t nowNs = currentMachNanoseconds();
            const uint64_t lastAuNs = g_lastAudioUnitRenderNs.load(std::memory_order_relaxed);
            const double lastSample = g_lastAudioUnitSampleTime.load(std::memory_order_relaxed);
            const BOOL handledByAU = (lastAuNs > 0) && ((nowNs - lastAuNs) < 4000000ULL) &&
                                     (!when || !when.isSampleTimeValid || std::fabs(when.sampleTime - lastSample) < 128.0);

            if (!handledByAU) {
                const double sr = buffer.format.sampleRate;
                const uint32_t ch = (uint32_t)buffer.format.channelCount;
                const uint32_t frames = (uint32_t)buffer.frameLength;
                if (buffer.floatChannelData) {
                    phl::dsp::VoiceDSPProcessor::shared().processFloatChannels(buffer.floatChannelData, ch, frames, sr);
                } else if (buffer.int16ChannelData) {
                    phl::dsp::VoiceDSPProcessor::shared().processInt16Channels(buffer.int16ChannelData, ch, frames, sr);
                }
            }
            g_avAudioCallbacks.fetch_add(1, std::memory_order_relaxed);
        }
        origCopy(buffer, when);
    };

    orig_installTapOnBus(selfObj, _cmd, bus, bufferSize, format, wrappedBlock);
}

static void installAVAudioInputNodeSwizzle() {
    Class targetCls = [AVAudioInputNode class];
    SEL sel = @selector(installTapOnBus:bufferSize:format:block:);
    Method method = class_getInstanceMethod(targetCls, sel);
    if (!method) {
        targetCls = [AVAudioNode class];
        method = class_getInstanceMethod(targetCls, sel);
    }
    if (method) {
        orig_installTapOnBus = reinterpret_cast<decltype(orig_installTapOnBus)>(method_getImplementation(method));
        method_setImplementation(method, reinterpret_cast<IMP>(hooked_installTapOnBus));
        g_avAudioHooked.store(true, std::memory_order_relaxed);
    }
}

#pragma mark - Public Hook Diagnostics

PHLAudioHookStats PHLGetAudioHookStats(void) {
    PHLAudioHookStats stats;
    stats.avAudioInputHooked = g_avAudioHooked.load(std::memory_order_relaxed);
    stats.audioUnitRenderHooked = g_audioUnitHooked.load(std::memory_order_relaxed);
    stats.audioQueueHooked = g_audioQueueHooked.load(std::memory_order_relaxed);
    stats.avAudioTapCallbacks = g_avAudioCallbacks.load(std::memory_order_relaxed);
    stats.audioUnitRenderCallbacks = g_audioUnitCallbacks.load(std::memory_order_relaxed);
    stats.audioQueueCallbacks = g_audioQueueCallbacks.load(std::memory_order_relaxed);
    return stats;
}

#pragma mark - Bootstrap & Constructor

@interface PHLBootstrapObserver : NSObject
@end

@implementation PHLBootstrapObserver
+ (void)startServicesOnce {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[PHLSyncManager sharedManager] startAutoSync];
        [[PHLOverlayUI sharedOverlay] attachOverlayIfNeeded];
    });
}
+ (void)onAppActive:(NSNotification *)note {
    [self startServicesOnce];
    [[PHLOverlayUI sharedOverlay] attachOverlayIfNeeded];
}
@end

__attribute__((constructor))
static void PHLVoiceEngineEntry(void) {
    @autoreleasepool {
        // Resolve own image base and original AudioToolbox symbols prior to GOT rebinding
        Dl_info selfInfo;
        if (dladdr(reinterpret_cast<const void *>(&PHLVoiceEngineEntry), &selfInfo) != 0) {
            g_selfImageBase = selfInfo.dli_fbase;
        }
        orig_AudioUnitRender = reinterpret_cast<AudioUnitRenderFn>(dlsym(RTLD_DEFAULT, "AudioUnitRender"));
        orig_AudioUnitSetProperty = reinterpret_cast<AudioUnitSetPropertyFn>(dlsym(RTLD_DEFAULT, "AudioUnitSetProperty"));
        orig_AudioQueueNewInput = reinterpret_cast<AudioQueueNewInputFn>(dlsym(RTLD_DEFAULT, "AudioQueueNewInput"));
        orig_AudioQueueDispose = reinterpret_cast<AudioQueueDisposeFn>(dlsym(RTLD_DEFAULT, "AudioQueueDispose"));

        // 1. Install real-time C audio hooks (AudioUnit + AudioQueue) via Mach-O rebinding
        installFishhookRebindings({
            {"AudioUnitRender",      reinterpret_cast<void *>(hooked_AudioUnitRender),      reinterpret_cast<void **>(&orig_AudioUnitRender)},
            {"AudioUnitSetProperty", reinterpret_cast<void *>(hooked_AudioUnitSetProperty), reinterpret_cast<void **>(&orig_AudioUnitSetProperty)},
            {"AudioQueueNewInput",   reinterpret_cast<void *>(hooked_AudioQueueNewInput),   reinterpret_cast<void **>(&orig_AudioQueueNewInput)},
            {"AudioQueueDispose",    reinterpret_cast<void *>(hooked_AudioQueueDispose),    reinterpret_cast<void **>(&orig_AudioQueueDispose)},
        });
        g_audioUnitHooked.store(true, std::memory_order_relaxed);
        g_audioQueueHooked.store(true, std::memory_order_relaxed);

        // 2. Install Objective-C AVAudioInputNode tap swizzle
        installAVAudioInputNodeSwizzle();

        // 3. Defer UI overlay & network sync safely until UIKit scene is active
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:[PHLBootstrapObserver class]
               selector:@selector(onAppActive:)
                   name:UIApplicationDidFinishLaunchingNotification
                 object:nil];
        [nc addObserver:[PHLBootstrapObserver class]
               selector:@selector(onAppActive:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([UIApplication sharedApplication] != nil) {
                [PHLBootstrapObserver startServicesOnce];
            }
        });
    }
}
