// Owner: Maxwell. Settings, system status, and the benchmark lab: run the
// standard task battery on EchoGuide, log the same tasks done with other
// apps, and export one CSV that compares them.

import SwiftUI
import EchoGuideInfra

struct SettingsView: View {
    let runtime: AppRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var cloudPhotos = AppSettings.imageConsent
    @State private var results: [TrialResult] = []
    @State private var csv = ""
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Depth", value: runtime.hasLiDAR ? "LiDAR" : "Not available")
                    LabeledContent("Object model", value: runtime.hasModel ? "Loaded" : "Not bundled")
                    LabeledContent("Cloud", value: runtime.cloudConfigured ? (runtime.online ? "Reachable" : "Offline") : "Not configured")
                }

                if runtime.cloudConfigured {
                    Section {
                        Toggle("Send photos for richer descriptions", isOn: $cloudPhotos)
                            .onChange(of: cloudPhotos) { _, on in AppSettings.imageConsent = on }
                    } footer: {
                        Text("Applies the next time EchoGuide opens. Photos are only sent when you tap Describe, and EchoGuide does not store them.")
                    }
                }

                Section {
                    Button("Measure on-device speed (20 s)") {
                        runtime.runLatencyBenchmark()
                        dismiss()
                    }
                } header: {
                    Text("Speed")
                } footer: {
                    Text("Times every stage from camera frame to spoken or felt cue, on this phone. Result appears on the main screen and is saved in Files > EchoGuide.")
                }

                Section {
                    ForEach(Array(BenchmarkTasks.all.enumerated()), id: \.offset) { i, t in
                        Button {
                            Task {
                                await runtime.startTrial(task: t.task, mode: t.mode)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(i + 1). \(t.task)")
                                Text(t.mode.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Run a benchmark task")
                } footer: {
                    Text("Starts the timer and switches to the right mode. Tap Success or Failed on the main screen when done. The same tasks are in benchmarks/PROTOCOL.md for other apps.")
                }

                Section("Results (\(results.count))") {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(r.product): \(r.task)").font(.subheadline).lineLimit(2)
                            Text("\(r.success ? "✓" : "✗") \(String(format: "%.1f", r.durationS)) s · first cue \(r.firstCueMs.map { String(format: "%.1f s", $0 / 1000) } ?? "none") · \(r.userPrompts) prompts\(r.offline ? " · offline" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Add a result from another app") { showManual = true }
                    if !results.isEmpty {
                        ShareLink("Export CSV", item: csv)
                        Button("Clear results", role: .destructive) {
                            Task {
                                await runtime.trials.clear()
                                await reload()
                            }
                        }
                    }
                }

                Section {
                    Button("Replay the introduction") {
                        AppSettings.onboarded = false
                        dismiss()
                    }
                } footer: {
                    Text("Shows the setup steps the next time EchoGuide opens.")
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await reload() }
            .sheet(isPresented: $showManual, onDismiss: { Task { await reload() } }) {
                ManualResultView(trials: runtime.trials)
            }
        }
    }

    private func reload() async {
        results = await runtime.trials.results.reversed()
        csv = await runtime.trials.csv
    }
}

/// Log a trial timed by hand on a competitor app, same columns as ours.
struct ManualResultView: View {
    let trials: TrialRecorder
    @Environment(\.dismiss) private var dismiss
    static let products = ["Google Gemini Guided Vision", "Apple Live Recognition / Point and Speak", "Be My Eyes (Be My AI)", "Microsoft Seeing AI", "Aira", "Other"]
    @State private var product = products[0]
    @State private var taskIndex = 0
    @State private var seconds = 30.0
    @State private var success = true
    @State private var firstCue = 3.0
    @State private var prompts = 1
    @State private var offline = false
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Picker("Product", selection: $product) { ForEach(Self.products, id: \.self) { Text($0) } }
                Picker("Task", selection: $taskIndex) {
                    ForEach(Array(BenchmarkTasks.all.enumerated()), id: \.offset) { i, t in Text("\(i + 1). \(t.task)").tag(i) }
                }
                Toggle("Succeeded", isOn: $success)
                Stepper("Total time: \(Int(seconds)) s", value: $seconds, in: 1...600, step: 1)
                Stepper("First useful cue: \(String(format: "%.1f", firstCue)) s", value: $firstCue, in: 0...120, step: 0.5)
                Stepper("Times the user had to ask: \(prompts)", value: $prompts, in: 0...50)
                Toggle("Was offline", isOn: $offline)
                TextField("Notes", text: $notes)
            }
            .navigationTitle("Other app result")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = BenchmarkTasks.all[taskIndex]
                        let r = TrialResult(product: product, task: t.task, mode: t.mode, startedAt: Date(), durationS: seconds,
                                            success: success, firstCueMs: firstCue * 1000, spokenLines: 0, userPrompts: prompts,
                                            cloudCalls: 0, offline: offline, notes: notes)
                        Task {
                            await trials.addManual(r)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
