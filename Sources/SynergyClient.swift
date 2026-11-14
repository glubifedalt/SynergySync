import Foundation

/// Foundation-only scraper. Keep this file independently compilable with `swiftc` on Linux.
/// Replace the endpoint and response keys below after inspecting your school's DevTools traffic.
enum SynergyConfiguration {
    /// Example only: replace with the exact request URL. `{weekStart}` and `{weekEnd}` are
    /// replaced by ISO-8601 calendar dates. If your portal uses different parameters, edit
    /// `requestURL(for:)` below.
    static let endpointTemplate = "https://YOUR-SCHOOL-PORTAL.example/api/timetable?start={weekStart}&end={weekEnd}"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let lessonsArrayKey = "lessons"       // JSON path/key containing the lesson array
    static let subjectKey = "subject"
    static let roomKey = "room"
    static let teacherKey = "teacher"
    static let startKey = "start"                // ISO-8601 date/time, e.g. 2027-01-04T09:00:00Z
    static let endKey = "end"
}

struct Lesson: Identifiable, Hashable {
    let subject: String
    let room: String
    let teacher: String
    let start: Date
    let end: Date
    var id: String { "\(start.timeIntervalSince1970)-\(subject)-\(room)" }
}

enum SynergyError: LocalizedError {
    case invalidEndpoint
    case unauthorized
    case loginRedirect
    case httpStatus(Int)
    case invalidResponse(String)
    case invalidLessonDate

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Set the Synergy endpoint URL in SynergyConfiguration before syncing."
        case .unauthorized: return "The School Synergy session cookie was rejected (HTTP 401/403). Update the cookie and try again."
        case .loginRedirect: return "School Synergy redirected to its login page. The session cookie may have expired."
        case .httpStatus(let code): return "The timetable request failed with HTTP \(code)."
        case .invalidResponse(let detail): return "Could not parse the timetable response: \(detail)"
        case .invalidLessonDate: return "A lesson has an invalid start or end date. Check the configured response keys/date format."
        }
    }
}

struct SynergyClient {
    var session: URLSession = .shared

    func fetchLessons(cookie: String, from startDate: Date, through endDate: Date,
                      progress: @escaping (String) -> Void) async throws -> [Lesson] {
        let calendar = Calendar(identifier: .iso8601)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: startDate)?.start ?? startDate
        var week = startOfWeek
        var results: [Lesson] = []
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"

        while week <= endDate {
            let nextWeek = calendar.date(byAdding: .day, value: 7, to: week) ?? endDate
            let weekEnd = min(calendar.date(byAdding: .day, value: 6, to: week) ?? week, endDate)
            progress("Fetching week of \(dateFormatter.string(from: week))…")
            results.append(contentsOf: try await fetchWeek(cookie: cookie, start: week, end: weekEnd,
                                                            dateFormatter: dateFormatter))
            if nextWeek <= endDate {
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            week = nextWeek
        }
        return results.filter { $0.start >= startDate && $0.start <= endDate }.sorted { $0.start < $1.start }
    }

    private func fetchWeek(cookie: String, start: Date, end: Date,
                           dateFormatter: DateFormatter) async throws -> [Lesson] {
        let startText = dateFormatter.string(from: start)
        let endText = dateFormatter.string(from: end)
        let urlText = SynergyConfiguration.endpointTemplate
            .replacingOccurrences(of: "{weekStart}", with: startText)
            .replacingOccurrences(of: "{weekEnd}", with: endText)
        guard !urlText.contains("YOUR-SCHOOL-PORTAL"), let url = URL(string: urlText) else {
            throw SynergyError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET" // Change if DevTools shows another method.
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(SynergyConfiguration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SynergyError.invalidResponse("Missing HTTP response") }
        if http.statusCode == 401 || http.statusCode == 403 { throw SynergyError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw SynergyError.httpStatus(http.statusCode) }
        if let finalURL = http.url, finalURL.path.lowercased().contains("login") { throw SynergyError.loginRedirect }
        return try parse(data: data)
    }

    /// Default parser for a JSON object containing an array under `lessonsArrayKey`.
    /// Edit keys above (or this function) to match the captured response. HTML responses
    /// require site-specific parsing; keep that implementation Foundation-only as well.
    func parse(data: Data) throws -> [Lesson] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? "non-text response"
            if body.lowercased().contains("login") || body.lowercased().contains("sign in") {
                throw SynergyError.loginRedirect
            }
            throw SynergyError.invalidResponse("Expected JSON. Response begins: \(body)")
        }
        let array: [[String: Any]]
        if let object = root as? [String: Any], let items = object[SynergyConfiguration.lessonsArrayKey] as? [[String: Any]] {
            array = items
        } else if let items = root as? [[String: Any]] {
            array = items
        } else {
            throw SynergyError.invalidResponse("Expected an array at key `\(SynergyConfiguration.lessonsArrayKey)` or a top-level array.")
        }
        return try array.compactMap { item in
            guard let startText = item[SynergyConfiguration.startKey] as? String,
                  let endText = item[SynergyConfiguration.endKey] as? String else { return nil }
            guard let start = Self.parseDate(startText), let end = Self.parseDate(endText), end > start else {
                throw SynergyError.invalidLessonDate
            }
            return Lesson(subject: item[SynergyConfiguration.subjectKey] as? String ?? "Lesson",
                          room: item[SynergyConfiguration.roomKey] as? String ?? "",
                          teacher: item[SynergyConfiguration.teacherKey] as? String ?? "",
                          start: start, end: end)
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: value)
    }
}
