#include "HeftTestDefaults.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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
// The suite is named for the process. One fixed name was shared by every
// `swift test` on the machine, so a run starting in one worktree emptied the
// suite under a run already going in another, and the two read each other's
// frecency.
//
// C, because a constructor is the one hook that runs before Swift Testing
// starts any test; Swift Testing has no process-wide set-up.

static char heft_suite[128];

static void heft_empty_suite(CFStringRef suite) {
    CFArrayRef keys = CFPreferencesCopyKeyList(
        suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys != NULL) {
        CFPreferencesSetMultiple(
            NULL, keys, suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFRelease(keys);
    }
    CFPreferencesSynchronize(suite, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static void heft_empty_named_suite(const char *name) {
    CFStringRef suite = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    if (suite == NULL) return;
    heft_empty_suite(suite);
    CFRelease(suite);
}

// A run that crashed or was killed never reaches its exit handler, and
// cfprefsd keeps the file of a domain it has emptied, so each run also
// clears away the suites of runs that are no longer alive: emptied first,
// so cfprefsd's cache agrees with the disk, then the file removed.
static void heft_sweep_dead_suites(void) {
    const char *home = getenv("HOME");
    if (home == NULL) return;
    char directory[1024];
    snprintf(directory, sizeof directory, "%s/Library/Preferences", home);
    DIR *listing = opendir(directory);
    if (listing == NULL) return;
    const char *prefix = HEFT_TEST_DEFAULTS_SUITE ".";
    size_t prefixLength = strlen(prefix);
    struct dirent *entry;
    while ((entry = readdir(listing)) != NULL) {
        if (strncmp(entry->d_name, prefix, prefixLength) != 0) continue;
        char *end = NULL;
        long pid = strtol(entry->d_name + prefixLength, &end, 10);
        if (end == entry->d_name + prefixLength || strcmp(end, ".plist") != 0) continue;
        if (pid <= 0 || pid == getpid()) continue;
        if (kill((pid_t)pid, 0) == 0 || errno != ESRCH) continue;
        char name[256];
        snprintf(name, sizeof name, "%s%ld", prefix, pid);
        heft_empty_named_suite(name);
        char path[1400];
        snprintf(path, sizeof path, "%s/%s", directory, entry->d_name);
        unlink(path);
    }
    closedir(listing);
}

static void heft_empty_own_suite(void) {
    heft_empty_named_suite(heft_suite);
}

__attribute__((constructor))
static void heft_isolate_test_defaults(void) {
    // An explicit choice from whoever launched the run wins.
    const char *existing = getenv(HEFT_TEST_DEFAULTS_ENV);
    if (existing != NULL && existing[0] != '\0') return;

    heft_sweep_dead_suites();
    // A pid can be reused, so the suite is emptied as well as unique.
    snprintf(heft_suite, sizeof heft_suite, "%s.%d", HEFT_TEST_DEFAULTS_SUITE, (int)getpid());
    heft_empty_own_suite();
    atexit(heft_empty_own_suite);
    setenv(HEFT_TEST_DEFAULTS_ENV, heft_suite, 1);
}

const char *heft_test_defaults_suite(void) {
    return heft_suite[0] == '\0' ? NULL : heft_suite;
}
