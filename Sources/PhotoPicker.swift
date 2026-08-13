//
//  PhotoPicker.swift
//  QSProbe (M5.1)
//
//  写真 App から写真・動画を選ぶ。
//
//  ## M5 で判明した問題
//
//  `loadFileRepresentation` は **Live Photo を `.pvt` パッケージ (ディレクトリ) として
//  渡してくる**。ディレクトリなので `FileHandle(forReadingFrom:)` が開けず、
//  `IMG_0044.pvt (160 バイト)` という実体のない項目が送信キューに入っていた。
//
//  ## M5.1 の方針
//
//  写真ライブラリ権限を取得し、**`PHAssetResource` 経由**で構成ファイルを
//  1 本ずつ書き出す。これで
//
//    - Live Photo → 静止画 + ペア動画の **2 ファイル**として送れる
//    - 動画 → 元のコーデックのまま (再エンコードなし)
//    - 編集済みなら編集後 (`.fullSize*`)、なければ元データ
//
//  `PHAssetResourceManager.writeData(for:toFile:)` を使うのでメモリに載りません。
//  FlyingCarpet は `requestData` で `NSMutableData` に貯めていますが、
//  大きな動画で jetsam に殺されるため書き出し API を選びました。
//
//  権限が得られなかった場合は従来の `loadFileRepresentation` に落ちます。
//  その際、ディレクトリ (`.pvt` など) は取り扱えないのでスキップします。
//

import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// 写真ライブラリ権限の取得。
enum PhotoLibraryAccess {

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        if isAuthorized {
            completion(true)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                let granted = (status == .authorized || status == .limited)
                if granted {
                    qlog(.ok, "写真ライブラリへのアクセスが許可されました (\(status.rawValue))")
                } else {
                    qlog(.warn, "写真ライブラリへのアクセスが拒否されました。"
                        + "Live Photo のペア動画は送れません")
                }
                completion(granted)
            }
        }
    }
}

struct PhotoPicker: UIViewControllerRepresentable {

    /// Live Photo のペア動画も一緒に送るか。
    let includeLivePhotoVideo: Bool
    /// 選択・書き出しが終わった一時ファイルの URL 群を返す。
    let onPicked: ([URL]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // `photoLibrary:` を渡すと result.assetIdentifier が得られ、PHAsset を引ける。
        // これが PHAssetResource 経由に進むための前提。
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 0  // 0 = 無制限
        configuration.filter = .any(of: [.images, .videos])
        // 元ファイルをそのまま取り出す (再エンコードさせない)
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(includeLivePhotoVideo: includeLivePhotoVideo, onPicked: onPicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        private let includeLivePhotoVideo: Bool
        private let onPicked: ([URL]) -> Void

        /// 同名ファイルが複数選ばれたときに上書きしないための予約表。
        private var usedNames = Set<String>()
        private let lock = NSLock()
        private var collected: [URL] = []

        init(includeLivePhotoVideo: Bool, onPicked: @escaping ([URL]) -> Void) {
            self.includeLivePhotoVideo = includeLivePhotoVideo
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // 二重配信で 2 回走らないようにデリゲートを外す
            picker.delegate = nil
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onPicked([])
                return
            }

            qlog(.info, "PhotoPicker: \(results.count) 件を書き出します")

            let authorized = PhotoLibraryAccess.isAuthorized
            if !authorized {
                qlog(.warn, "PhotoPicker: 写真ライブラリ権限が無いため簡易経路で処理します")
            }

            let group = DispatchGroup()

            for result in results {
                if authorized, let identifier = result.assetIdentifier {
                    group.enter()
                    exportViaAssetResources(identifier: identifier) {
                        group.leave()
                    }
                } else {
                    group.enter()
                    exportViaFileRepresentation(result) {
                        group.leave()
                    }
                }
            }

            group.notify(queue: .main) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let urls = self.collected.sorted { $0.lastPathComponent < $1.lastPathComponent }
                self.lock.unlock()
                qlog(.ok, "PhotoPicker: \(urls.count) 件を取り出しました")
                self.onPicked(urls)
            }
        }

        // MARK: - PHAssetResource 経路 (本命)

        private func exportViaAssetResources(identifier: String, completion: @escaping () -> Void) {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            guard let asset = assets.firstObject else {
                qlog(.warn, "PhotoPicker: PHAsset を取得できません (\(identifier))")
                completion()
                return
            }

            let resources = PHAssetResource.assetResources(for: asset)

            /// 編集済みがあればそちらを、無ければ元データを選ぶ。
            func preferred(
                _ edited: PHAssetResourceType,
                _ original: PHAssetResourceType
            ) -> PHAssetResource? {
                resources.first { $0.type == edited } ?? resources.first { $0.type == original }
            }

            var wanted: [PHAssetResource] = []
            if let photo = preferred(.fullSizePhoto, .photo) {
                wanted.append(photo)
            }
            if let video = preferred(.fullSizeVideo, .video) {
                wanted.append(video)
            }
            if includeLivePhotoVideo, let paired = preferred(.fullSizePairedVideo, .pairedVideo) {
                wanted.append(paired)
            }

            guard !wanted.isEmpty else {
                qlog(.warn, "PhotoPicker: 書き出せるリソースがありません — "
                    + "\(resources.map { "\($0.type.rawValue)" }.joined(separator: ","))")
                completion()
                return
            }

            if wanted.count > 1 {
                qlog(.info, "PhotoPicker: Live Photo / 複数リソース — \(wanted.count) ファイルとして送ります")
            }

            let innerGroup = DispatchGroup()
            for resource in wanted {
                innerGroup.enter()
                let destination = reserveURL(resource.originalFilename)

                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true  // iCloud 上にしかない場合に備える

                // writeData はディスクへ直接書く。requestData のように
                // メモリへ全部載せないので、大きな動画でも jetsam に殺されない。
                PHAssetResourceManager.default().writeData(
                    for: resource,
                    toFile: destination,
                    options: options
                ) { [weak self] error in
                    defer { innerGroup.leave() }
                    if let error {
                        qlog(.warn, "PhotoPicker: \(resource.originalFilename) の書き出しに失敗 — \(error)")
                        try? FileManager.default.removeItem(at: destination)
                        return
                    }
                    self?.lock.lock()
                    self?.collected.append(destination)
                    self?.lock.unlock()
                }
            }
            innerGroup.notify(queue: .global()) {
                completion()
            }
        }

        // MARK: - フォールバック経路

        private func exportViaFileRepresentation(
            _ result: PHPickerResult,
            completion: @escaping () -> Void
        ) {
            guard result.itemProvider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else {
                qlog(.warn, "PhotoPicker: 取り出せない項目をスキップしました")
                completion()
                return
            }

            result.itemProvider.loadFileRepresentation(
                forTypeIdentifier: UTType.item.identifier
            ) { [weak self] url, error in
                defer { completion() }
                guard let self else { return }
                guard let url else {
                    qlog(.warn, "PhotoPicker: 読み込みに失敗 — \(error?.localizedDescription ?? "不明")")
                    return
                }

                // Live Photo は `.pvt` パッケージ (ディレクトリ) で来る。
                // 単一ファイルとしては扱えないのでスキップする。
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    qlog(.warn, "PhotoPicker: \(url.lastPathComponent) はパッケージのためスキップしました。"
                        + "写真ライブラリへのアクセスを許可すると送れます")
                    return
                }

                let destination = self.reserveURL(url.lastPathComponent)
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: url, to: destination)
                    self.lock.lock()
                    self.collected.append(destination)
                    self.lock.unlock()
                } catch {
                    qlog(.warn, "PhotoPicker: コピーに失敗 — \(error)")
                }
            }
        }

        // MARK: - 名前の予約

        private func reserveURL(_ filename: String) -> URL {
            lock.lock()
            defer { lock.unlock() }

            let safeName = filename.isEmpty ? "item" : filename
            let ext = (safeName as NSString).pathExtension
            let stem = (safeName as NSString).deletingPathExtension
            var candidate = safeName
            var counter = 2
            while usedNames.contains(candidate) {
                candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                counter += 1
            }
            usedNames.insert(candidate)

            let url = Outbox.directory.appendingPathComponent(candidate)
            // writeData は既存ファイルがあると失敗するので先に消しておく
            try? FileManager.default.removeItem(at: url)
            return url
        }
    }
}
