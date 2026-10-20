#ifndef HEFT_TEST_DEFAULTS_H
#define HEFT_TEST_DEFAULTS_H

/// The variable `HeftDefaults` reads, and the prefix of the suite the test
/// process uses: the process id follows it.
#define HEFT_TEST_DEFAULTS_ENV "HEFT_DEFAULTS_SUITE"
#define HEFT_TEST_DEFAULTS_SUITE "com.example.heft.tests"

/// The suite this process was given, or NULL when its launcher chose one.
const char *heft_test_defaults_suite(void);

#endif
