import EventKit
import Foundation

@MainActor
final class CalendarSync {
    private let store = EKEventStore()
    private let calendarTitle = "School Timetable"

    func replaceFutureLessons(_ lessons: [Lesson], from start: Date, through end: Date) async throws {
        try await requestAccess()
        let calendar = try timetableCalendar()
        let predicate = store.predicateForEvents(withStart: start,
                                                  end: Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end,
                                                  calendars: [calendar])
        for event in store.events(matching: predicate) {
            try store.remove(event, span: .thisEvent, commit: false)
        }
        for lesson in lessons {
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = lesson.subject
            event.startDate = lesson.start
            event.endDate = lesson.end
            let details = [lesson.teacher.isEmpty ? nil : "Teacher: \(lesson.teacher)",
                           lesson.room.isEmpty ? nil : "Room: \(lesson.room)"]
                .compactMap { $0 }.joined(separator: "\n")
            event.notes = details.isEmpty ? nil : details
            try store.save(event, span: .thisEvent, commit: false)
        }
        try store.commit()
    }

    private func requestAccess() async throws {
        if #available(iOS 17.0, *) {
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw CalendarSyncError.accessDenied }
        } else {
            let granted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                store.requestAccess(to: .event) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
            guard granted else { throw CalendarSyncError.accessDenied }
        }
    }

    private func timetableCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: { $0.title == calendarTitle }) {
            return existing
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = calendarTitle
        calendar.source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first
        guard calendar.source != nil else { throw CalendarSyncError.noCalendarSource }
        try store.saveCalendar(calendar, commit: false)
        try store.commit()
        return calendar
    }
}

enum CalendarSyncError: LocalizedError {
    case accessDenied
    case noCalendarSource
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Calendar access was not granted. Enable full calendar access in Settings to refresh the dedicated timetable calendar."
        case .noCalendarSource: return "No writable calendar source is available on this device."
        }
    }
}
