import Testing
@testable import GoIDECore

@Suite struct PprofTests {
    static let functions = """
    File: prof.test
    Type: cpu
    Time: 2026-11-01 05:21:27 +08
    Duration: 4.67s, Total samples = 2030ms (43.47%)
    Showing nodes accounting for 1620ms, 79.80% of 2030ms total
    Dropped 38 nodes (cum <= 10.15ms)
          flat  flat%   sum%        cum   cum%
         990ms 48.77% 48.77%     1020ms 50.25%  example.com/prof.Fib
          90ms  4.43% 70.44%      260ms 12.81%  strings.Repeat
          60ms  2.96% 77.34%       60ms  2.96%  strings.(*Builder).copyCheck (inline)
             0     0% 99.25%   580.30MB 98.73%  example.com/prof.BenchmarkBuild
    """

    static let lines = """
    Type: cpu
          flat  flat%   sum%        cum   cum%
         620ms 30.54% 30.54%      650ms 32.02%  example.com/prof.Fib /w/prof/fib.go:5
         170ms  8.37% 38.92%     1020ms 50.25%  example.com/prof.Fib /w/prof/fib.go:9
         130ms  6.40% 45.32%      130ms  6.40%  example.com/prof.Fib /w/prof/fib.go:7
          10ms  0.49% 45.81%       10ms  0.49%  strings.Repeat /go/src/strings/strings.go:612 (inline)
    """

    @Test func parsesFunctionTable() {
        let report = Pprof.parseTop(Self.functions)
        #expect(report.type == "cpu")
        #expect(report.total == "2030ms")
        #expect(report.summary.first == "Duration: 4.67s, Total samples = 2030ms (43.47%)")
        #expect(report.rows.count == 4)
        let fib = report.rows[0]
        #expect(fib.flat == "990ms")
        #expect(fib.flatPercent == 48.77)
        #expect(fib.cum == "1020ms")
        #expect(fib.cumPercent == 50.25)
        #expect(fib.function == "example.com/prof.Fib")
        #expect(fib.shortName == "Fib")
        #expect(fib.package == "example.com/prof")
        #expect(fib.file == nil)
        let copyCheck = report.rows[2]
        #expect(copyCheck.isInline)
        #expect(copyCheck.function == "strings.(*Builder).copyCheck")
        #expect(copyCheck.shortName == "(*Builder).copyCheck")
        #expect(copyCheck.package == "strings")
        #expect(report.rows[3].flat == "0")
        #expect(report.rows[3].flatPercent == 0)
    }

    @Test func parsesLineTableAndLocatesFunctions() {
        let lineReport = Pprof.parseTop(Self.lines)
        #expect(lineReport.rows.count == 4)
        #expect(lineReport.rows[0].file == "/w/prof/fib.go")
        #expect(lineReport.rows[0].line == 5)
        #expect(lineReport.rows[3].isInline)
        #expect(lineReport.rows[3].line == 612)
        #expect(lineReport.rows[3].function == "strings.Repeat")

        let located = Pprof.locate(Pprof.parseTop(Self.functions).rows, using: lineReport.rows)
        #expect(located[0].file == "/w/prof/fib.go")
        #expect(located[0].line == 5)
        #expect(located[1].line == 612)
        #expect(located[2].file == nil)
    }
}
