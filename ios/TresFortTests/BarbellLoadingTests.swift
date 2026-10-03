import XCTest
@testable import TresFort

final class BarbellLoadingTests: XCTestCase {
    func testPlatesIncludeBothSidesAndRespectSelectedBar() throws {
        let result = try XCTUnwrap(BarbellLoading.breakdown(target: 185))
        XCTAssertEqual(result.perSide, [.init(weight: 45, count: 1), .init(weight: 25, count: 1)])
        XCTAssertEqual(result.achievableWeight, 185)
        XCTAssertEqual(BarbellLoading.breakdown(target: 95, bar: 35)?.perSide,
                       [.init(weight: 25, count: 1), .init(weight: 5, count: 1)])
    }
    func testFractionalTargetIsNeverRoundedUpAndInvalidInputHasNoAdvice() {
        XCTAssertEqual(BarbellLoading.breakdown(target: 137.5)?.achievableWeight, 135)
        XCTAssertEqual(BarbellLoading.breakdown(target: 137.5)?.remainingWeight, 2.5)
        XCTAssertNil(BarbellLoading.breakdown(target: 35))
        XCTAssertNil(BarbellLoading.breakdown(target: .infinity))
        XCTAssertNil(BarbellLoading.breakdown(target: 100, bar: 0))
    }
    func testWarmupIsDeterministicBoundedAndDeduplicatesLightLoads() {
        XCTAssertEqual(BarbellLoading.warmup(target: 185).map(\.weight), [45, 90, 135])
        XCTAssertEqual(BarbellLoading.warmup(target: 185).map(\.reps), [8, 5, 3])
        XCTAssertEqual(BarbellLoading.warmup(target: 50).map(\.weight), [45])
        XCTAssertEqual(BarbellLoading.warmup(target: 45).map(\.weight), [45])
        XCTAssertTrue(BarbellLoading.warmup(target: 25).isEmpty)
    }

    // A kg slot keeps its load in kg: a 20 kg bar and kg plates, never lb.
    func testKgLoadUsesTwentyKgBarAndKgPlates() throws {
        let result = try XCTUnwrap(BarbellLoading.breakdown(target: 100, unit: .kg))
        XCTAssertEqual(result.perSide, [.init(weight: 25, count: 1), .init(weight: 15, count: 1)])
        XCTAssertEqual(result.perSide.reduce(0) { $0 + $1.weight * Double($1.count) }, 40)
        XCTAssertEqual(result.achievableWeight, 100)
        XCTAssertEqual(result.remainingWeight, 0)
        XCTAssertEqual(BarbellLoading.breakdown(target: 102.5, unit: .kg)?.perSide,
                       [.init(weight: 25, count: 1), .init(weight: 15, count: 1), .init(weight: 1.25, count: 1)])
        XCTAssertEqual(BarbellLoading.breakdown(target: 60, unit: .kg, bar: 15)?.perSide,
                       [.init(weight: 20, count: 1), .init(weight: 2.5, count: 1)])
        XCTAssertEqual(BarbellLoading.breakdown(target: 20, unit: .kg)?.perSide, [])
    }
    func testKgFractionalTargetShowsRemainderAndBelowBarHasNoAdvice() {
        XCTAssertEqual(BarbellLoading.breakdown(target: 101, unit: .kg)?.achievableWeight, 100)
        XCTAssertEqual(BarbellLoading.breakdown(target: 101, unit: .kg)?.remainingWeight, 1)
        XCTAssertNil(BarbellLoading.breakdown(target: 15, unit: .kg))
        XCTAssertTrue(BarbellLoading.warmup(target: 15, unit: .kg).isEmpty)
    }
    func testKgWarmupRoundsDownToLoadableTwoAndAHalfKgSteps() {
        let steps = BarbellLoading.warmup(target: 105, unit: .kg)
        XCTAssertEqual(steps.map(\.weight), [20, 52.5, 77.5])
        XCTAssertEqual(steps.map(\.reps), [8, 5, 3])
        for step in steps {
            XCTAssertEqual(BarbellLoading.breakdown(target: step.weight, unit: .kg)?.remainingWeight, 0)
        }
        XCTAssertEqual(BarbellLoading.warmup(target: 22.5, unit: .kg).map(\.weight), [20])
        XCTAssertEqual(BarbellLoading.warmup(target: 20, unit: .kg).map(\.weight), [20])
    }
    func testPlateLabelsNameTheUnitInUse() {
        XCTAssertEqual(BarbellLoading.plateLabel(1.25, unit: .kg), "1.25 kg")
        XCTAssertEqual(BarbellLoading.plateLabel(2.5, unit: .lb), "2.5 lb")
        XCTAssertEqual(BarbellLoading.platesNote(.lb), "Uses 45, 35, 25, 10, 5 and 2.5 lb plates.")
        XCTAssertEqual(BarbellLoading.platesNote(.kg), "Uses 25, 20, 15, 10, 5, 2.5 and 1.25 kg plates.")
    }
}
