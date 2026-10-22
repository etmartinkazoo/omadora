import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland

// Desktop wallpaper, drawn on the background layer of every screen.
// Shows the theme's wallpaper image (or your own: `omadora-theme wallpaper
// PATH`); themes without images get a generated one from their palette: crisp
// at any resolution and nothing to download.
Scope {
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "omadora-wallpaper"
            color: Theme.darkerBackground

            // Generated wallpaper
            Item {
                anchors.fill: parent
                visible: Theme.wallpaper === "" || image.status === Image.Error

                Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Theme.background }
                        GradientStop { position: 1.0; color: Theme.darkerBackground }
                    }
                }

                component Glow: Shape {
                    id: glow
                    property color tint
                    property real strength: 0.2
                    property real cx
                    property real cy
                    property real radius
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeColor: "transparent"
                        fillGradient: RadialGradient {
                            centerX: glow.cx; centerY: glow.cy; centerRadius: glow.radius
                            focalX: glow.cx; focalY: glow.cy
                            GradientStop { position: 0.0; color: Qt.alpha(glow.tint, glow.strength) }
                            GradientStop { position: 1.0; color: Qt.alpha(glow.tint, 0) }
                        }
                        PathRectangle { width: glow.width; height: glow.height }
                    }
                }

                Glow {
                    tint: Theme.accent
                    strength: Theme.isLight ? 0.16 : 0.24
                    cx: win.width * 0.82; cy: win.height * 0.12
                    radius: Math.max(win.width, win.height) * 0.62
                }
                Glow {
                    tint: Theme.magenta
                    strength: Theme.isLight ? 0.08 : 0.12
                    cx: win.width * 0.08; cy: win.height * 0.95
                    radius: Math.max(win.width, win.height) * 0.5
                }

                // The omadora mark as a faint outline: one tall tile, two stacked.
                Item {
                    readonly property real u: Math.min(win.width, win.height) * 0.0072
                    width: 64 * u
                    height: 64 * u
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.rightMargin: win.width * 0.08
                    anchors.bottomMargin: win.height * 0.14
                    opacity: Theme.isLight ? 0.10 : 0.07

                    Repeater {
                        model: [[10, 10, 20, 44], [34, 34, 20, 20], [34, 10, 20, 20]]
                        delegate: Rectangle {
                            required property var modelData
                            x: modelData[0] * parent.u
                            y: modelData[1] * parent.u
                            width: modelData[2] * parent.u
                            height: modelData[3] * parent.u
                            radius: 4 * parent.u
                            color: "transparent"
                            border.color: Theme.textPrimary
                            border.width: Math.max(1, 0.8 * parent.u)
                        }
                    }
                }
            }

            Image {
                id: image
                anchors.fill: parent
                visible: Theme.wallpaper !== "" && status === Image.Ready
                source: Theme.wallpaper !== "" ? "file://" + Theme.wallpaper : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                // Decode at screen size, not the file's (4K+ images would cost
                // 100+ MB of RAM each otherwise).
                sourceSize.width: win.width * (win.modelData.devicePixelRatio || 1)
                sourceSize.height: win.height * (win.modelData.devicePixelRatio || 1)
            }
        }
    }
}
