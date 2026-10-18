import Testing
@testable import AndroidDriver

@Suite struct RomGuideTests {
    @Test func xiaomi() {
        let g = RomGuide.forManufacturer("Xiaomi")
        #expect(g.brand == "小米")
        #expect(g.steps.count == 2)
    }
    @Test func redmiAndPoco() {
        #expect(RomGuide.forManufacturer("Redmi").brand == "小米")
        #expect(RomGuide.forManufacturer("POCO").brand == "小米")
    }
    @Test func oppoFamily() {
        #expect(RomGuide.forManufacturer("OnePlus").brand == "OPPO / 一加 / realme")
        #expect(RomGuide.forManufacturer("OPPO").steps.last == "关闭「禁止权限监控」")
    }
    @Test func vivo() {
        #expect(RomGuide.forManufacturer("vivo").steps.last == "打开「USB 模拟点击」")
        #expect(RomGuide.forManufacturer("iQOO").brand == "vivo / iQOO")
    }
    @Test func fallback() {
        #expect(RomGuide.forManufacturer("Google").brand == "该设备")
        #expect(RomGuide.forManufacturer("").brand == "该设备")
    }
}
