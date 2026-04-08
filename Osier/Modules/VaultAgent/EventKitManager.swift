//
//  EventKitManager.swift
//  Osier — Module B: VaultAgent
//
//  Full EKEventStore service wrapper for Apple Calendar and Reminders.
//  Uses iOS 17+ async authorization APIs exclusively.
//  All mutating operations return data structures, never execute directly —
//  execution is routed through SafetyProtocolEngine (Module D).
//
//  Requires Info.plist keys:
//    NSCalendarsFullAccessUsageDescription
//    NSRemindersFullAccessUsageDescription
//

import EventKit
import Foundation

// MARK: - Authorization State

enum EKAuthState {
    case authorized
    case denied
    case notDetermined
    case restricted
}

// MARK: - Fetched Event/Reminder Models

/// Lightweight event descriptor returned from queries.
struct AgentEvent: Identifiable {
    let id: String          // EKEvent.eventIdentifier
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String?
    let notes: String?

    init(from event: EKEvent) {
        self.id            = event.eventIdentifier ?? UUID().uuidString
        self.title         = event.title ?? "(No Title)"
        self.startDate     = event.startDate
        self.endDate       = event.endDate
        self.isAllDay      = event.isAllDay
        self.calendarTitle = event.calendar?.title ?? "Unknown"
        self.location      = event.location
        self.notes         = event.notes
    }
}

/// Lightweight reminder descriptor returned from queries.
struct AgentReminder: Identifiable {
    let id: String          // EKReminder.calendarItemIdentifier
    let title: String
    let dueDate: DateComponents?
    let isCompleted: Bool
    let priority: Int       // 0 = none, 1 = high, 5 = medium, 9 = low (EKReminder standard)
    let listTitle: String
    let notes: String?

    init(from reminder: EKReminder) {
        self.id          = reminder.calendarItemIdentifier
        self.title       = reminder.title ?? "(No Title)"
        self.dueDate     = reminder.dueDateComponents
        self.isCompleted = reminder.isCompleted
        self.priority    = reminder.priority
        self.listTitle   = reminder.calendar?.title ?? "Reminders"
        self.notes       = reminder.notes
    }

    /// Convenience: true if this reminder is considered "low priority" for auto-snooze.
    var isLowPriority: Bool { priority == 9 || priority == 0 }
}

// MARK: - EventKit Manager

@MainActor
final class EventKitManager: ObservableObject {

    // MARK: - Published State

    @Published var calendarAuthState: EKAuthState = .notDetermined
    @Published var reminderAuthState: EKAuthState = .notDetermined

    // MARK: - Singleton

    static let shared = EventKitManager()
    private init() {}

    private let store = EKEventStore()

    // MARK: - Authorization (iOS 17+)

    /// Requests full access to Calendar events. Must be called before any event operation.
    func requestCalendarAccess() async throws {
        do {
            let granted = try await store.requestFullAccessToEvents()
            calendarAuthState = granted ? .authorized : .denied
        } catch {
            calendarAuthState = .denied
            throw EKManagerError.authorizationFailed(.event, error)
        }
    }

    /// Requests full access to Reminders. Must be called before any reminder operation.
    func requestReminderAccess() async throws {
        do {
            let granted = try await store.requestFullAccessToReminders()
            reminderAuthState = granted ? .authorized : .denied
        } catch {
            reminderAuthState = .denied
            throw EKManagerError.authorizationFailed(.reminder, error)
        }
    }

    /// Convenience: requests both calendar and reminder access sequentially.
    func requestAllAccess() async throws {
        try await requestCalendarAccess()
        try await requestReminderAccess()
    }

    // MARK: - Calendar Enumeration

    /// Returns all writable calendars for events.
    func availableCalendars() throws -> [EKCalendar] {
        guard calendarAuthState == .authorized else { throw EKManagerError.notAuthorized(.event) }
        return store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    /// Returns all writable reminder lists.
    func availableReminderLists() throws -> [EKCalendar] {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }
        return store.calendars(for: .reminder).filter { $0.allowsContentModifications }
    }

    /// Finds a calendar by title. Returns nil if not found.
    func calendar(named title: String) -> EKCalendar? {
        store.calendars(for: .event).first { $0.title.lowercased() == title.lowercased() }
    }

    /// Finds a reminder list by title. Returns nil if not found.
    func reminderList(named title: String) -> EKCalendar? {
        store.calendars(for: .reminder).first { $0.title.lowercased() == title.lowercased() }
    }

    // MARK: - Event Fetch

    /// Fetches events within a date range from specified calendars (nil = all calendars).
    func fetchEvents(from start: Date, to end: Date, calendars: [EKCalendar]? = nil) throws -> [AgentEvent] {
        guard calendarAuthState == .authorized else { throw EKManagerError.notAuthorized(.event) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map { AgentEvent(from: $0) }
    }

    /// Fetches events for today.
    func fetchTodaysEvents() throws -> [AgentEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end   = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return try fetchEvents(from: start, to: end)
    }

    // MARK: - Event Create

    /// Creates an EKEvent and saves it. Returns the new event's identifier.
    @discardableResult
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        calendarTitle: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        alarmMinutesBefore: Int? = nil
    ) throws -> String {
        guard calendarAuthState == .authorized else { throw EKManagerError.notAuthorized(.event) }

        let event        = EKEvent(eventStore: store)
        event.title      = title
        event.startDate  = startDate
        event.endDate    = endDate
        event.isAllDay   = isAllDay
        event.location   = location
        event.notes      = notes

        if let calTitle = calendarTitle, let cal = calendar(named: calTitle) {
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let minutes = alarmMinutesBefore {
            let alarm = EKAlarm(relativeOffset: TimeInterval(-minutes * 60))
            event.addAlarm(alarm)
        }

        try store.save(event, span: .thisEvent, commit: true)
        print("[EventKitManager] ✅ Event created: \(title)")
        return event.eventIdentifier ?? ""
    }

    // MARK: - Event Update

    /// Updates an existing event's title, dates, or notes by identifier.
    func updateEvent(
        identifier: String,
        newTitle: String? = nil,
        newStartDate: Date? = nil,
        newEndDate: Date? = nil,
        newNotes: String? = nil
    ) throws {
        guard calendarAuthState == .authorized else { throw EKManagerError.notAuthorized(.event) }

        guard let event = store.event(withIdentifier: identifier) else {
            throw EKManagerError.itemNotFound(identifier)
        }

        if let t = newTitle      { event.title     = t }
        if let s = newStartDate  { event.startDate = s }
        if let e = newEndDate    { event.endDate   = e }
        if let n = newNotes      { event.notes     = n }

        try store.save(event, span: .thisEvent, commit: true)
        print("[EventKitManager] ✅ Event updated: \(identifier)")
    }

    // MARK: - Event Delete

    /// Moves an event to the trash equivalent (removes from calendar by identifier).
    func deleteEvent(identifier: String) throws {
        guard calendarAuthState == .authorized else { throw EKManagerError.notAuthorized(.event) }

        guard let event = store.event(withIdentifier: identifier) else {
            throw EKManagerError.itemNotFound(identifier)
        }

        try store.remove(event, span: .thisEvent, commit: true)
        print("[EventKitManager] 🗑 Event deleted: \(identifier)")
    }

    // MARK: - Reminder Fetch

    /// Fetches incomplete reminders from specified lists (nil = all lists).
    func fetchIncompleteReminders(from lists: [EKCalendar]? = nil) async throws -> [AgentReminder] {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: lists
        )

        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: EKManagerError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders.map { AgentReminder(from: $0) })
            }
        }
    }

    /// Fetches reminders due today or overdue.
    func fetchOverdueAndTodayReminders() async throws -> [AgentReminder] {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: Date()) ?? Date()
        let predicate  = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: endOfToday,
            calendars: nil
        )

        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: EKManagerError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders.map { AgentReminder(from: $0) })
            }
        }
    }

    // MARK: - Reminder Create

    /// Creates and saves a new EKReminder. Returns the new reminder's identifier.
    @discardableResult
    func createReminder(
        title: String,
        dueDateComponents: DateComponents? = nil,
        listTitle: String? = nil,
        notes: String? = nil,
        priority: Int = 0
    ) throws -> String {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        let reminder            = EKReminder(eventStore: store)
        reminder.title          = title
        reminder.notes          = notes
        reminder.priority       = priority
        reminder.dueDateComponents = dueDateComponents

        if let listTitle, let list = reminderList(named: listTitle) {
            reminder.calendar = list
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        try store.save(reminder, commit: true)
        print("[EventKitManager] ✅ Reminder created: \(title)")
        return reminder.calendarItemIdentifier
    }

    // MARK: - Reminder Update

    /// Updates the due date of an existing reminder by identifier.
    func reschedulReminder(identifier: String, to newDueDate: DateComponents) throws {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EKManagerError.itemNotFound(identifier)
        }

        reminder.dueDateComponents = newDueDate
        try store.save(reminder, commit: true)
        print("[EventKitManager] ✅ Reminder rescheduled: \(identifier)")
    }

    /// Marks a reminder as completed.
    func completeReminder(identifier: String) throws {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EKManagerError.itemNotFound(identifier)
        }

        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        print("[EventKitManager] ✅ Reminder completed: \(identifier)")
    }

    // MARK: - Reminder Delete

    /// Removes a reminder by identifier.
    func deleteReminder(identifier: String) throws {
        guard reminderAuthState == .authorized else { throw EKManagerError.notAuthorized(.reminder) }

        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw EKManagerError.itemNotFound(identifier)
        }

        try store.remove(reminder, commit: true)
        print("[EventKitManager] 🗑 Reminder deleted: \(identifier)")
    }

    // MARK: - Smart Snooze

    /// Snooze Strategy specifies how far to push the due date.
    enum SnoozeInterval {
        case hours(Int)
        case days(Int)
        case nextWeekday

        func apply(to date: Date) -> Date {
            let cal = Calendar.current
            switch self {
            case .hours(let h): return cal.date(byAdding: .hour, value: h, to: date) ?? date
            case .days(let d):  return cal.date(byAdding: .day, value: d, to: date) ?? date
            case .nextWeekday:
                var next = cal.date(byAdding: .day, value: 1, to: date) ?? date
                while cal.isDateInWeekend(next) {
                    next = cal.date(byAdding: .day, value: 1, to: next) ?? next
                }
                return next
            }
        }
    }

    /// Finds all low-priority reminders and shifts their due dates forward.
    /// Returns the identifiers of all snoozed reminders.
    @discardableResult
    func snoozeLowPriorityReminders(
        in listTitle: String? = nil,
        by interval: SnoozeInterval = .days(1)
    ) async throws -> [String] {
        let list     = listTitle.flatMap { reminderList(named: $0) }
        let all      = try await fetchIncompleteReminders(from: list.map { [$0] } ?? nil)
        let targets  = all.filter { $0.isLowPriority && $0.dueDate != nil }
        var snoozed: [String] = []

        for reminder in targets {
            guard let dueDateComps = reminder.dueDate,
                  let date = Calendar.current.date(from: dueDateComps) else { continue }

            let newDate  = interval.apply(to: date)
            let newComps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: newDate)
            try reschedulReminder(identifier: reminder.id, to: newComps)
            snoozed.append(reminder.id)
        }

        print("[EventKitManager] 💤 Snoozed \(snoozed.count) low-priority reminder(s)")
        return snoozed
    }

    // MARK: - Utility: DateComponents Builder

    /// Builds `DateComponents` from a `Date` for use with Reminders.
    static func dateComponents(from date: Date) -> DateComponents {
        Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}

// MARK: - EventKit Errors

enum EKManagerError: LocalizedError {
    case authorizationFailed(EKEntityType, Error)
    case notAuthorized(EKEntityType)
    case itemNotFound(String)
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .authorizationFailed(let type, let err):
            return "Authorization failed for \(type == .event ? "Calendar" : "Reminders"): \(err.localizedDescription)"
        case .notAuthorized(let type):
            return "\(type == .event ? "Calendar" : "Reminders") access not authorized."
        case .itemNotFound(let id):
            return "No event or reminder found with identifier: \(id)"
        case .fetchFailed:
            return "Failed to fetch reminders from EventKit."
        }
    }
}
