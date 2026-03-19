# Magnetic - Claude Code Guidelines

## Performance Warning Rule

This project uses Metal shaders for real-time rendering on iOS devices. GPU performance is critical.

When the user requests a feature that is likely to increase GPU/CPU load significantly, **always warn them before implementing**. Examples of heavy operations:

- Adding FBM noise loops (each octave = more texture reads per pixel)
- Domain warping (noise-of-noise compounds cost exponentially)
- Additional ray march steps or secondary ray casts
- New per-pixel loops in fragment shaders
- Complex procedural backgrounds with many noise layers
- Adding more render passes or post-processing effects

In these cases, ask:
"This will increase GPU load and may cause frame drops. Proceed anyway?"

If the user agrees, implement it. If not, suggest a lighter alternative.

## Project Architecture

- **Shaders.metal**: Fragment/vertex shaders for 3D ray-marched metaballs. Performance-sensitive — every operation runs per-pixel per-frame.
- **MetaballSimulation.swift**: CPU-side physics. Runs every frame.
- **MetalMetaballView.swift**: Metal rendering bridge (UIViewRepresentable + MTKViewDelegate).
- **ContentView.swift**: Main UI, double-tap handling, state management.
- **SettingsView.swift**: Bottom sheet settings panel.
- **AudioEngine.swift**: Microphone input and beat detection.
- **VideoRecorder.swift**: Screen recording to camera roll.

## Coding Preferences

- Language: Swift + Metal Shading Language
- UI: SwiftUI (no Combine — use async/await)
- Keep shader code lean. Prefer `vnoise` (single sample) over `fbm3` (3 samples) over full `fbm` (5 samples) when visual quality allows.
- Star twinkle should be subtle and slow, not rapid flashing.
