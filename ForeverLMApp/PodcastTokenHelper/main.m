// PodcastTokenHelper
//
// Prints a signed Apple Podcasts API bearer token to stdout, or exits non-zero.
//
// ForeverLM downloads podcast transcripts from Apple's public transcript API
// (amp-api.podcasts.apple.com), which requires a short-lived JWT that only the
// Podcasts client is normally able to mint. Minting it means signing a request
// with Apple's Mescal (FairPlay) machinery, which lives in the private
// PodcastsFoundation framework. There is no public API for this, so we load the
// framework at runtime and message its classes reflectively — the class and
// method names are the only interoperable surface, treated here as facts about
// the platform, not borrowed implementation.
//
// The signing path can crash inside the framework's own asynchronous teardown
// after it has already produced a valid token. To keep that from ever reaching
// the host app, all of it runs in a forked child: the child writes the token to
// a pipe and _exit()s before any teardown runs, and the parent only ever reads
// bytes. A crash in the child cannot corrupt the token the parent already holds.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/wait.h>

// The App Store storefront identifier for the US Podcasts catalog. Constant.
static NSString *const kStoreFront = @"143441-1,42 t:podcasts1";
static NSString *const kPodcastsFoundationPath =
    @"/System/Library/PrivateFrameworks/PodcastsFoundation.framework/PodcastsFoundation";

// Builds the apiToken service URL, embedding the running macOS version so the
// request looks like the real Podcasts client on this machine.
static NSURL *TokenServiceURL(void) {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    NSString *osVersion = [NSString stringWithFormat:@"%ld.%ld", (long)v.majorVersion, (long)v.minorVersion];
    NSString *urlString = [NSString stringWithFormat:
        @"https://sf-api-token-service.itunes.apple.com/apiToken"
        @"?clientClass=apple&clientId=com.apple.podcasts.macos"
        @"&os=OS%%20X&osVersion=%@&productVersion=1.1.0&version=2", osVersion];
    return [NSURL URLWithString:urlString];
}

// Runs the whole signing flow. Prints the token to stdout on success; anything
// diagnostic goes to stderr. Never returns normally — always _exit()s so no
// framework teardown runs in this process.
static void FetchAndPrintTokenThenExit(void) {
    @autoreleasepool {
        if (dlopen(kPodcastsFoundationPath.fileSystemRepresentation, RTLD_LAZY) == NULL) {
            fprintf(stderr, "PodcastTokenHelper: could not load PodcastsFoundation (%s)\n", dlerror());
            _exit(2);
        }

        Class MescalClass = objc_getClass("AMSMescal");
        Class SessionClass = objc_getClass("AMSMescalSession");
        Class RequestClass = objc_getClass("AMSURLRequest");
        Class URLBagClass = objc_getClass("IMURLBag");
        if (!MescalClass || !SessionClass || !RequestClass || !URLBagClass) {
            fprintf(stderr, "PodcastTokenHelper: required private classes are unavailable on this OS\n");
            _exit(3);
        }

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];

        NSURL *tokenURL = TokenServiceURL();

        // Wrap the request in AMSURLRequest and set the headers the signature covers.
        id request = ((id (*)(id, SEL))objc_msgSend)((id)RequestClass, sel_registerName("alloc"));
        request = ((id (*)(id, SEL, id))objc_msgSend)(
            request, sel_registerName("initWithRequest:"),
            [NSMutableURLRequest requestWithURL:tokenURL]);
        SEL setHeader = sel_registerName("setValue:forHTTPHeaderField:");
        ((void (*)(id, SEL, id, id))objc_msgSend)(request, setHeader, timestamp, @"x-request-timestamp");
        ((void (*)(id, SEL, id, id))objc_msgSend)(request, setHeader, kStoreFront, @"X-Apple-Store-Front");

        // Sign the action. The policy names the fields and headers Mescal folds
        // into the signature; it mirrors the Podcasts client's own request.
        NSDictionary *policy = @{
            @"fields": @[@"clientId"],
            @"headers": @[@"x-apple-store-front", @"x-apple-client-application", @"x-request-timestamp"],
        };
        id actionData = ((id (*)(id, SEL, id, id))objc_msgSend)(
            (id)MescalClass, sel_registerName("_signedActionDataFromRequest:policy:"), request, policy);
        if (!actionData) {
            fprintf(stderr, "PodcastTokenHelper: signing produced no action data\n");
            _exit(4);
        }

        id session = ((id (*)(id, SEL))objc_msgSend)((id)SessionClass, sel_registerName("defaultSession"));
        id urlBag = ((id (*)(id, SEL))objc_msgSend)(
            ((id (*)(id, SEL))objc_msgSend)((id)URLBagClass, sel_registerName("alloc")),
            sel_registerName("init"));

        SEL signDataBag = sel_registerName("signData:bag:");
        if (![session respondsToSelector:signDataBag]) {
            fprintf(stderr, "PodcastTokenHelper: AMSMescalSession lacks signData:bag: on this OS\n");
            _exit(5);
        }

        dispatch_semaphore_t done = dispatch_semaphore_create(0);

        // signData:bag: returns an AMS promise; thenWithBlock: delivers the raw
        // signature bytes, which become the X-Apple-ActionSignature header.
        id promise = ((id (*)(id, SEL, id, id))objc_msgSend)(session, signDataBag, actionData, urlBag);
        // thenWithBlock: chains on the block's return value, so the block must be
        // typed to return id (returning nil ends the chain cleanly). A void block
        // leaves garbage in the return register that AMS treats as a promise.
        id (^onSigned)(id) = ^id(id signatureData) {
            NSString *actionSignature = [(NSData *)signatureData base64EncodedStringWithOptions:0];

            NSMutableURLRequest *tokenRequest = [NSMutableURLRequest requestWithURL:tokenURL];
            [tokenRequest setValue:timestamp forHTTPHeaderField:@"x-request-timestamp"];
            [tokenRequest setValue:kStoreFront forHTTPHeaderField:@"X-Apple-Store-Front"];
            [tokenRequest setValue:actionSignature forHTTPHeaderField:@"X-Apple-ActionSignature"];

            NSURLSessionDataTask *task = [[NSURLSession sharedSession]
                dataTaskWithRequest:tokenRequest
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                    NSString *token = nil;
                    if (data) {
                        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                        if ([json isKindOfClass:[NSDictionary class]]) {
                            token = [json objectForKey:@"token"];
                        }
                    }
                    // Valid Apple tokens are JWTs and start with "ey". Emit the
                    // token and terminate immediately, skipping all teardown.
                    if ([token isKindOfClass:[NSString class]] && [token hasPrefix:@"ey"]) {
                        fprintf(stdout, "%s\n", token.UTF8String);
                        fflush(stdout);
                        _exit(0);
                    }
                    fprintf(stderr, "PodcastTokenHelper: token service returned no usable token\n");
                    _exit(6);
                }];
            [task resume];
            return nil;
        };
        ((void (*)(id, SEL, id))objc_msgSend)(promise, sel_registerName("thenWithBlock:"), onSigned);

        // The completion handler _exit()s the process, so this wait never returns
        // in the success path; it only bounds a hung signing attempt.
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
        fprintf(stderr, "PodcastTokenHelper: timed out waiting for a signature\n");
        _exit(7);
    }
}

int main(int argc, const char *argv[]) {
    if (argc >= 2 && strcmp(argv[1], "--help") == 0) {
        printf("PodcastTokenHelper — prints an Apple Podcasts API bearer token to stdout.\n");
        return 0;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        fprintf(stderr, "PodcastTokenHelper: pipe() failed\n");
        return 1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "PodcastTokenHelper: fork() failed\n");
        return 1;
    }

    if (pid == 0) {
        // Child: redirect stdout into the pipe, then run the crash-prone work.
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        close(fds[1]);
        FetchAndPrintTokenThenExit();
        _exit(99); // unreachable
    }

    // Parent: read whatever the child printed before it exited, and forward the
    // first line if it looks like a JWT. The parent runs no framework code, so
    // it cannot inherit a teardown crash.
    close(fds[1]);
    NSMutableData *buffer = [NSMutableData data];
    char chunk[1024];
    ssize_t n;
    while ((n = read(fds[0], chunk, sizeof(chunk))) > 0) {
        [buffer appendBytes:chunk length:(NSUInteger)n];
    }
    close(fds[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    NSString *output = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    NSString *token = [[output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] firstObject];
    token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if (token.length > 10 && [token hasPrefix:@"ey"]) {
        printf("%s\n", token.UTF8String);
        return 0;
    }

    fprintf(stderr, "PodcastTokenHelper: no bearer token produced\n");
    return WIFEXITED(status) && WEXITSTATUS(status) != 0 ? WEXITSTATUS(status) : 1;
}
