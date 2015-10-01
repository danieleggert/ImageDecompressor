//
//  ImagePreview.swift
//  ImageDecompressor
//
//  Created by Daniel Eggert on 29/09/2015.
//  Copyright © 2015 Daniel Eggert. All rights reserved.
//

import UIKit


private let BitsPerComponent = 5
private func bytesPerRowForWidth(width: Int) -> Int { return width * 2 }
private let PreviewBitmapInfo = UInt32(CGImageAlphaInfo.NoneSkipFirst.rawValue)

struct ImagePreviewDataGenerator {
    init?(image: UIImage) {
        guard let cgImage = image.CGImage else { return nil }
        self.init(image: cgImage, orientation: image.imageOrientation)
    }
    init(image: CGImage, orientation: UIImageOrientation) {
        let fullWidth = CGImageGetWidth(image)
        let fullHeight = CGImageGetHeight(image)
        
        let targetPixelCount = 2500
        let scale = sqrt(Double(targetPixelCount) / Double(fullHeight * fullWidth))
        let width = Int(floor(Double(fullWidth) * scale))
        let height = Int(floor(Double(fullHeight) * Double(width) / Double(fullWidth)))
        
        let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)!
        let mutableData = NSMutableData(length: height * 2 * width)!
        let ctx = CGBitmapContextCreateWithData(mutableData.mutableBytes,
            width, height, BitsPerComponent, bytesPerRowForWidth(width), space, PreviewBitmapInfo,
            nil, UnsafeMutablePointer<Void>())
        CGContextDrawImage(ctx, CGRect(x: 0, y: 0, width: width, height: height), image)
        self.imageData = mutableData
        self.header = ImagePreviewHeader(fullWidth: fullWidth, fullHeight: fullHeight, width: width, height: height, orientation: orientation)
    }
    private let imageData: NSData
    private let header: ImagePreviewHeader
    func writeToFileAtURL(fileURL: NSURL) throws {
        let fm = NSFileManager.defaultManager()
        let tempDirectory = try fm.URLForDirectory(.ItemReplacementDirectory, inDomain: .UserDomainMask, appropriateForURL: fileURL, create: true)
        let tempFile = tempDirectory.URLByAppendingPathComponent(fileURL.lastPathComponent!)
        NSData().writeToURL(tempFile, atomically: false)
        let handle = try NSFileHandle(forWritingToURL: tempFile)
        handle.writeData(header.dataRepresentation)
        handle.writeData(imageData)
        handle.closeFile()
        try fm.replaceItemAtURL(fileURL, withItemAtURL: tempFile, backupItemName: nil, options: .UsingNewMetadataOnly, resultingItemURL: nil)
        try fm.removeItemAtURL(tempDirectory)
    }
}

public class ImagePreviewStore {
    private let baseURL: NSURL
    private let cache = NSCache()
    private var appWillBackgroundToken: NSObjectProtocol? = nil
    public init(baseURL: NSURL) {
        self.baseURL = baseURL
        try! NSFileManager.defaultManager().createDirectoryAtURL(baseURL, withIntermediateDirectories: false, attributes: nil)
        appWillBackgroundToken = NSNotificationCenter.defaultCenter().addObserverForName(UIApplicationDidEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }
    public func imageWithName(name: String) -> UIImage? {
        if let image = cache.objectForKey(name) as? UIImage {
            return image
        }
        do {
            let data = try NSData(contentsOfURL: fileURLForName(name), options: .DataReadingMappedIfSafe)
            if let image = uiKitImageFromMappedData(data) {
                cache.setObject(image, forKey: name)
                return image
            }
        } catch {}
        return nil
    }
    public func setImage(image: UIImage, forName name: String) -> Bool {
        do {
            guard let generator = ImagePreviewDataGenerator(image: image) else { return false }
            try generator.writeToFileAtURL(fileURLForName(name))
            return true
        } catch let e {
            print("\(e)")
        }
        return false
    }
    func fileURLForName(name: String) -> NSURL {
        let filename = name.stringByAddingPercentEncodingWithAllowedCharacters(NSCharacterSet.alphanumericCharacterSet())!
        return baseURL.URLByAppendingPathComponent(filename)
    }
}


private func uiKitImageFromMappedData(data: NSData) -> UIImage? {
    guard let (image, header) = imageFromMappedData(data) else { return nil }
    let scale = min(
        CGFloat(header.height) / CGFloat(header.fullHeight),
        CGFloat(header.width) / CGFloat(header.fullWidth)
    )
    return UIImage(CGImage: image, scale: scale, orientation: header.orientation)
}


private func imageFromMappedData(data: NSData) -> (CGImage,ImagePreviewHeader)? {
    guard
        let header = ImagePreviewHeader(dataRepresentaiton: data)
        where bytesPerRowForWidth(header.width) * header.height + ImagePreviewHeader.dataRepresentationLength == data.length
        else { return nil }
    
    let info = UnsafeMutablePointer<Void>(Unmanaged.passRetained(data).toOpaque())
    let bytes = data.bytes.advancedBy(ImagePreviewHeader.dataRepresentationLength)
    let size = data.length - ImagePreviewHeader.dataRepresentationLength
    let releaseInfo: CGDataProviderReleaseDataCallback = { (info: UnsafeMutablePointer<Void>, _, _) -> () in
        let pointer = COpaquePointer(info)
        Unmanaged<NSData>.fromOpaque(pointer).release()
        return
    }
    let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)!
    let provider = CGDataProviderCreateWithData(info, bytes, size, releaseInfo)
    guard let image = CGImageCreate(header.width, header.height, BitsPerComponent, 16, bytesPerRowForWidth(header.width), space, CGBitmapInfo(rawValue:PreviewBitmapInfo), provider, nil, true, .RenderingIntentDefault) else { return nil }
    return (image, header)
}


struct ImagePreviewHeader {
    static let magic: UInt16 = 0x5aec
    let fullWidth: Int
    let fullHeight: Int
    let width: Int
    let height: Int
    let orientation: UIImageOrientation
    init(fullWidth: Int, fullHeight: Int, width: Int, height: Int, orientation: UIImageOrientation) {
        self.width = width
        self.height = height
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
        self.orientation = orientation
    }
    init?(dataRepresentaiton data: NSData) {
        guard ImagePreviewHeader.dataRepresentationLength <= data.length else { return nil }
        let buffer = UnsafeBufferPointer<UInt16>(start: UnsafePointer<UInt16>(data.bytes), count: ImagePreviewHeader.dataRepresentationLength / 2)
        guard CFSwapInt16BigToHost(buffer[0]) == ImagePreviewHeader.magic else { return nil }
        self.fullWidth = Int(CFSwapInt16BigToHost(buffer[1]))
        self.fullHeight = Int(CFSwapInt16BigToHost(buffer[2]))
        self.width = Int(CFSwapInt16BigToHost(buffer[3]))
        self.height = Int(CFSwapInt16BigToHost(buffer[4]))
        guard let o = UIImageOrientation(rawValue: Int(CFSwapInt16BigToHost(buffer[5]))) else { return nil }
        self.orientation = o
    }
    static let dataRepresentationLength: Int = 6 * 2
    var dataRepresentation: NSData {
        let bigEndian: [UInt16] = [
            ImagePreviewHeader.magic,
            UInt16(fullWidth), UInt16(fullHeight),
            UInt16(width), UInt16(height),
            UInt16(orientation.rawValue),
        ].map { CFSwapInt16HostToBig($0) }
        let data = NSData(bytes: UnsafePointer<Void>(bigEndian), length: bigEndian.count * sizeof(UInt16))
        assert(data.length == ImagePreviewHeader.dataRepresentationLength)
        return data
    }
}
