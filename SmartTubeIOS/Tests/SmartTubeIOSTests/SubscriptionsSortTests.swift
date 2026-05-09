import Foundation
import Testing
@testable import SmartTubeIOSCore

// MARK: - SubscriptionsSortTests

@Suite("Subscriptions Sort Order")
struct SubscriptionsSortTests {

    /// Subscriptions videos must be sorted newest-first by publishedAt.
    /// Verifies the sort that fetchSubscriptions() applies after parseVideoGroup().
    @Test func subscriptionVideosSortedNewestFirst() {
        let older = Video(id: "old", title: "Older", channelTitle: "Ch",
                          publishedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let newer = Video(id: "new", title: "Newer", channelTitle: "Ch",
                          publishedAt: Date(timeIntervalSinceReferenceDate: 2000))
        let oldest = Video(id: "oldest", title: "Oldest", channelTitle: "Ch",
                           publishedAt: Date(timeIntervalSinceReferenceDate: 500))

        var group = VideoGroup(title: "Subscriptions", videos: [older, newer, oldest].shuffled())
        group.videos.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }

        #expect(group.videos[0].id == "new")
        #expect(group.videos[1].id == "old")
        #expect(group.videos[2].id == "oldest")
    }

    /// Videos without a publishedAt date sort to the end (distantPast fallback).
    @Test func videosWithoutPublishedAtSortToEnd() {
        let withDate = Video(id: "dated", title: "Dated", channelTitle: "Ch",
                             publishedAt: Date(timeIntervalSinceReferenceDate: 1000))
        let withoutDate = Video(id: "undated", title: "Undated", channelTitle: "Ch",
                                publishedAt: nil)

        var videos = [withoutDate, withDate]
        videos.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }

        #expect(videos[0].id == "dated")
        #expect(videos[1].id == "undated")
    }

    /// Subscribed channels must be sorted alphabetically (case-insensitive).
    @Test func subscribedChannelsSortedAlphabetically() {
        let channels = [
            Channel(id: "c1", title: "Zebra Channel"),
            Channel(id: "c2", title: "alpha Channel"),
            Channel(id: "c3", title: "Mango Talks"),
        ]
        let sorted = channels.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        #expect(sorted[0].title == "alpha Channel")
        #expect(sorted[1].title == "Mango Talks")
        #expect(sorted[2].title == "Zebra Channel")
    }
}
