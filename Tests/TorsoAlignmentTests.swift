import RealityKit
import simd
import XCTest
@testable import LifesaverVision

/// Coverage for registering an imported body onto the authored manikin.
///
/// The numbers in `manikinReference` are the ones authored in `TrainingManikin.usda`, so
/// these tests fail if the asset and the solver ever stop agreeing about the manikin's
/// size or its sternum landmark.
@MainActor
final class TorsoAlignmentTests: XCTestCase {

    // torso_shell: translate (0, 0.12, 0), scale (0.46, 0.18, 0.72) on a unit cube.
    // landmark_sternum: (0, 0.225, 0.095). Supine, head toward -Z, anatomical right -X.
    /// `sizeScale` grows the whole manikin, not one axis: a body registers by proportion
    /// as well as by size, so stretching only the width would legitimately change which
    /// orientation fits best and would be testing something else.
    private func manikinReference(sizeScale: Float = 1) -> TorsoAlignmentReference {
        TorsoAlignmentReference(
            frame: TorsoAnatomicalFrame(descriptor: .placeholderDefault),
            torsoCenter: SIMD3<Float>(0, 0.12, 0) * sizeScale,
            anatomicalExtents: SIMD3<Float>(0.46, 0.72, 0.18) * sizeScale,
            registrationPoint: SIMD3<Float>(0, 0.225, 0.095) * sizeScale,
            physicalEnvelopeCenter: SIMD3<Float>(0, 0.12, -0.16) * sizeScale,
            physicalEnvelopeExtents: SIMD3<Float>(0.73, 0.21, 1.04) * sizeScale
        )
    }

    /// A full-body export authored standing, Y-up, chest toward +Z — a different axis
    /// convention from the manikin's in every axis, which is the normal case.
    private func standingImport() -> TorsoAlignmentSubject {
        TorsoAlignmentSubject(
            torsoCenter: [0, 1.2, 0],
            torsoExtents: [0.40, 0.55, 0.16],
            registrationPoint: [0, 1.15, 0.08],
            fullCenter: [0, 0.9, 0],
            fullExtents: [0.55, 1.75, 0.28]
        )
    }

    // MARK: - Registration

    func testSolverRotatesAForeignAxisConventionOntoTheManikin() throws {
        let solution = try XCTUnwrap(
            TorsoAlignmentSolver.solve(
                reference: manikinReference(),
                subject: standingImport()
            )
        )

        // Head→feet is -Y in the export and +Z on the manikin; anterior is +Z in the
        // export and +Y on the manikin.
        assertVectorsEqual(solution.rotation * SIMD3<Float>(0, -1, 0), [0, 0, 1])
        assertVectorsEqual(solution.rotation * SIMD3<Float>(0, 0, 1), [0, 1, 0])
    }

    func testSolvedScaleComesFromMeasuredChestWidth() throws {
        let solution = try XCTUnwrap(
            TorsoAlignmentSolver.solve(
                reference: manikinReference(),
                subject: standingImport()
            )
        )
        // 0.46 m manikin chest / 0.40 m import chest.
        XCTAssertEqual(solution.scale, 0.46 / 0.40, accuracy: 0.001)
    }

    /// The point of measuring rather than hardcoding: a bigger manikin must produce a
    /// bigger body without a source change.
    func testScaleTracksTheManikinRatherThanAFixedNumber() throws {
        let standard = try XCTUnwrap(
            TorsoAlignmentSolver.solve(
                reference: manikinReference(),
                subject: standingImport()
            )
        )
        let doubled = try XCTUnwrap(
            TorsoAlignmentSolver.solve(
                reference: manikinReference(sizeScale: 2),
                subject: standingImport()
            )
        )
        XCTAssertEqual(doubled.scale, standard.scale * 2, accuracy: 0.001)
    }

    /// Registration is the whole point: the two sternum landmarks must end up at the same
    /// place, not merely at the same bounding-box centre.
    func testSolvedPlacementLandsTheSternumLandmarksOnTopOfEachOther() throws {
        let reference = manikinReference()
        let subject = standingImport()
        let solution = try XCTUnwrap(
            TorsoAlignmentSolver.solve(reference: reference, subject: subject)
        )

        let placed = solution.offsetMetres
            + solution.rotation * (try XCTUnwrap(subject.registrationPoint) * solution.scale)
        assertVectorsEqual(placed, try XCTUnwrap(reference.registrationPoint), accuracy: 0.0005)
    }

    /// Silhouette proportions are near enough front/back symmetric to be useless for
    /// telling face-up from face-down. The sternum landmark is what breaks the tie, and
    /// getting it wrong buries the compression site inside the mesh.
    func testLandmarkTermRejectsTheFaceDownOrientation() throws {
        let reference = manikinReference()
        let subject = standingImport()
        let solution = try XCTUnwrap(
            TorsoAlignmentSolver.solve(reference: reference, subject: subject)
        )

        // The import's chest normal must finish pointing the manikin's anterior way (+Y),
        // never into the table.
        let anterior = solution.rotation * SIMD3<Float>(0, 0, 1)
        XCTAssertGreaterThan(anterior.y, 0.99, "The body registered face-down")
    }

    func testSolverRejectsDegenerateMeasurements() {
        var subject = standingImport()
        subject = TorsoAlignmentSubject(
            torsoCenter: subject.torsoCenter,
            torsoExtents: [0, 0, 0],
            registrationPoint: subject.registrationPoint,
            fullCenter: subject.fullCenter,
            fullExtents: subject.fullExtents
        )
        XCTAssertNil(
            TorsoAlignmentSolver.solve(reference: manikinReference(), subject: subject)
        )
    }

    // MARK: - Candidate rotations

    func testCandidateSetIsThe24ProperRotationsOfACube() {
        let rotations = TorsoAlignmentSolver.axisAlignedRotations
        XCTAssertEqual(rotations.count, 24)

        var seen = Set<String>()
        for rotation in rotations {
            XCTAssertEqual(
                simd_determinant(rotation),
                1,
                accuracy: 0.0001,
                "A reflection would mirror the casualty's left and right"
            )
            let identity = rotation * rotation.transpose
            for row in 0..<3 {
                for column in 0..<3 {
                    XCTAssertEqual(
                        identity[column][row],
                        row == column ? 1 : 0,
                        accuracy: 0.0001
                    )
                }
            }
            seen.insert((0..<3).map { column in
                let vector = rotation[column]
                return "\(vector.x),\(vector.y),\(vector.z)"
            }.joined(separator: "|"))
        }
        XCTAssertEqual(seen.count, 24, "Duplicate candidates waste the search")
    }

    // MARK: - Euler round trip

    /// The solver works in matrices but the persisted placement and the in-headset
    /// steppers are Euler angles. If the decomposition drifts, a solved orientation stops
    /// matching what is rendered.
    func testEveryCandidateRotationSurvivesTheEulerRoundTrip() {
        for rotation in TorsoAlignmentSolver.axisAlignedRotations {
            var placement = PracticeVisualModelPlacement.identity
            placement.setOrientation(rotation)
            let rebuilt = simd_float3x3(placement.sanitized.orientation)
            for column in 0..<3 {
                assertVectorsEqual(rebuilt[column], rotation[column], accuracy: 0.001)
            }
        }
    }

    func testEulerRoundTripSurvivesTheGimbalLockedOrientation() {
        // Pitch ±90°: chest pointing straight down the head-to-feet axis.
        let rotation = simd_float3x3(
            simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        )
        var placement = PracticeVisualModelPlacement.identity
        placement.setOrientation(rotation)
        let rebuilt = simd_float3x3(placement.sanitized.orientation)
        for column in 0..<3 {
            assertVectorsEqual(rebuilt[column], rotation[column], accuracy: 0.001)
        }
    }

    // MARK: - Accuracy reporting

    func testAccuracyReportsZeroForAPerfectlyRegisteredBody() {
        let reference = manikinReference()
        let accuracy = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: reference.registrationPoint,
            measuredFrame: reference.frame,
            measuredChestWidthMetres: reference.chestWidthMetres,
            measuredChestLengthMetres: reference.chestLengthMetres
        )
        XCTAssertEqual(accuracy.registrationOffsetCentimetres, 0, accuracy: 0.001)
        XCTAssertEqual(accuracy.rotationErrorDegrees, 0, accuracy: 0.001)
        XCTAssertTrue(accuracy.isAligned)
    }

    func testAccuracyReportsOffsetInCentimetresAndRotationInDegrees() {
        let reference = manikinReference()
        // 12 cm down the head-to-feet axis, and a quarter turn about the vertical.
        let displaced = try? XCTUnwrap(reference.registrationPoint) + SIMD3<Float>(0, 0, 0.12)
        let yaw = simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))

        let accuracy = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: displaced,
            measuredFrame: reference.frame.rotated(by: yaw),
            measuredChestWidthMetres: reference.chestWidthMetres,
            measuredChestLengthMetres: reference.chestLengthMetres
        )
        XCTAssertEqual(accuracy.registrationOffsetCentimetres, 12, accuracy: 0.01)
        XCTAssertEqual(accuracy.longitudinalErrorDegrees, 90, accuracy: 0.01)
        XCTAssertFalse(accuracy.isAligned)
    }

    func testReportQuantifiesTheImprovementForTheDemoReadout() {
        let reference = manikinReference()
        let before = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: [0.3, 0.4, 0.5],
            measuredFrame: reference.frame.rotated(
                by: simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)))
            ),
            measuredChestWidthMetres: 0.9,
            measuredChestLengthMetres: 1.6
        )
        let after = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: reference.registrationPoint,
            measuredFrame: reference.frame,
            measuredChestWidthMetres: reference.chestWidthMetres,
            measuredChestLengthMetres: reference.chestLengthMetres
        )
        let report = TorsoAlignmentReport(before: before, after: after)

        XCTAssertGreaterThan(report.improvedOffsetCentimetres, 0)
        XCTAssertEqual(report.improvedRotationDegrees, 90, accuracy: 0.01)
        XCTAssertTrue(report.demoLine.contains("→"))
    }

    // MARK: - Proportional prop sizing

    func testAEDScaleIsAFractionOfMeasuredChestWidth() throws {
        let scale = try XCTUnwrap(
            ProportionalPropSizing.scale(
                chestWidthMetres: 0.46,
                measuredPropWidthMetres: 0.34
            )
        )
        let resultingWidth = 0.34 * scale
        XCTAssertEqual(
            resultingWidth / 0.46,
            ProportionalPropSizing.aedWidthAsFractionOfChestWidth,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ProportionalPropSizing.aedWidthAsFractionOfChestWidth,
            0.14,
            accuracy: 0.0001,
            """
            Half the anatomically faithful 0.25–0.30 band, by operator decision against \
            the physical demo scene (2026-08-10). A change here must be another such \
            decision, not a drift back toward the textbook proportion.
            """
        )
    }

    /// Sizing that follows the body is the requirement; a fixed number would not move.
    func testAEDScaleFollowsTheBodyWhenTheBodyResizes() throws {
        let narrow = try XCTUnwrap(
            ProportionalPropSizing.scale(chestWidthMetres: 0.46, measuredPropWidthMetres: 0.34)
        )
        let wide = try XCTUnwrap(
            ProportionalPropSizing.scale(chestWidthMetres: 0.69, measuredPropWidthMetres: 0.34)
        )
        XCTAssertEqual(wide, narrow * 1.5, accuracy: 0.0001)
    }

    func testAEDScaleRefusesUnusableMeasurements() {
        XCTAssertNil(
            ProportionalPropSizing.scale(chestWidthMetres: 0, measuredPropWidthMetres: 0.34)
        )
        XCTAssertNil(
            ProportionalPropSizing.scale(chestWidthMetres: 0.46, measuredPropWidthMetres: 0)
        )
        XCTAssertNil(
            ProportionalPropSizing.scale(chestWidthMetres: .nan, measuredPropWidthMetres: 0.34)
        )
    }

    // MARK: - Scene-level proxy resolution

    /// A minimal stand-in for `CPRPracticeRoom` + `TrainingManikin.usda`.
    private func makeManikinScene(includeTorsoGarment: Bool) -> Entity {
        let scene = Entity()
        scene.name = "CPRPracticeRoom"

        let manikin = Entity()
        manikin.name = "training_manikin"
        scene.addChild(manikin)

        let torso = ModelEntity(mesh: .generateBox(size: [0.46, 0.18, 0.72]))
        torso.name = "torso_shell"
        torso.position = [0, 0.12, 0]
        manikin.addChild(torso)

        let landmark = Entity()
        landmark.name = "landmark_sternum"
        landmark.position = [0, 0.225, 0.095]
        manikin.addChild(landmark)

        // The import: a standing full-body figure in its own axis convention.
        let body = Entity()
        body.name = "human_visual_model"
        manikin.addChild(body)

        let skin = ModelEntity(mesh: .generateBox(size: [0.55, 1.75, 0.28]))
        skin.name = "human_visual_body"
        skin.position = [0, 0.9, 0]
        body.addChild(skin)

        if includeTorsoGarment {
            let shirt = ModelEntity(mesh: .generateBox(size: [0.40, 0.55, 0.16]))
            shirt.name = "human_visual_clothing_top"
            shirt.position = [0, 1.2, 0]
            body.addChild(shirt)
        }

        let sternumSite = Entity()
        sternumSite.name = "human_visual_sternum_site"
        sternumSite.position = [0, 1.15, 0.08]
        body.addChild(sternumSite)

        return scene
    }

    /// The whole point of pairing proxies: the chest scale must come from a chest, not
    /// from head-to-toe height.
    func testSceneSolveScalesFromTheTorsoGarmentWhenTheExportHasOne() throws {
        let scene = makeManikinScene(includeTorsoGarment: true)
        let solved = try XCTUnwrap(
            PracticeVisualModelAlignment.solvePlacement(
                for: .human,
                in: scene,
                currentPlacement: PracticeVisualModel.human.defaultPlacement
            )
        )
        XCTAssertEqual(solved.placement.scale, 0.46 / 0.40, accuracy: 0.01)
    }

    /// And when it has none, resolution falls through to the declared whole-body pair
    /// rather than quietly reusing the first one.
    func testSceneSolveFallsThroughToTheWholeBodyPairWhenNoGarmentExists() throws {
        let scene = makeManikinScene(includeTorsoGarment: false)
        let solved = try XCTUnwrap(
            PracticeVisualModelAlignment.solvePlacement(
                for: .human,
                in: scene,
                currentPlacement: PracticeVisualModel.human.defaultPlacement
            )
        )
        XCTAssertEqual(solved.placement.scale, 0.46 / 0.55, accuracy: 0.01)
    }

    /// End to end: after solving, the import's sternum site sits on the manikin's.
    func testSceneSolveRegistersTheSternumSitesOntoEachOther() throws {
        let scene = makeManikinScene(includeTorsoGarment: true)
        let solved = try XCTUnwrap(
            PracticeVisualModelAlignment.solvePlacement(
                for: .human,
                in: scene,
                currentPlacement: PracticeVisualModel.human.defaultPlacement
            )
        )

        let manikin = try XCTUnwrap(
            PracticeVisualModelAlignment.firstEntity(named: "training_manikin", in: scene)
        )
        let body = try XCTUnwrap(
            PracticeVisualModelAlignment.firstEntity(named: "human_visual_model", in: scene)
        )
        PracticeVisualModelLoader.apply(solved.placement, to: body)

        let site = try XCTUnwrap(
            PracticeVisualModelAlignment.firstEntity(named: "human_visual_sternum_site", in: body)
        )
        assertVectorsEqual(site.position(relativeTo: manikin), [0, 0.225, 0.095], accuracy: 0.005)
    }

    /// The measured accuracy has to agree with the scene, which is what makes it evidence
    /// rather than a restatement of the solver's intent.
    func testMeasuredAccuracyReportsAlignedAfterASceneSolve() throws {
        let scene = makeManikinScene(includeTorsoGarment: true)
        let solved = try XCTUnwrap(
            PracticeVisualModelAlignment.solvePlacement(
                for: .human,
                in: scene,
                currentPlacement: PracticeVisualModel.human.defaultPlacement
            )
        )
        let body = try XCTUnwrap(
            PracticeVisualModelAlignment.firstEntity(named: "human_visual_model", in: scene)
        )
        PracticeVisualModelLoader.apply(solved.placement, to: body)

        let accuracy = try XCTUnwrap(
            PracticeVisualModelAlignment.measureAccuracy(
                for: .human,
                in: scene,
                placement: solved.placement
            )
        )
        XCTAssertLessThan(accuracy.registrationOffsetCentimetres, 1)
        XCTAssertLessThan(accuracy.rotationErrorDegrees, 1)
        XCTAssertLessThan(abs(accuracy.chestWidthErrorCentimetres), 1)
        XCTAssertTrue(accuracy.isAligned, "Measured: \(accuracy.summary)")
    }

    /// A human torso is not shaped like a rectangular trainer, so a uniform scale that
    /// matches chest width leaves a length difference. That is reported, not treated as a
    /// registration failure — nulling it would need a non-uniform scale that distorts the
    /// body.
    func testProportionalLengthResidualIsReportedWithoutFailingRegistration() {
        let reference = manikinReference()
        let accuracy = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: reference.registrationPoint,
            measuredFrame: reference.frame,
            measuredChestWidthMetres: reference.chestWidthMetres,
            measuredChestLengthMetres: reference.chestLengthMetres - 0.09
        )
        XCTAssertEqual(accuracy.chestLengthErrorCentimetres, -9, accuracy: 0.01)
        XCTAssertTrue(accuracy.isAligned)
        XCTAssertTrue(accuracy.summary.contains("length"))
    }

    /// Width, by contrast, is the dimension the scale is solved for, so a mismatch there
    /// does mean something went wrong.
    func testChestWidthMismatchFailsRegistration() {
        let reference = manikinReference()
        let accuracy = TorsoAlignmentSolver.accuracy(
            reference: reference,
            measuredRegistrationPoint: reference.registrationPoint,
            measuredFrame: reference.frame,
            measuredChestWidthMetres: reference.chestWidthMetres + 0.09,
            measuredChestLengthMetres: reference.chestLengthMetres
        )
        XCTAssertFalse(accuracy.isAligned)
    }

    /// The baseline the demo readout compares against. The shipped default is tuned to the
    /// PHYSICAL demo unit, whose frame is not the virtual skeleton's, so the solver's
    /// metric reads it as misaligned — which is expected, and why "Align to manikin" is an
    /// explicit button rather than an automatic first-attach solve.
    func testUnregisteredImportMeasuresAsMisalignedBeforeSolving() throws {
        let scene = makeManikinScene(includeTorsoGarment: true)
        let accuracy = try XCTUnwrap(
            PracticeVisualModelAlignment.measureAccuracy(
                for: .human,
                in: scene,
                placement: PracticeVisualModel.human.defaultPlacement
            )
        )
        XCTAssertFalse(accuracy.isAligned)
        XCTAssertGreaterThan(accuracy.registrationOffsetCentimetres, 10)
    }

    // MARK: - Helpers

    private func assertVectorsEqual(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>,
        accuracy: Float = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }
}
