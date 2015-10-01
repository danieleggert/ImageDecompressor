//
//  ImagePreviewTests.swift
//  ImageDecompressor
//
//  Created by Daniel Eggert on 29/09/2015.
//  Copyright © 2015 Daniel Eggert. All rights reserved.
//

import XCTest
import UIKit
@testable import Utilities



final class ImagePreviewTests: XCTestCase {
    
    var image: UIImage {
        let bundle = NSBundle(forClass: ImagePreviewTests.self)
        return UIImage(named: "bike.jpeg", inBundle: bundle, compatibleWithTraitCollection: nil)!
    }
    
    var filesToBeDeleted: [NSURL] = []
    
    var temporaryFileURL: NSURL {
        let temporaryDirectory = NSURL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let result = temporaryDirectory.URLByAppendingPathComponent(NSUUID().UUIDString)
        filesToBeDeleted.append(result)
        return result
    }
    
    override func tearDown() {
        super.tearDown()
        
        let fm = NSFileManager.defaultManager()
        for url in filesToBeDeleted {
            do {
                try fm.removeItemAtURL(url)
            } catch {}
        }
    }
    
    func testThatItCanCreateAGeneratorAndWriteToAFile() {
        let generator = ImagePreviewDataGenerator(image: image)
        XCTAssertNotNil(generator)
        do {
            try generator?.writeToFileAtURL(temporaryFileURL)
        } catch (let e) {
            XCTFail("\(e)")
        }
    }
    
    func testThatItCanRoundTripAnImageThroughTheStore() {
        let name = "foo"
        let sut = ImagePreviewStore(baseURL: temporaryFileURL)
        let success = sut.setImage(image, forName: name)
        XCTAssertTrue(success)
        let preview = sut.imageWithName(name)
        XCTAssertNotNil(preview)
        XCTAssertEqualWithAccuracy(preview!.size.height, 3264, accuracy: 0.5)
        XCTAssertEqualWithAccuracy(preview!.size.width, 2462, accuracy: 0.5)
    }
}
