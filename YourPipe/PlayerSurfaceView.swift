import SwiftUI
import AVFoundation

struct PlayerSurfaceView: UIViewRepresentable {
    let player: AVPlayer?
    let onLayerReady: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerSurfaceContainer {
        let view = PlayerSurfaceContainer()
        view.playerLayer.videoGravity = .resizeAspect
        onLayerReady(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceContainer, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerSurfaceContainer: UIView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
