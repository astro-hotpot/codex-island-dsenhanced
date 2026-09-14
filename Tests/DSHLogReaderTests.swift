import Foundation

@main struct DSHLogReaderTests {
    static func main() {
        let row = #"{"type":"assistant/message","seq":1,"time":1789115012356,"data":{"usage":{"inputTokens":357,"outputTokens":178,"totalTokens":9111,"cacheReadTokens":8576,"reasoningTokens":16},"stream":[{"chunk":{"usage":{"totalTokens":9111}}}]}}"#
        let ignored = #"{"type":"other","seq":2,"time":1789115012356,"data":{"usage":{"inputTokens":1,"outputTokens":2,"totalTokens":3}}}"#
        let parsed = DSHLogReader.parse(Data((row + "\n" + row + "\n" + ignored + "\n{broken").utf8))
        precondition(parsed.count == 1)
        precondition(parsed[0].tokens == 9111, "Do not double-count stream usage, repeated seq, or reasoning")
        precondition(parsed[0].billableTokens == 535)
        precondition(Calendar.current.isDate(parsed[0].dayStart, inSameDayAs: Date(timeIntervalSince1970: 1789115012.356)))
        print("DSH parser tests passed")
    }
}
