import RealityKit
import SwiftData
import SwiftUI
import UIKit

/// Volumetric achievement gallery. Unearned badge models remain visible as subdued
/// placeholders, and the pedestal states the exact status of the internal record.
struct AchievementGalleryRootView: View {
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Query private var badgeAwards: [BadgeAward]
    @Query private var signOffs: [PracticalSignOff]
    @State private var assetRegistry = AssetRegistry()
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var learnerID: String { authenticationModel.currentUser?.id ?? "" }
    private var learnerBadgeIDs: Set<String> {
        Set(badgeAwards.filter { $0.learnerID == learnerID }.map(\.badgeID))
    }
    private var hasApprovedSignOff: Bool {
        signOffs.contains {
            $0.learnerID == learnerID &&
            $0.statusRawValue == PracticalSignOffStatus.approved.rawValue
        }
    }
    private var descriptors: [AchievementBadgeDescriptor] {
        AchievementBadgeDescriptor.catalogue(
            rules: (try? BadgeRuleCodec.loadBundled()) ?? []
        )
    }

    var body: some View {
        ZStack {
            RealityView { content, attachments in
                do {
                    let scene = try await assetRegistry.loadScene(.achievementGallery)
                    try assetRegistry.decorateSemanticEntities(in: scene, for: .achievementGallery)
                    applyBadgeVisibility(in: scene)
                    if let status = attachments.entity(for: "gallery-status"),
                       let pedestal = assetRegistry.firstEntity(
                           named: "certificate_pedestal",
                           in: scene
                       ) {
                        status.position = [0, 0.30, 0]
                        pedestal.addChild(status)
                    }
                    content.add(scene)
                    isLoading = false
                    errorMessage = nil
                } catch is CancellationError {
                    // Window closure cancels loading without requiring a learner alert.
                } catch {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            } update: { content, _ in
                guard let scene = content.entities.first(where: {
                    $0.name == SpatialSceneName.achievementGallery.rawValue
                }) else { return }
                applyBadgeVisibility(in: scene)
            } attachments: {
                Attachment(id: "gallery-status") {
                    VStack(spacing: 6) {
                        Text("Completion record")
                            .font(.headline)
                        Text(
                            hasApprovedSignOff
                                ? "Instructor-verified"
                                : "Internal completion record — not SRFAC certification"
                        )
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .accessibilityLabel(
                            hasApprovedSignOff
                                ? "Practical status: Instructor-verified"
                                : "Practical status: Internal completion record, not SRFAC certification"
                        )
                    }
                    .frame(maxWidth: 360)
                    .padding(16)
                    .glassBackgroundEffect()
                }
            }

            if isLoading {
                ProgressView("Opening achievement gallery…")
                    .padding(20)
                    .glassBackgroundEffect()
            } else if let errorMessage {
                ContentUnavailableView(
                    "Gallery unavailable",
                    systemImage: "medal",
                    description: Text(errorMessage)
                )
                .padding(20)
                .glassBackgroundEffect()
            }
        }
        .onDisappear { assetRegistry.releaseScene(.achievementGallery) }
    }

    @MainActor
    private func applyBadgeVisibility(in scene: Entity) {
        for descriptor in descriptors {
            guard let entity = assetRegistry.firstEntity(named: descriptor.assetName, in: scene) else {
                continue
            }
            let earned = descriptor.isConfigured && learnerBadgeIDs.contains(descriptor.id)
            entity.components.set(OpacityComponent(opacity: earned ? 1.0 : 0.58))
            if !earned { applyGreyPlaceholderMaterial(to: entity) }
            if var accessibility = entity.components[AccessibilityComponent.self] {
                accessibility.value = LocalizedStringResource(
                    stringLiteral: earned ? "Earned" : "Not yet earned"
                )
                entity.components.set(accessibility)
            }
        }
    }

    @MainActor
    private func applyGreyPlaceholderMaterial(to entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = [
                SimpleMaterial(
                    color: UIColor(white: 0.42, alpha: 1),
                    roughness: 0.88,
                    isMetallic: false
                )
            ]
            entity.components.set(model)
        }
        for child in entity.children {
            applyGreyPlaceholderMaterial(to: child)
        }
    }
}
