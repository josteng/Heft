#include "HeftTestDefaults.h"

#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>

// Points the test process at a preferences suite of its own, emptied on every
// run, before any test reaches `HeftDefaults.shared`.
//
// Without it the suite writes to the test runner's standard domain, which
// every run grows by a few hundred keys: each disposable vault leaves its
// recents and rankings behind under its unique path. cfprefsd rewrites and
// re-notifies the whole domain on every write, so once it holds tens of
// thousands of keys each write on the main thread costs a noticeable fraction
// of a second, and the main-actor suites together hold the main thread for
// tens of seconds at a time.
//
// C, because a constructor is the one hook that runs before Swift Testing
// starts any test; Swift Testing has no process-wide set-up.
__attribute__((constructor))
static void heft_isolate_test_defaults(void) {
    // An explicit choice from whoever launched the run wins.
    const char *existing = getenv(HEFT_TEST_DEFAULTS_ENV);
    if (existing != NULL && existing[0] != '\0') return;

    CFStringRef suite = CFSTR(HEFT_TEST_DEFAULTS_SUITE);
    CFArrayRef keys = CFPreferencesCopyKeyList(
        suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys != NULL) {
        CFPreferencesSetMultiple(
            NULL, keys, suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
        CFPreferencesSynchronize(suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
    setenv(HEFT_TEST_DEFAULTS_ENV, HEFT_TEST_DEFAULTS_SUITE, 1);
}
