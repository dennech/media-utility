import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: DownloadViewModel
    @FocusState private var linkFocused: Bool
    @State private var showOptions = false
    @State private var showTools = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "waveform.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.teal)
                        .accessibilityHidden(true)
                    Text("Media Utility").font(.title.bold())
                    Spacer()
                    Button { showTools.toggle() } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Downloader information")
                    .help("Downloader and privacy")
                    .popover(isPresented: $showTools) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Downloader").font(.headline)
                            Text(viewModel.updateState.infoText)
                            Text(viewModel.toolchainStatusText)
                            Divider()
                            Text("Downloads start anonymously. If a site requires sign-in, you can approve a separate site session for that download.")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 280, alignment: .leading)
                        .padding()
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Media link").font(.headline)
                    TextField("Paste a video or audio URL", text: $viewModel.urlText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($linkFocused)
                        .onSubmit(viewModel.startDownload)
                        .disabled(viewModel.isWorking)
                }

                Picker("Save as", selection: $viewModel.selectedMode) {
                    ForEach(DownloadMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isWorking)

                if viewModel.selectedMode == .videoMov {
                    DisclosureGroup("Video options", isExpanded: $showOptions) {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Keep original streams when compatible", isOn: $viewModel.preserveOriginalWhenPossible)
                            Picker("Encoding quality", selection: $viewModel.videoCompressionPreset) {
                                ForEach(VideoCompressionPreset.allCases) { Text($0.title).tag($0) }
                            }
                            .help("Applies when the video is encoded again.")
                            .fixedSize()
                        }
                        .padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(viewModel.isWorking)
                }

                Divider()
                HStack(alignment: .center) {
                    if viewModel.isWorking {
                        ProgressView().controlSize(.small)
                        Text(viewModel.status.detail).font(.callout)
                        Spacer()
                        Button("Cancel", action: viewModel.cancelCurrentOperation)
                            .keyboardShortcut(.cancelAction)
                    } else {
                        if viewModel.status.kind == .idle {
                            Label(viewModel.status.detail == DownloadStatus.idle.detail ? "Ready" : viewModel.status.detail,
                                  systemImage: "circle.dotted")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download", action: viewModel.startDownload)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if viewModel.isWorking, let fraction = viewModel.processingProgress ?? viewModel.downloadProgress {
                    ProgressView(value: fraction) {
                        Text(viewModel.processingProgress == nil ? "Download" : "Conversion")
                    } currentValueLabel: { Text(fraction, format: .percent).monospacedDigit() }
                    .tint(.teal)
                }
                if viewModel.status.kind == .failure || viewModel.status.kind == .success {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(viewModel.status.title, systemImage: viewModel.status.kind == .failure ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.headline)
                        Text(viewModel.status.detail).textSelection(.enabled)
                        if viewModel.lastSavedURL != nil {
                            HStack {
                                Button("Open", action: viewModel.openLastSaved)
                                Button("Show in Finder", action: viewModel.revealLastSaved)
                            }
                        }
                    }
                }
            }
            .padding(26)
        }
        .background(alignment: .topTrailing) {
            if !reduceTransparency {
                LinearGradient(colors: [.indigo.opacity(viewModel.isWorking ? 0.16 : 0.035),
                                        .teal.opacity(viewModel.isWorking ? 0.11 : 0.02), .clear],
                               startPoint: .topTrailing, endPoint: .bottomLeading)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.1), value: viewModel.isWorking)
                    .ignoresSafeArea()
            }
        }
        .frame(minWidth: 420, idealWidth: 500, minHeight: 310, idealHeight: 360)
        .onAppear { linkFocused = true }
    }
}
