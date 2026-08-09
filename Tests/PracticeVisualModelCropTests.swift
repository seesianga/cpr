import RealityKit
import simd
import XCTest
@testable import LifesaverVision

/// Coverage for cropping the imported body down to the manikin's physical envelope.
///
/// These exercise real `MeshResource` surgery rather than a stand-in, because the risk
/// being tested is whether RealityKit accepts a rebuilt index buffer at all — a pure-value
/// test of the same maths would pass while the headset rendered nothing.
@MainActor
final class PracticeVisualModelCropTests: XCTestCase {

    /// A tessellated stand-in for a scanned body: a tube segmented along the head-to-feet
    /// axis, so the crop boundary can fall between triangles the way it does on a real
    /// import. A `generateBox` body would be four triangles long and is used deliberately
    /// in `testCoarseMeshFallsBackToTheApproximateCrop` instead.
    private func makeBody(
        lengthMetres: Float = 2,
        segments: Int = 60
    ) -> (host: Entity, body: ModelEntity) {
        let host = Entity()
        host.name = "training_manikin"
        let body = ModelEntity(
            mesh: tessellatedTube(lengthMetres: lengthMetres, segments: segments),
            materials: [SimpleMaterial()]
        )
        body.name = "human_visual_body"
        host.addChild(body)
        return (host, body)
    }

    private func tessellatedTube(lengthMetres: Float, segments: Int) -> MeshResource {
        let halfWidth: Float = 0.2
        let halfHeight: Float = 0.1
        var positions: [SIMD3<Float>] = []
        for step in 0...segments {
            let z = -lengthMetres / 2 + lengthMetres * Float(step) / Float(segments)
            positions.append([-halfWidth, -halfHeight, z])
            positions.append([halfWidth, -halfHeight, z])
            positions.append([halfWidth, halfHeight, z])
            positions.append([-halfWidth, halfHeight, z])
        }
        var indices: [UInt32] = []
        for step in 0..<segments {
            let ring = UInt32(step * 4)
            let next = UInt32((step + 1) * 4)
            for corner in 0..<4 {
                let corner0 = ring + UInt32(corner)
                let corner1 = ring + UInt32((corner + 1) % 4)
                let next0 = next + UInt32(corner)
                let next1 = next + UInt32((corner + 1) % 4)
                indices.append(contentsOf: [corner0, corner1, next1, corner0, next1, next0])
            }
        }
        var descriptor = MeshDescriptor(name: "tessellated_body")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        // swiftlint:disable:next force_try
        return try! MeshResource.generate(from: [descriptor])
    }

    /// Bounds of the geometry that is actually drawn.
    ///
    /// Not `visualBounds`: the crop rewrites index buffers and leaves the position buffer
    /// alone, and RealityKit derives `visualBounds` from the position buffer — so a
    /// cropped mesh keeps reporting its original bounds while rendering less. Only the
    /// vertices the surviving triangles reference say what is on screen.
    private func renderedBounds(of entity: ModelEntity) -> BoundingBox? {
        guard let mesh = entity.model?.mesh else { return nil }
        var bounds: BoundingBox?
        for model in mesh.contents.models {
            for part in model.parts {
                let positions = part.positions.elements
                for index in part.triangleIndices?.elements ?? [] {
                    guard Int(index) < positions.count else { continue }
                    let point = positions[Int(index)]
                    let box = BoundingBox(min: point, max: point)
                    bounds = bounds.map { $0.union(box) } ?? box
                }
            }
        }
        return bounds
    }

    private func triangleCount(of entity: ModelEntity) -> Int {
        guard let mesh = entity.model?.mesh else { return 0 }
        return mesh.contents.models.reduce(0) { total, model in
            total + model.parts.reduce(0) { partTotal, part in
                partTotal + (part.triangleIndices?.count ?? 0) / 3
            }
        }
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    /// The headline behaviour: a body longer than the manikin loses the overhang and keeps
    /// the chest.
    func testCroppingRemovesGeometryBeyondTheManikinEnvelope() throws {
        let (host, body) = makeBody(lengthMetres: 2)
        defer { PracticeVisualModelCrop.forget(host) }
        let before = triangleCount(of: body)
        XCTAssertGreaterThan(before, 0)

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 0.6],
            host: host
        )

        XCTAssertTrue(outcome.didCropAnything)
        XCTAssertGreaterThan(outcome.removedTriangleCount, 0)
        XCTAssertGreaterThan(outcome.keptTriangleCount, 0)
        XCTAssertLessThan(triangleCount(of: body), before)
        XCTAssertTrue(body.isEnabled, "The chest must survive the crop")
    }

    /// Surviving geometry has to stay inside the envelope, or the crop is cosmetic. On a
    /// tessellated mesh the strict rule makes this exact rather than approximate.
    func testCroppedGeometryFitsInsideTheEnvelope() throws {
        let (host, body) = makeBody(lengthMetres: 2)
        defer { PracticeVisualModelCrop.forget(host) }
        let halfLength: Float = 0.3

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, halfLength * 2],
            host: host
        )
        XCTAssertTrue(outcome.didCropAnything)
        XCTAssertFalse(
            outcome.usedApproximateCrop,
            "A tessellated body must take the strict, no-overhang path"
        )

        let bounds = try XCTUnwrap(renderedBounds(of: body))
        let allowance = halfLength + PracticeVisualModelCrop.envelopeMarginMetres + 0.001
        XCTAssertLessThanOrEqual(bounds.max.z, allowance)
        XCTAssertGreaterThanOrEqual(bounds.min.z, -allowance)
        // And it kept the chest, rather than passing by rendering nothing.
        XCTAssertGreaterThan(bounds.extents.z, halfLength)
    }

    /// A mesh whose triangles are longer than the crop boundary cannot be cut cleanly.
    /// Keeping an approximate body beats erasing it, and the outcome says which happened.
    func testCoarseMeshFallsBackToTheApproximateCrop() throws {
        let host = Entity()
        host.name = "training_manikin"
        let slab = ModelEntity(
            mesh: .generateBox(size: [0.4, 0.2, 2]),
            materials: [SimpleMaterial()]
        )
        slab.name = "human_visual_body"
        host.addChild(slab)
        defer { PracticeVisualModelCrop.forget(host) }

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 1.2],
            host: host
        )

        XCTAssertTrue(outcome.didCropAnything)
        XCTAssertTrue(outcome.usedApproximateCrop)
        XCTAssertTrue(slab.isEnabled, "The body must survive a crop it cannot make exact")
        XCTAssertTrue(outcome.summary.contains("approximate"))
    }

    func testCroppingLeavesAModelThatAlreadyFitsUntouched() throws {
        let (host, body) = makeBody(lengthMetres: 0.4)
        defer { PracticeVisualModelCrop.forget(host) }
        let before = triangleCount(of: body)

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [1, 1, 1],
            host: host
        )

        XCTAssertFalse(outcome.didCropAnything)
        XCTAssertEqual(triangleCount(of: body), before)
        XCTAssertTrue(body.isEnabled)
    }

    /// A whole limb sitting clear of the manikin is switched off rather than rebuilt,
    /// because mesh surgery on geometry that keeps nothing is wasted work.
    func testGeometryEntirelyOutsideTheEnvelopeIsDisabledNotRebuilt() throws {
        let host = Entity()
        host.name = "training_manikin"
        let leg = ModelEntity(mesh: .generateBox(size: [0.1, 0.1, 0.6]), materials: [SimpleMaterial()])
        leg.name = "human_visual_clothing_bottom"
        leg.position = [0, 0, 2]
        host.addChild(leg)
        defer { PracticeVisualModelCrop.forget(host) }

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 0.6],
            host: host
        )

        XCTAssertEqual(outcome.disabledEntityCount, 1)
        XCTAssertFalse(leg.isEnabled)
        XCTAssertEqual(outcome.removedTriangleCount, 0)
    }

    /// The crop is a display choice, so switching it off has to give the whole body back.
    func testRestorePutsTheOriginalMeshAndEnabledStateBack() throws {
        let (host, body) = makeBody(lengthMetres: 2)
        defer { PracticeVisualModelCrop.forget(host) }
        let before = triangleCount(of: body)

        _ = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 0.6],
            host: host
        )
        XCTAssertLessThan(triangleCount(of: body), before)

        PracticeVisualModelCrop.restore(host)

        XCTAssertEqual(triangleCount(of: body), before)
        XCTAssertTrue(body.isEnabled)
    }

    /// Re-applying must measure from the original mesh, not from the already-cropped one,
    /// or every room reload shaves the body a little further.
    func testReapplyingAWiderEnvelopeGrowsTheBodyBackAgain() throws {
        let (host, body) = makeBody(lengthMetres: 2)
        defer { PracticeVisualModelCrop.forget(host) }

        _ = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 0.4],
            host: host
        )
        let tight = triangleCount(of: body)

        _ = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0.5, 0.3, 1.2],
            host: host
        )

        XCTAssertGreaterThan(triangleCount(of: body), tight)
    }

    func testDegenerateEnvelopeIsIgnoredRatherThanErasingTheBody() throws {
        let (host, body) = makeBody(lengthMetres: 2)
        defer { PracticeVisualModelCrop.forget(host) }
        let before = triangleCount(of: body)

        let outcome = PracticeVisualModelCrop.apply(
            to: host,
            envelopeCenter: [0, 0, 0],
            envelopeExtents: [0, 0, 0],
            host: host
        )

        XCTAssertFalse(outcome.didCropAnything)
        XCTAssertEqual(triangleCount(of: body), before)
        XCTAssertTrue(body.isEnabled)
    }

    // MARK: - Legacy marker retirement

    /// The amber pad slabs are retired visually, but pad-drop classification reads the
    /// bounds of their parent zone Xforms. Naming a parent here would delete pad detection
    /// along with the visuals.
    func testRetiredLegacyMarkersNeverNameADetectionEntity() {
        let descriptor = PracticeAssetDescriptor.placeholderDescriptor
        var reserved: Set<String> = [
            descriptor.patches.rightPadZoneEntityName,
            descriptor.patches.leftPadZoneEntityName,
            descriptor.patches.rightPadEntityName,
            descriptor.patches.leftPadEntityName,
            descriptor.body.torsoRootEntityName,
            descriptor.body.figureEntityName,
            descriptor.body.sternumTargetEntityName,
            descriptor.body.xiphoidAvoidZoneEntityName
        ]
        reserved.formUnion(descriptor.body.landmarkEntityNames)

        for model in PracticeVisualModel.allCases {
            for name in model.supersededLegacyEntityNames {
                XCTAssertFalse(
                    reserved.contains(name),
                    "\(name) is read by detection and must not be retired"
                )
            }
        }
        XCTAssertEqual(
            PracticeVisualModel.human.supersededLegacyEntityNames,
            ["aed_right_pad_zone_surface", "aed_left_pad_zone_surface"]
        )
    }

    /// Retiring a marker by opacity keeps the bounds that pad-drop classification needs;
    /// disabling it would not, which is the whole reason opacity is used.
    func testRetiringAMarkerByOpacityPreservesTheBoundsDetectionReads() {
        let zone = Entity()
        zone.name = "aed_right_pad_zone"
        let surface = ModelEntity(mesh: .generateBox(size: [0.12, 0.018, 0.15]))
        surface.name = "aed_right_pad_zone_surface"
        zone.addChild(surface)

        surface.components.set(OpacityComponent(opacity: 0))

        let bounds = zone.visualBounds(recursive: true, relativeTo: zone)
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertEqual(bounds.extents.x, 0.12, accuracy: 0.001)
    }
}
