import CryptoKit
import Foundation
import System

import Logging
import XibLoc



struct Tarball {
	
	let url: URL
	
	var version: String
	var localPath: FilePath
	
	var expectedShasum: String?
	
	/** The name of the tarball without the extensions. Usually the name of the
	 folder inside the tarball. */
	let stem: String
	
	init(templateURL: String, version: String, downloadFolder: FilePath, expectedShasum: String?) throws {
		let tarballStringURL = templateURL.applying(xibLocInfo: Str2StrXibLocInfo(simpleSourceTypeReplacements: [OneWordTokens(leftToken: "{{", rightToken: "}}"): { _ in version }], identityReplacement: { $0 })!)
		Config.logger.debug("Tarball URL as string: \(tarballStringURL)")
		
		guard let tarballURL = URL(string: tarballStringURL) else {
			struct TarballURLIsNotValid : Error {var stringURL: String}
			throw TarballURLIsNotValid(stringURL: tarballStringURL)
		}
		guard let tarballPathComponent = FilePath.Component(tarballURL.lastPathComponent) else {
			struct TarballURLIsWeird : Error {var url: URL}
			throw TarballURLIsWeird(url: tarballURL)
		}
		
		self.url = tarballURL
		self.version = version
		self.localPath = downloadFolder.appending(tarballPathComponent)
		
		self.expectedShasum = expectedShasum
		
		/* Let’s compute the stem (always remove extension until we found one that
		 * has a number in it or there are none left). */
		var component = tarballPathComponent
		while !(component.extension?.contains(where: { $0.isNumber }) ?? false), let newComponent = FilePath.Component(component.stem), newComponent != component {
			component = newComponent
		}
		self.stem = component.string
	}
	
	func ensureDownloaded() async throws {
		if Config.fm.fileExists(atPath: localPath.string), try checkShasum(path: localPath) {
			/* File exists and already has correct checksum (or checksum is not checked) */
			Config.logger.info("Reusing downloaded tarball at path \(localPath)")
		} else {
			Config.logger.info("Downloading tarball from \(url)")
			let (tmpFileURL, urlResponse) = try await URLSession.shared.download(from: url, delegate: nil)
			guard let httpURLResponse = urlResponse as? HTTPURLResponse, 200..<300 ~= httpURLResponse.statusCode else {
				struct InvalidURLResponse : Error {var response: URLResponse}
				throw InvalidURLResponse(response: urlResponse)
			}
			/* At some point in the future, FilePath(tmpFileURL) will be possible
			 * (it is already possible when importing System instead of
			 * SystemPackage actually). This init might return nil, so the
			 * tmpFilePath variable would have to be set in the guard above. */
			assert(tmpFileURL.isFileURL)
			let tmpFilePath = FilePath(tmpFileURL.path)
			guard try checkShasum(path: tmpFilePath) else {
				struct InvalidChecksumForDownloadedTarball : Error {}
				throw InvalidChecksumForDownloadedTarball()
			}
			try Config.fm.ensureFileDeleted(path: localPath)
			try Config.fm.moveItem(at: tmpFileURL, to: localPath.url)
			Config.logger.info("Tarball downloaded")
		}
	}
	
	func extract(in folder: FilePath) throws -> FilePath {
		try Config.fm.ensureDirectory(path: folder)
		try Process.spawnAndStreamEnsuringSuccess("/usr/bin/tar", args: ["xf", localPath.string, "-C", folder.string], outputHandler: Process.logProcessOutputFactory())
		
		var isDir = ObjCBool(false)
		let extractedTarballDir = folder.appending(stem)
		guard Config.fm.fileExists(atPath: extractedTarballDir.string, isDirectory: &isDir), isDir.boolValue else {
			struct ExtractedTarballNotFound : Error {var expectedPath: FilePath}
			throw ExtractedTarballNotFound(expectedPath: extractedTarballDir)
		}
		return extractedTarballDir
	}
	
	private func checkShasum(path: FilePath) throws -> Bool {
		guard let expectedShasum = expectedShasum else {
			return true
		}
		
		let fileContents = try Data(contentsOf: path.url)
		return SHA256.hash(data: fileContents).reduce("", { $0 + String(format: "%02x", $1) }) == expectedShasum.lowercased()
	}
	
}
