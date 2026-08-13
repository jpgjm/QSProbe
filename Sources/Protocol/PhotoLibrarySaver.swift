//
//  PhotoLibrarySaver.swift
//  QSProbe
//
//  受信した写真・動画を「写真」App に取り込む。
//
//  AlterSend の `apps/mobile/src/transfer/receive/utils/downloadHandlers.ts` と
//  同じ考え方です。あちらは React Native なので `expo-media-library` の
//  `saveToLibraryAsync` を呼んでいますが、こちらはネイティブなので
//  `PHAssetCreationRequest` を直接使います。判定に使う拡張子の一覧も
//  AlterSend に合わせてあります。
//
//  ## ファイルは「コピー」ではなく「移動」する
//
//  `PHAssetResourceCreationOptions.shouldMoveFile = true` を使います。
//  コピーしてから元を消す方式だと、取り込みの瞬間だけディスクを二重に使います。
//  12 GB の動画を受け取れる実装なので、ここは無視できない差です。
//
//  ## 失敗したら Received に残す
//
//  権限が無い、写真として解釈できない、といった場合は**元の場所に残します**。
//  受け取ったのに何処にも無い、という状態を作らないためです。
//

import Foundation
import Photos

enum PhotoLibrarySaver {

    // AlterSend の IMAGE_EXTENSIONS / VIDEO_EXTENSIONS と同じ内容
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tiff", "tif"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"
    ]

    enum Outcome {
        /// 「写真」に入った。元のファイルは移動済みで、もう存在しない。
        case savedToPhotos
        /// 写真・動画ではないので何もしていない。
        case notMedia
        /// 取り込めなかったので元の場所に残っている。
        case keptInFiles(reason: String)
    }

    static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    private static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 追加のみの権限を要求する。
    ///
    /// `.addOnly` なので、ライブラリの中身を読む権限は要りません。
    /// ユーザーに見えるダイアログも「写真の追加のみ」になります。
    static func requestAddPermission(_ completion: @escaping (Bool) -> Void) {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            completion(true)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
            DispatchQueue.main.async {
                completion(newStatus == .authorized || newStatus == .limited)
            }
        }
    }

    /// 写真・動画なら「写真」へ移す。
    static func save(_ url: URL, completion: @escaping (Outcome) -> Void) {
        guard isMedia(url) else {
            completion(.notMedia)
            return
        }

        requestAddPermission { granted in
            guard granted else {
                completion(.keptInFiles(reason: "「写真」への追加が許可されていません"))
                return
            }

            let resourceType: PHAssetResourceType = isVideo(url) ? .video : .photo
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                // コピーせずに移す。取り込みの瞬間にディスクを二重に使わない。
                options.shouldMoveFile = true
                request.addResource(with: resourceType, fileURL: url, options: options)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.savedToPhotos)
                    } else {
                        let reason = error?.localizedDescription ?? "原因不明"
                        completion(.keptInFiles(reason: reason))
                    }
                }
            }
        }
    }
}
