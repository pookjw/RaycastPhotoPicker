//
//  ViewController.swift
//  RaycastPhotoPicker
//
//  Created by Jinwoo Kim on 5/19/24.
//

import UIKit
import ARKit
import RealityKit
import Photos
import os
import SwiftUI

@MainActor
fileprivate enum CellLayout {
    /*
     +----------------------------------------------+
     |                                              |
     | <-1-> +----+ <-2-> +----+ <-2-> +----+ <-1-> |
     |       |    |       |    |       |    |       |
     |       |    |       |    |       |    |       |
     |       +----+       +----+       +----+       |
     |       ^            ^            ^            |
     |       |            |            |            |
     |       2            2            2            |
     |       |            |            |            |
     |       v            v            v            |
     |       +----+       +----+       +----+       |
     |       |    |       |    |       |    |       |
     |       |    |       |    |       |    |       |
     |       +----+       +----+       +----+       |
     |       <-3->        <-3->        <-3->        |
     +----------------------------------------------+
     
     1 : containerPadding
     2 : cellPadding
     3 : cellSize
     */
    
    static let containerPadding: Float = 0.05
    static let cellPadding: Float = 0.003
    static let cellSize: Float = 0.1
    static let lineCount: Int = 6
    static let containerSize: Float = containerPadding + cellSize * Float(lineCount) + cellPadding * Float(lineCount + 1)
}

fileprivate struct AssetComponent: Component {
    let asset: PHAsset
    let image: UIImage
}

@MainActor
final class ViewController: UIViewController {
    private var arView: ARView! { view as? ARView }
    @ViewLoading private var coachingOverlayView: ARCoachingOverlayView
    @ViewLoading private var resetButton: UIButton
    private var assetComponents: [AssetComponent]?
    private var resetTask: Task<Void, Never>?
    
    deinit {
        resetTask?.cancel()
    }
    
    override func loadView() {
        view = ARView(
            frame: .null,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let arView: ARView = self.arView
        let session: ARSession = arView.session
        
        session.delegate = self
        
        let coachingOverlayView: ARCoachingOverlayView = .init(frame: arView.bounds)
        coachingOverlayView.delegate = self
        coachingOverlayView.goal = .anyPlane
        coachingOverlayView.activatesAutomatically = true
        coachingOverlayView.session = session
        
        coachingOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        arView.addSubview(coachingOverlayView)
        self.coachingOverlayView = coachingOverlayView
        
        //
        
        var configuration: UIButton.Configuration = .tinted()
        configuration.title = "Reset"
        let resetAction: UIAction = .init { [unowned self] _ in
            reset()
        }
        
        let resetButton: UIButton = .init(configuration: configuration, primaryAction: resetAction)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(resetButton)
        NSLayoutConstraint.activate([
            resetButton.centerXAnchor.constraint(equalTo: arView.layoutMarginsGuide.centerXAnchor),
            resetButton.bottomAnchor.constraint(equalTo: arView.layoutMarginsGuide.bottomAnchor)
        ])
        self.resetButton = resetButton
        
        //
        
        let tapGesture: UITapGestureRecognizer = .init(target: self, action: #selector(tapGestureDidTrigger(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        //
        
        reset()
    }
    
    @objc private func tapGestureDidTrigger(_ sender: UITapGestureRecognizer) {
        let arView: ARView = arView
        let location: CGPoint = sender.location(in: arView)
        
        guard let entity: Entity = arView.entity(at: location),
        let assetComponent: AssetComponent = entity.components[AssetComponent.self] as? AssetComponent else {
            return
        }
        
        let hostingController: UIHostingController = .init(rootView: PHAssetThumbnailView(phAsset: assetComponent.asset, playIfVideoAsset: true))
        hostingController.safeAreaRegions = []
        present(hostingController, animated: true)
    }
    
    private func reset() {
        resetTask?.cancel()
        resetTask = .init {
            let status: PHAuthorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            
            guard status == .authorized || status == .limited else {
                await view.window?.windowScene?.open(.init(string: UIApplication.openSettingsURLString)!, options: nil)
                return
            }
            
            let assetCollectionsFetchResult: PHFetchResult<PHAssetCollection> = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
            
            guard let recentlyAddedCollection: PHAssetCollection = assetCollectionsFetchResult.firstObject else {
                return
            }
            
            let fetchLimit: Int = 36
            let fetchOptions: PHFetchOptions = .init()
            fetchOptions.fetchLimit = fetchLimit
            fetchOptions.sortDescriptors = [
                .init(key: #keyPath(PHAsset.creationDate), ascending: false)
            ]
            
            fetchOptions.includeHiddenAssets = false
            
            let assetsFetchResult: PHFetchResult<PHAsset> = PHAsset.fetchAssets(in: recentlyAddedCollection, options: fetchOptions)
            
            let imageRequestOptions: PHImageRequestOptions = .init()
            imageRequestOptions.allowSecondaryDegradedImage = false
            imageRequestOptions.deliveryMode = .opportunistic
            imageRequestOptions.isNetworkAccessAllowed = true
            
            let stream = PHImageManager.default().requestImages(for: assetsFetchResult, targetSize: .init(width: 500.0, height: 500.0), contentMode: .aspectFit, options: imageRequestOptions)
            var results: [Int: AssetComponent] = [:]
            
            for await partial in stream {
                let index: Int = partial.index
                let asset: PHAsset = partial.asset
                let result: Result<(image: UIImage, isDegraded: Bool), Error> = partial.result
                
                switch result {
                case .success((let image, let isDegraged)):
                    if !isDegraged {
                        results[index] = .init(asset: asset, image: image)
                    }
                case .failure(let error):
                    print(error)
                }
            }
            
            guard !Task.isCancelled else { 
                return
            }
            
            let assetComponents: [AssetComponent] = .init(unsafeUninitializedCapacity: results.count) { buffer, initializedCount in
                let count: Int = results.count
                
                guard count > .zero else { return }
                
                for (index, assetComponent) in results {
                    (buffer.baseAddress! + index).initialize(to: assetComponent)
                }
                
                initializedCount = results.count
            }
            
            self.assetComponents = assetComponents
            runConfiguration()
        }
    }
    
    private func runConfiguration(with session: ARSession? = nil) {
        let configuration: ARWorldTrackingConfiguration = .init()
        configuration.planeDetection = .horizontal
        (session ?? arView.session).run(configuration, options: [.removeExistingAnchors, .resetSceneReconstruction, .resetTracking, .stopTrackedRaycasts])
    }
}

extension ViewController: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !frame.anchors.contains(where: { $0.name == "ContainerAnchor" }) else { return }
        guard let assetComponents: [AssetComponent] else { 
            return
        }
        
        let arView: ARView = arView
        let bounds: CGRect = arView.bounds
        
        guard let query: ARRaycastQuery = arView
            .makeRaycastQuery(from: CGPoint(x: bounds.midX, y: bounds.midY),
                              allowing: .estimatedPlane,
                              alignment: .any) else {
            return
        }
        
        let raycasts: [ARRaycastResult] = session.raycast(query)
        
        guard let firstRaycast: ARRaycastResult = raycasts.first else { return }
        
        let mesh: MeshResource = .generateBox(width: CellLayout.containerSize, height: 0.001, depth: CellLayout.containerSize)
        
        let containerEntity: ModelEntity = .init(
            mesh: mesh,
            materials: [
                SimpleMaterial(color: UIColor.black.withAlphaComponent(0.75), isMetallic: true)
            ]
        )
        containerEntity.name = "ContainerEntity"
        
        for (index, assetComponent) in assetComponents.enumerated() {
            guard let cgImage: CGImage = assetComponent.image.cgImage else { continue }
            
            let texture: TextureResource = try! .generate(from: cgImage, options: .init(semantic: .hdrColor))
            
            var material: UnlitMaterial = .init()
            material.color = .init(tint: .white, texture: .init(texture))
            
            let entity: ModelEntity = .init(mesh: .generatePlane(width: 0.1, depth: 0.1), materials: [material])
            entity.name = assetComponent.asset.localIdentifier
            entity.components[AssetComponent.self] = assetComponent
            
            // https://stackoverflow.com/a/65847268/17473716
            entity.generateCollisionShapes(recursive: false)
            containerEntity.addChild(entity, preservingWorldTransform: true)
        }
        
        let anchor: ARAnchor = .init(name: "ContainerAnchor", transform: firstRaycast.worldTransform)
        session.add(anchor: anchor)
        
        let anchorEntity: AnchorEntity = .init(anchor: anchor)
        anchorEntity.anchoring = .init(anchor)
        anchorEntity.addChild(containerEntity, preservingWorldTransform: true)
        
        arView.scene.addAnchor(anchorEntity)
        self.assetComponents = nil
    }
    
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let containerAnchor: ARAnchor = anchors.first(where: { $0.name == "ContainerAnchor" }) else {
            return
        }
        
        guard let containerEntity: ModelEntity = arView.scene.anchors.first(where: { $0.anchoring == .init(containerAnchor) })?.children.first as? ModelEntity else {
            return
        }
        
        let children: [ModelEntity] = containerEntity.children.compactMap { $0 as? ModelEntity }
        
        if let firstEntity: ModelEntity = children.first,
           firstEntity.transform.translation.y != .zero {
            return
        }
        
        for (index, child) in children.enumerated() {
            let row: Int = index / 6
            let column: Int = index % 6
            var transform: Transform = child.transform
            
            transform.translation = .init(
                x: CellLayout.cellPadding * Float(column + 1) + Float(column) * CellLayout.cellSize + (CellLayout.containerPadding + CellLayout.cellSize - CellLayout.containerSize) * 0.5,
                y: 0.01,
                z: CellLayout.cellPadding * Float(row + 1) + Float(row) * CellLayout.cellSize + (CellLayout.containerPadding + CellLayout.cellSize - CellLayout.containerSize) * 0.5
            )
            
            child.move(to: transform, relativeTo: nil, duration: 1.0, timingFunction: .easeInOut)
        }
    }
}

extension ViewController: ARCoachingOverlayViewDelegate {
    func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        runConfiguration(with: coachingOverlayView.session)
    }
}
