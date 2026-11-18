#import "AutoTrust.h"

#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

NSString *const AutoWatchProofContext = @"WatchRelay auto watch v1";
NSString *const AutoMacProofContext = @"WatchRelay auto mac v1";
static const NSUInteger SecretBytes = 32;

NSData *AutoTrustRandom(void) {
    uint8_t random[32];
    arc4random_buf(random, sizeof(random));
    return [NSData dataWithBytes:random length:sizeof(random)];
}

NSData *AutoTrustProof(NSData *key, NSString *context, NSData *macNonce, NSData *watchNonce) {
    NSData *tag = [context dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *message = [tag mutableCopy];
    [message appendData:macNonce];
    [message appendData:watchNonce];
    uint8_t output[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, message.bytes, message.length, output);
    return [NSData dataWithBytes:output length:sizeof(output)];
}

BOOL AutoTrustMatches(NSData *first, NSData *second) {
    if (first.length != SecretBytes || second.length != SecretBytes) {
        return NO;
    }
    const volatile uint8_t *a = first.bytes;
    const volatile uint8_t *b = second.bytes;
    uint8_t difference = 0;
    for (NSUInteger index = 0; index < SecretBytes; index++) {
        difference |= a[index] ^ b[index];
    }
    return difference == 0;
}

static void ReportError(NSError **error, int code) {
    if (error) {
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
    }
}

static NSString *KeyFilename(NSString *address) {
    if (address.length != 17) {
        return nil;
    }
    NSData *input = [address.lowercaseString dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, hash);
    NSMutableString *filename = [NSMutableString stringWithCapacity:2 * sizeof(hash) + 4];
    for (NSUInteger index = 0; index < sizeof(hash); index++) {
        [filename appendFormat:@"%02x", hash[index]];
    }
    [filename appendString:@".key"];
    return filename;
}

static int OpenKeyDirectory(BOOL create, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [support URLByAppendingPathComponent:@"WatchRelay/AutoTrust" isDirectory:YES];
    if (create && ![manager createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error]) {
        return -1;
    }
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd < 0) {
        if (create || errno != ENOENT) {
            ReportError(error, errno);
        }
        return -1;
    }
    struct stat info;
    if (fstat(fd, &info) < 0) {
        ReportError(error, errno);
        close(fd);
        return -1;
    }
    if (info.st_uid != getuid() || (info.st_mode & 0077)) {
        ReportError(error, EACCES);
        close(fd);
        return -1;
    }
    return fd;
}

NSData *AutoTrustReadKey(NSString *address, NSError **error) {
    NSString *filename = KeyFilename(address);
    if (!filename) {
        ReportError(error, EINVAL);
        return nil;
    }
    int directory = OpenKeyDirectory(NO, error);
    if (directory < 0) {
        return nil;
    }
    int fd = openat(directory, filename.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int openFailure = errno;
    close(directory);
    if (fd < 0) {
        if (openFailure != ENOENT) {
            ReportError(error, openFailure);
        }
        return nil;
    }
    struct stat info;
    uint8_t bytes[32];
    size_t offset = 0;
    int failure = 0;
    if (fstat(fd, &info) < 0) {
        failure = errno;
    } else if (!S_ISREG(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 0077) || info.st_size != sizeof(bytes)) {
        failure = EACCES;
    }
    while (!failure && offset < sizeof(bytes)) {
        ssize_t count = read(fd, bytes + offset, sizeof(bytes) - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count == 0 || errno != EINTR) {
            failure = count == 0 ? EIO : errno;
        }
    }
    close(fd);
    if (failure) {
        ReportError(error, failure);
        return nil;
    }
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

BOOL AutoTrustWriteKey(NSString *address, NSData *key, NSError **error) {
    NSString *filename = KeyFilename(address);
    if (!filename || key.length != SecretBytes) {
        ReportError(error, EINVAL);
        return NO;
    }
    int directory = OpenKeyDirectory(YES, error);
    if (directory < 0) {
        return NO;
    }
    NSString *temporary = NSUUID.UUID.UUIDString;
    int fd = openat(directory, temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    int failure = fd < 0 ? errno : 0;
    const uint8_t *bytes = key.bytes;
    size_t offset = 0;
    while (!failure && offset < key.length) {
        ssize_t count = write(fd, bytes + offset, key.length - offset);
        if (count > 0) {
            offset += (size_t)count;
        } else if (count == 0 || errno != EINTR) {
            failure = count == 0 ? EIO : errno;
        }
    }
    if (fd >= 0) {
        if (!failure && fsync(fd) < 0) {
            failure = errno;
        }
        close(fd);
    }
    if (!failure && renameat(directory, temporary.fileSystemRepresentation, directory, filename.fileSystemRepresentation) < 0) {
        failure = errno;
    }
    if (failure) {
        if (fd >= 0) {
            unlinkat(directory, temporary.fileSystemRepresentation, 0);
        }
        ReportError(error, failure);
    }
    close(directory);
    return failure == 0;
}
