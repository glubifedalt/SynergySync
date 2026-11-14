import SwiftUI
import UIKit

@main
struct SynergySyncApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

@MainActor
final class SyncViewModel: ObservableObject {
    @Published var cookie = UserDefaults.standard.string(forKey: "synergyCookie") ?? ""
    @Published var log = "Enter your School Synergy Cookie header value to begin."
    @Published var isSyncing = false
    @Published var alertMessage: String?

    func saveCookie() { UserDefaults.standard.set(cookie, forKey: "synergyCookie") }

    func sync() {
        saveCookie()
        guard !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            alertMessage = "Enter the Cookie value copied from your authenticated School Synergy request."
            return
        }
        isSyncing = true
        log = "Starting timetable sync…"
        Task {
            defer { isSyncing = false }
            do {
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                var components = DateComponents()
                components.year = 2027; components.month = 6; components.day = 18
                let finalDay = calendar.date(from: components) ?? today
                let lessons = try await SynergyClient().fetchLessons(cookie: cookie, from: today, through: finalDay) { message in
                    Task { @MainActor in self.log = message }
                }
                log = "Fetched \(lessons.count) lessons. Updating School Timetable calendar…"
                try await CalendarSync().replaceFutureLessons(lessons, from: today, through: finalDay)
                log = "Sync complete. Added \(lessons.count) lessons through 18 June 2027."
            } catch {
                log = "Sync failed: \(error.localizedDescription)"
                alertMessage = error.localizedDescription
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = SyncViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("School Synergy session") {
                    SecureField("Cookie header value", text: $model.cookie)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Paste from Clipboard") {
                        if let text = UIPasteboard.general.string { model.cookie = text }
                    }
                }
                Section {
                    Button {
                        model.sync()
                    } label: {
                        HStack {
                            if model.isSyncing { ProgressView().padding(.trailing, 6) }
                            Text(model.isSyncing ? "Syncing Timetable…" : "Sync Timetable")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(model.isSyncing)
                }
                Section("Sync status") {
                    Text(model.log).font(.callout).textSelection(.enabled)
                }
                Section {
                    Text("Lessons are written to the dedicated “School Timetable” calendar. Syncing clears its events from today through 18 June 2027 before saving the refreshed schedule.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Synergy Sync")
            .onChange(of: model.cookie) { _ in model.saveCookie() }
            .alert("Timetable Sync", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
                Button("OK", role: .cancel) { model.alertMessage = nil }
            } message: { Text(model.alertMessage ?? "") }
        }
    }
}
