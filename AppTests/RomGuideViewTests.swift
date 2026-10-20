import AndroidDriver
import Testing
@testable import Tandem

@MainActor
@Suite struct RomGuideViewTests {
    @Test func stepsSheetCardOrder() {
        #expect(RomStepsSheet.cards(for: .forManufacturer("vivo")).map(\.brand) == ["vivo / iQOO", "小米", "OPPO / 一加 / realme"])
        #expect(RomStepsSheet.cards(for: .forManufacturer("xiaomi")).map(\.brand) == ["小米", "OPPO / 一加 / realme", "vivo / iQOO"])
        #expect(RomStepsSheet.cards(for: .forManufacturer("samsung")).map(\.brand) == ["该设备", "小米", "OPPO / 一加 / realme", "vivo / iQOO"])
    }
}
