@testable import AzureBlobRepo
import Foundation
import Testing

struct AzureBlobRepoTests {
    let key = AzureBlobRepo.Credential.sharedKey(Data("key".utf8))

    @Test func virtualHostURL() throws {
        let repo = try AzureBlobRepo("https://acct.blob.core.windows.net/munki/repo/root", credential: key)
        #expect(repo.account == "acct")
        #expect(repo.containerPath == "/munki")
        #expect(repo.prefix == "repo/root")
    }

    @Test func pathStyleURL() throws {
        let repo = try AzureBlobRepo("http://127.0.0.1:10000/devstoreaccount1/munki-repo", credential: key)
        #expect(repo.account == "devstoreaccount1")
        #expect(repo.containerPath == "/devstoreaccount1/munki-repo")
        #expect(repo.prefix == "")
        let request = try repo.makeRequest("GET", blob: "pkgs/My App 1.0.pkg")
        #expect(request.url?.absoluteString ==
            "http://127.0.0.1:10000/devstoreaccount1/munki-repo/pkgs/My%20App%201.0.pkg")
    }

    @Test func urlWithoutContainerFails() {
        #expect(throws: (any Error).self) { try AzureBlobRepo("https://acct.blob.core.windows.net/", credential: key) }
        #expect(throws: (any Error).self) { try AzureBlobRepo("http://localhost:10000/devstoreaccount1", credential: key) }
        #expect(throws: (any Error).self) { try AzureBlobRepo("s3://bucket/repo", credential: key) }
    }

    @Test func sasTokenAppendedToQuery() throws {
        let repo = try AzureBlobRepo("https://acct.blob.core.windows.net/munki", credential: .sas("sv=x&sig=y"))
        let request = try repo.makeRequest("GET", blob: nil, query: ["comp": "list", "restype": "container"])
        #expect(request.url?.query == "comp=list&restype=container&sv=x&sig=y")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func stringToSign() throws {
        let repo = try AzureBlobRepo("https://acct.blob.core.windows.net/munki", credential: key)
        let headers = ["Content-Type": "application/octet-stream", "x-ms-version": "v", "x-ms-date": "d",
                       "x-ms-blob-type": "BlockBlob"]
        #expect(
            repo.stringToSign("PUT", path: "/munki/a%20b", query: ["comp": "block", "blockid": "MDA="],
                              headers: headers, contentLength: 5) ==
            "PUT\n\n\n5\n\napplication/octet-stream\n\n\n\n\n\n\n"
                + "x-ms-blob-type:BlockBlob\nx-ms-date:d\nx-ms-version:v\n"
                + "/acct/munki/a%20b\nblockid:MDA=\ncomp:block"
        )
    }

    @Test func blobListParser() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <EnumerationResults ServiceEndpoint="x" ContainerName="munki">
          <Prefix>pkgsinfo/</Prefix>
          <Blobs>
            <Blob><Name>pkgsinfo/a.plist</Name><Properties/></Blob>
            <Blob><Name>pkgsinfo/sub/b &amp; c.plist</Name><Properties/></Blob>
          </Blobs>
          <NextMarker>token</NextMarker>
        </EnumerationResults>
        """
        let page = try BlobListParser.parse(Data(xml.utf8))
        #expect(page.names == ["pkgsinfo/a.plist", "pkgsinfo/sub/b & c.plist"])
        #expect(page.nextMarker == "token")
    }
}
