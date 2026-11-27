import XCTest
import CoreAudio
import CMixerDSP
@testable import AudioCore

final class MixerTests: XCTestCase {
    func testOlderSettingsHaveAnEmptyMixAndKeepTheirBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let clean = try encoder.encode(AudioSettings())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: clean) as? [String: Any])
        legacy.removeValue(forKey: "mix")
        let decoded = try JSONDecoder().decode(AudioSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.mix.apps.isEmpty)
        XCTAssertEqual(try encoder.encode(decoded), clean)
    }

    func testOnlyAdjustedAppsAreStoredAndVolumesAreClamped() throws {
        var mix = MixSettings()
        mix.set("a", volume: 3, muted: false, name: "A")
        mix.set("b", volume: -1, muted: false, name: "B")
        mix.set("c", volume: 1, muted: true, name: "C")
        XCTAssertEqual(mix.apps.keys.sorted(), ["b", "c"])
        XCTAssertEqual(mix.apps["b"]?.volume, 0)
        XCTAssertEqual(mix.apps["c"]?.gain, 0)
        XCTAssertEqual(mix.apps["c"]?.volume, 1)
        mix.set("c", volume: 1, muted: false, name: "C")
        mix.reset("b")
        XCTAssertTrue(mix.apps.isEmpty)

        let saved = Data("""
        {"a":{"volume":4,"muted":false,"name":"A"},"b":{"volume":-2,"muted":true,"name":"B"}}
        """.utf8)
        let decoded = try JSONDecoder().decode(MixSettings.self, from: saved)
        XCTAssertEqual(decoded.apps.keys.sorted(), ["b"])
        XCTAssertEqual(decoded.apps["b"]?.volume, 0)
    }

    func testEncodedOrderDoesNotDependOnTheOrderOfAdjustments() throws {
        func mix(_ ids: [String]) -> MixSettings {
            var result = MixSettings()
            for id in ids { result.set(id, volume: 0.4, muted: false, name: id) }
            return result
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(mix(["z", "a"])), try encoder.encode(mix(["a", "z"])))
    }

    func testGroupsHelpersByTheirOwnerAndKeepsSystemSoundsTogether() throws {
        let groups = groupMixProcesses([
            MixProcess(objectID: 70, pid: 700, bundleID: "org.browser", ancestors: [], isPlaying: false),
            MixProcess(objectID: 72, pid: 702, bundleID: "org.browser.helper", ancestors: [701, 700], isPlaying: false),
            MixProcess(objectID: 71, pid: 701, bundleID: "com.apple.WebKit.GPU", ancestors: [700], isPlaying: true),
            MixProcess(objectID: 80, pid: 800, bundleID: "org.unowned.helper", ancestors: [], isPlaying: true, name: "Orphan Helper"),
            MixProcess(objectID: 90, pid: 900, bundleID: "com.apple.alertd", ancestors: [], isPlaying: true),
            MixProcess(objectID: 91, pid: 901, bundleID: nil, ancestors: [], isPlaying: false),
            MixProcess(objectID: 30, pid: 300, bundleID: "gg.tico.whopper", ancestors: [], isPlaying: true),
            MixProcess(objectID: 31, pid: 301, bundleID: nil, ancestors: [300], isPlaying: true),
        ], apps: [
            MixRunningApp(pid: 700, id: "org.browser", name: "Browser"),
            MixRunningApp(pid: 750, id: "org.idle", name: "Idle"),
        ], ownPID: 300)

        let app = try XCTUnwrap(groups.first { $0.id == "org.browser" })
        XCTAssertEqual(app.name, "Browser")
        XCTAssertTrue(app.isPlaying)
        XCTAssertEqual(app.processIDs, [70, 71, 72])
        XCTAssertEqual(groups.first { $0.id == "org.unowned.helper" }?.name, "Orphan Helper")
        XCTAssertEqual(groups.first { $0.id == MixApp.systemID }?.processIDs, [90, 91])
        XCTAssertEqual(groups.first { $0.id == "org.idle" }?.isPlaying, false)
        XCTAssertEqual(groups.first { $0.id == "org.idle" }?.processIDs, [])
        XCTAssertEqual(groups.count, 4)
    }

    func testAudioProcessBundleWinsOverTheLauncherAndKeepsBrowserHelpersTogether() throws {
        let apps = [
            MixRunningApp(pid: 10, id: "net.whatsapp.WhatsApp", name: "WhatsApp"),
            MixRunningApp(pid: 20, id: "gg.tico.brwsrrr", name: "brwsrrr"),
            MixRunningApp(pid: 30, id: "com.apple.Terminal", name: "Terminal"),
        ]
        let groups = groupMixProcesses([
            MixProcess(objectID: 101, pid: 11, bundleID: "net.whatsapp.WhatsApp", ancestors: [30], isPlaying: false),
            MixProcess(objectID: 102, pid: 21, bundleID: "com.apple.WebKit.GPU", ancestors: [20], isPlaying: true),
            MixProcess(objectID: 103, pid: 22, bundleID: "com.apple.WebKit.WebContent", ancestors: [20], isPlaying: false),
        ], apps: apps, ownPID: 50)

        XCTAssertEqual(groups.first { $0.id == "net.whatsapp.WhatsApp" }?.processIDs, [101])
        let browser = try XCTUnwrap(groups.first { $0.id == "gg.tico.brwsrrr" })
        XCTAssertEqual(browser.processIDs, [102, 103])
        XCTAssertTrue(browser.isPlaying)
        XCTAssertEqual(groups.first { $0.id == "com.apple.Terminal" }?.processIDs, [])
        var mix = MixSettings()
        mix.set(browser.id, volume: 0.3, muted: false, name: browser.name)
        XCTAssertEqual(MixTapPlan(mix: mix, live: groups).apps.first?.processes, [102, 103])
    }

    func testTapPlanFollowsAdjustedLiveProcessesAndKeepsFailedAppsInGlobalTap() {
        var mix = MixSettings()
        for id in ["a", "b", "closed"] { mix.set(id, volume: 0.5, muted: false, name: id) }
        let live = [
            MixApp(id: "new", name: "New App", isPlaying: true, processIDs: [40]),
            MixApp(id: "b", name: "B", isPlaying: true, processIDs: [30]),
            MixApp(id: "a", name: "A", isPlaying: false, processIDs: [20, 10]),
        ]
        XCTAssertTrue(MixTapPlan(mix: MixSettings(), live: live).apps.isEmpty)
        let plan = MixTapPlan(mix: mix, live: live)
        XCTAssertEqual(plan.apps.map(\.id), ["a", "b"])
        let resolved = plan.resolve(own: [1]) { $0.id == "a" ? $0.processes : nil }
        XCTAssertEqual(resolved.taps, [[10, 20]])
        XCTAssertEqual(resolved.ids, ["a"])
        XCTAssertEqual(resolved.exclusions, [1, 10, 20])
        XCTAssertEqual(resolved.failed, ["b"])
        XCTAssertNotEqual(plan, MixTapPlan(mix: mix, live: Array(live.dropLast())))
    }

    func testLinearGainRampRetargetsFromTheCurrentSample() {
        var ramp = WhoprrrGainRamp(gain: 1, target: 1, step: 0, remaining: 0)
        whoprrr_gain_target(&ramp, 0, 4)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 0.75)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 0.5)
        whoprrr_gain_target(&ramp, 1, 4)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 0.625)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 0.75)
        whoprrr_gain_target(&ramp, 1, 4)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 0.875)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 1)
        XCTAssertEqual(whoprrr_gain_next(&ramp), 1)
    }

    func testSyntheticBuffersSumGlobalAndAppWithIndependentGain() throws {
        let streams = [
            WhoprrrTapStream(firstBuffer: 1, planar: false, gain: 1),
            WhoprrrTapStream(firstBuffer: 2, planar: true, gain: 0.5),
        ]
        let mixer = try XCTUnwrap(whoprrr_mixer_create(streams, 2, 4, 2, false))
        defer { whoprrr_mixer_destroy(mixer) }
        let input = AudioBufferList.allocate(maximumBuffers: 4)
        defer { input.unsafeMutablePointer.deallocate() }
        var global: [Float] = [1, 2, 3, 4]
        var appLeft: [Float] = [2, 4]
        var appRight: [Float] = [4, 8]
        var left: [Float] = [0, 0]
        var right: [Float] = [0, 0]
        // The first buffer is a physical input. Mixer channels must never use it.
        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        global.withUnsafeMutableBytes { global in
            appLeft.withUnsafeMutableBytes { appLeft in
                appRight.withUnsafeMutableBytes { appRight in
                    input[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: global.baseAddress)
                    input[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: appLeft.baseAddress)
                    input[3] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: appRight.baseAddress)
                    XCTAssertEqual(whoprrr_mixer_sum(mixer, input.unsafePointer, &left, &right, 2), 2)
                    XCTAssertEqual(left, [2, 5])
                    XCTAssertEqual(right, [4, 8])

                    whoprrr_mixer_set_gain(mixer, 1, 0)
                    XCTAssertEqual(whoprrr_mixer_sum(mixer, input.unsafePointer, &left, &right, 2), 2)
                    XCTAssertEqual(left, [1.5, 3])
                    XCTAssertEqual(right, [3, 4])

                    // A quiet tap may have no samples while still reserving its buffer slots.
                    input[2].mData = nil
                    XCTAssertEqual(whoprrr_mixer_sum(mixer, input.unsafePointer, &left, &right, 2), 2)
                    XCTAssertEqual(left, [1, 3])
                    XCTAssertEqual(right, [2, 4])
                    XCTAssertFalse(whoprrr_mixer_layout_failed(mixer))

                    input[2].mNumberChannels = 2
                    XCTAssertEqual(whoprrr_mixer_sum(mixer, input.unsafePointer, &left, &right, 2), 0)
                    XCTAssertTrue(whoprrr_mixer_layout_failed(mixer))
                }
            }
        }
    }

    func testOutputFadesOnBothSidesOfATopologyChange() throws {
        let mixer = try XCTUnwrap(whoprrr_mixer_create(nil, 0, 0, 4, true))
        defer { whoprrr_mixer_destroy(mixer) }
        var left: [Float] = [1, 1, 1, 1]
        var right = left
        whoprrr_mixer_finish(mixer, &left, &right, 4)
        XCTAssertEqual(left, [0.25, 0.5, 0.75, 1])
        XCTAssertEqual(right, left)
        whoprrr_mixer_fade_out(mixer)
        left = [1, 1, 1, 1]
        right = left
        whoprrr_mixer_finish(mixer, &left, &right, 4)
        XCTAssertEqual(left, [0.75, 0.5, 0.25, 0])
        XCTAssertEqual(right, left)
        XCTAssertTrue(whoprrr_mixer_is_faded_out(mixer))
    }
}
