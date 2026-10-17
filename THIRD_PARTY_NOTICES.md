# Third-party components

SoundOff's repository contains its own Swift source, configuration and tests. It includes no third-party framework source or binaries.

- **Apple AppKit, AVFoundation, Core Audio, Audio Toolbox, Synchronization and Service Management:** provided by macOS and the Apple development tools, under Apple's applicable terms. Audio Unit effects are loaded from macOS rather than redistributed.
- **BlackHole 2ch:** a separate required audio driver by Existential Audio. It must be obtained from [the official developer](https://existential.audio/blackhole/). Its source is [available separately](https://github.com/ExistentialAudio/BlackHole) under GPLv3; official binaries, branding and installer terms are controlled by Existential Audio. SoundOff neither includes nor modifies the driver.
- **GitHub Actions checkout:** used only by the CI workflow; its repository and license are available at [actions/checkout](https://github.com/actions/checkout).
