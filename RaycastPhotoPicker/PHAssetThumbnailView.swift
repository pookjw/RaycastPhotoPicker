//
//  PHAssetThumbnailView.swift
//  RaycastPhotoPicker
//
//  Created by Jinwoo Kim on 5/19/24.
//

import SwiftUI
import Photos
import AVFoundation

final class VideoPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    
    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
    
    init(player: AVPlayer) {
        super.init(frame: .null)
        self.playerLayer.player = player
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension VideoPlayerView {
    struct SwiftUIView: UIViewRepresentable {
        private let player: AVPlayer
        private var videoGravity: AVLayerVideoGravity = .resizeAspect
        
        init(player: AVPlayer) {
            self.player = player
        }
        
        func makeUIView(context: Context) -> VideoPlayerView {
            let uiView = VideoPlayerView(player: player)
            uiView.playerLayer.videoGravity = videoGravity
            return uiView
        }
        
        func updateUIView(_ uiView: VideoPlayerView, context: Context) {
            if uiView.playerLayer.player != player {
                uiView.playerLayer.player = player
            }
            
            uiView.playerLayer.videoGravity = videoGravity
        }
    }
}

extension View {
    func onChangeSize(_ handler: @escaping (_ size: CGSize) -> Void) -> some View {
        overlay {
            GeometryReader { proxy in
                Color
                    .clear
                    .preference(key: SizePrefenceKey.self, value: proxy.size)
            }
        }
        .onPreferenceChange(SizePrefenceKey.self) { size in
            handler(size)
        }
    }
}

fileprivate struct SizePrefenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

extension VideoPlayerView.SwiftUIView {
    func videoGravity(_ videoGravity: AVLayerVideoGravity) -> VideoPlayerView.SwiftUIView {
        var copy = self
        copy.videoGravity = videoGravity
        return copy
    }
}

struct PHAssetThumbnailView: View {
    private let phAsset: PHAsset
    private let playIfVideoAsset: Bool
    
    @State private var viewSize = CGSize.zero
    @State private var image: UIImage?
    @State private var player: AVQueuePlayer?
    @State private var playerLooper: AVPlayerLooper?
    @Environment(\.displayScale) private var displayScale: CGFloat
    
    @State private var imageRequestID: PHImageRequestID?
    @State private var videoRequestID: PHImageRequestID?
    
    init(phAsset: PHAsset, playIfVideoAsset: Bool) {
        self.phAsset = phAsset
        self.playIfVideoAsset = playIfVideoAsset
    }
    
    var body: some View {
        Group {
            if let image {
                Color
                    .clear
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipShape(Rectangle())
                    .overlay {
                        if let player {
                            VideoPlayerView.SwiftUIView(player: player)
                                .videoGravity(.resizeAspectFill)
                        }
                    }
            } else {
                Color
                    .clear
                    .overlay {
                        ProgressView()
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4.0))
        .onChangeSize { size in
            guard viewSize != size else { return }
            viewSize = size
        }
        .onChange(of: phAsset, initial: true) { _, _ in
            requestImage()
        }
        .onChange(of: viewSize, initial: false) { _, _ in
            requestImage()
        }
        .onChange(of: displayScale, initial: false) { _, _ in
            requestImage()
        }
        .onChange(of: playIfVideoAsset, initial: true) { _, newValue in
            guard newValue else {
                cancelCurrentVideoRequestIfNeeded()
                player?.removeAllItems()
                player = nil
                playerLooper = nil
                return
            }
            
            requestVideo()
        }
    }
    
    private func requestImage() {
        cancelCurrentImageRequestIfNeeded()
        
        image = nil
        
        let targetSize = CGSize(width: viewSize.width * displayScale, height: viewSize.height * displayScale)
        
        let imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isSynchronous = false
        imageRequestOptions.deliveryMode = .opportunistic
        imageRequestOptions.resizeMode = .fast
        imageRequestOptions.isNetworkAccessAllowed = true
        imageRequestOptions.allowSecondaryDegradedImage = true
        
        let imageRequestID = PHImageManager.default().requestImage(for: phAsset, targetSize: targetSize, contentMode: .aspectFill, options: imageRequestOptions) { image, userInfo in
            let isCanclled = userInfo?[PHImageCancelledKey] as? Bool ?? false
            
            guard !isCanclled else {
                return
            }
            
            if let error = userInfo?[PHImageErrorKey] as? Error {
                print(error)
                return
            }
            
            guard let image else {
                print("No Image!")
                return
            }
            
            let requestID = userInfo?[PHImageResultRequestIDKey] as? PHImageRequestID
            
            Task { @MainActor in
                guard self.imageRequestID == requestID else {
                    return
                }
                
                let displayImage = await image.byPreparingForDisplay()
                
                guard self.imageRequestID == requestID else {
                    return
                }
                
                self.image = displayImage
            }
        }
        
        self.imageRequestID = imageRequestID
    }
    
    private func requestVideo() {
        cancelCurrentVideoRequestIfNeeded()
        
        player?.removeAllItems()
        player = nil
        playerLooper = nil
        
        guard phAsset.mediaType == .video else {
            return
        }
        
        let videoRequestOptions = PHVideoRequestOptions()
        videoRequestOptions.deliveryMode = .fastFormat
        videoRequestOptions.isNetworkAccessAllowed = true
        
        let videoRequestID = PHImageManager.default().requestPlayerItem(forVideo: phAsset, options: videoRequestOptions) { playerItem, userInfo in
            let isCanclled = userInfo?[PHImageCancelledKey] as? Bool ?? false
            
            guard !isCanclled else {
                return
            }
            
            if let error = userInfo?[PHImageErrorKey] as? Error {
                print(error)
                return
            }
            
            guard let playerItem else {
                print("No playerItem")
                return
            }
            
            let requestID = userInfo?[PHImageResultRequestIDKey] as? PHImageRequestID
            
            Task { @MainActor in
                guard self.videoRequestID == requestID else {
                    return
                }
                
                let player = AVQueuePlayer(playerItem: playerItem)
                player.isMuted = true
                let playerLooper = AVPlayerLooper(player: player, templateItem: playerItem)
                
                self.player = player
                self.playerLooper = playerLooper
                
                player.play()
            }
        }
        
        self.videoRequestID = videoRequestID
    }
    
    @discardableResult
    private func cancelCurrentImageRequestIfNeeded() -> Bool {
        guard let imageRequestID else {
            return false
        }
        
        PHImageManager.default().cancelImageRequest(imageRequestID)
        self.imageRequestID = nil
        
        return true
    }
    
    @discardableResult
    private func cancelCurrentVideoRequestIfNeeded() -> Bool {
        guard let videoRequestID else {
            return false
        }
        
        PHImageManager.default().cancelImageRequest(videoRequestID)
        self.videoRequestID = nil
        
        return true
    }
}
