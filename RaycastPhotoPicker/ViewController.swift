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
import MultipeerConnectivity

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

fileprivate struct AssetComponent: Component, Codable {
    private enum CodingKeys: CodingKey {
        case localIdentifier
        case heicData
    }
    
    let asset: PHAsset?
    let image: UIImage?
    
    init(asset: PHAsset, image: UIImage) {
        self.asset = asset
        self.image = image
    }
    
    init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        if let localIdentifier: String = try container.decodeIfPresent(String.self, forKey: .localIdentifier) {
            let options: PHFetchOptions = .init()
            options.includeHiddenAssets = true
            options.fetchLimit = 1
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: options).firstObject
        } else {
            asset = nil
        }
        
        if let heicData: Data = try container.decodeIfPresent(Data.self, forKey: .heicData) {
            image = .init(data: heicData)
        } else {
            image = nil
        }
    }
    
    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        
        if let localIdentifier: String = asset?.localIdentifier {
            try container.encode(localIdentifier, forKey: .localIdentifier)
        }
        
        if let image: UIImage {
            try container.encode(image.heicData(), forKey: .heicData)
        }
    }
}

fileprivate struct DidRequestComponent: Component {
    let didRequest: Bool
}

@MainActor
final class ViewController: UIViewController {
    private var arView: ARView! { view as? ARView }
    @ViewLoading private var coachingOverlayView: ARCoachingOverlayView
    @ViewLoading private var resetButton: UIButton
    private var assetComponents: [AssetComponent]?
    private var resetTask: Task<Void, Never>?
    
    private let peerID: MCPeerID
    private let multiSession: MCSession
    private let advertiserAssistant: MCAdvertiserAssistant
    private var sessionIdentifiersByPeerID: [MCPeerID: UUID] = [:]
    
    private var sessionIdentifierObservation: NSKeyValueObservation?
    
    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        let peerID: MCPeerID = .init(displayName: UUID().uuidString)
        let multiSession: MCSession = .init(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        let advertiserAssistant: MCAdvertiserAssistant = .init(serviceType: "ar-collab", discoveryInfo: nil, session: multiSession)
        
        self.peerID = peerID
        self.multiSession = multiSession
        self.advertiserAssistant = advertiserAssistant
        
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        
        multiSession.delegate = self
        
        let navigationItem: UINavigationItem = navigationItem
        
        navigationItem.leadingItemGroups = [
            .init(
                barButtonItems: [
                    .init(title: nil, image: .init(systemName: "arrow.clockwise"), target: self, action: #selector(resetBarButtonItemDidTrigger(_:)))
                ], 
                representativeItem: nil
            )
        ]
        
        navigationItem.trailingItemGroups = [
            .init(
                barButtonItems: [
                    .init(title: nil, image: .init(systemName: "person.3.fill"), target: self, action: #selector(multipeerBrowserBarButtonItemDidTrigger(_:)))
                ], 
                representativeItem: nil
            )
        ]
        
        navigationItem.largeTitleDisplayMode = .never
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
    
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
        
        sessionIdentifierObservation = arView.observe(\.session.identifier, options: .new, changeHandler: { [weak self] arView, change in
            Task { @MainActor [weak self] in
                let sessionIdentifier: UUID = change.newValue ?? arView.session.identifier
                self?.sessionIdentifierDidChange(sessionIdentifier)
            }
        })
        
        arView.scene.synchronizationService = try! MultipeerConnectivityService(session: multiSession)
        
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
        
        let tapGesture: UITapGestureRecognizer = .init(target: self, action: #selector(tapGestureDidTrigger(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        //
        
        runConfiguration()
        advertiserAssistant.start()
    }
    
    @objc private func resetBarButtonItemDidTrigger(_ sender: UIBarButtonItem) {
        reset()
    }
    
    @objc private func multipeerBrowserBarButtonItemDidTrigger(_ sender: UIBarButtonItem) {
        let browser: MCNearbyServiceBrowser = .init(peer: peerID, serviceType: "ar-collab")
        let browserViewController: MCBrowserViewController = .init(browser: browser, session: multiSession)
        browserViewController.delegate = self
        
        present(browserViewController, animated: true)
    }
    
    @objc private func tapGestureDidTrigger(_ sender: UITapGestureRecognizer) {
        let arView: ARView = arView
        let location: CGPoint = sender.location(in: arView)
        
        guard let entity: Entity = arView.entity(at: location),
              let assetComponent: AssetComponent = entity.components[AssetComponent.self] as? AssetComponent,
              let asset: PHAsset = assetComponent.asset
        else {
            return
        }
        
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
        configuration.isCollaborationEnabled = true
        (session ?? arView.session).run(configuration, options: [.removeExistingAnchors, .resetSceneReconstruction, .resetTracking, .stopTrackedRaycasts])
    }
    
    private func sessionIdentifierDidChange(_ sessionIdentifier: UUID) {
        let connectedPeers: [MCPeerID] = multiSession.connectedPeers
        
        guard !connectedPeers.isEmpty else { return }
        
        let prpoertyListEncoder: PropertyListEncoder = .init()
        
        let dictionary: [String: Data] = [
            "sessionIdentifier": sessionIdentifier.uuidString.data(using: .utf8)!
        ]
        
        let data: Data = try! prpoertyListEncoder.encode(dictionary)
        
        try! multiSession.send(data, toPeers: connectedPeers, with: .reliable)
    }
    
    private func removeAnchors(for peerID: MCPeerID) {
        guard let sessionIdentifier: UUID = sessionIdentifiersByPeerID[peerID],
            let currentFrame: ARFrame = arView.session.currentFrame else {
            return
        }
        
        currentFrame
            .anchors
            .filter { $0.sessionIdentifier == sessionIdentifier }
            .forEach { anchor in
                arView.session.remove(anchor: anchor)
            }
    }
    
    private var assetModelEntities: [ModelEntity] {
        return arView
            .scene
            .anchors
            .filter({ $0.name == "ContainerAnchor" })
            .compactMap({ $0 as? AnchorEntity })
            .flatMap({ $0.children })
            .filter({ $0.name == "ContainerEntity" })
            .flatMap({ $0.children })
            .compactMap({ $0 as? ModelEntity })
    }
}

extension ViewController: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated {
            let assetModelEntities: [ModelEntity] = assetModelEntities
            
            if !assetModelEntities.isEmpty {
                var requiredComponentNames: [String] = []
                
                for containerEntity in assetModelEntities {
                    let didRequest: Bool = containerEntity.components[DidRequestComponent.self]?.didRequest ?? false
                    
                    guard !didRequest, 
                            !containerEntity.isOwner,
                          containerEntity.components[AssetComponent.self] == nil
                    else {
                        continue
                    }
                    
                    containerEntity.withUnsynchronized {
                        containerEntity.components[DidRequestComponent.self] = DidRequestComponent(didRequest: true)
                    }
                    requiredComponentNames.append(containerEntity.name)
                }
                
                if !requiredComponentNames.isEmpty {
                    let prpoertyListEncoder: PropertyListEncoder = .init()
                    
                    let requiredComponentNamesData: Data = try! prpoertyListEncoder.encode(requiredComponentNames)
                    
                    let dictionary: [String: Data] = [
                        "requiredComponentNames": requiredComponentNamesData
                    ]
                    
                    let data: Data = try! prpoertyListEncoder.encode(dictionary)
                    try! multiSession.send(data, toPeers: multiSession.connectedPeers, with: .reliable)
                }
            }
            
            if let assetComponents: [AssetComponent],
               !frame.anchors.contains(where: { $0.name == "ContainerAnchor" })
            {
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
                
                for assetComponent in assetComponents {
                    guard let cgImage: CGImage = assetComponent.image?.cgImage,
                          let asset: PHAsset = assetComponent.asset
                    else { 
                        continue
                    }
                    
                    let texture: TextureResource = try! .generate(from: cgImage, options: .init(semantic: .hdrColor))
                    
                    var material: UnlitMaterial = .init()
                    material.color = .init(tint: .white, texture: .init(texture))
                    
                    let entity: ModelEntity = .init(mesh: .generatePlane(width: 0.1, depth: 0.1), materials: [material])
                    entity.name = asset.localIdentifier
                    entity.components[AssetComponent.self] = assetComponent
                    
                    // https://stackoverflow.com/a/65847268/17473716
                    entity.generateCollisionShapes(recursive: false)
                    containerEntity.addChild(entity, preservingWorldTransform: true)
                }
                
                let anchor: ARAnchor = .init(name: "ContainerAnchor", transform: firstRaycast.worldTransform)
                session.add(anchor: anchor)
                
                let anchorEntity: AnchorEntity = .init(anchor: anchor)
                anchorEntity.name = "ContainerAnchor"
                anchorEntity.anchoring = .init(anchor)
                anchorEntity.addChild(containerEntity, preservingWorldTransform: true)
                
                arView.scene.addAnchor(anchorEntity)
                self.assetComponents = nil
            }
        }
    }
    
    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        MainActor.assumeIsolated {
            guard let containerAnchor: ARAnchor = anchors.first(where: { $0.name == "ContainerAnchor" }) else {
                return
            }
            
            guard let containerEntities: [ModelEntity] = arView
                .scene
                .anchors
                .first(where: { $0.anchoring == .init(containerAnchor) })?
                .children
                .compactMap({ $0 as? ModelEntity })
            else {
                return
            }
            
            let children: [ModelEntity] = containerEntities
                .map { $0.children }
                .flatMap { $0 }
                .compactMap { $0 as? ModelEntity }
            
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
    
    nonisolated func session(_ session: ARSession, didOutputCollaborationData data: ARSession.CollaborationData) {
        MainActor.assumeIsolated { 
            let connectedPeers: [MCPeerID] = multiSession.connectedPeers
            
            guard !connectedPeers.isEmpty else { return }
            
            let collaborationData: Data = try! NSKeyedArchiver.archivedData(withRootObject: data, requiringSecureCoding: true)
            
            let dictionary: [String: Data] = [
                "collaborationData": collaborationData
            ]
            
            let prpoertyListEncoder: PropertyListEncoder = .init()
            let _data: Data = try! prpoertyListEncoder.encode(dictionary)
            
            try! multiSession.send(_data, toPeers: connectedPeers, with: data.priority == .critical ? .reliable : .reliable)
        }
    }
}

extension ViewController: ARCoachingOverlayViewDelegate {
    nonisolated func coachingOverlayViewDidRequestSessionReset(_ coachingOverlayView: ARCoachingOverlayView) {
        MainActor.assumeIsolated {
            runConfiguration(with: coachingOverlayView.session)
        }
    }
}

extension ViewController: MCBrowserViewControllerDelegate {
    nonisolated func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
        MainActor.assumeIsolated { 
            browserViewController.dismiss(animated: true)
        }
    }
    
    nonisolated func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
        MainActor.assumeIsolated { 
            browserViewController.dismiss(animated: true)
        }
    }
}

extension ViewController: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .notConnected:
            Task { @MainActor in
                removeAnchors(for: peerID)
                sessionIdentifiersByPeerID.removeValue(forKey: peerID)
            }
        case .connecting:
            break
            
        case .connected:
            break
        @unknown default:
            break
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let decoder: PropertyListDecoder = .init()
        let dictionary: [String: Data] = try! decoder.decode([String: Data].self, from: data)
        
        if let sessionIdentifierData: Data = dictionary["sessionIdentifier"] {
            let sessionIdentifier: String = .init(data: sessionIdentifierData, encoding: .utf8)!
            
            Task { @MainActor in
                removeAnchors(for: peerID)
                sessionIdentifiersByPeerID[peerID] = .init(uuidString: sessionIdentifier) 
            }
        }
        
        if let _collaborationData: Data = dictionary["collaborationData"] {
            Task { @MainActor in
                let collaborationData: ARSession.CollaborationData = try! NSKeyedUnarchiver.unarchivedObject(ofClass: ARSession.CollaborationData.self, from: _collaborationData)!
                arView.session.update(with: collaborationData)
            }
        }
        
        if let requiredComponentNamesData: Data = dictionary["requiredComponentNames"] {
            let decoder: PropertyListDecoder = .init()
            let requiredComponentNames: [String] = try! decoder.decode([String].self, from: requiredComponentNamesData)
            
            Task { @MainActor in
                let assetModelEntities: [ModelEntity] = assetModelEntities
                var componentsByName: [String: AssetComponent] = .init()
                
                for entity in assetModelEntities {
                    guard requiredComponentNames.contains(entity.name),
                          let assetComponent: AssetComponent = entity.components[AssetComponent.self]
                    else {
                        continue
                    }
                    
                    componentsByName[entity.name] = assetComponent
                }
                
                let encoder: PropertyListEncoder = .init()
                let componentsByNameData: Data = try! encoder.encode(componentsByName)
                
                let dictionary: [String: Data] = [
                    "componentsByName": componentsByNameData
                ]
                
                let data: Data = try! encoder.encode(dictionary)
                
                try! session.send(data, toPeers: session.connectedPeers, with: .reliable)
            }
        }
        
        if let componentsByNamesData: Data = dictionary["componentsByName"] {
            let decoder: PropertyListDecoder = .init()
            let componentsByName: [String: AssetComponent] = try! decoder.decode([String: AssetComponent].self, from: componentsByNamesData)
            
            Task { @MainActor in
                for modelEntity in assetModelEntities {
                    guard let assetComponent: AssetComponent = componentsByName[modelEntity.name] else {
                        continue
                    }
                    
                    modelEntity.withUnsynchronized {
                        modelEntity.components[AssetComponent.self] = assetComponent
                        
                        let texture: TextureResource = try! .generate(from: assetComponent.image!.cgImage!, options: .init(semantic: .hdrColor))
                        
                        var material: UnlitMaterial = .init()
                        material.color = .init(tint: .white, texture: .init(texture))
                        
                        modelEntity.model = .init(mesh: .generatePlane(width: 0.1, depth: 0.1), materials: [material])
                    }
                }
            }
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        
    }
    
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        
    }
    
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {
        
    }
}
