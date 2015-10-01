//
//  ImageLoader.swift
//  ImageDecompressor
//
//  Created by Daniel Eggert on 29/09/2015.
//  Copyright © 2015 Daniel Eggert. All rights reserved.
//

import UIKit



public class ImageLoader {
    private let baseURL: NSURL
    private let cache = NSCache()
    private var appWillBackgroundToken: NSObjectProtocol? = nil
    private let workQueue = NSOperationQueue()
    public init(baseURL: NSURL) {
        self.baseURL = baseURL
        appWillBackgroundToken = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
        workQueue.name = "ImageLoader"
        workQueue.qualityOfService = .Utility
    }
    public func imageAtURL(fileURL: NSURL, forKey key: String) -> UIImage? {
        if let image = cache.objectForKey(key) as? UIImage {
            return image
        }
        do {
//            cache.setObject(image, forKey: key)
//            return image
        } catch {}
        return nil
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
    convenience init?(image: UIImage) {
        guard
            let cgImage = image.CGImage,
            let (data, info) = createBitmapDataForImage(cgImage)
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
    init(image: CGImage) {
        width = CGImageGetWidth(image)
        height = CGImageGetWidth(image)
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
        let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
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
        let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
        if let ctx = CGBitmapContextCreate(UnsafeMutablePointer<Void>(data.mutableBytes), width, height, bitsPerComponent, bytesPerRow, space, bitmapInfo.rawValue) {
            block(ctx)
            return true
        } else {
            return false
        }
    }
}

func createBitmapDataForImage(image: CGImage) -> (NSPurgeableData,BitmapInfo)? {
    let bitmapInfo = BitmapInfo(image: image)
    guard let data = NSPurgeableData(length: bitmapInfo.bufferLength) else { return nil }
    let success = bitmapInfo.withBitmapContextWithData(data) { ctx in
        CGContextDrawImage(ctx, bitmapInfo.bounds, image)
    }
    if success {
        return (data,bitmapInfo)
    }
    return nil
}
