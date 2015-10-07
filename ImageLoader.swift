//
//  ImageLoader.swift
//  ImageDecompressor
//
//  Created by Daniel Eggert on 29/09/2015.
//  Copyright © 2015 Daniel Eggert. All rights reserved.
//

import UIKit


/// This class decodes images into a bitmap buffer and returns a new image from that data.
/// The resulting image hence no longer has to be decoded (from JPEG / PNG) to be used. That way the UI
/// thread isn't blocked for decoding.
///
/// The `ImageLoader` class uses a cache such that a subsequent call to an image may return the image from
/// that cache. The cache contains purgeable data such that the resulting pressure is low except for images
/// currently in use.
public class ImageLoader {
    public enum TargetSize {
        /// No downsampling.
        case Full
        /// Downsample the image to the specified width.
        case Width(CGFloat)
    }
    
    private let cache = NSCache()
    private var appWillBackgroundToken: NSObjectProtocol? = nil
    private let workQueue = NSOperationQueue()
    private let callbackQueue: dispatch_queue_t
    private var beingDecompressed: [(String,DecompressionHandler)] = []
    public init(callbackQueue: dispatch_queue_t) {
        self.callbackQueue = callbackQueue
        appWillBackgroundToken = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
        workQueue.name = "ImageLoader"
        workQueue.qualityOfService = .Utility
        workQueue.maxConcurrentOperationCount = 3
    }
    public typealias DecompressionHandler = (UIImage?) -> ()
    public func imageWithData(imageData: () -> NSData?, forKey key: String, targetSize: TargetSize, decompressionHandler: DecompressionHandler) -> UIImage? {
        return imageForKey(key, targetSize: targetSize, loadOriginal: { imageData().flatMap { UIImage(data: $0) } }, decompressionHandler: decompressionHandler)
    }
    public func imageAtURL(fileURL: NSURL, forKey key: String, targetSize: TargetSize, decompressionHandler: DecompressionHandler) -> UIImage? {
        return imageForKey(key, targetSize: targetSize, loadOriginal: {
            guard let path = fileURL.path, let compressedImage = UIImage(contentsOfFile: path) else {
                return nil
            }
            return compressedImage
        }, decompressionHandler: decompressionHandler)
    }
}

extension ImageLoader {
    private func imageForKey(key: String, targetSize: TargetSize, loadOriginal: () -> UIImage?, decompressionHandler: DecompressionHandler) -> UIImage? {
        if let bitmap = cache.objectForKey(key) as? PurgeableImageBitmapData {
            if let image = bitmap.createImage() {
                return image
            } else {
                cache.removeObjectForKey(key)
            }
        }
        if !checkExistsAndAddKey(key, handler: decompressionHandler) {
            workQueue.addOperationWithBlock { [weak self] in
                if let compressedImage = loadOriginal(),
                    let bitmap = PurgeableImageBitmapData(image: compressedImage, targetSize: targetSize) {
                        self?.cache.setObject(bitmap, forKey: key)
                        let image = bitmap.createImage()
                        bitmap.endContentAccess() // Starts out as 'begin access', need to balance.
                        self?.didDecompressImage(image, forKey: key)
                        return
                }
                self?.didDecompressImage(nil, forKey: key)
            }
        }
        return nil
    }
    
    private func checkExistsAndAddKey(key: String, handler: DecompressionHandler) -> Bool {
        let keyExists = beingDecompressed.indexOf({ $0.0 == key }) != nil
        beingDecompressed.append((key, handler))
        return keyExists
    }
    
    private func didDecompressImage(image: UIImage?, forKey key: String) {
        dispatch_async(callbackQueue) { [weak self] in
            guard let loader = self else { return }
            while let idx = loader.beingDecompressed.indexOf({ $0.0 == key }) {
                let handler = loader.beingDecompressed[idx].1
                loader.beingDecompressed.removeAtIndex(idx)
                handler(image)
            }
        }
    }
}


private final class PurgeableImageBitmapData {
    let data: NSPurgeableData
    let bitmapInfo: BitmapInfo
    let orientation: UIImageOrientation
    init(data: NSPurgeableData, bitmapInfo: BitmapInfo, orientation: UIImageOrientation) {
        self.data = data
        self.bitmapInfo = bitmapInfo
        self.orientation = orientation
    }
}

extension PurgeableImageBitmapData : NSDiscardableContent {
    @objc func beginContentAccess() -> Bool {
        return data.beginContentAccess()
    }
    @objc func endContentAccess() {
        return data.endContentAccess()
    }
    @objc func discardContentIfPossible() {
        data.discardContentIfPossible()
    }
    @objc func isContentDiscarded() -> Bool {
        return data.isContentDiscarded()
    }
}


private extension PurgeableImageBitmapData {
    convenience init?(image: UIImage, targetSize: ImageLoader.TargetSize) {
        guard
            let cgImage = image.CGImage,
            let (data, info) = createBitmapDataForImage(cgImage, targetSize: targetSize)
            else { return nil }
        self.init(data: data, bitmapInfo: info, orientation: image.imageOrientation)
    }
    func createImage() -> UIImage? {
        guard let cgImage = createCGImage() else { return nil }
        return UIImage(CGImage: cgImage, scale: 1, orientation: orientation)
    }
    func createCGImage() -> CGImage? {
        guard let provider = createDataProvider() else { return nil }
        return bitmapInfo.createImageWithDataProvider(provider)
    }
    func createDataProvider() -> CGDataProvider? {
        guard beginContentAccess() else { return nil }
        let info = UnsafeMutablePointer<Void>(Unmanaged.passRetained(data).toOpaque())
        let release: CGDataProviderReleaseDataCallback = { (info, _, _) -> () in
            let pointer = COpaquePointer(info)
            let data = Unmanaged<NSPurgeableData>.fromOpaque(pointer).takeRetainedValue()
            data.endContentAccess()
        }
        return CGDataProviderCreateWithData(info, data.bytes, data.length, release)
    }
}

struct BitmapInfo {
    let width: Int
    let height: Int
    let bitsPerPixel: Int
    let bitsPerComponent: Int
    let bitmapInfo: CGBitmapInfo
    init(image: CGImage, targetSize: ImageLoader.TargetSize) {
        switch targetSize {
        case .Full:
            width = CGImageGetWidth(image)
            height = CGImageGetHeight(image)
        case .Width(let w):
            let ww = Int(ceil(w))
            if ww < CGImageGetWidth(image) {
                width = ww
                let scale = w / CGFloat(CGImageGetWidth(image))
                height = Int(round(CGFloat(CGImageGetHeight(image)) * scale))
            } else {
                width = CGImageGetWidth(image)
                height = CGImageGetHeight(image)
            }
        }
        if CGColorSpaceGetModel(CGImageGetColorSpace(image)) == .RGB {
            bitsPerPixel = CGImageGetBitsPerPixel(image)
            bitsPerComponent = CGImageGetBitsPerComponent(image)
            bitmapInfo = CGImageGetBitmapInfo(image)
        } else {
            bitsPerPixel = 24
            bitsPerComponent = 8
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.PremultipliedFirst.rawValue)
        }
    }
    init(dimensionsFromImage image: CGImage) {
        width = CGImageGetWidth(image)
        height = CGImageGetWidth(image)
        bitsPerPixel = 24
        bitsPerComponent = 8
        bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.PremultipliedFirst.rawValue)
    }
    func createImageWithDataProvider(provider: CGDataProvider) -> CGImage? {
        let space = rgbColorSpace()
        return CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, space, bitmapInfo, provider, nil, true, .RenderingIntentDefault)
    }
}

extension BitmapInfo {
    var bytesPerRow: Int {
        return bitsPerPixel * width / 8
    }
    var bufferLength: Int {
        return bytesPerRow * height
    }
    var bounds: CGRect {
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
    func withBitmapContextWithData(data: NSMutableData, @noescape block: (CGContext) -> ()) -> Bool {
        let space = rgbColorSpace()
        if let ctx = CGBitmapContextCreate(UnsafeMutablePointer<Void>(data.mutableBytes), width, height, bitsPerComponent, bytesPerRow, space, bitmapInfo.rawValue) {
            block(ctx)
            return true
        } else {
            return false
        }
    }
}

func createBitmapDataForImage(image: CGImage, targetSize: ImageLoader.TargetSize) -> (NSPurgeableData,BitmapInfo)? {
    let bitmapInfo = BitmapInfo(image: image, targetSize: targetSize)
    guard let data = NSPurgeableData(length: bitmapInfo.bufferLength) else { return nil }
    let success = bitmapInfo.withBitmapContextWithData(data) { ctx in
        CGContextDrawImage(ctx, bitmapInfo.bounds, image)
    }
    if success {
        return (data,bitmapInfo)
    }
    return nil
}

private func rgbColorSpace() -> CGColorSpace {
    if #available(iOS 9.0, *) {
        return CGColorSpaceCreateWithName(kCGColorSpaceSRGB)!
    } else {
        return CGColorSpaceCreateDeviceRGB()!
    }
}
