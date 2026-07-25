import SwiftUI

/// Brick — the iPod's built-in game, driven by the click wheel.
///
/// Played in the LCD's own 320×240 coordinate space, so the physics constants
/// below are in real screen pixels and behave the same at any window size.
struct BrickView: View {
    @Environment(BrickGame.self) private var game

    let unit: CGFloat

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 320

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.screenBacklight))

            for brick in game.bricks where !brick.isBroken {
                let rect = CGRect(
                    x: brick.frame.minX * scale,
                    y: brick.frame.minY * scale,
                    width: brick.frame.width * scale,
                    height: brick.frame.height * scale
                )
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: scale, dy: scale), cornerRadius: scale),
                    with: .color(Palette.screenInk)
                )
            }

            let paddle = CGRect(
                x: game.paddleX * scale,
                y: BrickGame.paddleY * scale,
                width: BrickGame.paddleWidth * scale,
                height: BrickGame.paddleHeight * scale
            )
            context.fill(Path(roundedRect: paddle, cornerRadius: scale), with: .color(Palette.screenInk))

            let ball = CGRect(
                x: (game.ball.x - BrickGame.ballRadius) * scale,
                y: (game.ball.y - BrickGame.ballRadius) * scale,
                width: BrickGame.ballRadius * 2 * scale,
                height: BrickGame.ballRadius * 2 * scale
            )
            context.fill(Path(ellipseIn: ball), with: .color(Palette.screenInk))

            context.draw(
                Text("\(game.score)")
                    .font(.system(size: 11 * unit, weight: .semibold))
                    .foregroundStyle(Palette.screenInkDim),
                at: CGPoint(x: size.width - 16 * unit, y: 12 * unit)
            )

            if game.isOver {
                context.draw(
                    Text(
                        game.hasWon
                            ? String(localized: "brick.won", defaultValue: "You Win", bundle: .module)
                            : String(localized: "brick.over", defaultValue: "Game Over", bundle: .module)
                    )
                    .font(.system(size: 20 * unit, weight: .bold))
                    .foregroundStyle(Palette.screenInk),
                    at: CGPoint(x: size.width / 2, y: size.height / 2)
                )
            }
        }
        .accessibilityLabel(String(localized: "a11y.brick", defaultValue: "Brick game", bundle: .module))
        .accessibilityValue(
            String(
                format: String(localized: "a11y.score", defaultValue: "Score %d", bundle: .module),
                game.score
            )
        )
    }
}

/// Brick's state and physics. Separate from the view so the wheel can drive the
/// paddle through the same input path as every other screen.
@MainActor
@Observable
final class BrickGame {
    struct Brick: Identifiable {
        let id: Int
        let frame: CGRect
        var isBroken = false
    }

    // Field is the LCD area below the status bar: 320 × 218.
    static let fieldWidth: CGFloat = 320
    static let fieldHeight: CGFloat = 218
    static let paddleWidth: CGFloat = 52
    static let paddleHeight: CGFloat = 7
    static let paddleY: CGFloat = 200
    static let ballRadius: CGFloat = 3.5

    private(set) var bricks: [Brick] = []
    private(set) var ball = CGPoint(x: 160, y: 150)
    private(set) var score = 0
    private(set) var isOver = false
    private(set) var hasWon = false

    var paddleX: CGFloat = (fieldWidth - paddleWidth) / 2

    private var velocity = CGVector(dx: 105, dy: -105)
    private var tickTask: Task<Void, Never>?
    private var lastTick: Date?

    init() { reset() }

    func reset() {
        var built: [Brick] = []
        let columns = 8
        let rows = 5
        let brickWidth = Self.fieldWidth / CGFloat(columns)
        let brickHeight: CGFloat = 13
        for row in 0..<rows {
            for column in 0..<columns {
                built.append(
                    Brick(
                        id: row * columns + column,
                        frame: CGRect(
                            x: CGFloat(column) * brickWidth,
                            y: 18 + CGFloat(row) * brickHeight,
                            width: brickWidth,
                            height: brickHeight
                        )
                    )
                )
            }
        }
        bricks = built
        ball = CGPoint(x: Self.fieldWidth / 2, y: 150)
        velocity = CGVector(dx: 105, dy: -105)
        paddleX = (Self.fieldWidth - Self.paddleWidth) / 2
        score = 0
        isOver = false
        hasWon = false
    }

    func start() {
        guard tickTask == nil else { return }
        lastTick = Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                self?.step()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Wheel input: positive steps move the paddle right.
    func movePaddle(by steps: Int) {
        let delta = CGFloat(steps) * 9
        paddleX = min(Self.fieldWidth - Self.paddleWidth, max(0, paddleX + delta))
    }

    private func step() {
        guard !isOver else { return }
        let now = Date()
        // Real elapsed time rather than a fixed step, so the ball travels at
        // the same speed regardless of how the timer actually fires.
        let delta = min(0.05, now.timeIntervalSince(lastTick ?? now))
        lastTick = now

        var next = CGPoint(
            x: ball.x + velocity.dx * delta,
            y: ball.y + velocity.dy * delta
        )

        if next.x < Self.ballRadius {
            next.x = Self.ballRadius
            velocity.dx = abs(velocity.dx)
        } else if next.x > Self.fieldWidth - Self.ballRadius {
            next.x = Self.fieldWidth - Self.ballRadius
            velocity.dx = -abs(velocity.dx)
        }
        if next.y < Self.ballRadius {
            next.y = Self.ballRadius
            velocity.dy = abs(velocity.dy)
        }

        // Paddle
        let paddleRect = CGRect(
            x: paddleX, y: Self.paddleY,
            width: Self.paddleWidth, height: Self.paddleHeight
        )
        if velocity.dy > 0, paddleRect.insetBy(dx: -Self.ballRadius, dy: -Self.ballRadius).contains(next) {
            next.y = Self.paddleY - Self.ballRadius
            velocity.dy = -abs(velocity.dy)
            // Steer off the paddle: hitting the edges angles the ball away.
            let offset = (next.x - paddleRect.midX) / (Self.paddleWidth / 2)
            velocity.dx += offset * 60
            velocity.dx = min(190, max(-190, velocity.dx))
        }

        // Bricks
        for index in bricks.indices where !bricks[index].isBroken {
            let expanded = bricks[index].frame.insetBy(dx: -Self.ballRadius, dy: -Self.ballRadius)
            guard expanded.contains(next) else { continue }
            bricks[index].isBroken = true
            score += 10

            // Bounce off whichever axis the ball entered through.
            let previous = CGPoint(x: ball.x, y: ball.y)
            if previous.y <= bricks[index].frame.minY || previous.y >= bricks[index].frame.maxY {
                velocity.dy = -velocity.dy
            } else {
                velocity.dx = -velocity.dx
            }
            break
        }

        if bricks.allSatisfy(\.isBroken) {
            hasWon = true
            isOver = true
        }
        if next.y > Self.fieldHeight {
            isOver = true
        }

        ball = next
    }
}
