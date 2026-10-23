import Foundation

/// Turns spoken expiration dates ("the 20th", "next Friday", "in a week",
/// "October 20", "10/20") into a calendar day.
///
/// The on-device model is unreliable at date math, so it passes along the user's
/// words and this does the conversion. Dates without a year (or month) resolve to
/// the next time they occur, counting today.
struct SpokenDateParser {
    var calendar: Calendar = .current
    var now: Date = .now

    private var today: Date { calendar.startOfDay(for: now) }

    func parse(_ phrase: String) -> Date? {
        let text = normalize(phrase)
        guard !text.isEmpty else { return nil }

        return parseISO(text)
            ?? parseNumeric(text)
            ?? parseMonthAndDay(text)
            ?? parseRelative(text)
            ?? parseWeekday(text)
            ?? parseDayOfMonth(text)
            ?? parseWithDataDetector(phrase)
    }

    // MARK: - Formats

    /// 2026-10-20
    private func parseISO(_ text: String) -> Date? {
        guard let match = text.firstMatch(of: #/(\d{4})-(\d{1,2})-(\d{1,2})/#) else { return nil }
        return makeDate(year: Int(match.1), month: Int(match.2), day: Int(match.3))
    }

    /// 10/20, 10/20/26, 10/20/2026 (US month-first order)
    private func parseNumeric(_ text: String) -> Date? {
        guard let match = text.firstMatch(of: #/(\d{1,2})[\/.](\d{1,2})(?:[\/.](\d{2,4}))?/#) else { return nil }
        guard let month = Int(match.1), let day = Int(match.2) else { return nil }
        if let yearText = match.3, var year = Int(yearText) {
            if year < 100 { year += 2000 }
            return makeDate(year: year, month: month, day: day)
        }
        return nextOccurrence(month: month, day: day)
    }

    /// "october 20", "oct 20th", "20 october", "20th of october", "october 20 2027"
    private func parseMonthAndDay(_ text: String) -> Date? {
        let words = text.split(separator: " ").map(String.init)
        guard let monthIndex = words.firstIndex(where: { Self.month(named: $0) != nil }),
              let month = Self.month(named: words[monthIndex]) else { return nil }

        let after = words[(monthIndex + 1)...].compactMap(Self.dayNumber)
        let before = words[..<monthIndex].reversed().compactMap(Self.dayNumber)
        guard let day = after.first ?? before.first else {
            // "october" alone isn't a usable expiration date.
            return nil
        }
        if let year = words[(monthIndex + 1)...].compactMap({ Int($0) }).first(where: { $0 >= 2000 }) {
            return makeDate(year: year, month: month, day: day)
        }
        return nextOccurrence(month: month, day: day)
    }

    /// "today", "tomorrow", "yesterday", "in 5 days", "a week", "two weeks", "a month", "a couple days"
    private func parseRelative(_ text: String) -> Date? {
        if text.contains("day after tomorrow") { return adding(.day, 2) }
        if text.contains("today") || text.contains("tonight") { return today }
        if text.contains("tomorrow") { return adding(.day, 1) }
        if text.contains("yesterday") { return adding(.day, -1) }

        let words = text.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() {
            let unit: Calendar.Component
            switch word {
            case "day", "days": unit = .day
            case "week", "weeks": unit = .weekOfYear
            case "month", "months": unit = .month
            case "year", "years": unit = .year
            default: continue
            }
            // "two weeks", "a couple of days"
            var countIndex = index - 1
            if countIndex >= 0, words[countIndex] == "of" { countIndex -= 1 }
            let count = countIndex >= 0 ? Self.quantity(words[countIndex]) : nil
            return adding(unit, count ?? 1)
        }
        return nil
    }

    /// "friday", "next friday", "this fri"
    private func parseWeekday(_ text: String) -> Date? {
        let words = text.split(separator: " ")
        guard let weekday = words.lazy.compactMap({ Self.weekday(named: String($0)) }).first else { return nil }
        // Upcoming occurrence, not counting today.
        let current = calendar.component(.weekday, from: today)
        var offset = (weekday - current + 7) % 7
        if offset == 0 { offset = 7 }
        return adding(.day, offset)
    }

    /// "the 20th", "20th", "20"
    private func parseDayOfMonth(_ text: String) -> Date? {
        let days = text.split(separator: " ").compactMap { Self.dayNumber(String($0)) }
        guard days.count == 1, let day = days.first else { return nil }
        let currentMonth = calendar.dateComponents([.year, .month], from: today)
        for monthOffset in 0..<3 {
            guard let monthStart = calendar.date(from: currentMonth),
                  let month = calendar.date(byAdding: .month, value: monthOffset, to: monthStart) else { continue }
            var parts = calendar.dateComponents([.year, .month], from: month)
            parts.day = day
            if let date = validDate(parts), date >= today { return date }
        }
        return nil
    }

    private func parseWithDataDetector(_ phrase: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)),
              let date = match.date else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Helpers

    private func normalize(_ phrase: String) -> String {
        phrase.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func adding(_ component: Calendar.Component, _ value: Int) -> Date? {
        calendar.date(byAdding: component, value: value, to: today)
    }

    private func makeDate(year: Int?, month: Int?, day: Int?) -> Date? {
        validDate(DateComponents(year: year, month: month, day: day))
    }

    private func validDate(_ components: DateComponents) -> Date? {
        var components = components
        components.calendar = calendar
        guard components.isValidDate, let date = components.date else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// This year's month/day if it hasn't passed yet, otherwise next year's.
    private func nextOccurrence(month: Int, day: Int) -> Date? {
        let year = calendar.component(.year, from: today)
        if let date = makeDate(year: year, month: month, day: day), date >= today { return date }
        return makeDate(year: year + 1, month: month, day: day)
    }

    private static let monthNames = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ]

    private static func month(named word: String) -> Int? {
        let word = word.trimmingCharacters(in: .punctuationCharacters)
        guard word.count >= 3 else { return nil }
        if word == "sept" { return 9 }
        guard let index = monthNames.firstIndex(where: { word.hasPrefix($0) }) else { return nil }
        // Avoid matching words that only start like a month ("marshmallow", "decent").
        let fullNames = ["january", "february", "march", "april", "may", "june", "july",
                         "august", "september", "october", "november", "december"]
        guard word == monthNames[index] || fullNames[index].hasPrefix(word) else { return nil }
        return index + 1
    }

    private static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    private static func weekday(named word: String) -> Int? {
        let fullNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let index = fullNames.firstIndex(of: word) { return index + 1 }
        if let index = weekdayNames.firstIndex(of: word) { return index + 1 }
        if ["tues", "weds", "thur", "thurs"].contains(word) {
            return word.hasPrefix("tu") ? 3 : word.hasPrefix("we") ? 4 : 5
        }
        return nil
    }

    private static let ordinalWords = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    /// "20", "20th", "1st", "twentieth" → day of month (1–31).
    private static func dayNumber(_ word: String) -> Int? {
        let word = word.trimmingCharacters(in: .punctuationCharacters)
        if let value = ordinalWords[word] { return value }
        if word.hasPrefix("twenty-") || word.hasPrefix("thirty-") {
            let parts = word.split(separator: "-")
            if parts.count == 2, let unit = ordinalWords[String(parts[1])], unit < 10 {
                return (parts[0] == "twenty" ? 20 : 30) + unit
            }
        }
        let digits = word.replacing(#/(st|nd|rd|th)$/#, with: "")
        guard digits.allSatisfy(\.isNumber), let value = Int(digits), (1...31).contains(value) else { return nil }
        return value
    }

    private static let numberWords = [
        "a": 1, "an": 1, "one": 1, "two": 2, "couple": 2, "three": 3, "few": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    private static func quantity(_ word: String) -> Int? {
        Int(word) ?? numberWords[word]
    }
}
