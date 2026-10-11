import SwiftUI
import EditorCore

struct ProxyQueueView: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss

    private var running: Bool { store.proxyGenerationTask != nil }
    private var unfinished: Bool { store.proxyJobs.contains { $0.state != .completed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Proxy queue").font(.title2.bold())
            Text("Jobs are saved with this project. Resume them when ready after reopening. Completed proxy files stay on disk when entries are cleared.")
                .foregroundStyle(.secondary)
            if store.proxyJobs.isEmpty {
                ContentUnavailableView("No proxy jobs", systemImage: "film.stack", description: Text("Select video sources in the media bin and choose Create proxies."))
                    .frame(height: 180)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(store.proxyJobs) { job in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(job.sourceSnapshot.name).font(.headline)
                                    Spacer()
                                    Text(stateLabel(job.state)).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                                }
                                Text("\(job.preset == .proResProxy ? "ProRes Proxy" : "H.264") · \(resolutionLabel(job.scaleDivisor)) · \(job.outputURL.lastPathComponent)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(job.outputURL.deletingLastPathComponent().path)
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                if let progress = store.proxyQueueProgress[job.id], job.state == .running {
                                    ProgressView(value: progress.fraction)
                                    Text(progress.stage).font(.caption)
                                }
                                if let message = job.message {
                                    Text(message).font(.caption).foregroundStyle(job.state == .failed ? .red : .secondary)
                                        .textSelection(.enabled)
                                }
                                if job.state.canResume {
                                    HStack {
                                        Button("Retry") { store.retryProxyJob(id: job.id) }
                                        Button("Retry to new file") { store.retryProxyJob(id: job.id, freshDestination: true) }
                                            .help("Use a new filename and preserve any existing output file.")
                                        Button("Remove job") { store.removeProxyJob(id: job.id) }
                                            .help("Remove this queue entry and preserve its output file and registered proxy.")
                                    }.disabled(running || store.isRelinkingProxy)
                                }
                            }
                            Divider()
                        }
                    }.padding(.trailing, 8)
                }.frame(minHeight: 180, maxHeight: 380)
            }
            HStack {
                Button("Clear completed", action: store.clearFinishedProxyJobs)
                    .disabled(running || !store.proxyJobs.contains { $0.state == .completed })
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if running {
                    Button("Cancel queue", action: store.cancelProxyQueue)
                } else {
                    Button("Resume queue") { store.runProxyQueue() }
                        .disabled(!unfinished || store.isRelinkingProxy)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }.padding(24).frame(width: 650)
    }

    private func stateLabel(_ state: ProxyGenerationJobState) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Running"
        case .interrupted: "Interrupted"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .completed: "Complete"
        }
    }

    private func resolutionLabel(_ divisor: Int) -> String {
        switch divisor { case 1: "Full resolution"; case 2: "Half resolution"; default: "Quarter resolution" }
    }
}
