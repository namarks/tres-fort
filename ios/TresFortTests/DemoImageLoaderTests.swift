import XCTest
import UIKit
@testable import TresFort

@MainActor
final class DemoImageLoaderTests: XCTestCase {
    private func loader(bundle: @escaping (String) -> UIImage? = { _ in nil }) -> DemoImageLoader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DemoRequestProtocol.self]
        return DemoImageLoader(session: URLSession(configuration: config), bundledImage: bundle)
    }

    private func imageData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 384, height: 256)).pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 384, height: 256))
        }
    }

    func testThumbnailUsesEitherBundledFrameWithoutNetwork() async {
        let image = UIImage(systemName: "dumbbell")!
        DemoRequestProtocol.configure { _ in XCTFail("Bundled thumbnail must stay offline"); return (500, Data()) }
        let subject = loader { $0 == "offline__1" ? image : nil }
        await subject.load(exerciseID: "exercise", demoSlug: "offline", jwt: "test",
                           presentation: .thumbnail)
        XCTAssertTrue(subject.frames[0] === image)
        XCTAssertNil(subject.frames[1])
        XCTAssertFalse(subject.isLoading)
    }

    func testRemoteThumbnailDownloadsOneFrameAndBoundsDecodedSize() async throws {
        let bytes = imageData()
        DemoRequestProtocol.configure { _ in (200, bytes) }
        let subject = loader()
        await subject.load(exerciseID: "exercise", demoSlug: "new-slug", jwt: "test",
                           presentation: .thumbnail)
        let image = try XCTUnwrap(subject.frames[0]?.cgImage)
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 128)
        XCTAssertNil(subject.frames[1])
        let requests = DemoRequestProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/api/exercises/exercise/demo/0")
        XCTAssertEqual(requests.first?.url?.query, "demo=new-slug")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test")
    }

    func testUnavailableFirstFrameFallsBackToSecondAndMissingArtClearsOldImage() async {
        let bytes = imageData()
        DemoRequestProtocol.configure { request in
            request.url?.lastPathComponent == "0" ? (404, Data()) : (200, bytes)
        }
        let subject = loader()
        await subject.load(exerciseID: "exercise", demoSlug: "remote", jwt: "test",
                           presentation: .thumbnail)
        XCTAssertNotNil(subject.frames[0])
        XCTAssertEqual(DemoRequestProtocol.requests.count, 2)
        await subject.load(exerciseID: "missing", demoSlug: nil, jwt: "test",
                           presentation: .thumbnail)
        XCTAssertTrue(subject.frames.allSatisfy { $0 == nil })
        XCTAssertEqual(DemoRequestProtocol.requests.count, 2)
        DemoRequestProtocol.configure { _ in (200, Data("invalid image".utf8)) }
        await subject.load(exerciseID: "broken", demoSlug: "broken", jwt: "test",
                           presentation: .thumbnail)
        XCTAssertTrue(subject.frames.allSatisfy { $0 == nil })
        XCTAssertFalse(subject.isLoading)
    }

    func testLateResponseCannotRestorePreviousExerciseArt() async {
        let requested = expectation(description: "Old image requested")
        let bytes = imageData()
        DemoRequestProtocol.configure(hold: true, onHold: { requested.fulfill() }) { _ in (200, bytes) }
        let subject = loader()
        let old = Task {
            await subject.load(exerciseID: "old", demoSlug: "old", jwt: "test",
                               presentation: .thumbnail)
        }
        await fulfillment(of: [requested], timeout: 3)
        await subject.load(exerciseID: "new", demoSlug: nil, jwt: nil,
                           presentation: .thumbnail)
        DemoRequestProtocol.releaseHeldResponse()
        await old.value
        XCTAssertTrue(subject.frames.allSatisfy { $0 == nil })
        XCTAssertFalse(subject.isLoading)
    }

    func testTechniqueStillLoadsBothFramesAndOfflineMissDoesNotRequest() async {
        let bytes = imageData()
        DemoRequestProtocol.configure { _ in (200, bytes) }
        let subject = loader()
        await subject.load(exerciseID: "exercise", demoSlug: "remote", jwt: "test")
        XCTAssertEqual(subject.frames.compactMap { $0 }.count, 2)
        XCTAssertEqual(DemoRequestProtocol.requests.count, 2)
        await subject.load(exerciseID: "offline", demoSlug: "remote", jwt: nil,
                           presentation: .thumbnail)
        XCTAssertTrue(subject.frames.allSatisfy { $0 == nil })
        XCTAssertEqual(DemoRequestProtocol.requests.count, 2)
    }
}

private final class DemoRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recorded: [URLRequest] = []
    private static var response: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    private static var holdResponse = false
    private static var onHold: (() -> Void)?
    private static var held: (() -> Void)?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    static func configure(hold: Bool = false, onHold: (() -> Void)? = nil,
                          response: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        recorded = []; held = nil; holdResponse = hold; Self.response = response; Self.onHold = onHold
    }
    static func releaseHeldResponse() {
        lock.lock(); let send = held; held = nil; lock.unlock()
        send?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let response = Self.response, hold = Self.holdResponse, onHold = Self.onHold
        Self.lock.unlock()
        let (status, bytes) = response(request)
        let send = { [self] in
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        }
        if hold {
            Self.lock.lock(); Self.held = send; Self.lock.unlock()
            onHold?()
        } else { send() }
    }
    override func stopLoading() {}
}
