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

@MainActor
final class ViewController: UIViewController {
    private var arView: ARView! { view as? ARView }
    @ViewLoading private var coachingOverlayView: ARCoachingOverlayView
    @ViewLoading private var resetButton: UIButton
    private var images: [UIImage]?
    private var assetsFetchResult: PHFetchResult<PHAsset>?
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
        guard let assetsFetchResult: PHFetchResult<PHAsset> else {
            return
        }
        
        let arView: ARView = arView
        let location: CGPoint = sender.location(in: arView)
        
        guard let entity: Entity = arView.entity(at: location) else {
            return
        }
        
        let name: String = entity.name
        
        var asset: PHAsset?
        assetsFetchResult.enumerateObjects { _asset, _, stop in
            if _asset.localIdentifier == name {
                asset = _asset
                stop.pointee = true
            }
        }
        
        guard let asset: PHAsset else { return }
        
        let hostingController: UIHostingController = .init(rootView: PHAssetThumbnailView(phAsset: asset, playIfVideoAsset: true))
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
            
            let images: [UIImage] = try! await withThrowingTaskGroup(of: (Int, UIImage).self, returning: [UIImage].self) { group in
                let imageManager: PHImageManager = .default()
                
                let imageRequestOptions: PHImageRequestOptions = .init()
                imageRequestOptions.allowSecondaryDegradedImage = false
                imageRequestOptions.deliveryMode = .opportunistic
                imageRequestOptions.isNetworkAccessAllowed = true
                
                var interator: NSFastEnumerationIterator = .init(assetsFetchResult)
                var index: Int = .zero
                
                while let asset: PHAsset = interator.next() as? PHAsset {
                    group.addTask { [index] in
                        let lock: OSAllocatedUnfairLock = .init()
                        var requestID: PHImageRequestID?
                        let onCancel: () -> Void = {
                            lock.lock()
                            defer { lock.unlock() }
                            
                            if let requestID: PHImageRequestID {
                                imageManager.cancelImageRequest(requestID)
                            }
                        }
                        
                        return try await withTaskCancellationHandler { 
                            let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                                lock.lock()
                                defer { lock.unlock() }
                                
                                guard !Task.isCancelled else {
                                    continuation.resume(throwing: CancellationError())
                                    return
                                }
                                
                                requestID = imageManager.requestImage(
                                    for: asset,
                                    targetSize: CGSize(width: 1000.0, height: 1000.0),
                                    contentMode: .aspectFit,
                                    options: imageRequestOptions,
                                    resultHandler: { image, userInfo in
                                        if let userInfo {
                                            if let error: Error = userInfo[PHImageErrorKey] as? Error {
                                                continuation.resume(throwing: error)
                                                return
                                            } else if let isCancelled: Bool = userInfo[PHImageCancelledKey] as? Bool,
                                                      isCancelled {
                                                continuation.resume(throwing: CancellationError())
                                                return
                                            } else if let isDegraged: Bool = userInfo[PHImageResultIsDegradedKey] as? Bool,
                                                      isDegraged {
                                                return
                                            }
                                        }
                                        
                                        if let image: UIImage {
                                            continuation.resume(returning: image)
                                        }
                                    }
                                )
                            }
                            
                            return (index, image)
                        } onCancel: { 
                            onCancel()
                        }
                    }
                    
                    index += 1
                }
                
                
                var results: [(Int, UIImage)] = []
                while let next = try await group.next() {
                    results.append(next)
                }
                
                return [UIImage].init(unsafeUninitializedCapacity: results.count) { buffer, initializedCount in
                    let count: Int = results.count
                    
                    guard count > .zero else { return }
                    
                    for (index, image) in results {
                        (buffer.baseAddress! + index).initialize(to: image)
                    }
                    
                    initializedCount = results.count
                }
            }
            
            self.images = images
            self.assetsFetchResult = assetsFetchResult
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
        guard let images: [UIImage],
        let assetsFetchResult: PHFetchResult<PHAsset> else { 
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
        
        for (index, image) in images.enumerated() {
            let asset: PHAsset = assetsFetchResult[index]
            let texture: TextureResource = try! .generate(from: image.cgImage!, withName: asset.localIdentifier, options: .init(semantic: .hdrColor))
            
            var material: UnlitMaterial = .init()
            material.color = .init(tint: .white, texture: .init(texture))
            
            let entity: ModelEntity = .init(mesh: .generatePlane(width: 0.1, depth: 0.1), materials: [material])
            entity.name = asset.localIdentifier
            
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
        self.images = nil
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
