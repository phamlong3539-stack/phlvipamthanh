#import "PHLSyncManager.h"
#import "PHLVoiceDSP.hpp"

#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>

#if __has_include("generated_key.h")
#import "generated_key.h"
#endif

#ifndef PHL_HAS_EMBEDDED_HMAC_KEY
#define PHL_HAS_EMBEDDED_HMAC_KEY 0
#endif

NSNotificationName const PHLSyncDidUpdateStateNotification = @"PHLSyncDidUpdateStateNotification";
NSNotificationName const PHLSyncProgressNotification = @"PHLSyncProgressNotification";

static NSString *const kVoiceRepoRawBase = @"https://raw.githubusercontent.com/phamlong3539-stack/amthanh_dylib/main";
static NSString *const kDefaultMusicOwner = @"phamlong3539-stack";
static NSString *const kDefaultMusicRepo = @"phl-music-data";
static NSString *const kDefaultMusicBranch = @"main";
static NSString *const kDefaultMusicPlaylistPath = @"playlist.json";

static NSString *const kKeychainService = @"vn.phl.voiceengine.seal";
static NSString *const kKeychainSealAccount = @"cache_hmac_v1";
static NSString *const kKeychainMetaAccount = @"trusted_meta_v1";

#pragma mark - Model Implementations

@interface PHLVoiceItem ()
@property (nonatomic, copy, readwrite) NSString *voiceId;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *voiceDescription;
@property (nonatomic, copy, readwrite) NSString *category;
@property (nonatomic, assign, readwrite) BOOL locked;
@property (nonatomic, assign, readwrite) BOOL effectiveLocked;
@property (nonatomic, copy, readwrite) NSString *packPath;
@property (nonatomic, copy, readwrite) NSString *packSha256;
@end

@implementation PHLVoiceItem
@end

@interface PHLVoicePack ()
@property (nonatomic, copy, readwrite) NSString *voiceId;
@property (nonatomic, assign, readwrite) float pitchSemitones;
@property (nonatomic, assign, readwrite) float formantShift;
@property (nonatomic, assign, readwrite) float eqLowDb;
@property (nonatomic, assign, readwrite) float eqMidDb;
@property (nonatomic, assign, readwrite) float eqHighDb;
@property (nonatomic, assign, readwrite) float noiseGateDb;
@property (nonatomic, assign, readwrite) float compressorThresholdDb;
@property (nonatomic, assign, readwrite) float compressorRatio;
@property (nonatomic, assign, readwrite) float limiterCeilingDb;
@property (nonatomic, assign, readwrite) float naturalness;
@property (nonatomic, assign, readwrite) float targetF0Hz;
@property (nonatomic, assign, readwrite) BOOL adaptivePitch;
@property (nonatomic, assign, readwrite) double detectedF0Hz;
@end

@implementation PHLVoicePack
@end

@interface PHLMusicTrack ()
@property (nonatomic, copy, readwrite) NSString *trackId;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *artist;
@property (nonatomic, assign, readwrite) NSInteger durationSec;
@property (nonatomic, copy, readwrite) NSString *filePath;
@property (nonatomic, assign, readwrite) int64_t fileSizeBytes;
@property (nonatomic, copy, readwrite) NSString *sha256Hex;
@property (nonatomic, assign, readwrite) BOOL locked;
@property (nonatomic, assign, readwrite) BOOL effectiveLocked;
@property (nonatomic, assign, readwrite) float defaultVolume;
@property (nonatomic, strong, readwrite) NSURL *remoteURL;
@end

@implementation PHLMusicTrack
@end

#pragma mark - Crypto & Canonical JSON Helpers

static NSString *PHLHexStringFromBytes(const uint8_t *bytes, size_t len) {
    static const char hex[] = "0123456789abcdef";
    NSMutableString *out = [NSMutableString stringWithCapacity:len * 2];
    for (size_t i = 0; i < len; ++i) {
        char pair[3] = { hex[(bytes[i] >> 4) & 0x0F], hex[bytes[i] & 0x0F], '\0' };
        [out appendFormat:@"%s", pair];
    }
    return [out copy];
}

static NSString *PHLSHA256Hex(NSData *data) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return PHLHexStringFromBytes(digest, CC_SHA256_DIGEST_LENGTH);
}

static NSString *PHLHMACSHA256Hex(NSData *keyData, NSData *messageData) {
    uint8_t mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, keyData.bytes, keyData.length, messageData.bytes, messageData.length, mac);
    return PHLHexStringFromBytes(mac, CC_SHA256_DIGEST_LENGTH);
}

static BOOL PHLConstantTimeEqualHex(NSString *a, NSString *b) {
    if (![a isKindOfClass:[NSString class]] || ![b isKindOfClass:[NSString class]]) return NO;
    NSString *la = [a lowercaseString];
    NSString *lb = [b lowercaseString];
    if (la.length != lb.length || la.length == 0) return NO;
    const char *ca = [la UTF8String];
    const char *cb = [lb UTF8String];
    if (!ca || !cb) return NO;
    size_t n = strlen(ca);
    if (n != strlen(cb)) return NO;
    uint8_t diff = 0;
    for (size_t i = 0; i < n; ++i) {
        diff |= (uint8_t)(ca[i] ^ cb[i]);
    }
    return diff == 0;
}

static BOOL PHLIsValidHex64(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length != 64) return NO;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [[s stringByTrimmingCharactersInSet:hexSet] length] == 0;
}

static void PHLAppendEscapedJSONString(NSMutableString *out, NSString *str) {
    [out appendString:@"\""];
    NSUInteger len = str.length;
    for (NSUInteger i = 0; i < len; ++i) {
        unichar ch = [str characterAtIndex:i];
        switch (ch) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\b': [out appendString:@"\\b"];  break;
            case '\f': [out appendString:@"\\f"];  break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default:
                if (ch < 0x20) {
                    [out appendFormat:@"\\u%04x", (unsigned int)ch];
                } else {
                    [out appendFormat:@"%C", ch];
                }
                break;
        }
    }
    [out appendString:@"\""];
}

static BOOL PHLSerializeCanonicalJSON(id obj, NSMutableString *out) {
    if (obj == nil || obj == [NSNull null]) {
        [out appendString:@"null"];
        return YES;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        PHLAppendEscapedJSONString(out, (NSString *)obj);
        return YES;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)obj;
        if (CFGetTypeID((__bridge CFTypeRef)num) == CFBooleanGetTypeID()) {
            [out appendString:([num boolValue] ? @"true" : @"false")];
        } else if (CFNumberIsFloatType((__bridge CFNumberRef)num)) {
            [out appendFormat:@"%.15g", [num doubleValue]];
        } else {
            [out appendFormat:@"%lld", [num longLongValue]];
        }
        return YES;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        [out appendString:@"["];
        for (NSUInteger i = 0; i < arr.count; ++i) {
            if (i > 0) [out appendString:@","];
            if (!PHLSerializeCanonicalJSON(arr[i], out)) return NO;
        }
        [out appendString:@"]"];
        return YES;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSArray<NSString *> *sortedKeys = [[dict allKeys] sortedArrayUsingComparator:^NSComparisonResult(id k1, id k2) {
            return [[k1 description] compare:[k2 description] options:NSLiteralSearch];
        }];
        [out appendString:@"{"];
        for (NSUInteger i = 0; i < sortedKeys.count; ++i) {
            id key = sortedKeys[i];
            if (![key isKindOfClass:[NSString class]]) return NO;
            if (i > 0) [out appendString:@","];
            PHLAppendEscapedJSONString(out, (NSString *)key);
            [out appendString:@":"];
            if (!PHLSerializeCanonicalJSON(dict[key], out)) return NO;
        }
        [out appendString:@"}"];
        return YES;
    }
    return NO;
}

static NSData * _Nullable PHLCanonicalJSONData(id obj) {
    NSMutableString *str = [NSMutableString stringWithCapacity:1024];
    if (!PHLSerializeCanonicalJSON(obj, str)) return nil;
    return [str dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - Keychain Anti-Tamper Storage

static NSData * _Nullable PHLLoadOrCreateKeychainSealKey(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainSealAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL) {
        NSData *keyData = (__bridge_transfer NSData *)result;
        if (keyData.length == 32) {
            return keyData;
        }
    }

    uint8_t randomKey[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(randomKey), randomKey) != errSecSuccess) {
        return nil;
    }
    NSData *newKey = [NSData dataWithBytes:randomKey length:sizeof(randomKey)];
    volatile uint8_t *vp = randomKey;
    for (size_t i = 0; i < sizeof(randomKey); ++i) vp[i] = 0;

    NSDictionary *deleteQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainSealAccount
    };
    SecItemDelete((__bridge CFDictionaryRef)deleteQuery);

    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainSealAccount,
        (__bridge id)kSecValueData: newKey,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (addStatus == errSecSuccess) {
        return newKey;
    }
    return nil;
}

static NSDictionary * _Nullable PHLLoadTrustedMetaFromKeychain(void) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainMetaAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) == errSecSuccess && result != NULL) {
        NSData *data = (__bridge_transfer NSData *)result;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            return (NSDictionary *)obj;
        }
    }
    return nil;
}

static void PHLSaveTrustedMetaToKeychain(NSInteger version, NSString *keyFingerprint) {
    NSDictionary *meta = @{
        @"last_version": @(version),
        @"key_fp": keyFingerprint ?: @""
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    if (!data) return;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainMetaAccount
    };
    SecItemDelete((__bridge CFDictionaryRef)query);

    NSMutableDictionary *add = [query mutableCopy];
    add[(__bridge id)kSecValueData] = data;
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

#pragma mark - PHLSyncManager

@interface PHLSyncManager ()
@property (atomic, assign, readwrite) BOOL globalLock;
@property (atomic, assign, readwrite) BOOL musicGlobalLock;
@property (atomic, assign, readwrite) BOOL maintenanceEnabled;
@property (atomic, copy, readwrite) NSString *maintenanceMessage;
@property (atomic, assign, readwrite) NSInteger manifestVersion;
@property (atomic, copy, readwrite) NSString *manifestUpdatedAt;
@property (atomic, assign, readwrite) NSInteger playlistVersion;
@property (atomic, assign, readwrite) BOOL tamperDetected;
@property (atomic, assign, readwrite) BOOL usingOfflineCache;
@property (atomic, assign, readwrite) BOOL signatureStrictlyVerified;
@property (atomic, copy, readwrite) NSString *statusSummaryText;
@property (atomic, copy, readwrite) NSString *lastSyncTimeFormatted;

@property (atomic, copy, readwrite) NSArray<PHLVoiceItem *> *voices;
@property (atomic, copy, readwrite) NSArray<PHLMusicTrack *> *tracks;
@property (atomic, copy, readwrite, nullable) NSString *selectedVoiceId;
@property (atomic, strong, readwrite, nullable) PHLVoicePack *activeVoicePack;
@end

@implementation PHLSyncManager {
    dispatch_queue_t _syncQueue;
    dispatch_source_t _pollTimer;
    NSURLSession *_session;
    NSData *_deviceSealKey;
    NSInteger _pollIntervalSec;
    BOOL _isSyncing;
    NSMutableDictionary<NSString *, PHLVoicePack *> *_packMemoryCache;
    NSArray<NSString *> *_remoteLockedTrackIds;
    NSString *_musicOwner;
    NSString *_musicRepo;
    NSString *_musicBranch;
    NSString *_musicPlaylistPath;
}

+ (instancetype)sharedManager {
    static PHLSyncManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[PHLSyncManager alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _syncQueue = dispatch_queue_create("vn.phl.voiceengine.sync", DISPATCH_QUEUE_SERIAL);
        _packMemoryCache = [NSMutableDictionary dictionary];
        _voices = @[];
        _tracks = @[];
        _remoteLockedTrackIds = @[];
        _globalLock = YES; // Fail-closed until verified manifest loads
        _musicGlobalLock = YES;
        _maintenanceEnabled = NO;
        _maintenanceMessage = @"";
        _manifestUpdatedAt = @"--";
        _lastSyncTimeFormatted = @"Chưa đồng bộ";
        _statusSummaryText = @"Đang khởi tạo bảo mật & dữ liệu...";
        _pollIntervalSec = 15;
        _musicOwner = kDefaultMusicOwner;
        _musicRepo = kDefaultMusicRepo;
        _musicBranch = kDefaultMusicBranch;
        _musicPlaylistPath = kDefaultMusicPlaylistPath;
        _voiceChangeEnabled = NO;
        _signatureStrictlyVerified = (PHL_HAS_EMBEDDED_HMAC_KEY == 1);

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.timeoutIntervalForRequest = 10.0;
        cfg.timeoutIntervalForResource = 18.0;
        _session = [NSURLSession sessionWithConfiguration:cfg];

        _deviceSealKey = PHLLoadOrCreateKeychainSealKey();
        [self loadSavedUserSelection];
        [self loadSealedCachesOnStartup];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleAppDidBecomeActive)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopAutoSync];
}

#pragma mark - Paths & Sealed Cache

- (NSString *)cacheDirectoryPath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    NSString *dir = [base stringByAppendingPathComponent:@"PHLVoiceEngine"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)packsCacheDirectoryPath {
    NSString *dir = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"packs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (BOOL)writeSealedJSON:(NSDictionary *)jsonObj toPath:(NSString *)filePath monotoneVersion:(NSInteger)version {
    if (!_deviceSealKey) return NO;
    NSData *payloadData = PHLCanonicalJSONData(jsonObj);
    if (!payloadData) return NO;

    NSString *msgToSign = [NSString stringWithFormat:@"%ld|%@", (long)version, [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding]];
    NSString *sealHmac = PHLHMACSHA256Hex(_deviceSealKey, [msgToSign dataUsingEncoding:NSUTF8StringEncoding]);

    NSDictionary *envelope = @{
        @"envelope_version": @1,
        @"monotone_version": @(version),
        @"data": jsonObj,
        @"device_seal_hmac": sealHmac
    };
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    if (!encoded) return NO;
    return [encoded writeToFile:filePath options:NSDataWritingAtomic error:nil];
}

- (nullable NSDictionary *)readSealedJSONAtPath:(NSString *)filePath outTampered:(BOOL *)outTampered {
    if (outTampered) *outTampered = NO;
    NSData *raw = [NSData dataWithContentsOfFile:filePath];
    if (!raw) return nil;
    if (!_deviceSealKey) {
        if (outTampered) *outTampered = YES;
        return nil;
    }

    id envelopeObj = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    if (![envelopeObj isKindOfClass:[NSDictionary class]]) {
        if (outTampered) *outTampered = YES;
        return nil;
    }
    NSDictionary *envelope = (NSDictionary *)envelopeObj;
    NSDictionary *dataObj = envelope[@"data"];
    NSNumber *verNum = envelope[@"monotone_version"];
    NSString *sealHex = envelope[@"device_seal_hmac"];
    if (![dataObj isKindOfClass:[NSDictionary class]] || ![verNum isKindOfClass:[NSNumber class]] || !PHLIsValidHex64(sealHex)) {
        if (outTampered) *outTampered = YES;
        return nil;
    }

    NSData *canonicalData = PHLCanonicalJSONData(dataObj);
    if (!canonicalData) {
        if (outTampered) *outTampered = YES;
        return nil;
    }
    NSString *canonicalStr = [[NSString alloc] initWithData:canonicalData encoding:NSUTF8StringEncoding];
    NSString *msg = [NSString stringWithFormat:@"%ld|%@", (long)[verNum integerValue], canonicalStr];
    NSString *expectedHmac = PHLHMACSHA256Hex(_deviceSealKey, [msg dataUsingEncoding:NSUTF8StringEncoding]);

    if (!PHLConstantTimeEqualHex(expectedHmac, sealHex)) {
        if (outTampered) *outTampered = YES;
        return nil;
    }
    return dataObj;
}

#pragma mark - Manifest Signature & Anti-Tamper Verification

- (BOOL)verifyManifestDictionary:(NSDictionary *)manifest
                        isFromCache:(BOOL)isFromCache
                       errorMessage:(NSString * __autoreleasing *)errorMsg {
    NSDictionary *payload = manifest[@"payload"];
    NSDictionary *integrity = manifest[@"integrity"];
    if (![payload isKindOfClass:[NSDictionary class]] || ![integrity isKindOfClass:[NSDictionary class]]) {
        if (errorMsg) *errorMsg = @"Cấu trúc manifest không hợp lệ.";
        return NO;
    }

    NSString *algo = integrity[@"algorithm"];
    NSString *claimedSha = integrity[@"payload_sha256"];
    NSString *claimedHmac = integrity[@"hmac_sha256"];
    NSString *keyFp = integrity[@"key_fingerprint"];
    if (![algo isEqualToString:@"HMAC-SHA256"] || !PHLIsValidHex64(claimedSha) || !PHLIsValidHex64(claimedHmac) || ![keyFp isKindOfClass:[NSString class]] || keyFp.length < 8) {
        if (errorMsg) *errorMsg = @"Thiếu chữ ký HMAC-SHA256 hoặc định dạng chữ ký sai.";
        return NO;
    }

    NSData *canonical = PHLCanonicalJSONData(payload);
    if (!canonical) {
        if (errorMsg) *errorMsg = @"Không thể chuẩn hóa canonical payload.";
        return NO;
    }

    NSString *computedSha = PHLSHA256Hex(canonical);
    if (!PHLConstantTimeEqualHex(computedSha, claimedSha)) {
        if (errorMsg) *errorMsg = @"Dữ liệu manifest bị sai lệch checksum SHA-256.";
        return NO;
    }

#if PHL_HAS_EMBEDDED_HMAC_KEY
    uint8_t keyBuf[256];
    size_t keyLen = 0;
    PHLReconstructHMACKey(keyBuf, sizeof(keyBuf), &keyLen);
    if (keyLen == 0 || keyLen > sizeof(keyBuf)) {
        volatile uint8_t *vp = keyBuf;
        for (size_t i = 0; i < sizeof(keyBuf); ++i) vp[i] = 0;
        if (errorMsg) *errorMsg = @"Lỗi khởi tạo khóa xác thực.";
        return NO;
    }
    NSData *secretData = [NSData dataWithBytesNoCopy:keyBuf length:keyLen freeWhenDone:NO];
    NSString *computedHmac = PHLHMACSHA256Hex(secretData, canonical);
    volatile uint8_t *vp = keyBuf;
    for (size_t i = 0; i < sizeof(keyBuf); ++i) vp[i] = 0;

    if (!PHLConstantTimeEqualHex(computedHmac, claimedHmac)) {
        if (errorMsg) *errorMsg = @"Chữ ký HMAC-SHA256 không khớp với khóa máy chủ!";
        return NO;
    }
#endif

    NSNumber *verNum = payload[@"version"];
    if (![verNum isKindOfClass:[NSNumber class]] || [verNum integerValue] < 1) {
        if (errorMsg) *errorMsg = @"Phiên bản manifest không hợp lệ.";
        return NO;
    }
    NSInteger incomingVersion = [verNum integerValue];

    NSDictionary *trustedMeta = PHLLoadTrustedMetaFromKeychain();
    if (trustedMeta) {
        NSInteger lastTrustedVersion = [trustedMeta[@"last_version"] integerValue];
        NSString *pinnedFp = trustedMeta[@"key_fp"];
        if (incomingVersion < lastTrustedVersion) {
            if (errorMsg) *errorMsg = @"Phát hiện hạ cấp (rollback) phiên bản manifest trái phép.";
            return NO;
        }
        if (isFromCache && pinnedFp.length > 0 && ![pinnedFp isEqualToString:keyFp]) {
            if (errorMsg) *errorMsg = @"Fingerprint chữ ký cache không khớp Keychain.";
            return NO;
        }
    }

    return YES;
}

#pragma mark - Startup Cache & Preferences

- (void)loadSavedUserSelection {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    _selectedVoiceId = [ud stringForKey:@"PHL_SelectedVoiceId"];
    _voiceChangeEnabled = [ud boolForKey:@"PHL_VoiceChangeEnabled"];
}

- (void)loadSealedCachesOnStartup {
    NSString *manifestCachePath = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"manifest_sealed.json"];
    NSString *playlistCachePath = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"playlist_sealed.json"];

    BOOL manifestTampered = NO;
    NSDictionary *cachedManifest = [self readSealedJSONAtPath:manifestCachePath outTampered:&manifestTampered];
    if (manifestTampered) {
        [[NSFileManager defaultManager] removeItemAtPath:manifestCachePath error:nil];
        [self enterTamperSafeLockWithReason:@"Phát hiện sửa đổi cache manifest trái phép — Đã từ chối & giữ khóa an toàn"];
        return;
    }

    if (cachedManifest) {
        NSString *err = nil;
        if ([self verifyManifestDictionary:cachedManifest isFromCache:YES errorMessage:&err]) {
            [self applyManifestDictionary:cachedManifest fromCache:YES];
            if (self.selectedVoiceId.length > 0) {
                PHLVoiceItem *selItem = [self voiceItemForId:self.selectedVoiceId];
                if (selItem && !selItem.effectiveLocked) {
                    NSString *packCacheFile = [[self packsCacheDirectoryPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", selItem.voiceId]];
                    NSData *cachedBytes = [NSData dataWithContentsOfFile:packCacheFile];
                    PHLVoicePack *cachedPack = [self parsePackBytes:cachedBytes expectedSha:selItem.packSha256 voiceId:selItem.voiceId];
                    if (cachedPack) {
                        NSString *memKey = [NSString stringWithFormat:@"%@:%@", selItem.voiceId, selItem.packSha256];
                        _packMemoryCache[memKey] = cachedPack;
                        self.activeVoicePack = cachedPack;
                    }
                }
            }
        } else {
            [[NSFileManager defaultManager] removeItemAtPath:manifestCachePath error:nil];
            [self enterTamperSafeLockWithReason:(err ?: @"Cache manifest không hợp lệ — Giữ khóa an toàn")];
            return;
        }
    }

    BOOL playlistTampered = NO;
    NSDictionary *cachedPlaylist = [self readSealedJSONAtPath:playlistCachePath outTampered:&playlistTampered];
    if (playlistTampered) {
        [[NSFileManager defaultManager] removeItemAtPath:playlistCachePath error:nil];
        self.tamperDetected = YES;
        self.musicGlobalLock = YES;
        self.tracks = @[];
    } else if (cachedPlaylist) {
        [self applyPlaylistDictionary:cachedPlaylist];
    }

    [self applyCurrentVoiceToDSP];
}

- (void)enterTamperSafeLockWithReason:(NSString *)reason {
    self.tamperDetected = YES;
    self.globalLock = YES;
    self.musicGlobalLock = YES;
    self.voices = @[];
    self.tracks = @[];
    self.activeVoicePack = nil;
    self.statusSummaryText = reason;
    phl::dsp::VoiceDSPProcessor::shared().setLockedBypass(true);
    [self notifyStateChanged];
}

#pragma mark - Progress & Notifications

- (void)postProgress:(double)progress step:(NSString *)step active:(BOOL)active {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PHLSyncProgressNotification
                                                            object:self
                                                          userInfo:@{
                                                              @"progress": @(progress),
                                                              @"step": step ?: @"",
                                                              @"active": @(active)
                                                          }];
    });
}

- (void)notifyStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:PHLSyncDidUpdateStateNotification
                                                            object:self];
    });
}

#pragma mark - Auto Sync & Manual Sync

- (void)handleAppDidBecomeActive {
    [self syncNowWithCompletion:nil];
}

- (void)startAutoSync {
    dispatch_async(_syncQueue, ^{
        [self reschedulePollTimerLocked];
    });
    [self syncNowWithCompletion:nil];
}

- (void)stopAutoSync {
    dispatch_async(_syncQueue, ^{
        if (self->_pollTimer) {
            dispatch_source_cancel(self->_pollTimer);
            self->_pollTimer = nil;
        }
    });
}

- (void)reschedulePollTimerLocked {
    if (_pollTimer) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
    NSInteger interval = MAX(10, MIN(120, _pollIntervalSec));
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _syncQueue);
    uint64_t ns = (uint64_t)interval * NSEC_PER_SEC;
    dispatch_source_set_timer(_pollTimer, dispatch_time(DISPATCH_TIME_NOW, ns), ns, 1 * NSEC_PER_SEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        [weakSelf syncInternalWithSilentProgress:YES completion:nil];
    });
    dispatch_resume(_pollTimer);
}

- (void)syncNowWithCompletion:(void (^ _Nullable)(BOOL, NSString *))completion {
    dispatch_async(_syncQueue, ^{
        [self syncInternalWithSilentProgress:NO completion:completion];
    });
}

- (NSURL *)cacheBustedURL:(NSString *)basePath {
    uint64_t ms = (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
    NSString *sep = [basePath containsString:@"?"] ? @"&" : @"?";
    NSString *full = [NSString stringWithFormat:@"%@%@cb=%llu", basePath, sep, ms];
    return [NSURL URLWithString:full];
}

- (NSData * _Nullable)blockingFetchURL:(NSURL *)url error:(NSError * __autoreleasing *)outError {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:10.0];
    [req setValue:@"no-cache, no-store, max-age=0" forHTTPHeaderField:@"Cache-Control"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    [req setValue:@"PHLVoiceEngine/1.0" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *resultData = nil;
    __block NSError *resultErr = nil;
    __block NSInteger statusCode = 0;

    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = [(NSHTTPURLResponse *)resp statusCode];
        }
        resultData = data;
        resultErr = err;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));

    if (resultErr) {
        if (outError) *outError = resultErr;
        return nil;
    }
    if (statusCode < 200 || statusCode >= 300 || !resultData) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"PHLSync"
                                            code:statusCode ?: -1
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)statusCode]}];
        }
        return nil;
    }
    return resultData;
}

- (void)syncInternalWithSilentProgress:(BOOL)silent
                            completion:(void (^ _Nullable)(BOOL, NSString *))completion {
    if (_isSyncing) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, @"Đang đồng bộ...");
            });
        }
        return;
    }
    _isSyncing = YES;

    if (!silent) [self postProgress:0.12 step:@"Đang kết nối GitHub..." active:YES];

    NSString *manifestUrlStr = [NSString stringWithFormat:@"%@/dist/manifest.json", kVoiceRepoRawBase];
    NSError *netErr = nil;
    NSData *manifestRaw = [self blockingFetchURL:[self cacheBustedURL:manifestUrlStr] error:&netErr];

    if (!manifestRaw) {
        // Fallback smoothly to previously verified cache if not tampered
        _isSyncing = NO;
        BOOL hasValidCache = (!self.tamperDetected && self.manifestVersion > 0);
        self.usingOfflineCache = hasValidCache;
        NSString *msg = hasValidCache
            ? @"Mạng chậm/ngoại tuyến — Đang dùng cấu hình cache đã xác thực"
            : @"Không thể kết nối GitHub (Giữ khóa an toàn)";
        self.statusSummaryText = msg;
        if (!silent) [self postProgress:1.0 step:msg active:NO];
        [self notifyStateChanged];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(hasValidCache, msg); });
        }
        return;
    }

    if (!silent) [self postProgress:0.38 step:@"Đang đồng bộ dữ liệu giọng & nhạc..." active:YES];

    id manifestObj = [NSJSONSerialization JSONObjectWithData:manifestRaw options:0 error:nil];
    if (![manifestObj isKindOfClass:[NSDictionary class]]) {
        _isSyncing = NO;
        NSString *msg = @"Manifest từ GitHub sai định dạng JSON";
        self.statusSummaryText = msg;
        if (!silent) [self postProgress:1.0 step:msg active:NO];
        [self notifyStateChanged];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, msg); });
        return;
    }

    if (!silent) [self postProgress:0.58 step:@"Đang xác thực chữ ký bảo mật..." active:YES];

    NSString *verifyErr = nil;
    if (![self verifyManifestDictionary:(NSDictionary *)manifestObj isFromCache:NO errorMessage:&verifyErr]) {
        _isSyncing = NO;
        [self enterTamperSafeLockWithReason:(verifyErr ?: @"Chữ ký manifest không hợp lệ — Từ chối cập nhật")];
        if (!silent) [self postProgress:1.0 step:self.statusSummaryText active:NO];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, self.statusSummaryText); });
        return;
    }

    // Valid manifest verified!
    NSDictionary *manifestDict = (NSDictionary *)manifestObj;
    self.tamperDetected = NO;
    self.usingOfflineCache = NO;
    [self applyManifestDictionary:manifestDict fromCache:NO];

    NSInteger ver = [manifestDict[@"payload"][@"version"] integerValue];
    NSString *keyFp = manifestDict[@"integrity"][@"key_fingerprint"];
    PHLSaveTrustedMetaToKeychain(ver, keyFp);

    NSString *manifestCachePath = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"manifest_sealed.json"];
    [self writeSealedJSON:manifestDict toPath:manifestCachePath monotoneVersion:ver];

    // Fetch playlist from phl-music-data
    NSString *playlistUrlStr = [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@/%@",
                                _musicOwner, _musicRepo, _musicBranch, _musicPlaylistPath];
    NSData *playlistRaw = [self blockingFetchURL:[self cacheBustedURL:playlistUrlStr] error:nil];
    if (playlistRaw) {
        id playlistObj = [NSJSONSerialization JSONObjectWithData:playlistRaw options:0 error:nil];
        if ([playlistObj isKindOfClass:[NSDictionary class]]) {
            [self applyPlaylistDictionary:(NSDictionary *)playlistObj];
            NSString *playlistCachePath = [[self cacheDirectoryPath] stringByAppendingPathComponent:@"playlist_sealed.json"];
            [self writeSealedJSON:(NSDictionary *)playlistObj toPath:playlistCachePath monotoneVersion:self.playlistVersion];
        }
    }

    if (!silent) [self postProgress:0.84 step:@"Đang tối ưu bộ lọc âm thanh..." active:YES];

    // Refresh active voice pack if selected & unlocked
    if (self.selectedVoiceId.length > 0) {
        PHLVoiceItem *selItem = [self voiceItemForId:self.selectedVoiceId];
        if (selItem && !selItem.effectiveLocked) {
            PHLVoicePack *pack = [self loadOrFetchPackForVoice:selItem error:nil];
            if (pack) {
                self.activeVoicePack = pack;
            }
        }
    }
    [self applyCurrentVoiceToDSP];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss dd/MM";
    self.lastSyncTimeFormatted = [df stringFromDate:[NSDate date]];
    self.statusSummaryText = [NSString stringWithFormat:@"Đã đồng bộ v%ld (%lu giọng, %lu bài nhạc)",
                              (long)self.manifestVersion,
                              (unsigned long)self.voices.count,
                              (unsigned long)self.tracks.count];

    [self reschedulePollTimerLocked];
    _isSyncing = NO;

    if (!silent) [self postProgress:1.0 step:@"Sẵn sàng sử dụng" active:NO];
    [self notifyStateChanged];

    if (completion) {
        NSString *doneMsg = self.statusSummaryText;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, doneMsg);
        });
    }
}

#pragma mark - Apply Parsed Manifest & Playlist

- (void)applyManifestDictionary:(NSDictionary *)manifest fromCache:(BOOL)fromCache {
    NSDictionary *payload = manifest[@"payload"];
    self.manifestVersion = [payload[@"version"] integerValue];
    self.manifestUpdatedAt = [payload[@"updated_at"] description] ?: @"--";
    self.globalLock = [payload[@"global_lock"] boolValue];

    NSDictionary *maint = [payload[@"maintenance"] isKindOfClass:[NSDictionary class]] ? payload[@"maintenance"] : @{};
    self.maintenanceEnabled = [maint[@"enabled"] boolValue];
    self.maintenanceMessage = [maint[@"message"] isKindOfClass:[NSString class]] ? maint[@"message"] : @"Hệ thống đang bảo trì.";

    NSInteger poll = [payload[@"poll_interval_seconds"] integerValue];
    if (poll >= 5 && poll <= 300) {
        _pollIntervalSec = poll;
    }

    NSDictionary *musicCfg = [payload[@"music"] isKindOfClass:[NSDictionary class]] ? payload[@"music"] : @{};
    if ([musicCfg[@"repo_owner"] isKindOfClass:[NSString class]]) _musicOwner = musicCfg[@"repo_owner"];
    if ([musicCfg[@"repo_name"] isKindOfClass:[NSString class]]) _musicRepo = musicCfg[@"repo_name"];
    if ([musicCfg[@"branch"] isKindOfClass:[NSString class]]) _musicBranch = musicCfg[@"branch"];
    if ([musicCfg[@"playlist_path"] isKindOfClass:[NSString class]]) _musicPlaylistPath = musicCfg[@"playlist_path"];
    self.musicGlobalLock = [musicCfg[@"global_lock"] boolValue];
    _remoteLockedTrackIds = [musicCfg[@"locked_track_ids"] isKindOfClass:[NSArray class]] ? musicCfg[@"locked_track_ids"] : @[];

    NSArray *rawVoices = [payload[@"voices"] isKindOfClass:[NSArray class]] ? payload[@"voices"] : @[];
    NSMutableArray<PHLVoiceItem *> *parsedVoices = [NSMutableArray arrayWithCapacity:rawVoices.count];

    for (id obj in rawVoices) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)obj;
        NSString *vid = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
        NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
        NSString *packPath = [d[@"pack_path"] isKindOfClass:[NSString class]] ? d[@"pack_path"] : nil;
        NSString *packSha = [d[@"pack_sha256"] isKindOfClass:[NSString class]] ? d[@"pack_sha256"] : nil;
        if (!vid.length || !name.length || !packPath.length || !PHLIsValidHex64(packSha)) continue;

        PHLVoiceItem *item = [[PHLVoiceItem alloc] init];
        item.voiceId = vid;
        item.name = name;
        item.voiceDescription = [d[@"description"] isKindOfClass:[NSString class]] ? d[@"description"] : @"";
        item.category = [d[@"category"] isKindOfClass:[NSString class]] ? d[@"category"] : @"Chung";
        item.locked = [d[@"locked"] boolValue];
        item.effectiveLocked = (item.locked || self.globalLock || self.maintenanceEnabled || self.tamperDetected);
        item.packPath = packPath;
        item.packSha256 = packSha;
        [parsedVoices addObject:item];
    }
    self.voices = [parsedVoices copy];

    if (self.selectedVoiceId.length == 0 && self.voices.count > 0) {
        for (PHLVoiceItem *v in self.voices) {
            if (!v.effectiveLocked) {
                self.selectedVoiceId = v.voiceId;
                break;
            }
        }
    }
    self.usingOfflineCache = fromCache;
}

- (void)applyPlaylistDictionary:(NSDictionary *)playlist {
    self.playlistVersion = [playlist[@"version"] integerValue];
    BOOL playlistGlobalLock = [playlist[@"global_lock"] boolValue];
    BOOL effectiveMusicLock = (playlistGlobalLock || self.musicGlobalLock || self.globalLock || self.maintenanceEnabled || self.tamperDetected);

    NSArray *rawTracks = [playlist[@"tracks"] isKindOfClass:[NSArray class]] ? playlist[@"tracks"] : @[];
    NSMutableArray<PHLMusicTrack *> *parsed = [NSMutableArray arrayWithCapacity:rawTracks.count];
    NSSet<NSString *> *remoteLockedSet = [NSSet setWithArray:_remoteLockedTrackIds ?: @[]];

    for (id obj in rawTracks) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)obj;
        NSString *tid = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : nil;
        NSString *fp = [d[@"file_path"] isKindOfClass:[NSString class]] ? d[@"file_path"] : nil;
        if (!tid.length || !fp.length) continue;

        NSString *encodedFp = [fp stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        if (!encodedFp.length) continue;
        NSString *urlString = [NSString stringWithFormat:@"https://raw.githubusercontent.com/%@/%@/%@/%@",
                               _musicOwner, _musicRepo, _musicBranch, encodedFp];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) continue;

        PHLMusicTrack *t = [[PHLMusicTrack alloc] init];
        t.trackId = tid;
        t.title = [d[@"title"] isKindOfClass:[NSString class]] ? d[@"title"] : tid;
        t.artist = [d[@"artist"] isKindOfClass:[NSString class]] ? d[@"artist"] : @"PHL Music";
        t.durationSec = [d[@"duration_sec"] integerValue];
        t.filePath = fp;
        t.fileSizeBytes = [d[@"file_size_bytes"] longLongValue];
        t.sha256Hex = [d[@"sha256"] isKindOfClass:[NSString class]] ? d[@"sha256"] : @"";
        t.locked = [d[@"locked"] boolValue];
        t.effectiveLocked = (t.locked || effectiveMusicLock || [remoteLockedSet containsObject:tid]);
        float vol = [d[@"default_volume"] isKindOfClass:[NSNumber class]] ? [d[@"default_volume"] floatValue] : 0.75f;
        t.defaultVolume = MAX(0.0f, MIN(1.0f, vol));
        t.remoteURL = url;
        [parsed addObject:t];
    }
    self.tracks = [parsed copy];
}

#pragma mark - Pack Loading & DSP Update

- (nullable PHLVoicePack *)parsePackBytes:(NSData *)rawBytes
                             expectedSha:(NSString *)expectedSha
                                 voiceId:(NSString *)voiceId {
    if (!rawBytes || !PHLConstantTimeEqualHex(PHLSHA256Hex(rawBytes), expectedSha)) {
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:rawBytes options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;
    NSDictionary *dsp = [dict[@"dsp"] isKindOfClass:[NSDictionary class]] ? dict[@"dsp"] : nil;
    if (!dsp) return nil;

    PHLVoicePack *pack = [[PHLVoicePack alloc] init];
    pack.voiceId = voiceId;
    pack.pitchSemitones = [dsp[@"pitch_semitones"] floatValue];
    pack.formantShift = [dsp[@"formant_shift"] floatValue] ?: 1.0f;
    pack.eqLowDb = [dsp[@"eq_low_db"] floatValue];
    pack.eqMidDb = [dsp[@"eq_mid_db"] floatValue];
    pack.eqHighDb = [dsp[@"eq_high_db"] floatValue];
    pack.noiseGateDb = [dsp[@"noise_gate_db"] isKindOfClass:[NSNumber class]] ? [dsp[@"noise_gate_db"] floatValue] : -46.0f;
    pack.compressorThresholdDb = [dsp[@"compressor_threshold_db"] isKindOfClass:[NSNumber class]] ? [dsp[@"compressor_threshold_db"] floatValue] : -18.0f;
    pack.compressorRatio = [dsp[@"compressor_ratio"] isKindOfClass:[NSNumber class]] ? [dsp[@"compressor_ratio"] floatValue] : 2.5f;
    pack.limiterCeilingDb = [dsp[@"limiter_ceiling_db"] isKindOfClass:[NSNumber class]] ? [dsp[@"limiter_ceiling_db"] floatValue] : -0.8f;
    pack.naturalness = [dsp[@"naturalness"] isKindOfClass:[NSNumber class]] ? [dsp[@"naturalness"] floatValue] : 0.90f;

    NSDictionary *analysis = [dict[@"analysis"] isKindOfClass:[NSDictionary class]] ? dict[@"analysis"] : @{};
    pack.detectedF0Hz = [analysis[@"detected_f0_hz"] doubleValue];
    float targetF0 = [dsp[@"target_f0_hz"] isKindOfClass:[NSNumber class]]
        ? [dsp[@"target_f0_hz"] floatValue]
        : (float)pack.detectedF0Hz;
    pack.targetF0Hz = targetF0;
    pack.adaptivePitch = [dsp[@"adaptive_pitch"] isKindOfClass:[NSNumber class]]
        ? [dsp[@"adaptive_pitch"] boolValue]
        : (targetF0 >= 65.0f && targetF0 <= 420.0f);
    return pack;
}

- (nullable PHLVoicePack *)loadOrFetchPackForVoice:(PHLVoiceItem *)item error:(NSString * __autoreleasing *)errMsg {
    NSString *memKey = [NSString stringWithFormat:@"%@:%@", item.voiceId, item.packSha256];
    PHLVoicePack *memPack = _packMemoryCache[memKey];
    if (memPack) {
        return memPack;
    }

    NSString *packCacheFile = [[self packsCacheDirectoryPath] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", item.voiceId]];
    NSData *cachedBytes = [NSData dataWithContentsOfFile:packCacheFile];
    if (cachedBytes) {
        PHLVoicePack *cachedPack = [self parsePackBytes:cachedBytes expectedSha:item.packSha256 voiceId:item.voiceId];
        if (cachedPack) {
            _packMemoryCache[memKey] = cachedPack;
            return cachedPack;
        }
        [[NSFileManager defaultManager] removeItemAtPath:packCacheFile error:nil];
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/%@", kVoiceRepoRawBase, item.packPath];
    NSError *netErr = nil;
    NSData *remoteBytes = [self blockingFetchURL:[self cacheBustedURL:urlStr] error:&netErr];
    if (!remoteBytes) {
        if (errMsg) *errMsg = @"Không tải được gói thông số giọng từ GitHub.";
        return nil;
    }

    PHLVoicePack *remotePack = [self parsePackBytes:remoteBytes expectedSha:item.packSha256 voiceId:item.voiceId];
    if (!remotePack) {
        if (errMsg) *errMsg = @"Gói thông số giọng không khớp mã kiểm tra SHA-256.";
        return nil;
    }

    [remoteBytes writeToFile:packCacheFile options:NSDataWritingAtomic error:nil];
    _packMemoryCache[memKey] = remotePack;
    return remotePack;
}

- (void)selectVoiceWithId:(NSString *)voiceId
               completion:(void (^ _Nullable)(BOOL, PHLVoicePack * _Nullable, NSString *))completion {
    dispatch_async(_syncQueue, ^{
        PHLVoiceItem *item = [self voiceItemForId:voiceId];
        if (!item) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil, @"Không tìm thấy giọng nói."); });
            return;
        }
        if (item.effectiveLocked) {
            self.selectedVoiceId = item.voiceId;
            [self applyCurrentVoiceToDSP];
            [self notifyStateChanged];
            NSString *lockMsg = self.maintenanceEnabled ? self.maintenanceMessage : @"Giọng này hiện đang bị Admin khóa — Giữ nguyên giọng gốc.";
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil, lockMsg); });
            return;
        }

        [self postProgress:0.25 step:[NSString stringWithFormat:@"Đang tải cấu hình giọng \"%@\"...", item.name] active:YES];
        NSString *err = nil;
        PHLVoicePack *pack = [self loadOrFetchPackForVoice:item error:&err];
        if (!pack) {
            [self postProgress:1.0 step:(err ?: @"Lỗi nạp cấu hình giọng") active:NO];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil, err ?: @"Lỗi tải gói giọng."); });
            return;
        }

        [self postProgress:0.78 step:@"Đang tối ưu bộ lọc âm thanh..." active:YES];
        self.selectedVoiceId = item.voiceId;
        self.activeVoicePack = pack;
        [[NSUserDefaults standardUserDefaults] setObject:item.voiceId forKey:@"PHL_SelectedVoiceId"];
        [self applyCurrentVoiceToDSP];

        [self postProgress:1.0 step:@"Sẵn sàng sử dụng" active:NO];
        [self notifyStateChanged];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, pack, [NSString stringWithFormat:@"Đã kích hoạt giọng %@", item.name]);
            });
        }
    });
}

- (void)setVoiceChangeEnabled:(BOOL)enabled {
    _voiceChangeEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"PHL_VoiceChangeEnabled"];
    [self applyCurrentVoiceToDSP];
    [self notifyStateChanged];
}

- (BOOL)isCurrentVoiceEffectiveLocked {
    if (self.tamperDetected || self.globalLock || self.maintenanceEnabled) return YES;
    PHLVoiceItem *item = [self voiceItemForId:self.selectedVoiceId];
    if (!item) return YES;
    return item.effectiveLocked;
}

- (void)applyCurrentVoiceToDSP {
    BOOL locked = [self isCurrentVoiceEffectiveLocked];
    PHLVoicePack *pack = self.activeVoicePack;

    phl::dsp::DSPParams params;
    if (pack && !locked) {
        params.pitch_semitones = pack.pitchSemitones;
        params.formant_shift = pack.formantShift;
        params.eq_low_db = pack.eqLowDb;
        params.eq_mid_db = pack.eqMidDb;
        params.eq_high_db = pack.eqHighDb;
        params.noise_gate_db = pack.noiseGateDb;
        params.compressor_threshold_db = pack.compressorThresholdDb;
        params.compressor_ratio = pack.compressorRatio;
        params.limiter_ceiling_db = pack.limiterCeilingDb;
        params.naturalness = pack.naturalness;
        params.target_f0_hz = pack.targetF0Hz;
        params.adaptive_pitch = pack.adaptivePitch ? true : false;
    }
    params.enabled = self.voiceChangeEnabled;
    params.locked_bypass = locked || (pack == nil);

    phl::dsp::VoiceDSPProcessor::shared().updateParams(params);
}

- (nullable PHLVoiceItem *)voiceItemForId:(NSString *)voiceId {
    if (!voiceId.length) return nil;
    for (PHLVoiceItem *v in self.voices) {
        if ([v.voiceId isEqualToString:voiceId]) return v;
    }
    return nil;
}

- (nullable PHLMusicTrack *)trackForId:(NSString *)trackId {
    if (!trackId.length) return nil;
    for (PHLMusicTrack *t in self.tracks) {
        if ([t.trackId isEqualToString:trackId]) return t;
    }
    return nil;
}

@end
