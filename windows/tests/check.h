#pragma once
// A very small test runner: TEST(name) { CHECK(a == b); }. Each test file registers its own tests.

#include <cmath>
#include <cstdio>
#include <functional>
#include <string>
#include <vector>

namespace vltest {
struct Case {
    const char* name;
    std::function<void()> run;
};
inline std::vector<Case>& cases() {
    static std::vector<Case> all;
    return all;
}
inline int& failures() {
    static int n = 0;
    return n;
}
struct Register {
    Register(const char* name, std::function<void()> run) { cases().push_back({name, std::move(run)}); }
};
}  // namespace vltest

#define VL_CAT2(a, b) a##b
#define VL_CAT(a, b) VL_CAT2(a, b)
#define TEST(name)                                                              \
    static void VL_CAT(test_, __LINE__)();                                      \
    static vltest::Register VL_CAT(reg_, __LINE__)(name, VL_CAT(test_, __LINE__)); \
    static void VL_CAT(test_, __LINE__)()
#define CHECK(cond)                                                             \
    do {                                                                        \
        if (!(cond)) {                                                          \
            std::printf("    FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);     \
            vltest::failures()++;                                               \
        }                                                                       \
    } while (0)
#define CHECK_NEAR(a, b, tol) CHECK(std::fabs(double(a) - double(b)) <= (tol))
