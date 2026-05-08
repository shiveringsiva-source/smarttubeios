import SwiftUI
import SmartTubeIOSCore
import os
#if canImport(UIKit)
import UIKit
#endif

private let menuLog = CrashlyticsLogger(category: "PlayerMenu")

// MARK: - PlayerView overlay sheets
//
// Pure-SwiftUI overlays rendered inside the player's ZStack so no UIKit
// sheet presentation fires onDisappear and tears down playback.
//
// Includes:
//   • moreMenuOverlay      — all top-bar actions + share/download
//   • descriptionOverlay   — scrollable video description
//   • commentsOverlay      — video comments list
//   • loadComments()       — async comment fetching
//   • descriptionAttributedString(_:) — URL linkification helper

extension PlayerView {

    // MARK: - More menu overlay

    /// Pure-SwiftUI bottom sheet combining all top-bar controls + Share/Download.
    /// Rendered inside the player's ZStack so no UIKit sheet presentation
    /// fires onDisappear and teardowns the action sheet mid-animation.
    var moreMenuOverlay: some View {
        let currentVideo = vm.playerInfo?.video ?? video
        menuLog.notice("[moreMenu] rendering — video=\(currentVideo.id) availableFormats=\(vm.availableFormats.count) isSignedIn=\(authService.isSignedIn)")
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    menuLog.notice("[moreMenu] background tap — dismissing")
                    showMoreMenu = false
                }

            GeometryReader { geo in
            VStack(spacing: 0) {
                // Speed
                Button {
                    menuLog.notice("[moreMenu] Speed row tapped — closing moreMenu, opening speedPicker")
                    showMoreMenu = false
                    showSpeedPicker = true
                } label: {
                    HStack {
                        Label("Playback Speed", systemImage: "speedometer")
                        Spacer()
                        Text(store.settings.playbackSpeed == 1.0 ? "Normal"
                             : "\(store.settings.playbackSpeed, specifier: "%.2g")×")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("player.moreMenu.speedRow")
                #if os(tvOS)
                .background(moreMenuFocusedRow == .speed ? Color.white.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($moreMenuFocusedRow, equals: .speed)
                #endif
                Divider()
                // Quality (only when formats are available)
                if !vm.availableFormats.isEmpty {
                    Button {
                        showMoreMenu = false
                        showQualityPicker = true
                    } label: {
                        HStack {
                            Label("Quality", systemImage: "4k.tv")
                            Spacer()
                            Text(vm.selectedFormat?.qualityLabel ?? "Auto")
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    #if os(tvOS)
                    .background(moreMenuFocusedRow == .quality ? Color.white.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($moreMenuFocusedRow, equals: .quality)
                    #endif
                    Divider()
                }
                // Like / Dislike (requires sign-in)
                if authService.isSignedIn {
                    HStack(spacing: 0) {
                        Button {
                            vm.like()
                            showMoreMenu = false
                        } label: {
                            Label(
                                vm.likeStatus == .like ? "Liked" : "Like",
                                systemImage: vm.likeStatus == .like
                                    ? "\(AppSymbol.thumbsUp).fill" : AppSymbol.thumbsUp
                            )
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundStyle(vm.likeStatus == .like ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .background(moreMenuFocusedRow == .like ? Color.white.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($moreMenuFocusedRow, equals: .like)
                        #endif
                        Divider().frame(height: 44)
                        Button {
                            vm.dislike()
                            showMoreMenu = false
                        } label: {
                            Label(
                                vm.likeStatus == .dislike ? "Disliked" : "Dislike",
                                systemImage: vm.likeStatus == .dislike
                                    ? "\(AppSymbol.thumbsDown).fill" : AppSymbol.thumbsDown
                            )
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundStyle(vm.likeStatus == .dislike ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #if os(tvOS)
                        .background(moreMenuFocusedRow == .dislike ? Color.white.opacity(0.15) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .focused($moreMenuFocusedRow, equals: .dislike)
                        #endif
                    }
                    Divider()
                }
                // Share
                #if os(iOS)
                Button {
                    showMoreMenu = false
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(currentVideo.id)") {
                        presentShareSheet(url: url)
                    }
                } label: {
                    Label("Share", systemImage: AppSymbol.share)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                Divider()
                #endif
                // Sleep timer
                Button {
                    menuLog.notice("[moreMenu] Sleep Timer row tapped — closing moreMenu, opening sleepTimerPicker")
                    showMoreMenu = false
                    showSleepTimerPicker = true
                } label: {
                    HStack {
                        Label("Sleep Timer", systemImage: "moon.zzz")
                        Spacer()
                        if let mins = vm.sleepTimerMinutes {
                            Text("\(mins) min")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Off")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("player.moreMenu.sleepTimerRow")
                #if os(tvOS)
                .background(moreMenuFocusedRow == .sleepTimer ? Color.white.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($moreMenuFocusedRow, equals: .sleepTimer)
                #endif
                Divider()
                #if !os(tvOS)
                // Download
                Button {
                    showMoreMenu = false
                    downloadService.download(video: currentVideo)
                } label: {
                    Group {
                        if downloadService.state.isActive {
                            Label("Downloading…", systemImage: AppSymbol.download)
                        } else {
                            Label("Download to Gallery", systemImage: AppSymbol.download)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .disabled(downloadService.state.isActive)
                Divider()
                // Captions (only when tracks are available)
                if !vm.availableCaptions.isEmpty {
                    Button {
                        showMoreMenu = false
                        showCaptionPicker = true
                    } label: {
                        HStack {
                            Label("Captions", systemImage: "captions.bubble")
                            Spacer()
                            Text(vm.selectedCaption.map {
                                $0.isAutoGenerated ? "\($0.name) (auto)" : $0.name
                            } ?? "Off")
                            .foregroundStyle(.secondary)
                        }
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    Divider()
                }
                // Audio track (only when multiple tracks are available)
                if vm.availableAudioTracks.count > 1 {
                    Button {
                        showMoreMenu = false
                        showAudioTrackPicker = true
                    } label: {
                        HStack {
                            Label("Audio Track", systemImage: "waveform")
                            Spacer()
                            Text(vm.selectedAudioTrack.map {
                                $0.isOriginal ? "\($0.name) (Original)" : $0.name
                            } ?? "Auto")
                            .foregroundStyle(.secondary)
                        }
                        .padding()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("player.moreMenu.audioTrackRow")
                    Divider()
                }
                #endif
                // Description
                let descriptionText = currentVideo.description ?? ""
                if !descriptionText.isEmpty {
                    Button {
                        showMoreMenu = false
                        showDescriptionSheet = true
                    } label: {
                        Label("Description", systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    #if os(tvOS)
                    .background(moreMenuFocusedRow == .description ? Color.white.opacity(0.15) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .focused($moreMenuFocusedRow, equals: .description)
                    #endif
                    Divider()
                }
                Button {
                    showMoreMenu = false
                    showCommentsSheet = true
                    if videoComments.isEmpty && !isLoadingComments {
                        loadComments()
                    }
                } label: {
                    Label("Comments", systemImage: "bubble.left.and.bubble.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                #if os(tvOS)
                .background(moreMenuFocusedRow == .comments ? Color.white.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($moreMenuFocusedRow, equals: .comments)
                #endif
                Divider()
                Button { showMoreMenu = false } label: {                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .fontWeight(.semibold)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("player.moreMenu.cancel")
                #if os(tvOS)
                .background(moreMenuFocusedRow == .cancel ? Color.white.opacity(0.15) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .focused($moreMenuFocusedRow, equals: .cancel)
                #endif
            }
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxHeight: geo.size.height * 0.75)
            #if os(tvOS)
            .onMoveCommand { direction in
                let rows = moreMenuVisibleRows
                let current = moreMenuFocusedRow ?? .speed
                // Left/right within the Like ↔ Dislike pair.
                if current == .like, direction == .right { moreMenuFocusedRow = .dislike; return }
                if current == .dislike, direction == .left { moreMenuFocusedRow = .like; return }
                // For up/down, treat .dislike as .like (same vertical row).
                let verticalCurrent: MoreMenuRow = current == .dislike ? .like : current
                guard let idx = rows.firstIndex(of: verticalCurrent) else {
                    moreMenuFocusedRow = .speed
                    return
                }
                switch direction {
                case .down where idx < rows.count - 1:
                    moreMenuFocusedRow = rows[idx + 1]
                case .up where idx > 0:
                    moreMenuFocusedRow = rows[idx - 1]
                default:
                    break
                }
            }
            .onExitCommand {
                menuLog.notice("[moreMenu] onExitCommand fired — dismissing via Menu button")
                showMoreMenu = false
            }
            .onAppear {
                menuLog.notice("[moreMenu] overlay appeared — explicit D-pad navigation via onMoveCommand + moreMenuFocusedRow")
            }
            .onDisappear {
                menuLog.notice("[moreMenu] overlay disappeared")
            }
            #endif
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Description overlay

    var descriptionOverlay: some View {
        let currentVideo = vm.playerInfo?.video ?? video
        let description = currentVideo.description ?? ""
        return ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showDescriptionSheet = false }

            VStack(spacing: 0) {
                HStack {
                    Button { showDescriptionSheet = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Description")
                        .fontWeight(.semibold)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 4)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(currentVideo.title)
                            .font(.headline)
                        if !currentVideo.channelTitle.isEmpty {
                            Text(currentVideo.channelTitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !description.isEmpty {
                            Text(descriptionAttributedString(description))
                                .font(.body)
                        } else {
                            Text("No description available.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .frame(maxHeight: 400)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
    }

    func descriptionAttributedString(_ string: String) -> AttributedString {
        var attributed = AttributedString(string)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        let nsString = string as NSString
        let matches = detector.matches(in: string, range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard let range = Range(match.range, in: string),
                  let url = match.url,
                  let attrRange = Range(range, in: attributed) else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }

    // MARK: - Comments overlay

    var commentsOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { showCommentsSheet = false }

            VStack(spacing: 0) {
                HStack {
                    Button { showCommentsSheet = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Comments")
                        .fontWeight(.semibold)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 4)
                Divider()
                if isLoadingComments {
                    ProgressView()
                        .padding(40)
                } else if videoComments.isEmpty {
                    Text("No comments available.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(videoComments) { comment in
                                CommentRowView(comment: comment)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 400)
                }
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
    }

    // MARK: - Comments loading

    func loadComments() {
        let videoId = (vm.playerInfo?.video ?? video).id
        isLoadingComments = true
        Task {
            do {
                let fetched = try await commentsAPI.fetchComments(videoId: videoId)
                videoComments = fetched
            } catch {
                // Comments unavailable — empty state shown
            }
            isLoadingComments = false
        }
    }
}
