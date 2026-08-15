import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testLaunchBackgroundContainsRequiredLightAndDarkColors() throws {
    let dynamicColor = try XCTUnwrap(
      UIColor(named: "LaunchBackground", in: .main, compatibleWith: nil)
    )
    let light = dynamicColor.resolvedColor(
      with: UITraitCollection(userInterfaceStyle: .light)
    )
    let dark = dynamicColor.resolvedColor(
      with: UITraitCollection(userInterfaceStyle: .dark)
    )

    assertColor(light, red: 0, green: 109, blue: 119)
    assertColor(dark, red: 0, green: 63, blue: 69)
  }

  func testJapaneseLocalizationIsBundled() {
    XCTAssertNotNil(Bundle.main.path(forResource: "ja", ofType: "lproj"))
  }

  func testBackupExclusionIsReadBackForDirectoryAndFinalFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "backup-exclusion-\(UUID().uuidString)",
      isDirectory: true
    )
    let finalFile = root.appendingPathComponent("managed.mp4")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false
    )
    XCTAssertTrue(
      FileManager.default.createFile(
        atPath: finalFile.path,
        contents: Data([0x00, 0x01, 0x02])
      )
    )

    try BackupExclusionAttribute.applyAndVerify(path: root.path)
    try BackupExclusionAttribute.applyAndVerify(path: finalFile.path)

    let rootValues = try root.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    let fileValues = try finalFile.resourceValues(
      forKeys: [.isExcludedFromBackupKey]
    )
    XCTAssertEqual(rootValues.isExcludedFromBackup, true)
    XCTAssertEqual(fileValues.isExcludedFromBackup, true)
  }

  private func assertColor(
    _ color: UIColor,
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var actualRed: CGFloat = 0
    var actualGreen: CGFloat = 0
    var actualBlue: CGFloat = 0
    var actualAlpha: CGFloat = 0
    XCTAssertTrue(
      color.getRed(
        &actualRed,
        green: &actualGreen,
        blue: &actualBlue,
        alpha: &actualAlpha
      ),
      file: file,
      line: line
    )
    XCTAssertEqual(actualRed * 255, red, accuracy: 0.5, file: file, line: line)
    XCTAssertEqual(
      actualGreen * 255,
      green,
      accuracy: 0.5,
      file: file,
      line: line
    )
    XCTAssertEqual(
      actualBlue * 255,
      blue,
      accuracy: 0.5,
      file: file,
      line: line
    )
    XCTAssertEqual(actualAlpha, 1, accuracy: 0.001, file: file, line: line)
  }
}
