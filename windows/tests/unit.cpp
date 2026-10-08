// vidlark-tests: runs every TEST in the files listed in CMakeLists.txt.
#include "check.h"
#include "support.h"

TEST("clock rounds down, and shows hours from one hour on") {
    CHECK(vl::clock(0) == "00:00");
    CHECK(vl::clock(59.99) == "00:59");
    CHECK(vl::clock(61) == "01:01");
    CHECK(vl::clock(3661.5) == "1:01:01");
    CHECK(vl::clock(-4) == "00:00");
}

TEST("jsonNumber never writes minus zero") {
    CHECK(vl::jsonNumber(-0.0001) == "0.000");
    CHECK(vl::jsonNumber(0.35, 4) == "0.3500");
    CHECK(vl::jsonNumber(-1.25) == "-1.250");
}

TEST("jsonString escapes quotes, slashes and control characters") {
    CHECK(vl::jsonString("a\"b\\c\nd\x01") == "\"a\\\"b\\\\c\\nd\\u0001\"");
    CHECK(vl::jsonString("caf\xC3\xA9") == "\"caf\xC3\xA9\"");
}

TEST("noEmDash turns em dashes into commas") {
    CHECK(vl::noEmDash("one \xE2\x80\x94 two") == "one, two");
    CHECK(vl::noEmDash("one\xE2\x80\x94two") == "one, two");
}

TEST("runTool reads stdout and stderr and the exit code") {
#ifdef _WIN32
    auto shell = vl::tools::find("cmd");
    if (!shell) return;
    auto r = vl::runTool(*shell, {"/c", "echo out& echo err 1>&2& exit 3"});
#else
    auto r = vl::runTool("/bin/sh", {"-c", "echo out; echo err >&2; exit 3"});
#endif
    CHECK(r.status == 3);
    CHECK(vl::trim(r.out) == "out");
    CHECK(r.lastErrorLine() == "err");
}

int main() {
    int run = 0;
    for (const auto& c : vltest::cases()) {
        int before = vltest::failures();
        c.run();
        std::printf("%s %s\n", vltest::failures() == before ? "  ok  " : "  FAIL", c.name);
        run++;
    }
    std::printf("%d tests, %d failed checks\n", run, vltest::failures());
    return vltest::failures() == 0 ? 0 : 1;
}
