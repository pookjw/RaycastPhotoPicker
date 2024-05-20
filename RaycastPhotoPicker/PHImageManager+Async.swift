//
//  PHImageManager+Async.swift
//  RaycastPhotoPicker
//
//  Created by Jinwoo Kim on 5/20/24.
//

import UIKit
@preconcurrency import Photos
import os

/*
 /* Usage */
 
 var results: [Int: UIImage] = [:]
 
 for await partial in stream {
     let index: Int = partial.index
     let result: Result<(image: UIImage, isDegraded: Bool), Error> = partial.result
     
     switch result {
     case .success((let image, let isDegraged)):
         if !isDegraged {
             results[index] = image
         }
     case .failure(let error):
         print(error)
     }
 }
 
 // To Array
 
 let images: [UIImage] = .init(unsafeUninitializedCapacity: results.count) { buffer, initializedCount in
     let count: Int = results.count
     
     guard count > .zero else { return }
     
     for (index, image) in results {
         (buffer.baseAddress! + index).initialize(to: image)
     }
     
     initializedCount = results.count
 }
 */
extension PHImageManager {
    nonisolated func requestImages(
        for assets: PHFetchResult<PHAsset>,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        options: PHImageRequestOptions?
    ) -> AsyncStream<(asset: PHAsset, index: Int, result: Result<(image: UIImage, isDegraded: Bool), Error>)> {
        let copiedOptions: PHImageRequestOptions? = options?.copy() as? PHImageRequestOptions
        let (stream, continuation) = AsyncStream<(asset: PHAsset, index: Int, result: Result<(image: UIImage, isDegraded: Bool), Error>)>.makeStream(bufferingPolicy: .unbounded)
        
        let task: Task<Void, Never> = .init {
            await withDiscardingTaskGroup(returning: Void.self) { group in
                var interator: NSFastEnumerationIterator = .init(assets)
                var index: Int = .zero
                
                while let asset: PHAsset = interator.next() as? PHAsset {
                    group.addTask { [index] in
                        let lock: OSAllocatedUnfairLock<PHImageRequestID?> = .init(initialState: nil)
                        
                        await withTaskCancellationHandler {
                            let _: Void = await withCheckedContinuation { _continuation in
                                lock.withLock { requestID in
                                    guard !Task.isCancelled else {
                                        continuation.yield((asset, index, .failure(CancellationError())))
                                        _continuation.resume()
                                        return
                                    }
                                    
                                    requestID = self.requestImage(
                                        for: asset,
                                        targetSize: targetSize,
                                        contentMode: contentMode,
                                        options: copiedOptions,
                                        resultHandler: { image, userInfo in
                                            if let userInfo {
                                                if let error: Error = userInfo[PHImageErrorKey] as? Error {
                                                    continuation.yield((asset, index, .failure(error)))
                                                    _continuation.resume()
                                                    return
                                                } else if let isCancelled: Bool = userInfo[PHImageCancelledKey] as? Bool,
                                                          isCancelled {
                                                    continuation.yield((asset, index, .failure(CancellationError())))
                                                    _continuation.resume()
                                                    return
                                                }
                                            }
                                            
                                            if let image: UIImage {
                                                let isDegraged: Bool = userInfo?[PHImageResultIsDegradedKey] as? Bool ?? false
                                                continuation.yield((asset, index, .success((image, isDegraged))))
                                                
                                                if !isDegraged {
                                                    _continuation.resume()
                                                }
                                            }
                                        }
                                    )
                                }
                            }
                        } onCancel: {
                            lock.withLock { requestID in
                                if let requestID: PHImageRequestID {
                                    self.cancelImageRequest(requestID)
                                }
                            }
                        }
                    }
                    
                    index += 1
                }
            }
            
            continuation.finish()
        }
        
        continuation.onTermination = { termination in
            switch termination {
            case .cancelled:
                task.cancel()
            case .finished:
                break
            @unknown default:
                break
            }
        }
        
        return stream
    }
}
